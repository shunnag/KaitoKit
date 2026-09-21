import Foundation

// [MS-CFB] Compound File Binary File Format v20240423（Microsoft Open Specification）の公開仕様に基づく
// クリーンルーム実装。storage を directory、stream を file として公開する。Windows Installer（MSI）が stream 名に
// 使う詰め込み表記（U+3800〜U+4840 の UTF-16 unit）には公開仕様が無く、7-Zip 26.03 の一覧（実物の MSI 23 名と
// 自作 file の探り）から黒箱で写像を確定した（2026-09-21 の検証記録）。7-Zip と同じく root の CLSID に関わらず
// unit ごとに戻す。

enum CFBBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }
}

/// §2.2 の header（512 byte）。
struct CFBHeader {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let size = 512
    static let headerDIFATEntries = 109
    // §2.1 の予約 sector 番号。
    static let maxRegularSector: UInt32 = 0xFFFF_FFFA
    static let difatSector: UInt32 = 0xFFFF_FFFC
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let noStream: UInt32 = 0xFFFF_FFFF

    let majorVersion: UInt16
    let sectorShift: Int
    let miniSectorShift: Int
    let directorySectorCount: UInt32
    let fatSectorCount: UInt32
    let firstDirectorySector: UInt32
    let miniStreamCutoff: UInt32
    let firstMiniFATSector: UInt32
    let miniFATSectorCount: UInt32
    let firstDIFATSector: UInt32
    let difatSectorCount: UInt32
    let headerDIFAT: [UInt32]

    var sectorSize: Int { 1 << sectorShift }
    var miniSectorSize: Int { 1 << miniSectorShift }

    init(_ b: [UInt8]) throws {
        guard b.count >= Self.size else { throw KaitoError.truncated }
        guard Array(b[0..<8]) == Self.signature else { throw KaitoError.unsupportedFormat }
        majorVersion = CFBBytes.u16(b, 26)
        guard CFBBytes.u16(b, 28) == 0xFFFE else { throw KaitoError.malformed("cfb byte order") }
        let shift = Int(CFBBytes.u16(b, 30))
        switch (majorVersion, shift) {
        case (3, 9), (4, 12): sectorShift = shift
        default: throw KaitoError.unsupportedFormat
        }
        miniSectorShift = Int(CFBBytes.u16(b, 32))
        guard miniSectorShift == 6 else { throw KaitoError.malformed("cfb mini sector shift \(miniSectorShift)") }
        directorySectorCount = CFBBytes.u32(b, 40)
        fatSectorCount = CFBBytes.u32(b, 44)
        firstDirectorySector = CFBBytes.u32(b, 48)
        miniStreamCutoff = CFBBytes.u32(b, 56)
        guard miniStreamCutoff == 4096 else { throw KaitoError.malformed("cfb mini stream cutoff \(miniStreamCutoff)") }
        firstMiniFATSector = CFBBytes.u32(b, 60)
        miniFATSectorCount = CFBBytes.u32(b, 64)
        firstDIFATSector = CFBBytes.u32(b, 68)
        difatSectorCount = CFBBytes.u32(b, 72)
        headerDIFAT = (0..<Self.headerDIFATEntries).map { CFBBytes.u32(b, 76 + $0 * 4) }
    }
}

/// §2.6.1 の directory entry（128 byte）。
struct CFBDirectoryEntry {
    static let size = 128
    enum ObjectType: UInt8 { case unallocated = 0, storage = 1, stream = 2, root = 5 }

    let name: String
    let type: ObjectType
    let leftSibling: UInt32
    let rightSibling: UInt32
    let child: UInt32
    let clsid: [UInt8]
    let created: UInt64
    let modified: UInt64
    let startSector: UInt32
    let size: UInt64

