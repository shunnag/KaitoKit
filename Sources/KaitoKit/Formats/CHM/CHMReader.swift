import Foundation

// Microsoft HTML Help（CHM / ITSS）の reader。実装入力は Matthew Russotto の "Microsoft's HTML Help (.chm) format"
//（2001–2003、無改変複製を許す著作権表示。`inbox/chm/chmformat-wayback.html`）と、Paul Wise / Jed Wing の
// "Unofficial (Preliminary) HTML Help Specification"（GNU GPL v2+ の文書。`inbox/chm/chmspec/`）の散文。
// LZX 本体は既存の [MS-PATCH] 由来 `LZXDecoder`（CAB と同じ bitstream）で、CHM 固有の点（reset interval ごとの
// 全状態 reset、0x8000 byte block ごとの 16 bit 境界、末尾の 0x8000 への padding）は Russotto の記述と
// 利用者所有の実物 2 本の黒箱で確定した。2026-09-21 の検証記録を参照。

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
        for (index, entry) in directory.enumerated() {
            try checkCancellation(every: index)
            guard entry.name.hasPrefix("/") && entry.name != "/" else { continue }
            guard entry.section <= UInt64(Int.max) else { throw KaitoError.malformed("chm section id exceeds Int") }
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
            try checkCancellation(every: visited)
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
                try checkCancellation(every: entries.count)
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
        try recordIndex(of: entry, label: "chm")
        switch locations[entry.index] {
        case .empty:
            return try EntryStream.empty(entryIndex: entry.index, limits: limits)
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
