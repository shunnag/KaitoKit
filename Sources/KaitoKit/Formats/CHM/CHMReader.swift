import Foundation

// Microsoft HTML Help（CHM / ITSS）の reader。実装入力は Matthew Russotto の "Microsoft's HTML Help (.chm) format"
//（2001–2003、無改変複製を許す著作権表示。`inbox/chm/chmformat-wayback.html`）と、Paul Wise / Jed Wing の
// "Unofficial (Preliminary) HTML Help Specification"（GNU GPL v2+ の文書。`inbox/chm/chmspec/`）の散文。
// LZX 本体は既存の [MS-PATCH] 由来 `LZXDecoder`（CAB と同じ bitstream）で、CHM 固有の点（reset interval ごとの
// 全状態 reset、0x8000 byte block ごとの 16 bit 境界、末尾の 0x8000 への padding）は Russotto の記述と
// 利用者所有の実物 2 本の黒箱で確定した。2026-09-21 の検証記録を参照。

enum CHMBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

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

final class CHMReader: FormatReader {
    private enum Location {
        case stored(offset: UInt64, length: UInt64)
        case compressed(section: Int, offset: UInt64, length: UInt64)
        case unsupported(String)
        case empty
    }

    let format: ArchiveFormat = .chm
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf8
    private let source: any ByteSource
    private let locations: [Location]
    private let sections: [Int: CHMCompressedSection]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let limits = options.limits
        let head = try readByteRange(source: source, offset: 0, count: Int(min(source.length, 0x60)))
        let header = try CHMHeader(head, sourceLength: source.length)
        let directory = try Self.directory(source: source, header: header, limits: limits)
        let byName = Dictionary(directory.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let content = header.contentOffset

        // section 0 の file を読む helper。
        func stored(_ name: String) throws -> [UInt8]? {
            guard let entry = byName[name], entry.section == 0 else { return nil }
            try Checked.size(entry.length, limit: limits.maxMetadataSize)
            let offset = try Checked.add(content, entry.offset)
            guard try Checked.add(offset, entry.length) <= source.length else { throw KaitoError.truncated }
            return try readByteRange(source: source, offset: offset, count: Int(entry.length))
        }
        // ::DataSpace/NameList: WORD 全長（word）、WORD 個数、{WORD 長、UTF-16LE、WORD 0}。
        var sectionNames = ["Uncompressed"]
        if let list = try stored("::DataSpace/NameList"), list.count >= 4 {
            let count = Int(CHMBytes.u16(list, 2))
            var names: [String] = []
            var index = 4
            for _ in 0..<count {
                guard index + 2 <= list.count else { throw KaitoError.malformed("chm name list") }
                let length = Int(CHMBytes.u16(list, index)) * 2
                index += 2
                guard index + length + 2 <= list.count else { throw KaitoError.malformed("chm name list") }
                let units = stride(from: index, to: index + length, by: 2).map { CHMBytes.u16(list, $0) }
                names.append(String(decoding: units, as: UTF16.self))
                index += length + 2
            }
            if !names.isEmpty { sectionNames = names }
        }
        var sections: [Int: CHMCompressedSection] = [:]
        var unsupportedSections: [Int: String] = [:]
        for (number, name) in sectionNames.enumerated() where number > 0 {
            let base = "::DataSpace/Storage/\(name)/"
            guard let contentEntry = byName[base + "Content"], contentEntry.section == 0 else {
                unsupportedSections[number] = "CHM section \(name) without content"
                continue
            }
            do {
                guard let control = try stored(base + "ControlData"),
                      let reset = try stored(base + "Transform/{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}/InstanceData/ResetTable") else {
                    throw KaitoError.unsupportedMethod("CHM section \(name) compression")
                }
                let offset = try Checked.add(content, contentEntry.offset)
                guard try Checked.add(offset, contentEntry.length) <= source.length else { throw KaitoError.truncated }
                sections[number] = try CHMCompressedSection(source: source, contentOffset: offset, contentLength: contentEntry.length,
                                                            controlData: control, resetTable: reset, limits: limits)
            } catch KaitoError.unsupportedMethod(let reason) {
                unsupportedSections[number] = reason
            }
        }
        self.sections = sections

        // 利用者 file（`/` で始まる）を公開する。`::` の内部 file は出さない（7-Zip と同じ）。
        var entries: [ArchiveEntry] = []
        var locations: [Location] = []
        for entry in directory where entry.name.hasPrefix("/") && entry.name != "/" {
            guard entries.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("chm entry count") }
            let isDirectory = entry.name.hasSuffix("/")
            let path = String(entry.name.dropFirst().dropLast(isDirectory ? 1 : 0))
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty, components.count <= limits.maxPathComponentCount,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw KaitoError.malformed("chm entry name \(entry.name)")
            }
            let location: Location
            let method: String
            if isDirectory || entry.length == 0 {
                location = .empty
                method = entry.section == 0 ? "stored" : "LZX"
            } else if entry.section == 0 {
                let offset = try Checked.add(content, entry.offset)
                guard try Checked.add(offset, entry.length) <= source.length else { throw KaitoError.truncated }
                location = .stored(offset: offset, length: entry.length)
                method = "stored"
            } else if let section = sections[Int(clamping: entry.section)] {
                guard try Checked.add(entry.offset, entry.length) <= section.uncompressedLength else { throw KaitoError.truncated }
                location = .compressed(section: Int(entry.section), offset: entry.offset, length: entry.length)
                method = "LZX"
            } else {
                location = .unsupported(unsupportedSections[Int(clamping: entry.section)] ?? "CHM section \(entry.section)")
                method = "unknown"
            }
            try Checked.size(entry.length, limit: limits.maxEntrySize)
            var specific: [String: String] = ["section": String(entry.section)]
            if entry.section > 0, entry.section < UInt64(sectionNames.count) { specific["sectionName"] = sectionNames[Int(entry.section)] }
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: Array(path.utf8), declaredEncoding: .utf8, isDirectoryHint: isDirectory),
                name: path, pathComponents: components, kind: isDirectory ? .directory : .file,
                uncompressedSize: isDirectory ? 0 : entry.length, compressedSize: nil,
                modificationDate: nil, posixPermissions: nil, isEncrypted: false, solidGroup: entry.section > 0 ? Int(entry.section) : -1,
                crc32: nil, methodDescription: method, formatSpecific: specific))
            locations.append(location)
        }
        self.entries = entries
        self.locations = locations
    }

    /// ITSP header と PMGL（listing）chunk の並びから directory を読む。PMGI（index）chunk は読み飛ばす。
    static func directory(source: any ByteSource, header: CHMHeader, limits: ReadLimits) throws -> [CHMDirectoryEntry] {
        guard header.directoryLength >= 0x54 else { throw KaitoError.malformed("chm directory header") }
        try Checked.size(header.directoryLength, limit: limits.maxMetadataSize)
        let d = try readByteRange(source: source, offset: header.directoryOffset, count: Int(header.directoryLength))
        guard Array(d[0..<4]) == Array("ITSP".utf8) else { throw KaitoError.malformed("chm directory signature") }
        let headerLength = Int(CHMBytes.u32(d, 8))
        let chunkSize = Int(CHMBytes.u32(d, 0x10))
        let firstChunk = Int32(bitPattern: CHMBytes.u32(d, 0x20))
        let lastChunk = Int32(bitPattern: CHMBytes.u32(d, 0x24))
        let chunkCount = Int(CHMBytes.u32(d, 0x2C))
        guard headerLength >= 0x54, chunkSize >= 0x20, chunkSize <= 1 << 20, chunkCount >= 1,
              headerLength + chunkCount * chunkSize <= d.count else {
            throw KaitoError.malformed("chm directory layout")
        }
        try Checked.size(UInt64(chunkCount), limit: UInt64(limits.maxMetadataRecordCount))
        var entries: [CHMDirectoryEntry] = []
        var chunk = firstChunk
        var visited = 0
        while chunk >= 0 {
            guard Int(chunk) < chunkCount, visited < chunkCount else { throw KaitoError.malformed("chm listing chunk chain") }
            visited += 1
            let base = headerLength + Int(chunk) * chunkSize
            guard Array(d[base..<(base + 4)]) == Array("PMGL".utf8) else { throw KaitoError.malformed("chm listing chunk") }
            let freeLength = Int(CHMBytes.u32(d, base + 4))
            let next = Int32(bitPattern: CHMBytes.u32(d, base + 0x10))
            guard freeLength <= chunkSize - 0x14 else { throw KaitoError.malformed("chm listing chunk free length") }
            let count = Int(CHMBytes.u16(d, base + chunkSize - 2))
            var index = base + 0x14
            let end = base + chunkSize - freeLength
            for _ in 0..<count {
                guard entries.count < limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("chm directory entries") }
                let nameLength = try CHMBytes.encint(d, &index, end: end)
                guard nameLength <= UInt64(end - index), nameLength <= 4096 else { throw KaitoError.malformed("chm entry name length") }
                let name = String(decoding: d[index..<(index + Int(nameLength))], as: UTF8.self)
                index += Int(nameLength)
                let section = try CHMBytes.encint(d, &index, end: end)
                let offset = try CHMBytes.encint(d, &index, end: end)
                let length = try CHMBytes.encint(d, &index, end: end)
                entries.append(CHMDirectoryEntry(name: name, section: section, offset: offset, length: length))
            }
            if chunk == lastChunk { break }
            chunk = next
        }
        return entries
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("chm entry index \(entry.index)")
        }
        switch locations[entry.index] {
        case .empty:
            return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits)
        case .stored(let offset, let length):
            return try EntryStream(source: source, offset: offset, length: length, limits: limits)
        case .compressed(let section, let offset, let length):
            guard let compressed = sections[section] else { throw KaitoError.unsupportedMethod("CHM section \(section)") }
            return try EntryStream(decompressor: CHMSectionDecompressor(section: compressed, offset: offset, length: length),
                                   length: length, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
        case .unsupported(let reason):
            throw KaitoError.unsupportedMethod(reason)
        }
    }
}