    init(_ b: [UInt8], _ o: Int, majorVersion: UInt16) throws {
        guard let type = ObjectType(rawValue: b[o + 66]) else { throw KaitoError.malformed("cfb directory entry type \(b[o + 66])") }
        self.type = type
        let nameLength = Int(CFBBytes.u16(b, o + 64))
        guard nameLength <= 64, nameLength % 2 == 0 else { throw KaitoError.malformed("cfb directory entry name length \(nameLength)") }
        // 終端の null を除く UTF-16LE。unallocated entry は名前が空。
        var units: [UInt16] = []
        var index = 0
        while index + 1 < nameLength {
            let unit = CFBBytes.u16(b, o + index)
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        name = String(decoding: units, as: UTF16.self)
        leftSibling = CFBBytes.u32(b, o + 68)
        rightSibling = CFBBytes.u32(b, o + 72)
        child = CFBBytes.u32(b, o + 76)
        clsid = Array(b[(o + 80)..<(o + 96)])
        created = CFBBytes.u64(b, o + 100)
        modified = CFBBytes.u64(b, o + 108)
        startSector = CFBBytes.u32(b, o + 116)
        // §2.6.3: version 3 では上位 32 bit が未初期化のことがあるので下位だけを使う。
        size = majorVersion == 3 ? UInt64(CFBBytes.u32(b, o + 120)) : CFBBytes.u64(b, o + 120)
    }

    /// CLSID を registry 形式（`{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`）で。全 0 なら nil。
    var clsidString: String? {
        guard clsid.contains(where: { $0 != 0 }) else { return nil }
        let a = String(format: "%08X", CFBBytes.u32(clsid, 0))
        let bPart = String(format: "%04X", CFBBytes.u16(clsid, 4))
        let c = String(format: "%04X", CFBBytes.u16(clsid, 6))
        let d = clsid[8..<10].map { String(format: "%02X", $0) }.joined()
        let e = clsid[10..<16].map { String(format: "%02X", $0) }.joined()
        return "{\(a)-\(bPart)-\(c)-\(d)-\(e)}"
    }
}

/// storage / stream の木を読み、stream を file として公開する。
final class CFBReader: FormatReader {
    private struct Record {
        let entry: CFBDirectoryEntry
    }

    let format: ArchiveFormat = .compoundFile
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf8
    private let source: any ByteSource
    private let header: CFBHeader
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    /// root entry の chain（mini stream）の sector 列。
    private let miniStreamSectors: [UInt32]
    private let miniStreamSize: UInt64
    private let records: [Record]
    private let limits: ReadLimits

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        limits = options.limits
        let headerBytes = try readByteRange(source: source, offset: 0, count: CFBHeader.size)
        let header = try CFBHeader(headerBytes)
        self.header = header
        let sectorSize = header.sectorSize
        // sector 番号 n は file offset (n + 1) × sector size（§2.3）。file 内の sector 数で全 chain を抑える。
        guard source.length >= UInt64(sectorSize * 3) else { throw KaitoError.truncated }
        let sectorCount = (source.length - UInt64(sectorSize)) / UInt64(sectorSize)
        guard sectorCount <= UInt64(CFBHeader.maxRegularSector) else { throw KaitoError.malformed("cfb sector count") }
        var budget = CFBMetadataBudget(limits: options.limits)

        // §2.5: DIFAT（header の 109 個 + DIFAT sector 列）が FAT sector の位置を並べる。
        var fatSectors: [UInt32] = []
        for location in header.headerDIFAT where location <= CFBHeader.maxRegularSector { fatSectors.append(location) }
        var difatLocation = header.firstDIFATSector
        var difatSeen = 0
        while difatLocation <= CFBHeader.maxRegularSector {
            guard difatSeen < Int(header.difatSectorCount), difatSeen < 1 << 16 else { throw KaitoError.malformed("cfb difat chain") }
            let b = try Self.sector(difatLocation, source: source, sectorSize: sectorSize, sectorCount: sectorCount, budget: &budget)
            for index in 0..<(sectorSize / 4 - 1) {
                let location = CFBBytes.u32(b, index * 4)
                if location <= CFBHeader.maxRegularSector { fatSectors.append(location) }
            }
            difatLocation = CFBBytes.u32(b, sectorSize - 4)
            difatSeen += 1
        }
        guard fatSectors.count >= Int(header.fatSectorCount) else { throw KaitoError.malformed("cfb fat sector count") }
        fatSectors.removeLast(fatSectors.count - Int(header.fatSectorCount))

