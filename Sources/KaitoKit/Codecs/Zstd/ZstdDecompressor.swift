import Foundation

// 指定範囲をブロック単位で読み、独立したフレームを連続出力として公開する。
final class ZstdDecompressor: Decompressor {
    private let input: ZstdInput
    private let limits: ReadLimits
    private let expectedSize: UInt64?
    private let tuning: ZstdTuning
    private var frame: ZstdFrameDecoder?
    private var pending = UnsafeRawBufferPointer(start: nil, count: 0)
    private var pendingOffset = 0
    private var produced: UInt64 = 0
    private var sawFrame = false
    private var terminalError: (any Error)?
    private(set) var isFinished = false
    var allocatedScratchBytes: Int { frame?.allocatedScratchBytes ?? 0 }
    var allocatedBufferBytes: Int { frame?.allocatedBufferBytes ?? 0 }

    init(source: any ByteSource, offset: UInt64 = 0, compressedSize: UInt64? = nil,
         expectedSize: UInt64? = nil, limits: ReadLimits = ReadLimits(), tuning: ZstdTuning = .default) throws {
        input = try ZstdInput(source: source, offset: offset,
                              size: compressedSize ?? Checked.sub(source.length, offset))
        self.limits = limits
        self.expectedSize = expectedSize
        self.tuning = tuning
        if let expectedSize { try Checked.size(expectedSize, limit: limits.maxEntrySize) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while pendingOffset == pending.count {
                // D11: 全 byte を消費してから view を破棄する。その後だけ次 block に進むか frame を解放する。
                pending = UnsafeRawBufferPointer(start: nil, count: 0)
                pendingOffset = 0
                if let frame, !frame.finished {
                    pending = try frame.nextBlock(input)
                    produced = try Checked.add(produced, UInt64(pending.count))
                    try Checked.size(produced, limit: limits.maxEntrySize)
                    if let expectedSize, produced > expectedSize {
                        throw KaitoError.malformed("zstd output exceeds expected size")
                    }
                    if !pending.isEmpty { break }
                } else {
                    frame = nil
                    if input.remaining == 0 {
                        guard sawFrame else { throw KaitoError.truncated }
                        if let expectedSize, expectedSize != produced {
                            throw KaitoError.malformed("zstd expected size mismatch")
                        }
                        isFinished = true
                        return 0
                    }
                    let magic = try input.integer(4)
                    sawFrame = true
                    if ZstdFrameHeader.isSkippable(magic) {
                        try input.skip(input.integer(4))
                        continue
                    }
                    guard magic == ZstdFrameHeader.magic else { throw KaitoError.malformed("zstd frame magic") }
                    frame = try ZstdFrameDecoder(header: ZstdFrameHeader(input: input, limits: limits), tuning: tuning)
                }
            }
            let count = min(buffer.count, pending.count - pendingOffset)
            // D11: frame を保持中で nextBlock は未呼出し。検査済み pending 範囲だけを caller にコピーする。
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: pending[pendingOffset..<(pendingOffset + count)]))
            pendingOffset += count
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    // ブロックの実体を展開せず、全フレームの宣言サイズと構造を確認する。
    static func contentSize(source: any ByteSource, limits: ReadLimits) throws -> UInt64? {
        let input = try ZstdInput(source: source, offset: 0, size: source.length)
        guard input.remaining > 0 else { throw KaitoError.truncated }
        var total: UInt64 = 0
        var known = true
        while input.remaining > 0 {
            let magic = try input.integer(4)
            if ZstdFrameHeader.isSkippable(magic) {
                try input.skip(input.integer(4))
                continue
            }
            guard magic == ZstdFrameHeader.magic else { throw KaitoError.malformed("zstd frame magic") }
            let header = try ZstdFrameHeader(input: input, limits: limits)
            if let size = header.contentSize {
                total = try Checked.add(total, size)
                try Checked.size(total, limit: limits.maxEntrySize)
            } else { known = false }
            var last = false
            while !last {
                let block = try header.blockHeader(input)
                try input.skip(UInt64(block.type == 1 ? 1 : block.size))
                last = block.last
            }
            if header.checksum { try input.skip(4) }
        }
        return known ? total : nil
    }
}
