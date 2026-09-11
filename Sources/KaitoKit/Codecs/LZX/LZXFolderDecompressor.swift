// CAB のチェックサムはエントリーと交差する CFDATA だけで検査する。先行フレームは履歴の復元に使う。
protocol CabFolderDecoder: AnyObject {
    var position: UInt64 { get }
    func skip(to offset: UInt64, entryIndex: Int) throws
    func read(into buffer: UnsafeMutableRawBufferPointer, entryIndex: Int) throws -> Int
}

final class LZXFolderDecompressor: CabFolderDecoder {
    private let source: any ByteSource
    private let blocks: [CabDataBlock]
    private let decoder: LZXDecoder
    private var blockIndex = 0
    private var loadedBlock: Int?
    private var checksumVerified = false
    private var input: [UInt8] = []
    private var output: [UInt8] = []
    private var outputOffset = 0
    private(set) var position: UInt64 = 0

    init(source: any ByteSource, blocks: [CabDataBlock], windowBits: Int,
         outputSize: UInt64, dictionarySizeLimit: UInt64, folderContinues: Bool = false) throws {
        self.source = source; self.blocks = blocks
        decoder = try LZXDecoder(windowBits: windowBits, outputSize: outputSize,
            dictionarySizeLimit: dictionarySizeLimit, folderContinues: folderContinues)
    }

    func skip(to offset: UInt64, entryIndex: Int) throws {
        guard offset >= position else { throw KaitoError.malformed("cab folder decoder cannot rewind") }
        while position < offset {
            if outputOffset == output.count {
                guard blockIndex < blocks.count else { throw KaitoError.truncated }
                let block = blocks[blockIndex]
                let end = try Checked.add(block.folderOffset, UInt64(block.uncompressedSize))
                try loadFrame(entryIndex: end > offset ? entryIndex : nil)
            }
            let count = Int(min(offset - position, UInt64(output.count - outputOffset)))
            outputOffset += count
            position = try Checked.add(position, UInt64(count))
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, entryIndex: Int) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if outputOffset == output.count { try loadFrame(entryIndex: entryIndex) }
        try verifyChecksum(entryIndex: entryIndex)
        let count = min(buffer.count, output.count - outputOffset)
        output.withUnsafeBytes { bytes in
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[outputOffset..<(outputOffset + count)]))
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

    private func loadFrame(entryIndex: Int?) throws {
        guard blockIndex < blocks.count else { throw KaitoError.truncated }
        let block = blocks[blockIndex]
        guard block.uncompressedSize > 0 else { throw KaitoError.malformed("cab LZX empty or split frame") }
        input = try readByteRange(source: source, offset: block.dataOffset, count: Int(block.compressedSize))
        loadedBlock = blockIndex; checksumVerified = false
        if let entryIndex { try verifyChecksum(entryIndex: entryIndex) }
        output = try decoder.decodeFrame(input: input, outputSize: Int(block.uncompressedSize))
        outputOffset = 0
        blockIndex += 1
    }
}