        // §2.3: FAT を 1 本の配列にする。
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * (sectorSize / 4))
        for location in fatSectors {
            let b = try Self.sector(location, source: source, sectorSize: sectorSize, sectorCount: sectorCount, budget: &budget)
            for index in 0..<(sectorSize / 4) { fat.append(CFBBytes.u32(b, index * 4)) }
        }
        self.fat = fat

        // §2.6: directory の chain を辿って entry 表を作る。
        let directorySectors = try Self.chain(from: header.firstDirectorySector, fat: fat, sectorCount: sectorCount,
                                              maximumSectors: header.directorySectorCount == 0 ? nil : UInt64(header.directorySectorCount),
                                              label: "directory")
        var directory: [CFBDirectoryEntry] = []
        let entriesPerSector = sectorSize / CFBDirectoryEntry.size
        try Checked.size(UInt64(directorySectors.count) * UInt64(entriesPerSector), limit: UInt64(options.limits.maxMetadataRecordCount))
        for location in directorySectors {
            let b = try Self.sector(location, source: source, sectorSize: sectorSize, sectorCount: sectorCount, budget: &budget)
            for index in 0..<entriesPerSector {
                directory.append(try CFBDirectoryEntry(b, index * CFBDirectoryEntry.size, majorVersion: header.majorVersion))
            }
        }
        guard let root = directory.first, root.type == .root else { throw KaitoError.malformed("cfb root entry") }

        // §2.4: mini FAT と、root entry が指す mini stream。
        var miniFAT: [UInt32] = []
        if header.firstMiniFATSector <= CFBHeader.maxRegularSector {
            let miniFATSectors = try Self.chain(from: header.firstMiniFATSector, fat: fat, sectorCount: sectorCount,
                                                maximumSectors: UInt64(header.miniFATSectorCount), label: "mini fat")
            for location in miniFATSectors {
                let b = try Self.sector(location, source: source, sectorSize: sectorSize, sectorCount: sectorCount, budget: &budget)
                for index in 0..<(sectorSize / 4) { miniFAT.append(CFBBytes.u32(b, index * 4)) }
            }
        }
        self.miniFAT = miniFAT
        miniStreamSize = root.size
        if root.startSector <= CFBHeader.maxRegularSector, root.size > 0 {
            let needed = (root.size + UInt64(sectorSize) - 1) / UInt64(sectorSize)
            miniStreamSectors = try Self.chain(from: root.startSector, fat: fat, sectorCount: sectorCount, maximumSectors: needed, label: "mini stream")
            guard UInt64(miniStreamSectors.count) == needed else { throw KaitoError.malformed("cfb mini stream chain is shorter than its size") }
        } else {
            miniStreamSectors = []
        }

