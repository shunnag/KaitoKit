import Foundation

// CHM（ITSS）の on-disk 構造と LZX 圧縮 section。出典は CHMReader.swift の先頭。

enum CHMBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { LittleEndian.uint16(b, at: o) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { LittleEndian.uint32(b, at: o) }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { LittleEndian.uint64(b, at: o) }

    /// ENCINT: 上位 bit が継続、上位桁が先。
    static func encint(_ b: [UInt8], _ index: inout Int, end: Int) throws -> UInt64 {
        var value: UInt64 = 0
        var count = 0
        while true {
            guard index < end, count < 10 else { throw KaitoError.malformed("chm encoded integer") }
            let byte = b[index]
            index += 1
            count += 1
            value = value << 7 | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
    }
}

/// directory の 1 entry。
struct CHMDirectoryEntry {
    let name: String
    let section: UInt64
    let offset: UInt64
    let length: UInt64
}

/// ITSF header（0x38 byte）+ header section table（2 × 16 byte）+ version 3 の content offset。
struct CHMHeader {
    static let signature: [UInt8] = Array("ITSF".utf8)
    let version: UInt32
    let headerLength: UInt32
    let languageID: UInt32
    let directoryOffset: UInt64
    let directoryLength: UInt64
    let contentOffset: UInt64

    init(_ b: [UInt8], sourceLength: UInt64) throws {
        guard b.count >= 0x58 else { throw KaitoError.truncated }
        guard Array(b[0..<4]) == Self.signature else { throw KaitoError.unsupportedFormat }
        version = CHMBytes.u32(b, 4)
        guard version == 2 || version == 3 else { throw KaitoError.unsupportedFormat }
        headerLength = CHMBytes.u32(b, 8)
        languageID = CHMBytes.u32(b, 0x14)
        directoryOffset = CHMBytes.u64(b, 0x48)
        directoryLength = CHMBytes.u64(b, 0x50)
        if version >= 3 {
            guard b.count >= 0x60 else { throw KaitoError.truncated }
            contentOffset = CHMBytes.u64(b, 0x58)
        } else {
            contentOffset = try Checked.add(directoryOffset, directoryLength)
        }
        guard try Checked.add(directoryOffset, directoryLength) <= sourceLength, contentOffset <= sourceLength else {
            throw KaitoError.truncated
        }
    }
}

/// 圧縮 section（`MSCompressed`）: LZXC の control data と reset table。
final class CHMCompressedSection {
    let contentOffset: UInt64          // file 内の Content の位置
    let contentLength: UInt64
    let uncompressedLength: UInt64
    let windowBits: Int
    let resetIntervalBlocks: Int
    let blockSize: UInt64
    let blockOffsets: [UInt64]         // reset table: 各 0x8000 block の圧縮側 offset
    private let source: any ByteSource
    private let limits: ReadLimits
    private let lock = NSLock()
    private var cachedGroup = -1
    private var cachedBlocks: [[UInt8]] = []

