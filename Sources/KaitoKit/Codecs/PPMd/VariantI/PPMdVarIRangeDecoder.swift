import Foundation

// 公開ドメイン原典 Coder.hpp の carryless range coder。
// 正規化の位置は Model.cpp が決めるため、区間更新とは分ける。
// 兄弟: variant H の SevenZipPPMdRangeDecoder（7z）と RARPPMdRangeDecoder（RAR）は PPMd7RangeDecoding
// 経由で PPMd7Model が使う。一覧: Core/BitReader.swift の先頭。
final class PPMdVarIRangeDecoder {
    private static let bufferSize = 64 * 1024
    private let source: any ByteSource
    private let endOffset: UInt64
    private var sourceOffset: UInt64
    private let bytes: UnsafeMutableRawPointer
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
        // Allocate after validating the range. Any subsequent throw occurs with
        // a fully initialized instance, so deinit releases the owned buffer.
        self.bytes = .allocate(byteCount: Self.bufferSize, alignment: 1)
        for _ in 0..<4 { code = (code << 8) | UInt32(try readByte()) }
    }

    @inline(__always)
    func threshold(total: Int) throws -> Int {
        guard total > 0, total <= Int(UInt16.max) else {
            throw KaitoError.malformed("invalid PPMd var.I frequency total")
        }
        scale = total
        range /= UInt32(total)
        return try currentCount()
    }

    @inline(__always)
    func shiftThreshold() throws -> Int {
        scale = 1 << 14
        range >>= 14
        return try currentCount()
    }

    @inline(__always)
    private func currentCount() throws -> Int {
        guard range != 0 else { throw KaitoError.malformed("PPMd var.I range collapsed") }
        let value = (code &- low) / range
        guard value < UInt32(scale) else {
            throw KaitoError.malformed("PPMd var.I threshold is outside the model")
        }
        return Int(value)
    }

    @inline(__always)
    func remove(low start: Int, high: Int) throws {
        guard start >= 0, start < high, high <= scale else {
            throw KaitoError.malformed("invalid PPMd var.I subrange")
        }
        low = low &+ range &* UInt32(start)
        range = range &* UInt32(high - start)
        guard range != 0 else { throw KaitoError.malformed("PPMd var.I range collapsed") }
    }

    @inline(__always)
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

    deinit { bytes.deallocate() }

    @inline(__always)
    private func readByte() throws -> UInt8 {
        // refill publishes only a validated count; 0 <= byteOffset < byteCount
        // covers this load even when the ByteSource returns a short read.
        if byteOffset == byteCount { try refill() }
        let result = bytes.load(fromByteOffset: byteOffset, as: UInt8.self)
        byteOffset += 1
        return result
    }

    @inline(never)
    private func refill() throws {
        guard sourceOffset < endOffset else { throw KaitoError.truncated }
        let requested = Int(min(UInt64(Self.bufferSize), endOffset - sourceOffset))
        byteOffset = 0
        byteCount = 0
        let count = try source.read(
            into: UnsafeMutableRawBufferPointer(start: bytes, count: requested),
            at: sourceOffset
        )
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        byteCount = count
        sourceOffset = try Checked.add(sourceOffset, UInt64(byteCount))
    }
}