        // §2.6.4: 各 storage の子は red-black tree。左 → 自分 → 右の順に辿り、storage は再帰する。
        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        var visited = Set<UInt32>()
        func walk(_ id: UInt32, components: [String], depth: Int) throws {
            guard id != CFBHeader.noStream else { return }
            guard id <= CFBHeader.maxRegularSector, Int(id) < directory.count else { throw KaitoError.malformed("cfb stream id \(id)") }
            guard visited.insert(id).inserted else { throw KaitoError.malformed("cfb directory tree cycle") }
            let entry = directory[Int(id)]
            try walk(entry.leftSibling, components: components, depth: depth)
            switch entry.type {
            case .storage, .stream:
                guard depth < options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("cfb path depth") }
                guard entries.count < options.limits.maxEntryCount else { throw KaitoError.limitExceeded("cfb entry count") }
                let published = Self.publishedName(entry.name)
                let path = components + [published]
                let kind: EntryKind = entry.type == .storage ? .directory : .file
                let size: UInt64 = entry.type == .stream ? entry.size : 0
                if entry.type == .stream { try Checked.size(size, limit: options.limits.maxEntrySize) }
                var specific: [String: String] = [:]
                if published != entry.name { specific["storedName"] = entry.name }
                if let clsid = entry.clsidString { specific["clsid"] = clsid }
                if entry.created != 0, let date = WIMBytes.fileTime(entry.created) { specific["created"] = ISO8601DateFormatter().string(from: date) }
                let name = path.joined(separator: "/")
                entries.append(ArchiveEntry(index: entries.count,
                    rawName: RawName(bytes: Array(name.utf8), declaredEncoding: .utf8, isDirectoryHint: kind == .directory),
                    name: name, pathComponents: path, kind: kind, uncompressedSize: size, compressedSize: size,
                    modificationDate: WIMBytes.fileTime(entry.modified), posixPermissions: nil, isEncrypted: false, solidGroup: -1,
                    crc32: nil, methodDescription: "stored", formatSpecific: specific))
                records.append(Record(entry: entry))
                if entry.type == .storage { try walk(entry.child, components: path, depth: depth + 1) }
            case .root:
                throw KaitoError.malformed("cfb root entry inside the tree")
            case .unallocated:
                break
            }
            try walk(entry.rightSibling, components: components, depth: depth)
        }
        try walk(root.child, components: [], depth: 0)
        self.entries = entries
        self.records = records
    }

    /// MSI の詰め込み名を戻し、制御文字（Office / MSI の `\u{05}SummaryInformation` など）は path に置けないので
    /// `[5]` の形にする。
    static func publishedName(_ name: String) -> String {
        var result = ""
        for scalar in unpackMSIName(name).unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" {
                result += "[\(scalar.value)]"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "[]" : result
    }

    /// Windows Installer の名前: U+3800〜U+47FF の unit は 2 文字（下位 6 bit が先）、U+4800〜U+483F は 1 文字、
    /// U+4840 は `!`、それ以外はそのまま。字母は 0-9 A-Z a-z . _ の 64 文字。
    static let msiAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._")
    static func unpackMSIName(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { (0x3800...0x4840).contains($0.value) }) else { return name }
        var result = ""
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x3800...0x47FF:
                let value = Int(scalar.value - 0x3800)
                result.append(msiAlphabet[value % 64])
                result.append(msiAlphabet[value / 64])
            case 0x4800...0x483F:
                result.append(msiAlphabet[Int(scalar.value - 0x4800)])
            case 0x4840:
                result.append("!")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func sector(_ location: UInt32, source: any ByteSource, sectorSize: Int, sectorCount: UInt64,
                               budget: inout CFBMetadataBudget) throws -> [UInt8] {
        guard location <= CFBHeader.maxRegularSector, UInt64(location) < sectorCount else { throw KaitoError.truncated }
        try budget.charge(UInt64(sectorSize))
        return try readByteRange(source: source, offset: UInt64(location + 1) * UInt64(sectorSize), count: sectorSize)
    }

    /// FAT の chain を辿る。sector 数は file の大きさと宣言値で抑え、循環は訪問済み集合で拒む。
    private static func chain(from start: UInt32, fat: [UInt32], sectorCount: UInt64, maximumSectors: UInt64?, label: String) throws -> [UInt32] {
        var result: [UInt32] = []
        var seen = Set<UInt32>()
        var current = start
        while current != CFBHeader.endOfChain {
            guard current <= CFBHeader.maxRegularSector else { throw KaitoError.malformed("cfb \(label) chain sector \(current)") }
            guard UInt64(current) < sectorCount else { throw KaitoError.truncated }
            guard Int(current) < fat.count else { throw KaitoError.malformed("cfb \(label) chain leaves the fat") }
            guard seen.insert(current).inserted else { throw KaitoError.malformed("cfb \(label) chain cycle") }
            if let maximumSectors, UInt64(result.count) >= maximumSectors {
                // 宣言より長い chain: 宣言分だけ使う（§2.7 は chain ≥ size を要求する）。
                break
            }
            result.append(current)
            current = fat[Int(current)]
        }
        return result
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("cfb entry index \(entry.index)")
        }
        let record = records[entry.index].entry
        guard record.type == .stream else {
            return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits)
        }
        let size = record.size
        if size == 0 { return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits) }
        let sectorSize = UInt64(header.sectorSize)
        let sectorCount = (source.length - sectorSize) / sectorSize
        var runs: [(offset: UInt64, length: UInt64)] = []
        if size < UInt64(header.miniStreamCutoff) {
            // §2.6.3: mini FAT の chain。mini sector n は mini stream の n × 64 byte 目。
            let miniSize = UInt64(header.miniSectorSize)
            let needed = (size + miniSize - 1) / miniSize
            var current = record.startSector
            var seen = Set<UInt32>()
            var remaining = size
            while remaining > 0 {
                guard current <= CFBHeader.maxRegularSector, Int(current) < miniFAT.count else { throw KaitoError.malformed("cfb mini chain") }
                guard seen.insert(current).inserted, UInt64(seen.count) <= needed else { throw KaitoError.malformed("cfb mini chain cycle") }
                let miniOffset = UInt64(current) * miniSize
                let length = min(remaining, miniSize)
                guard miniOffset + length <= miniStreamSize else { throw KaitoError.malformed("cfb mini sector outside the mini stream") }
                let index = Int(miniOffset / sectorSize)
                guard index < miniStreamSectors.count else { throw KaitoError.malformed("cfb mini stream chain") }
                let fileOffset = UInt64(miniStreamSectors[index] + 1) * sectorSize + miniOffset % sectorSize
                if let last = runs.last, last.offset + last.length == fileOffset {
                    runs[runs.count - 1].length += length
                } else {
                    runs.append((fileOffset, length))
                }
                remaining -= length
                current = miniFAT[Int(current)]
            }
        } else {
            let needed = (size + sectorSize - 1) / sectorSize
            let sectors = try Self.chain(from: record.startSector, fat: fat, sectorCount: sectorCount, maximumSectors: needed, label: "stream")
            guard UInt64(sectors.count) == needed else { throw KaitoError.truncated }
            var remaining = size
            for location in sectors {
                let fileOffset = UInt64(location + 1) * sectorSize
                let length = min(remaining, sectorSize)
                if let last = runs.last, last.offset + last.length == fileOffset {
                    runs[runs.count - 1].length += length
                } else {
                    runs.append((fileOffset, length))
                }
                remaining -= length
            }
        }
        for run in runs { guard run.offset + run.length <= source.length else { throw KaitoError.truncated } }
        if runs.count == 1 {
            return try EntryStream(source: source, offset: runs[0].offset, length: runs[0].length, limits: limits)
        }
        return try EntryStream(decompressor: ByteRunDecompressor(source: source, runs: runs), length: size,
                               expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }
}

/// metadata（DIFAT / FAT / directory / mini FAT）の読み取り量を `maxMetadataSize` で抑える。
struct CFBMetadataBudget {
    let limits: ReadLimits
    private var total: UInt64 = 0
    init(limits: ReadLimits) { self.limits = limits }
    mutating func charge(_ bytes: UInt64) throws {
        total = try Checked.add(total, bytes)
        try Checked.size(total, limit: limits.maxMetadataSize)
    }
}
