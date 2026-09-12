// 指定レポート Ch.12 の符号付き block・固定符号割当・PackBits に基づく。
import Foundation

final class StuffItMethod6: Decompressor {
    private let source: any ByteSource
    private let end: UInt64
    private var position: UInt64
    private let translation: UnsafeMutablePointer<UInt8>
    private let tree: StuffItPrefixTree
    private var input: StuffItPackedInput?
    private var huffman = false
    private var intermediate: UInt64 = 0
    private var remaining: UInt64
    private var pending = 0
    private var literalRun = false
    private var repeated: UInt8 = 0
    var isFinished: Bool { remaining == 0 }

    init(source: any ByteSource, offset: UInt64, stored: UInt64, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(UInt64(256 + (257 * 13 + 1) * 3 * MemoryLayout<Int>.stride), limit: limits.maxDictionarySize)
        end = try Checked.add(offset, stored)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source; position = offset; remaining = size
        tree = try Self.codebook()
        translation = .allocate(capacity: 256); translation.initialize(repeating: 0, count: 256)
    }
    deinit { translation.deallocate() }

    static func codebook() throws -> StuffItPrefixTree {
        let runs = [(1, 3), (1, 4), (4, 5), (12, 6), (32, 7), (16, 8), (49, 9),
                    (2, 10), (2, 9), (40, 10), (95, 11), (2, 13), (1, 12)]
        let tree = StuffItPrefixTree(capacity: 257 * 13 + 1)
        var code: UInt64 = 0, previousLength = 3, symbol = 0
        for (count, length) in runs {
            for _ in 0..<count {
                if symbol > 0 {
                    if length >= previousLength { code = (code + 1) << (length - previousLength) }
                    else { code = (code >> (previousLength - length)) + 1 }
                }
                try tree.insert(symbol: symbol, code: code, length: length)
                previousLength = length; symbol += 1
            }
        }
        return tree
    }

    private func startBlock() throws {
        guard end - position >= 4 else { throw KaitoError.truncated }
        let header = try readByteRange(source: source, offset: position, count: 4)
        // Int64 へ広げてから絶対値を取るため、Int32.min もオーバーフローしない。
        let signed = Int64(Int32(bitPattern: UInt32(StuffItHeader.be32(header, 0))))
        let extent = UInt64(signed < 0 ? -signed : signed)
        guard extent >= (signed < 0 ? 4 : 10), extent <= end - position else {
            throw KaitoError.malformed("StuffIt method 6 block extent")
        }
        let block = try StuffItPackedInput(source: source, offset: position + 4, size: extent - 4)
        position += extent; huffman = signed > 0
        if huffman {
            intermediate = UInt64(try block.bits(32, lsb: false))
            let count = try block.bits(16, lsb: false)
            guard count <= 256, UInt64(count) <= extent - 10 else { throw KaitoError.malformed("StuffIt method 6 translation count") }
            for i in 0..<count { translation[i] = try block.byte() }
        } else { intermediate = extent - 4 }
        input = block
    }

    private func intermediateByte() throws -> UInt8 {
        guard intermediate > 0, let input else { throw KaitoError.malformed("StuffIt method 6 PackBits operand") }
        let symbol = try huffman ? tree.decode(input, lsb: false) : Int(input.byte())
        guard symbol < 256 else { throw KaitoError.malformed("StuffIt method 6 early stop") }
        intermediate -= 1
        return huffman ? translation[symbol] : UInt8(symbol)
    }

    private func token() throws {
        while pending == 0 {
            while intermediate == 0 { try startBlock() }
            let control = Int(Int8(bitPattern: try intermediateByte()))
            if control == -128 { continue }
            literalRun = control >= 0
            pending = literalRun ? control + 1 : 1 - control
            guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt method 6 output extent") }
            if literalRun {
                guard UInt64(pending) <= intermediate else { throw KaitoError.malformed("StuffIt method 6 literal extent") }
            } else { repeated = try intermediateByte() }
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            if pending == 0 { try token() }
            destination[i] = try literalRun ? intermediateByte() : repeated
            pending -= 1; remaining -= 1
        }
        // 最終 block の宣言 I も検証する。末尾の PackBits no-op は許容する。
        if remaining == 0 {
            while intermediate > 0 {
                guard try intermediateByte() == 128 else { throw KaitoError.malformed("StuffIt method 6 trailing intermediate bytes") }
            }
        }
        return count
    }
}
