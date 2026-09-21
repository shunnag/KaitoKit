import Foundation

/// Apple disk image（UDIF `.dmg` と生の HFS+ image）: UDIF の chunk 表を展開した disk から HFS Plus / HFSX volume を
/// 見つけて file を公開する。HFS+ が無く ISO 9660 / UDF の volume があれば（hdiutil makehybrid）その reader に渡す。
/// partition 表は GPT（UEFI 仕様の header と entry）と Apple Partition Map（Inside Macintosh: Devices）の位置だけを
/// 読み、UDIF なら blkx の開始 sector も候補にする。
final class DMGReader: FormatReader {
    private enum Body {
        case volume(HFSVolumeListing)
        case inner(any FormatReader)
    }

    let format: ArchiveFormat = .dmg
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf8
    private let body: Body

    /// UDIF なら展開後の disk、そうでなければ file 自身。
    static func diskSource(for source: any ByteSource, limits: ReadLimits) throws -> any ByteSource {
        if let trailer = try UDIFTrailer.read(source: source) {
            return try UDIFDiskByteSource(file: source, trailer: trailer, limits: limits)
        }
        return source
    }

    /// volume の開始 offset（byte）の候補: bare volume、GPT / APM の partition、UDIF の blkx。
    static func volumeCandidates(disk: any ByteSource) throws -> [UInt64] {
        var candidates: [UInt64] = [0]
        guard disk.length >= 1024 else { return candidates }
        let sector1 = try readByteRange(source: disk, offset: 512, count: 512)
        if Array(sector1[0..<8]) == Array("EFI PART".utf8) {
            // UEFI GPT header（little-endian）: partition entry LBA @72、entry 数 @80、entry size @84。
            // entry: starting LBA @32、ending LBA @40。
            let entryLBA = UInt64(sector1[72]) | UInt64(sector1[73]) << 8 | UInt64(sector1[74]) << 16 | UInt64(sector1[75]) << 24
                | UInt64(sector1[76]) << 32 | UInt64(sector1[77]) << 40 | UInt64(sector1[78]) << 48 | UInt64(sector1[79]) << 56
            let count = Int(UInt32(sector1[80]) | UInt32(sector1[81]) << 8 | UInt32(sector1[82]) << 16 | UInt32(sector1[83]) << 24)
            let size = Int(UInt32(sector1[84]) | UInt32(sector1[85]) << 8 | UInt32(sector1[86]) << 16 | UInt32(sector1[87]) << 24)
            if size >= 128, size <= 4096, count > 0, count <= 1024, entryLBA > 0,
               (try? Checked.add(Checked.mul(entryLBA, 512), UInt64(count * size))) ?? UInt64.max <= disk.length {
                let table = try readByteRange(source: disk, offset: entryLBA * 512, count: count * size)
                for index in 0..<count {
                    let o = index * size
                    guard table[o..<(o + 16)].contains(where: { $0 != 0 }) else { continue }     // 空 entry
                    var start: UInt64 = 0
                    for byte in 0..<8 { start |= UInt64(table[o + 32 + byte]) << (8 * byte) }
                    if let offset = try? Checked.mul(start, 512), offset < disk.length { candidates.append(offset) }
                }
            }
        } else if sector1[0] == 0x50, sector1[1] == 0x4D {
            // Apple Partition Map（big-endian）: 各 entry は 1 sector。pmMapBlkCnt @4、pmPyPartStart @8、pmPartBlkCnt @12。
            let mapCount = min(Int(HFSBytes.u32(sector1, 4)), 64)
            for index in 0..<mapCount {
                let offset = UInt64(index + 1) * 512
                guard offset + 512 <= disk.length else { break }
                let entry = index == 0 ? sector1 : try readByteRange(source: disk, offset: offset, count: 512)
                guard entry[0] == 0x50, entry[1] == 0x4D else { break }
                if let start = try? Checked.mul(UInt64(HFSBytes.u32(entry, 8)), 512), start < disk.length { candidates.append(start) }
            }
        }
        if let udif = disk as? UDIFDiskByteSource {
            for table in udif.tables where table.sectorCount > 0 {
                if let offset = try? Checked.mul(table.firstSector, 512), offset < disk.length { candidates.append(offset) }
            }
        }
        var seen = Set<UInt64>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// `offset` に HFS+ / HFSX の volume header があるか。
    static func hasHFSPlusVolume(disk: any ByteSource, at offset: UInt64) throws -> Bool {
        guard let end = try? Checked.add(offset, 1536), end <= disk.length else { return false }
        return HFSVolumeHeader.isPlausible(try readByteRange(source: disk, offset: offset + 1024, count: 512))
    }

    /// 検出: koly を持つ UDIF か、HFS+ の volume を含む disk image。
    static func detect(source: any ByteSource, limits: ReadLimits) throws -> Bool {
        let trailer = try UDIFTrailer.read(source: source)
        if trailer != nil { return true }
        let disk = source
        for offset in try volumeCandidates(disk: disk) where try hasHFSPlusVolume(disk: disk, at: offset) { return true }
        return false
    }

    init(source: any ByteSource, options: ReaderOptions) throws {
        let limits = options.limits
        let disk = try Self.diskSource(for: source, limits: limits)
        let candidates = try Self.volumeCandidates(disk: disk)
        if let offset = try candidates.first(where: { try Self.hasHFSPlusVolume(disk: disk, at: $0) }) {
            let listing = try HFSVolumeListing(volume: HFSPlusVolume(source: disk, baseOffset: offset), options: options)
            body = .volume(listing)
            entries = listing.entries
            return
        }
        // ISO 9660 / UDF（hdiutil makehybrid の hybrid image、UDF volume）: partition か disk 先頭。
        for offset in candidates {
            guard let end = try? Checked.add(offset, 34816), end <= disk.length else { continue }
            let sector = try readByteRange(source: disk, offset: offset + 32768, count: 2048)
            let volumeSource: any ByteSource = offset == 0 ? disk : try RebasedByteSource(source: disk, baseOffset: offset)
            if ISOReader.isPlausibleVolumeDescriptor(sector) {
                let inner = try ISOReader(source: volumeSource, options: options)
                body = .inner(inner)
                entries = inner.entries
                return
            }
            if try UDFVolume.hasRecognitionSequence(source: volumeSource, pureOnly: true) {
                let inner = try UDFReader(source: volumeSource, options: options)
                body = .inner(inner)
                entries = inner.entries
                return
            }
        }
        // APFS（container superblock の signature "NXSB" が block 0）は範囲外。
        if disk.length >= 40, Array(try readByteRange(source: disk, offset: 32, count: 4)) == Array("NXSB".utf8) {
            throw KaitoError.unsupportedMethod("APFS volume in a disk image")
        }
        for offset in candidates where offset + 40 <= disk.length {
            if Array(try readByteRange(source: disk, offset: offset + 32, count: 4)) == Array("NXSB".utf8) {
                throw KaitoError.unsupportedMethod("APFS volume in a disk image")
            }
        }
        throw KaitoError.unsupportedMethod("disk image without an HFS+, ISO 9660 or UDF volume")
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        switch body {
        case .volume(let listing): return try listing.stream(for: entry, limits: limits)
        case .inner(let inner): return try inner.stream(for: entry, limits: limits)
        }
    }
}

/// HFS+ volume の catalog を entry 列にする。
final class HFSVolumeListing {
    private struct Record {
        let fileID: UInt32
        let fork: HFSForkData?
        let forkType: UInt8          // 0 = data、0xFF = resource
        let unsupported: String?
    }

