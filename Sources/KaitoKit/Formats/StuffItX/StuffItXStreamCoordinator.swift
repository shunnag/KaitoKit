// 7z と同じ寿命で solid decoder を保持し、先頭からの checksum を終端で照合する。
import CryptoKit
import Foundation

final class StuffItXStreamCoordinator {
    private let source: any ByteSource
    let element: StuffItXElement
    let size: UInt64
    private let limits: ReadLimits
    private var password: String?
    private(set) var crypto: StuffItXCrypto?
    private var decoder: (any Decompressor)?
    private var position: UInt64 = 0
    private var generation: UInt64 = 0
    private var crc = CRC32()
    private var md5 = Insecure.MD5()
    private var verified = false
    private var expected: [(UInt64, [UInt8])] = []
    var hasRetainedDecoderState: Bool { decoder != nil }

    init(source: any ByteSource, element: StuffItXElement, size: UInt64, limits: ReadLimits, password: String? = nil) {
        self.source = source; self.element = element; self.size = size; self.limits = limits
        self.password = password
    }
    func setPassword(_ password: String?) {
        // String の正準等価比較では、異なる UTF-8 password の鍵を再利用してしまう。
        guard self.password.map({ Array($0.utf8) }) != password.map({ Array($0.utf8) }) else { return }
        self.password = password; crypto = nil; decoder = nil; verified = false; position = 0
        generation &+= 1
    }
    static func validateAlgorithms(_ algorithms: [StuffItXAlgorithm]) throws {
        guard algorithms.filter({ $0.key == 1 }).count <= 1 else { throw KaitoError.unsupportedMethod("StuffIt X repeated compression") }
        guard algorithms.filter({ $0.key == 3 }).count <= 1 else { throw KaitoError.unsupportedMethod("StuffIt X repeated preprocessing") }
        for algorithm in algorithms {
            switch algorithm.key {
            case 1: break
            case 2, 6:
                guard algorithm.value <= 1 else { throw KaitoError.unsupportedMethod("StuffIt X digest \(algorithm.value)") }
            case 3:
                guard algorithm.value == 0 || algorithm.value == 2 else { throw KaitoError.unsupportedMethod("StuffIt X preprocessing \(algorithm.value)") }
            case 4: break
            case 5: throw KaitoError.unsupportedMethod("StuffIt X recovery \(algorithm.value)")
            default: throw KaitoError.unsupportedMethod("StuffIt X algorithm \(algorithm.key):\(algorithm.value)")
            }
        }
        try StuffItXCrypto.validate(algorithms)
    }
    private func restart() throws {
        try Self.validateAlgorithms(element.algorithms)
        var input: any ByteSource = try StuffItXFramedInput(source: source, ranges: element.data)
        if element.algorithms.contains(where: { $0.key == 4 }) {
            guard let password else { throw KaitoError.passwordRequired }
            if crypto == nil { crypto = try StuffItXCrypto(password: password, algorithms: element.algorithms) }
            input = try crypto!.decrypt(input)
        }
        var expected: [(UInt64, [UInt8])] = []
        let digests = element.algorithms.filter { $0.key == 2 || $0.key == 6 }
        if !digests.isEmpty {
            // 本 slice は最終出力の単一 digest の範囲。層間・反復 digest は後続で扱う。
            guard digests.count == 1 else { throw KaitoError.unsupportedMethod("StuffIt X multiple digest scopes") }
            let count = digests[0].value == 0 ? 4 : 16
            let bytes: [UInt8]
            if digests[0].value == 0 {
                guard let first = element.checksums.first, first.upperBound - first.lowerBound == UInt64(count) else {
                    throw KaitoError.malformed("StuffIt X checksum block length")
                }
                bytes = try readByteRange(source: source, offset: first.lowerBound, count: count)
            } else {
                let framed = try StuffItXFramedInput(source: source, ranges: element.checksums)
                guard framed.length == 16 else { throw KaitoError.malformed("StuffIt X MD5 length") }
                bytes = try readByteRange(source: framed, offset: 0, count: count)
            }
            expected.append((digests[0].value, bytes))
        }
        let preprocessing = element.algorithms.first { $0.key == 3 }?.value
        // English の中間長には marker と縮約 token が含まれ、最終 fork 長とは一致しない。
        var decoder = try StuffItXCodec.make(method: element.compression, source: input, size: preprocessing == 0 ? nil : size, limits: limits)
        if preprocessing == 0 { decoder = try StuffItXEnglish(decoder: decoder, size: size) }
        if preprocessing == 2 { decoder = StuffItXX86(decoder: decoder, size: size) }
        self.decoder = decoder; self.expected = expected
        position = 0; crc = CRC32(); md5 = Insecure.MD5(); verified = false
    }
    func stream(offset: UInt64, length: UInt64) throws -> any Decompressor {
        let end = try Checked.add(offset, length)
        guard end <= size else { throw KaitoError.malformed("StuffIt X fork interval") }
        generation = try Checked.add(generation, 1)
        do {
            if offset < position || (decoder == nil && !verified) { try restart() }
            if position < offset {
                try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { scratch in
                    while position < offset {
                        let n = Int(min(UInt64(scratch.count), offset - position))
                        _ = try consume(UnsafeMutableRawBufferPointer(rebasing: scratch[..<n]))
                    }
                }
            }
            if length == 0 && end == size { try finish() }
        } catch { decoder = nil; verified = false; throw error }
        return StuffItXStreamRange(coordinator: self, generation: generation, length: length, endsStream: end == size)
    }
    private func consume(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let decoder else { throw KaitoError.malformed("StuffIt X missing decoder") }
        let n = try decoder.read(into: buffer)
        guard n > 0, n <= buffer.count else { throw KaitoError.truncated }
        position = try Checked.add(position, UInt64(n))
        let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<n])
        if expected.contains(where: { $0.0 == 0 }) { crc.update(bytes) }
        if expected.contains(where: { $0.0 == 1 }) { md5.update(bufferPointer: bytes) }
        return n
    }
    fileprivate func read(generation expectedGeneration: UInt64, remaining: inout UInt64,
                          endsStream: Bool, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard generation == expectedGeneration else { throw KaitoError.malformed("a newer StuffIt X stream invalidated this stream") }
        if remaining == 0 { if endsStream { try finish() }; return 0 }
        if buffer.isEmpty { return 0 }
        do {
            let count = Int(min(UInt64(buffer.count), remaining))
            let n = try consume(UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]))
            remaining -= UInt64(n)
            if remaining == 0 && endsStream { try finish() }
            return n
        } catch { decoder = nil; verified = false; throw error }
    }
    private func finish() throws {
        if verified { return }
        guard position == size, let decoder else { throw KaitoError.malformed("StuffIt X stream length") }
        defer { self.decoder = nil }
        var extra: UInt8 = 0
        guard try withUnsafeMutableBytes(of: &extra, { try decoder.read(into: $0) }) == 0, decoder.isFinished else {
            throw KaitoError.malformed("StuffIt X excess output")
        }
        for (method, value) in expected {
            let actual = method == 0 ? (0..<4).map { UInt8(truncatingIfNeeded: crc.value >> (24 - $0 * 8)) } : Array(md5.finalize())
            guard actual == value else { throw KaitoError.checksumMismatch(entry: -1) }
        }
        verified = true
    }
}

private final class StuffItXStreamRange: Decompressor {
    let coordinator: StuffItXStreamCoordinator
    let generation: UInt64
    let endsStream: Bool
    var remaining: UInt64
    init(coordinator: StuffItXStreamCoordinator, generation: UInt64, length: UInt64, endsStream: Bool) {
        self.coordinator = coordinator; self.generation = generation; remaining = length; self.endsStream = endsStream
    }
    var isFinished: Bool { remaining == 0 }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try coordinator.read(generation: generation, remaining: &remaining, endsStream: endsStream, into: buffer)
    }
}