    init(source: any ByteSource, contentOffset: UInt64, contentLength: UInt64, controlData: [UInt8], resetTable: [UInt8],
         limits: ReadLimits) throws {
        self.source = source
        self.limits = limits
        self.contentOffset = contentOffset
        self.contentLength = contentLength
        // ControlData: DWORD count, 'LZXC', version, reset interval, window size, cache size。
        guard controlData.count >= 24, Array(controlData[4..<8]) == Array("LZXC".utf8) else {
            throw KaitoError.unsupportedMethod("CHM section compression")
        }
        let version = CHMBytes.u32(controlData, 8)
        let reset = UInt64(CHMBytes.u32(controlData, 12))
        let window = UInt64(CHMBytes.u32(controlData, 16))
        guard version == 1 || version == 2 else { throw KaitoError.unsupportedMethod("CHM LZXC version \(version)") }
        // version 2 は 0x8000 byte block 単位、version 1 は byte 単位。
        let windowBytes = version == 2 ? try Checked.mul(window, 0x8000) : window
        let resetBytes = version == 2 ? try Checked.mul(reset, 0x8000) : reset
        guard windowBytes > 0, windowBytes & (windowBytes - 1) == 0, (1 << 15...1 << 21).contains(windowBytes) else {
            throw KaitoError.malformed("chm LZX window size \(windowBytes)")
        }
        windowBits = windowBytes.trailingZeroBitCount
        try Checked.size(windowBytes, limit: limits.maxDictionarySize)
        // ResetTable: version, entry count, entry size (8), header length, uncompressed / compressed length, block size。
        guard resetTable.count >= 0x28 else { throw KaitoError.malformed("chm reset table") }
        let entryCount = Int(CHMBytes.u32(resetTable, 4))
        let entrySize = Int(CHMBytes.u32(resetTable, 8))
        let tableHeader = Int(CHMBytes.u32(resetTable, 12))
        uncompressedLength = CHMBytes.u64(resetTable, 16)
        blockSize = CHMBytes.u64(resetTable, 32)
        guard entrySize == 8, blockSize == 0x8000, tableHeader >= 0x28,
              resetTable.count >= tableHeader + entryCount * entrySize else {
            throw KaitoError.malformed("chm reset table layout")
        }
        guard resetBytes > 0, resetBytes % blockSize == 0 else { throw KaitoError.malformed("chm LZX reset interval \(resetBytes)") }
        resetIntervalBlocks = Int(resetBytes / blockSize)
        // 1 group（reset interval 分）を復号して cache する。上限は window と同程度に留める。
        guard resetBytes <= max(windowBytes, 1 << 22) else { throw KaitoError.unsupportedMethod("CHM LZX reset interval \(resetBytes)") }
        let neededBlocks = uncompressedLength == 0 ? 0 : (uncompressedLength - 1) / blockSize + 1
        guard UInt64(entryCount) >= neededBlocks else { throw KaitoError.malformed("chm reset table is shorter than the section") }
        var offsets: [UInt64] = []
        offsets.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let value = CHMBytes.u64(resetTable, tableHeader + index * entrySize)
            guard value <= contentLength, offsets.last.map({ $0 <= value }) ?? (value == 0) else {
                throw KaitoError.malformed("chm reset table offset")
            }
            offsets.append(value)
        }
        blockOffsets = offsets
    }

    var blockCount: Int { uncompressedLength == 0 ? 0 : Int((uncompressedLength - 1) / blockSize + 1) }

    /// block `index` の展開後 byte（最後の block は 0x8000 に padding された長さ）。
    func block(_ index: Int) throws -> [UInt8] {
        let group = index / resetIntervalBlocks
        lock.lock()
        defer { lock.unlock() }
        if group != cachedGroup {
            cachedBlocks = try decodeGroup(group)
            cachedGroup = group
        }
        return cachedBlocks[index - group * resetIntervalBlocks]
    }

    /// reset interval ごとに LZX の状態を全て捨てて（新しい stream として）block 列を復号する。
    private func decodeGroup(_ group: Int) throws -> [[UInt8]] {
        let first = group * resetIntervalBlocks
        let last = min(first + resetIntervalBlocks, blockCount)
        guard first < last else { throw KaitoError.malformed("chm block index") }
        // 出力は 0x8000 の倍数（Russotto: 末尾は 0x8000 境界まで padding される）。
        let decoder = try LZXDecoder(windowBits: windowBits, outputSize: UInt64(last - first) * blockSize,
                                     dictionarySizeLimit: limits.maxDictionarySize)
        var blocks: [[UInt8]] = []
        blocks.reserveCapacity(last - first)
        for index in first..<last {
            let start = blockOffsets[index]
            let end = index + 1 < blockOffsets.count ? blockOffsets[index + 1] : contentLength
            guard end >= start, end <= contentLength else { throw KaitoError.malformed("chm block range") }
            let input = try readByteRange(source: source, offset: Checked.add(contentOffset, start), count: Int(end - start))
            blocks.append(try decoder.decodeFrame(input: input, outputSize: Int(blockSize)))
        }
        return blocks
    }
}

/// 圧縮 section 内の 1 file を block 境界をまたいで返す。
final class CHMSectionDecompressor: Decompressor {
    private let section: CHMCompressedSection
    private var position: UInt64
    private let end: UInt64

    init(section: CHMCompressedSection, offset: UInt64, length: UInt64) throws {
        self.section = section
        position = offset
        end = try Checked.add(offset, length)
        guard end <= section.uncompressedLength else { throw KaitoError.truncated }
    }

    var isFinished: Bool { position == end }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        let block = try section.block(Int(position / section.blockSize))
        let inBlock = Int(position % section.blockSize)
        let count = min(buffer.count, block.count - inBlock, Int(end - position))
        block.withUnsafeBytes { bytes in
            buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: inBlock), byteCount: count)
        }
        position += UInt64(count)
        return count
    }
}