    let entries: [ArchiveEntry]
    private let volume: HFSPlusVolume
    private let records: [Record]

    init(volume: HFSPlusVolume, options: ReaderOptions) throws {
        self.volume = volume
        let limits = options.limits
        var budget: UInt64 = 0
        try volume.loadOverflowExtents(limits: limits, budget: &budget)
        let items = try volume.catalogItems(limits: limits, budget: &budget)

        // folder ID → (親 ID、名前)。root は ID 2（親 1）。
        var folders: [UInt32: (parent: UInt32, name: String)] = [:]
        var children: [UInt32: [HFSCatalogItem]] = [:]
        var inodes: [UInt32: HFSCatalogItem] = [:]      // hard link の link reference → indirect node file
        var privateDataID: UInt32?
        var privateDirectoryID: UInt32?
        for item in items {
            if item.kind == .folder {
                folders[item.nodeID] = (item.parentID, item.name)
                if item.parentID == 2 {
                    if item.name == "\0\0\0\0HFS+ Private Data" { privateDataID = item.nodeID }
                    if item.name == ".HFS+ Private Directory Data\r" { privateDirectoryID = item.nodeID }
                }
            }
            children[item.parentID, default: []].append(item)
        }
        if let privateDataID {
            for item in children[privateDataID] ?? [] where item.kind == .file && item.name.hasPrefix("iNode") {
                if let number = UInt32(item.name.dropFirst(5)) { inodes[number] = item }
            }
        }

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        var visited = Set<UInt32>()
        let rootName = folders[2]?.name
        func walk(folderID: UInt32, components: [String], depth: Int) throws {
            guard visited.insert(folderID).inserted else { throw KaitoError.malformed("hfs+ folder tree cycle") }
            guard depth <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("hfs+ path depth") }
            let sorted = (children[folderID] ?? []).sorted { $0.name < $1.name }
            for item in sorted {
                if folderID == 2, item.nodeID == privateDataID || item.nodeID == privateDirectoryID { continue }
                guard entries.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("hfs+ entry count") }
                let path = components + [item.name]
                guard !item.name.isEmpty, item.name != ".", item.name != "..", !item.name.contains("/") else {
                    throw KaitoError.malformed("hfs+ item name")
                }
                let name = path.joined(separator: "/")
                var specific: [String: String] = [:]
                if let rootName { specific["volumeName"] = rootName }
                if item.kind == .folder {
                    if item.fileType == Array("fdrp".utf8), item.creator == Array("MACS".utf8) {
                        specific["directoryHardLink"] = String(item.special)
                    }
                    entries.append(ArchiveEntry(index: entries.count,
                        rawName: RawName(bytes: Array(name.utf8), declaredEncoding: .utf8, isDirectoryHint: true),
                        name: name, pathComponents: path, kind: .directory, uncompressedSize: 0, compressedSize: 0,
                        modificationDate: item.modificationDate, posixPermissions: item.fileMode & 0o7777 == 0 ? nil : item.fileMode & 0o7777,
                        isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "HFS+ (stored)", formatSpecific: specific))
                    records.append(Record(fileID: item.nodeID, fork: nil, forkType: 0, unsupported: nil))
                    try walk(folderID: item.nodeID, components: path, depth: depth + 1)
                    continue
                }
                // file: hard link は indirect node file の fork を使う。
                var target = item
                if item.fileType == Array("hlnk".utf8), item.creator == Array("hfs+".utf8) {
                    specific["hardLink"] = String(item.special)
                    if let inode = inodes[item.special] { target = inode } else { specific["danglingHardLink"] = "true" }
                }
                let isSymlink = target.fileMode & 0o170000 == 0o120000
                let compressed = target.ownerFlags & 0x20 != 0          // UF_COMPRESSED（chflags(2)）
                if compressed { specific["hfsCompressed"] = "true" }
                if target.fileType.contains(where: { $0 != 0 }) {
                    specific["macType"] = String(decoding: target.fileType.map { $0 < 0x20 || $0 > 0x7E ? 0x3F : $0 }, as: UTF8.self)
                    specific["macCreator"] = String(decoding: target.creator.map { $0 < 0x20 || $0 > 0x7E ? 0x3F : $0 }, as: UTF8.self)
                }
                if isSymlink { specific["linkTargetStoredAsData"] = "true" }
                let dataSize = target.dataFork?.logicalSize ?? 0
                try Checked.size(dataSize, limit: limits.maxEntrySize)
                let method = compressed ? "HFS+ compressed (decmpfs)" : "HFS+ (stored)"
                entries.append(ArchiveEntry(index: entries.count,
                    rawName: RawName(bytes: Array(name.utf8), declaredEncoding: .utf8, isDirectoryHint: false),
                    name: name, pathComponents: path, kind: isSymlink ? .symlink : .file,
                    uncompressedSize: compressed ? nil : dataSize, compressedSize: compressed ? nil : dataSize,
                    modificationDate: target.modificationDate, posixPermissions: target.fileMode & 0o7777,
                    isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: method, formatSpecific: specific))
                records.append(Record(fileID: target.nodeID, fork: target.dataFork, forkType: 0,
                                      unsupported: compressed ? "HFS+ compressed file (decmpfs)" : nil))
                // decmpfs（UF_COMPRESSED）の file では resource fork が圧縮 data の置き場なので fork として出さない。
                if let resource = target.resourceFork, resource.logicalSize > 0, !isSymlink, !compressed {
                    try Checked.size(resource.logicalSize, limit: limits.maxEntrySize)
                    let forkPath = path + ["..namedfork", "rsrc"]
                    var forkSpecific = specific
                    forkSpecific["fork"] = "resource"
                    entries.append(ArchiveEntry(index: entries.count,
                        rawName: RawName(bytes: Array((name + "/..namedfork/rsrc").utf8), declaredEncoding: .utf8, isDirectoryHint: false),
                        name: name + "/..namedfork/rsrc", pathComponents: forkPath, kind: .file,
                        uncompressedSize: resource.logicalSize, compressedSize: resource.logicalSize,
                        modificationDate: target.modificationDate, posixPermissions: target.fileMode & 0o7777,
                        isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "HFS+ (stored)", formatSpecific: forkSpecific))
                    records.append(Record(fileID: target.nodeID, fork: resource, forkType: 0xFF, unsupported: nil))
                }
            }
        }
        try walk(folderID: 2, components: [], depth: 0)
        self.entries = entries
        self.records = records
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("hfs+ entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let reason = record.unsupported { throw KaitoError.unsupportedMethod(reason) }
        guard let fork = record.fork, fork.logicalSize > 0 else {
            return try EntryStream(source: DataByteSource(Data()), offset: 0, length: 0, limits: limits)
        }
        let extents = try volume.extents(of: fork, fileID: record.fileID, forkType: record.forkType)
        var runs: [(offset: UInt64, length: UInt64)] = []
        var remaining = fork.logicalSize
        for extent in extents where remaining > 0 {
            let length = min(remaining, UInt64(extent.blockCount) * volume.blockSize)
            let offset = try Checked.add(volume.baseOffset, Checked.mul(UInt64(extent.startBlock), volume.blockSize))
            if let last = runs.last, last.offset + last.length == offset { runs[runs.count - 1].length += length }
            else { runs.append((offset, length)) }
            remaining -= length
        }
        guard remaining == 0 else { throw KaitoError.truncated }
        if runs.count == 1 {
            return try EntryStream(source: volume.source, offset: runs[0].offset, length: runs[0].length, limits: limits)
        }
        return try EntryStream(decompressor: ByteRunDecompressor(source: volume.source, runs: runs), length: fork.logicalSize,
                               expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }
}
