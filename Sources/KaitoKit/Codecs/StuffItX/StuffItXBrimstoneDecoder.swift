// 前処理の中間長が不明な場合は root escape まで読む。Blend は指定長で停止する。
import Foundation

final class StuffItXBrimstoneDecoder: Decompressor {
    let model: StuffItXBrimstoneModel
    private var remaining: UInt64?
    private let outputLimit: UInt64
    private var produced: UInt64 = 0
    private(set) var isFinished = false

    init(input: StuffItXBitReader, size: UInt64?, limits: ReadLimits) throws {
        let exponent = Int(try input.byte()), order = Int(try input.byte())
        guard (0..<31).contains(exponent) else { throw KaitoError.malformed("StuffIt X Brimstone memory exponent") }
        guard (1...255).contains(order) else { throw KaitoError.malformed("StuffIt X Brimstone order") }
        try Checked.size(UInt64(1) << exponent, limit: limits.maxDictionarySize)
        let range = try StuffItXRangeDecoder(input: input, explicitLower: true)
        model = try StuffItXBrimstoneModel(range: range, exponent: exponent, order: order, limits: limits)
        remaining = size; outputLimit = limits.maxTotalUncompressedSize
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        if remaining == 0 { isFinished = true; return 0 }
        let n = Int(min(UInt64(buffer.count), remaining ?? UInt64(buffer.count)))
        let bytes = buffer.bindMemory(to: UInt8.self)
        var written = 0
        while written < n {
            guard let byte = try model.decodeByte() else {
                if let remaining, remaining != UInt64(written) { throw KaitoError.truncated }
                isFinished = true; break
            }
            guard produced < outputLimit else { throw KaitoError.limitExceeded("StuffIt X Brimstone output") }
            bytes[written] = byte; written += 1; produced += 1
        }
        if remaining != nil { remaining! -= UInt64(written) }
        return written
    }
}
