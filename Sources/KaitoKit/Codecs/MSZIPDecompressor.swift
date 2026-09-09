// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表に基づくクリーンルーム実装。
// 他の archiver の実装 source は開かず、参照・引用していない。
import Foundation
private import zlib

final class MSZIPDecompressor {
    private let source: any ByteSource
    private let blocks: [CabDataBlock]
    private let stored: Bool
    private var blockIndex = 0
    private var loadedBlock: Int?
    private var checksumVerified = false
    private var history: [UInt8] = []
    private var input: [UInt8] = []
    private var output = [UInt8](repeating: 0, count: 32769)
    private var outputOffset = 0, outputEnd = 0
    private var stream = z_stream()
    private var streamWasInitialized = false
    private(set) var position: UInt64 = 0

    init(source: any ByteSource, blocks: [CabDataBlock], stored: Bool) {
        self.source = source; self.blocks = blocks; self.stored = stored
        input.reserveCapacity(Int(UInt16.max))
        history.reserveCapacity(32768)
    }

    deinit {
        if streamWasInitialized { _ = inflateEnd(&stream) }
    }

    func skip(to offset: UInt64, entryIndex: Int) throws {
        guard offset >= position else { throw KaitoError.malformed("cab folder decoder cannot rewind") }
        if stored, offset > position {
            // 保存方式には辞書がない。二分探索で飛ばし、定容量・多数ファイルの実測で見えた再走査を避ける。
            var lower = 0, upper = blocks.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let end = try Checked.add(blocks[middle].folderOffset, UInt64(blocks[middle].uncompressedSize))
                if end <= offset { lower = middle + 1 } else { upper = middle }
            }
            if loadedBlock == lower {
                outputOffset = try Checked.toInt(Checked.sub(offset, blocks[lower].folderOffset))
                position = offset
                return
            }
            blockIndex = lower; loadedBlock = nil
            outputOffset = 0; outputEnd = 0
            position = lower < blocks.count ? blocks[lower].folderOffset : offset
        }
        while position < offset {
            if outputOffset == outputEnd {
                guard blockIndex < blocks.count else { throw KaitoError.truncated }
                let block = blocks[blockIndex]
                let end = try Checked.add(block.folderOffset, UInt64(block.uncompressedSize))
                try loadBlock(entryIndex: end > offset ? entryIndex : nil)
            }
            let count = try Checked.toInt(min(try Checked.sub(offset, position), UInt64(outputEnd - outputOffset)))
            outputOffset += count
            position = try Checked.add(position, UInt64(count))
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, entryIndex: Int) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        while outputOffset == outputEnd { try loadBlock(entryIndex: entryIndex) }
        try verifyChecksum(entryIndex: entryIndex)
        let count = min(buffer.count, outputEnd - outputOffset)
        if stored {
            input.withUnsafeBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[outputOffset..<(outputOffset + count)]))
            }
        } else {
            output.withUnsafeBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[outputOffset..<(outputOffset + count)]))
            }
        }
        outputOffset += count
        position = try Checked.add(position, UInt64(count))
        return count
    }

    private func verifyChecksum(entryIndex: Int) throws {
        guard !checksumVerified, let loadedBlock else { return }
        let block = blocks[loadedBlock]
        if block.checksum != 0, block.computedChecksum(input) != block.checksum {
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        checksumVerified = true
    }

    private func loadBlock(entryIndex: Int?) throws {
        guard blockIndex < blocks.count else { throw KaitoError.truncated }
        let block = blocks[blockIndex]
        let count = Int(block.compressedSize)
        guard try Checked.add(block.dataOffset, UInt64(count)) <= source.length else { throw KaitoError.truncated }
        input.removeAll(keepingCapacity: true)
        input.append(contentsOf: repeatElement(0, count: count))
        var filled = 0
        while filled < count {
            let offset = try Checked.add(block.dataOffset, UInt64(filled))
            let actual = try input.withUnsafeMutableBytes { bytes in
                try source.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<count]), at: offset)
            }
            guard actual > 0, actual <= count - filled else { throw KaitoError.truncated }
            filled += actual
        }
        loadedBlock = blockIndex; checksumVerified = false
        // 履歴用の先行ブロックは検証対象外。空の出力範囲もファイルの半開区間と交差しない。
        if let entryIndex, block.uncompressedSize > 0 { try verifyChecksum(entryIndex: entryIndex) }
        if stored {
            guard block.compressedSize == block.uncompressedSize else { throw KaitoError.malformed("cab stored block size") }
        } else {
            try inflateBlock(size: Int(block.uncompressedSize))
            let size = Int(block.uncompressedSize)
            // 短いブロックだけ以前の履歴を残す。32 KiB の出力なら連結用の複製は不要。
            if size >= 32768 {
                history.removeAll(keepingCapacity: true)
                history.append(contentsOf: output[(size - 32768)..<size])
            } else {
                let excess = max(0, history.count + size - 32768)
                if excess > 0 { history.removeFirst(excess) }
                history.append(contentsOf: output[..<size])
            }
        }
        outputOffset = 0; outputEnd = Int(block.uncompressedSize)
        blockIndex += 1
    }

    private func inflateBlock(size: Int) throws {
        guard input.starts(with: [0x43, 0x4b]) else { throw KaitoError.malformed("cab MSZIP signature") }
        if streamWasInitialized {
            guard inflateReset(&stream) == Z_OK else { throw KaitoError.malformed("cab MSZIP reset") }
        } else {
            let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw KaitoError.malformed("cab MSZIP initialization") }
            streamWasInitialized = true
        }
        // zlib の reset は辞書も捨てるため、CFDATA 境界をまたぐ MSZIP の参照履歴を毎回戻す。
        if !history.isEmpty {
            let status = history.withUnsafeBufferPointer { bytes in
                inflateSetDictionary(&stream, bytes.baseAddress, uInt(bytes.count))
            }
            guard status == Z_OK else { throw KaitoError.malformed("cab MSZIP dictionary") }
        }
        // 余分な 1 byte で宣言超過を検出し、出力がぴったりでも終端 marker を読む余地を残す。
        let inputCount = input.count
        let status = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = UnsafeMutablePointer(mutating: inputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: 2))
                stream.avail_in = uInt(inputCount - 2)
                stream.next_out = outputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(size + 1)
                defer { stream.next_in = nil; stream.next_out = nil }
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw KaitoError.malformed("cab MSZIP block stream")
        }
    }
}
