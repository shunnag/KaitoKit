import Foundation

// 公開ドメイン原典 Coder.hpp の carryless range coder。
// 正規化の位置は Model.cpp が決めるため、区間更新とは分ける。
final class PPMdVarIRangeDecoder {
    private let source: any ByteSource
    private let endOffset: UInt64
    private var sourceOffset: UInt64
    private var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    private var byteOffset = 0
    private var byteCount = 0
    private var low: UInt32 = 0
    private var code: UInt32 = 0
    private var range = UInt32.max
    private var scale = 0

    init(source: any ByteSource, offset: UInt64, endOffset: UInt64) throws {
        guard offset <= endOffset, endOffset <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.sourceOffset = offset
        self.endOffset = endOffset
        for _ in 0..<4 { code = (code << 8) | UInt32(try readByte()) }
    }

    func threshold(total: Int) throws -> Int {
        guard total > 0, total <= Int(UInt16.max) else {
            throw KaitoError.malformed("invalid PPMd var.I frequency total")
        }
        scale = total
        range /= UInt32(total)
        return try currentCount()
    }

    func shiftThreshold() throws -> Int {
        scale = 1 << 14
        range >>= 14
        return try currentCount()
    }

    private func currentCount() throws -> Int {
        guard range != 0 else { throw KaitoError.malformed("PPMd var.I range collapsed") }
        let value = (code &- low) / range
        guard value < UInt32(scale) else {
            throw KaitoError.malformed("PPMd var.I threshold is outside the model")
        }
        return Int(value)
    }

    func remove(low start: Int, high: Int) throws {
        guard start >= 0, start < high, high <= scale else {
            throw KaitoError.malformed("invalid PPMd var.I subrange")
        }
        low = low &+ range &* UInt32(start)
        range = range &* UInt32(high - start)
        guard range != 0 else { throw KaitoError.malformed("PPMd var.I range collapsed") }
    }

    func normalize() throws {
        // 各反復は圧縮範囲内の一バイトを消費し、無限ループを防ぐ。
        while true {
            if (low ^ (low &+ range)) >= 1 << 24 {
                if range >= 1 << 15 { return }
                range = (0 &- low) & ((1 << 15) - 1)
                guard range != 0 else { throw KaitoError.malformed("PPMd var.I normalization collapsed") }
            }
            code = (code << 8) | UInt32(try readByte())
            range <<= 8
            low <<= 8
        }
    }

    private func readByte() throws -> UInt8 {
        if byteOffset == byteCount {
            guard sourceOffset < endOffset else { throw KaitoError.truncated }
            let requested = Int(min(UInt64(bytes.count), endOffset - sourceOffset))
            // 読み込み失敗後に古いバッファを再利用しないよう、位置と有効長を同時に初期化する。
            byteOffset = 0
            byteCount = 0
            byteCount = try bytes.withUnsafeMutableBytes { storage in
                try source.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                    at: sourceOffset
                )
            }
            guard byteCount > 0, byteCount <= requested else { throw KaitoError.truncated }
            sourceOffset = try Checked.add(sourceOffset, UInt64(byteCount))
        }
        let result = bytes[byteOffset]
        byteOffset += 1
        return result
    }
}
