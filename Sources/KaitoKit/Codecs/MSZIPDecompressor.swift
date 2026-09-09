// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表に基づくクリーンルーム実装。
// 他の archiver の実装 source は開かず、参照・引用していない。
import Foundation
private import zlib

// CFDATA の framing を所有する。None も同じ block / checksum / slice 規則で処理する。
final class MSZIPDecompressor: Decompressor {
    private let source: any ByteSource
    private let blocks: [CabDataBlock]
    private let stored: Bool
    private let entryIndex: Int
    private let sliceStart, sliceEnd: UInt64
    private var blockIndex = 0
    private var folderOffset: UInt64 = 0
    private var history: [UInt8] = []
    private var output: [UInt8] = []
    private var outputOffset = 0, outputEnd = 0
    private(set) var checksumsMatch = true
    private(set) var isFinished = false

    init(source: any ByteSource, blocks: [CabDataBlock], stored: Bool, offset: UInt64, length: UInt64, entryIndex: Int) throws {
        self.source = source; self.blocks = blocks; self.stored = stored
        self.entryIndex = entryIndex
        sliceStart = offset; sliceEnd = try Checked.add(offset, length)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        while true {
            if outputOffset < outputEnd {
                let count = min(buffer.count, outputEnd - outputOffset)
                output.withUnsafeBytes { bytes in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[outputOffset..<(outputOffset + count)]))
                }
                outputOffset += count
                return count
            }
            guard blockIndex < blocks.count else { isFinished = true; return 0 }
            let block = blocks[blockIndex]
            let data = try readByteRange(source: source, offset: block.dataOffset, count: Int(block.compressedSize))
            if block.checksum != 0, block.computedChecksum(data) != block.checksum { checksumsMatch = false }
            if stored {
                guard block.compressedSize == block.uncompressedSize else { throw KaitoError.malformed("cab stored block size") }
                output = data
            } else {
                do {
                    output = try inflateBlock(data, size: Int(block.uncompressedSize))
                } catch {
                    // 破損で復号を続行できない場合も、確認済み checksum 不一致を codec error で隠さない。
                    if !checksumsMatch { throw KaitoError.checksumMismatch(entry: entryIndex) }
                    throw error
                }
                // 短い block が続く場合も、それ以前を含む末尾 32 KiB を次の独立 stream へ渡す。
                history = Array((history + output).suffix(32768))
            }
            let end = try Checked.add(folderOffset, UInt64(output.count))
            let lower = max(folderOffset, sliceStart), upper = min(end, sliceEnd)
            if lower < upper {
                outputOffset = try Checked.toInt(Checked.sub(lower, folderOffset))
                outputEnd = try Checked.toInt(Checked.sub(upper, folderOffset))
            } else { outputOffset = 0; outputEnd = 0 }
            folderOffset = end
            blockIndex += 1
            // slice 後も終端確認時に残りの folder を読み、全 CFDATA checksum を確定する。
        }
    }

    private func inflateBlock(_ data: [UInt8], size: Int) throws -> [UInt8] {
        guard data.starts(with: [0x43, 0x4b]) else { throw KaitoError.malformed("cab MSZIP signature") }
        var stream = z_stream()
        let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw KaitoError.malformed("cab MSZIP initialization") }
        defer { _ = inflateEnd(&stream) }
        if !history.isEmpty {
            let status = history.withUnsafeBufferPointer { bytes in
                inflateSetDictionary(&stream, bytes.baseAddress, uInt(bytes.count))
            }
            guard status == Z_OK else { throw KaitoError.malformed("cab MSZIP dictionary") }
        }
        // 余分な 1 byte で宣言超過を検出し、出力がぴったりでも終端 marker を読む余地を残す。
        var result = [UInt8](repeating: 0, count: size + 1)
        let status = data.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: 2))
                stream.avail_in = uInt(data.count - 2)
                stream.next_out = output.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(output.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw KaitoError.malformed("cab MSZIP block stream")
        }
        result.removeLast()
        return result
    }
}
