// 指定資料 Ch.07 §6 の六 octet 窓と 8192 の曖昧性規則を再現する。
import Foundation

final class StuffItXBlend: Decompressor {
    private let input: StuffItXBitReader
    private let limits: ReadLimits
    private var remaining: UInt64
    private let knownLength: Bool
    private var blockRemaining: UInt64 = 0
    private var decoder: (any Decompressor)?
    private(set) var isFinished = false

    init(input: StuffItXBitReader, size: UInt64?, limits: ReadLimits) {
        self.input = input; remaining = size ?? limits.maxTotalUncompressedSize; knownLength = size != nil; self.limits = limits
    }
    static func acceptsHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 6, bytes[0] == 0x77, bytes[1] <= 3 else { return false }
        let ambiguous = (2...4).contains { bytes[$0] == 0x77 && bytes[$0 + 1] <= 3 }
        let length = bytes[2...5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return !ambiguous || length % 8192 == 0
    }
    private func nextBlock() throws {
        // 入力を subdecoder と共有し、pread の先読み位置ではなく消費済み octet の位置を使う。
        guard input.source.length - input.offset >= 6 else {
            guard !knownLength else { throw KaitoError.truncated }
            while !input.isAtEnd { _ = try input.byte() }
            isFinished = true; return
        }
        var header: [UInt8] = []
        for _ in 0..<6 { header.append(try input.byte()) }
        while !Self.acceptsHeader(header) {
            if input.isAtEnd && !knownLength { isFinished = true; return }
            header.removeFirst(); header.append(try input.byte())
        }
        let size = header[2...5].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard size <= remaining else { throw KaitoError.malformed("StuffIt X Blend block length") }
        blockRemaining = size
        let method = Int(header[1])
        switch method {
        case 0: decoder = nil
        case 1: decoder = try StuffItXDarkhorse(input: input, exponent: Int(input.byte()), size: size, limits: limits)
        case 2: decoder = try StuffItXCyanide(input: input, size: size, limits: limits)
        default: decoder = try StuffItXBrimstoneDecoder(input: input, size: size, limits: limits)
        }
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        if knownLength && remaining == 0 { isFinished = true; return 0 }
        while blockRemaining == 0 {
            if !knownLength && input.isAtEnd { isFinished = true; return 0 }
            try nextBlock()
            if isFinished { return 0 }
        }
        let count = Int(min(UInt64(buffer.count), blockRemaining)), actual: Int
        if let decoder {
            actual = try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]))
            guard actual > 0, actual <= count else { throw KaitoError.truncated }
        } else {
            let output = buffer.bindMemory(to: UInt8.self)
            for i in 0..<count { output[i] = try input.byte() }; actual = count
        }
        blockRemaining -= UInt64(actual); remaining -= UInt64(actual)
        if blockRemaining == 0 { decoder = nil }
        return actual
    }
}
