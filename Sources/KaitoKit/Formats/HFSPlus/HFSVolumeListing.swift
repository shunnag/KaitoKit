import Foundation

// HFS+ / HFSX の catalog を entry 列にし、fork を stream として返す。出典は HFSPlusVolume.swift の先頭。

/// HFS+ volume の catalog を entry 列にする。
final class HFSVolumeListing {
    private struct Record {
        let fileID: UInt32
        let fork: HFSForkData?
        let forkType: UInt8          // 0 = data、0xFF = resource
        let error: KaitoError?
        var decmpfs: (header: DecmpfsHeader, payload: [UInt8])? = nil
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
        var attributeBudget: UInt64 = 0
        let attributes = try items.contains { $0.ownerFlags & 0x20 != 0 }
            ? volume.decmpfsAttributes(limits: limits, budget: &attributeBudget) : [:]

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
                    records.append(Record(fileID: item.nodeID, fork: nil, forkType: 0, error: nil))
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
                var method = "HFS+ (stored)"
                var size: UInt64? = dataSize, packedSize: UInt64? = dataSize
                var compression: (header: DecmpfsHeader, payload: [UInt8])?
                var error: KaitoError?
                if compressed {
                    method = "HFS+ decmpfs"
                    size = nil; packedSize = nil
                    switch attributes[target.nodeID] {
                    case .inline(let bytes):
                        do { compression = (try DecmpfsHeader(attribute: bytes), Array(bytes.dropFirst(16))) }
                        catch let failure as KaitoError { error = failure }
                    case .fork: error = .unsupportedMethod("HFS+ decmpfs attribute stored as a fork")
                    case nil: error = .malformed("hfs+ compressed file without com.apple.decmpfs")
                    }
                    if let compression {
                        try Checked.size(compression.header.uncompressedSize, limit: limits.maxEntrySize)
                        size = compression.header.uncompressedSize
                        packedSize = compression.header.usesResourceFork ? target.resourceFork?.logicalSize ?? 0 : UInt64(compression.payload.count)
                        method = compression.header.methodDescription
                        specific["decmpfsType"] = String(compression.header.compressionType)
                    }
                }
                entries.append(ArchiveEntry(index: entries.count,
                    rawName: RawName(bytes: Array(name.utf8), declaredEncoding: .utf8, isDirectoryHint: false),
                    name: name, pathComponents: path, kind: isSymlink ? .symlink : .file,
                    uncompressedSize: size, compressedSize: packedSize,
                    modificationDate: target.modificationDate, posixPermissions: target.fileMode & 0o7777,
                    isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: method, formatSpecific: specific))
                let resourceCompressed = compression?.header.usesResourceFork == true
                records.append(Record(fileID: target.nodeID, fork: resourceCompressed ? target.resourceFork : target.dataFork,
                                      forkType: resourceCompressed ? 0xFF : 0, error: error, decmpfs: compression))
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
                    records.append(Record(fileID: target.nodeID, fork: resource, forkType: 0xFF, error: nil))
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
        if let error = record.error { throw error }
        if let compression = record.decmpfs {
            var resource: DecmpfsDecompressor.ResourceFork?
            if compression.header.usesResourceFork, let fork = record.fork {
                let extents = try volume.extents(of: fork, fileID: record.fileID, forkType: 0xFF)
                resource = DecmpfsDecompressor.ResourceFork(length: fork.logicalSize) { [volume] offset, count in
                    try volume.readFork(fork: fork, extents: extents, offset: offset, count: count)
                }
            }
            let decoder = try DecmpfsDecompressor(header: compression.header, inlinePayload: compression.payload,
                                                 resourceFork: resource, limits: limits)
            return try EntryStream(decompressor: decoder, length: compression.header.uncompressedSize,
                                   expectedCRC32: nil, entryIndex: entry.index, limits: limits)
        }
        guard let fork = record.fork, fork.logicalSize > 0 else {
            return try EntryStream.empty(entryIndex: entry.index, limits: limits)
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
