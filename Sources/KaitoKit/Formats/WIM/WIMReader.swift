import Foundation

/// Windows Imaging（WIM）の reader。lookup table の SHA-1 で resource を引き、metadata resource の
/// DIRENTRY 木を image ごとに辿る。image が複数なら `<index>/` を先頭に付ける。
final class WIMReader: FormatReader {
    private struct Record {
        var resource: WIMLookupEntry?
        var unsupported: String?
    }
    private struct Pending {
        let parent: Int?
        let name: String
        let kind: EntryKind
        let date: Date?
        var specific: [String: String]
        let record: Record
    }

    let format: ArchiveFormat = .wim
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf16LittleEndian
    private let source: any ByteSource
    private let header: WIMHeader
    private let compression: WIMCompression
    private let options: ReaderOptions
    private let records: [Record]

    static let attributeDirectory: UInt32 = 0x10
    static let attributeReparsePoint: UInt32 = 0x400
    static let attributeEncrypted: UInt32 = 0x4000
    /// [MS-FSCC] 2.1.2.1: IO_REPARSE_TAG_SYMLINK / IO_REPARSE_TAG_MOUNT_POINT。
    static let reparseTagSymbolicLink: UInt32 = 0xA000_000C
    static let reparseTagMountPoint: UInt32 = 0xA000_0003
    /// DIRENTRY の固定部（黒箱で確定: whitepaper の struct より 4 byte 長い）。
    static let directoryEntryFixedSize = 102
    static let streamEntryFixedSize = 38

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        self.options = options
        header = try WIMHeader(try readByteRange(source: source, offset: 0, count: WIMHeader.size))
        compression = try header.compression
        guard header.totalParts <= 1 || header.partNumber == 1 else {
            throw KaitoError.unsupportedMethod("WIM spanned part \(header.partNumber) of \(header.totalParts) (open the first part)")
        }
        let budget = ISOMetadataBudget(options.limits)
        // lookup table: 50 byte の entry 列（part 1 では他 part の resource も含む）。
        let table = header.lookupTable
        guard !table.isEmpty, !table.isCompressed else { throw KaitoError.malformed("wim lookup table header") }
        try Checked.size(table.packedSize, limit: options.limits.maxMetadataSize)
        try budget.charge(table.packedSize)
        let tableBytes = try readByteRange(source: source, offset: table.offset, count: Int(table.packedSize))
        guard tableBytes.count % WIMLookupEntry.size == 0 else { throw KaitoError.malformed("wim lookup table length") }
        let entryCount = tableBytes.count / WIMLookupEntry.size
        guard entryCount <= options.limits.maxMetadataRecordCount * 16 else { throw KaitoError.limitExceeded("wim lookup table entries") }
        var byHash: [[UInt8]: WIMLookupEntry] = [:]
        var metadata: [WIMLookupEntry] = []
        for index in 0..<entryCount {
            let entry = WIMLookupEntry(tableBytes, index * WIMLookupEntry.size)
            if entry.header.isMetadata {
                metadata.append(entry)
            } else if byHash[entry.hash] == nil {
                byHash[entry.hash] = entry
            }
        }
        guard !metadata.isEmpty else { throw KaitoError.malformed("wim has no metadata resource") }
        guard metadata.count <= 1024 else { throw KaitoError.limitExceeded("wim image count") }

        var pending: [Pending] = []
        for (imageIndex, image) in metadata.enumerated() {
            guard image.partNumber == header.partNumber || image.partNumber == 0 else {
                throw KaitoError.unsupportedMethod("WIM metadata in another part")
            }
            let bytes = try Self.readResource(image.header, source: source, chunkSize: header.chunkSize, compression: compression,
                                              limits: options.limits, budget: budget)
            var root: Int?
            if metadata.count > 1 {
                root = pending.count
                pending.append(Pending(parent: nil, name: String(imageIndex + 1), kind: .directory, date: nil,
                                       specific: ["image": String(imageIndex + 1)], record: Record()))
            }
            try Self.walk(metadata: bytes, image: imageIndex + 1, root: root, byHash: byHash, header: header, source: source,
                          options: options, budget: budget, into: &pending)
        }
        (entries, records) = try Self.finalize(pending, compression: compression, options: options, budget: budget)
    }

    /// resource を全部読む（metadata 用）。1 つの metadata resource は `maxTotalMetadataSize` 以内
    /// （install.wim の metadata は数十 MB）。buffer は image を辿った後に捨てるので累積予算には entry 由来の
    /// 費用だけを加え、buffer 自体は image ごとの上限で抑える。
    private static func readResource(_ resource: WIMResourceHeader, source: any ByteSource, chunkSize: UInt32,
                                     compression: WIMCompression, limits: ReadLimits, budget: ISOMetadataBudget) throws -> [UInt8] {
        try Checked.size(resource.originalSize, limit: limits.maxTotalMetadataSize)
        if !resource.isCompressed {
            guard resource.packedSize == resource.originalSize else { throw KaitoError.malformed("wim stored resource size") }
            return try readByteRange(source: source, offset: resource.offset, count: Int(resource.originalSize))
        }
        let decompressor = try WIMResourceDecompressor(source: source, resource: resource, chunkSize: chunkSize,
                                                       compression: compression, limits: limits)
        var output = [UInt8](repeating: 0, count: Int(resource.originalSize))
        var filled = 0
        while filled < output.count {
            let count = try output.withUnsafeMutableBytes { buffer in
                try decompressor.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]))
            }
            guard count > 0 else { throw KaitoError.truncated }
            filled += count
        }
        return output
    }

    // MARK: - metadata walk

    private struct DirectoryEntry {
        let length: UInt64
        let attributes: UInt32
        let subdirectoryOffset: UInt64
        let writeTime: UInt64
        let hash: [UInt8]
        let reparseTag: UInt32
        let hardLink: UInt64
        let streamCount: Int
        let name: String
        let end: Int
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func directoryEntry(_ m: [UInt8], at offset: Int) throws -> DirectoryEntry? {
        guard offset + 8 <= m.count else { throw KaitoError.truncated }
        let length = WIMBytes.u64(m, offset)
        if length == 0 { return nil }
        guard length >= UInt64(directoryEntryFixedSize), length <= UInt64(m.count - offset), length % 8 == 0 else {
            throw KaitoError.malformed("wim directory entry length")
        }
        let nameLength = Int(WIMBytes.u16(m, offset + 100))
        let shortLength = Int(WIMBytes.u16(m, offset + 98))
        guard nameLength % 2 == 0, shortLength % 2 == 0,
              UInt64(directoryEntryFixedSize + nameLength + shortLength) <= length else {
            throw KaitoError.malformed("wim directory entry name length")
        }
        guard let name = utf16(m[(offset + 102)..<(offset + 102 + nameLength)]) else {
            throw KaitoError.malformed("wim directory entry name")
        }
        return DirectoryEntry(length: length, attributes: WIMBytes.u32(m, offset + 8), subdirectoryOffset: WIMBytes.u64(m, offset + 16),
                              writeTime: WIMBytes.u64(m, offset + 56), hash: Array(m[(offset + 64)..<(offset + 84)]),
                              reparseTag: WIMBytes.u32(m, offset + 84), hardLink: WIMBytes.u64(m, offset + 84),
                              streamCount: Int(WIMBytes.u16(m, offset + 96)), name: name, end: offset + Int(length))
    }

    private struct StreamEntry {
        let hash: [UInt8]
        let name: String
        let end: Int
    }

    private static func streamEntry(_ m: [UInt8], at offset: Int) throws -> StreamEntry {
        guard offset + streamEntryFixedSize <= m.count else { throw KaitoError.truncated }
        let length = WIMBytes.u64(m, offset)
        let nameLength = Int(WIMBytes.u16(m, offset + 36))
        guard length >= UInt64(streamEntryFixedSize + nameLength), length <= UInt64(m.count - offset), length % 8 == 0,
              nameLength % 2 == 0 else {
            throw KaitoError.malformed("wim stream entry length")
        }
        guard let name = utf16(m[(offset + 38)..<(offset + 38 + nameLength)]) else { throw KaitoError.malformed("wim stream name") }
        return StreamEntry(hash: Array(m[(offset + 16)..<(offset + 36)]), name: name, end: offset + Int(length))
    }

    private static func walk(metadata m: [UInt8], image: Int, root: Int?, byHash: [[UInt8]: WIMLookupEntry], header: WIMHeader,
                             source: any ByteSource, options: ReaderOptions, budget: ISOMetadataBudget, into pending: inout [Pending]) throws {
        guard m.count >= 8 else { throw KaitoError.truncated }
        // SECURITYBLOCK_DISK: total length、entry 数、entry 長 …、descriptor 本体。root DIRENTRY はその直後の 8 byte 境界。
        let securityLength = Int(WIMBytes.u32(m, 0))
        guard securityLength >= 8, securityLength <= m.count else { throw KaitoError.malformed("wim security block length") }
        let rootOffset = (securityLength + 7) / 8 * 8
        guard let rootEntry = try directoryEntry(m, at: rootOffset) else { throw KaitoError.malformed("wim root directory entry missing") }
        guard rootEntry.attributes & attributeDirectory != 0 else { throw KaitoError.malformed("wim root is not a directory") }
        let zeroHash = [UInt8](repeating: 0, count: 20)
        var stack: [(offset: UInt64, parent: Int?, depth: Int)] = [(rootEntry.subdirectoryOffset, root, root == nil ? 0 : 1)]
        var visited = Set<UInt64>()
        var directoryCount = 0
        while let node = stack.popLast() {
            guard node.offset != 0 else { continue }
            guard visited.insert(node.offset).inserted else { throw KaitoError.malformed("wim directory cycle") }
            directoryCount += 1
            guard directoryCount <= options.limits.maxMetadataRecordCount else { throw KaitoError.limitExceeded("wim directory count") }
            guard node.offset < UInt64(m.count) else { throw KaitoError.malformed("wim subdirectory offset") }
            var offset = Int(node.offset)
            var children: [(offset: UInt64, parent: Int?, depth: Int)] = []
            while let entry = try directoryEntry(m, at: offset) {
                guard pending.count < options.limits.maxEntryCount else { throw KaitoError.limitExceeded("wim entry count") }
                try budget.charge(UInt64(256 + entry.name.utf8.count))
                var streamOffset = entry.end
                var streams: [StreamEntry] = []
                for _ in 0..<entry.streamCount {
                    let stream = try streamEntry(m, at: streamOffset)
                    streams.append(stream)
                    streamOffset = stream.end
                }
                offset = streamOffset
                let isDirectory = entry.attributes & attributeDirectory != 0
                var specific: [String: String] = ["attributes": "0x" + String(entry.attributes, radix: 16), "image": String(image)]
                if entry.attributes & 0x2 != 0 { specific["hidden"] = "true" }
                if entry.hardLink != 0, entry.attributes & attributeReparsePoint == 0 { specific["hardLinkGroup"] = String(entry.hardLink) }
                var kind: EntryKind = isDirectory ? .directory : .file
                var record = Record()
                // 本文の hash: DIRENTRY の hash、無ければ名前の無い STREAMENTRY。
                var mainHash = entry.hash
                if mainHash == zeroHash, let unnamed = streams.first(where: { $0.name.isEmpty }) { mainHash = unnamed.hash }
                if entry.attributes & attributeReparsePoint != 0 {
                    specific["reparseTag"] = "0x" + String(entry.reparseTag, radix: 16)
                    // symbolic link / junction は resource の REPARSE_DATA_BUFFER から target を読む
                    // （[MS-FSCC] 2.1.2.4 / 2.1.2.5。7-Zip も同じ resource から symlink を作る）。
                    if let target = try reparseTarget(tag: entry.reparseTag, hash: mainHash, byHash: byHash, header: header, source: source,
                                                      options: options, budget: budget, zeroHash: zeroHash) {
                        kind = .symlink
                        specific["linkPath"] = target.path
                        if target.absolute { specific["linkTargetAbsolute"] = "true" }
                        record = Record()
                    } else {
                        kind = .other
                        specific["unsupported"] = "WIM reparse point"
                        record.unsupported = "WIM reparse point 0x\(String(entry.reparseTag, radix: 16))"
                    }
                } else if entry.attributes & attributeEncrypted != 0 {
                    specific["unsupported"] = "WIM encrypted (EFS) file"
                    record.unsupported = "WIM encrypted (EFS) file"
                }
                if !isDirectory, kind == .file, mainHash != zeroHash {
                    specific["sha1"] = mainHash.map { String(format: "%02x", $0) }.joined()
                    if let resource = byHash[mainHash] {
                        record.resource = resource
                        if resource.partNumber != header.partNumber {
                            record.unsupported = "WIM resource in part \(resource.partNumber)"
                            specific["unsupported"] = record.unsupported
                        }
                    } else {
                        record.unsupported = "WIM resource missing"
                        specific["unsupported"] = record.unsupported
                    }
                }
                let index = pending.count
                pending.append(Pending(parent: node.parent, name: entry.name, kind: kind, date: WIMBytes.fileTime(entry.writeTime),
                                       specific: specific, record: record))
                // 名前付き stream（alternate data stream）は `name:stream` として公開する。
                for stream in streams where !stream.name.isEmpty {
                    var streamSpecific = specific
                    streamSpecific["stream"] = stream.name
                    streamSpecific.removeValue(forKey: "unsupported")
                    var streamRecord = Record()
                    if stream.hash != zeroHash { streamSpecific["sha1"] = stream.hash.map { String(format: "%02x", $0) }.joined() }
                    if let resource = byHash[stream.hash] {
                        streamRecord.resource = resource
                        if resource.partNumber != header.partNumber {
                            streamRecord.unsupported = "WIM resource in part \(resource.partNumber)"
                            streamSpecific["unsupported"] = streamRecord.unsupported
                        }
                    } else if stream.hash != zeroHash {
                        streamRecord.unsupported = "WIM resource missing"
                        streamSpecific["unsupported"] = streamRecord.unsupported
                    }
                    guard pending.count < options.limits.maxEntryCount else { throw KaitoError.limitExceeded("wim entry count") }
                    pending.append(Pending(parent: node.parent, name: entry.name + ":" + stream.name, kind: .file,
                                           date: WIMBytes.fileTime(entry.writeTime), specific: streamSpecific, record: streamRecord))
                }
                if isDirectory, entry.subdirectoryOffset != 0 {
                    guard node.depth < options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("wim directory depth") }
                    children.append((entry.subdirectoryOffset, index, node.depth + 1))
                }
            }
            stack.append(contentsOf: children.reversed())
        }
    }

    /// reparse resource（REPARSE_DATA_BUFFER: tag、data length、reserved、本体）から link 先を読む。
    /// symbolic link は Flags bit 0（SYMLINK_FLAG_RELATIVE）、junction は常に絶対。`\??\` を外し `\` を `/` にする。
    private static func reparseTarget(tag: UInt32, hash: [UInt8], byHash: [[UInt8]: WIMLookupEntry], header: WIMHeader, source: any ByteSource,
                                      options: ReaderOptions, budget: ISOMetadataBudget, zeroHash: [UInt8]) throws -> (path: String, absolute: Bool)? {
        guard tag == reparseTagSymbolicLink || tag == reparseTagMountPoint, hash != zeroHash,
              let resource = byHash[hash], resource.partNumber == header.partNumber,
              resource.header.originalSize >= 16, resource.header.originalSize <= 65536 else { return nil }
        let bytes: [UInt8]
        do {
            bytes = try readResource(resource.header, source: source, chunkSize: header.chunkSize,
                                     compression: try header.compression, limits: options.limits, budget: budget)
        } catch { return nil }
        guard WIMBytes.u32(bytes, 0) == tag else { return nil }
        let dataLength = Int(WIMBytes.u16(bytes, 4))
        let bodyStart = 8
        guard bodyStart + dataLength <= bytes.count, dataLength >= (tag == reparseTagSymbolicLink ? 12 : 8) else { return nil }
        let substituteOffset = Int(WIMBytes.u16(bytes, bodyStart)), substituteLength = Int(WIMBytes.u16(bytes, bodyStart + 2))
        let printOffset = Int(WIMBytes.u16(bytes, bodyStart + 4)), printLength = Int(WIMBytes.u16(bytes, bodyStart + 6))
        let flags = tag == reparseTagSymbolicLink ? WIMBytes.u32(bytes, bodyStart + 8) : 0
        let pathBuffer = bodyStart + (tag == reparseTagSymbolicLink ? 12 : 8)
        func name(_ offset: Int, _ length: Int) -> String? {
            guard length % 2 == 0, pathBuffer + offset + length <= bodyStart + dataLength else { return nil }
            return utf16(bytes[(pathBuffer + offset)..<(pathBuffer + offset + length)])
        }
        guard var target = (printLength > 0 ? name(printOffset, printLength) : nil) ?? name(substituteOffset, substituteLength),
              !target.isEmpty, !target.utf8.contains(0) else { return nil }
        if target.hasPrefix("\\??\\") { target.removeFirst(4) }
        target = target.replacingOccurrences(of: "\\", with: "/")
        let absolute = tag == reparseTagMountPoint || flags & 1 == 0
        return (target, absolute)
    }

    private static func finalize(_ pending: [Pending], compression: WIMCompression, options: ReaderOptions,
                                 budget: ISOMetadataBudget) throws -> ([ArchiveEntry], [Record]) {
        var paths: [Int: [String]] = [:]
        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        for (index, item) in pending.enumerated() {
            guard !item.name.isEmpty, item.name != ".", item.name != "..", !item.name.utf8.contains(where: { $0 == 0 || $0 == 0x2F }) else {
                throw KaitoError.malformed("wim name")
            }
            var components = item.parent.flatMap { paths[$0] } ?? []
            components.append(item.name)
            guard components.count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("wim path component count") }
            paths[index] = components
            let path = components.joined(separator: "/")
            try budget.charge(UInt64(path.utf8.count + 64))
            let size: UInt64? = item.kind == .directory ? 0 : (item.record.resource?.header.originalSize ?? (item.record.unsupported == nil ? 0 : nil))
            let packed: UInt64? = item.kind == .directory ? 0 : (item.record.resource?.header.packedSize ?? (item.record.unsupported == nil ? 0 : nil))
            let compressed = item.record.resource?.header.isCompressed == true
            let method = compressed ? "WIM \(compression.rawValue)" : "WIM (stored)"
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: Array(path.utf8), declaredEncoding: .utf8, isDirectoryHint: item.kind == .directory),
                name: path, pathComponents: components, kind: item.kind, uncompressedSize: size, compressedSize: packed,
                modificationDate: item.date, posixPermissions: nil, isEncrypted: false, solidGroup: -1, crc32: nil,
                methodDescription: method, formatSpecific: item.specific))
            records.append(item.record)
        }
        return (entries, records)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("wim entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let reason = record.unsupported { throw KaitoError.unsupportedMethod(reason) }
        guard let resource = record.resource else {
            return try EntryStream(source: source, offset: 0, length: 0, limits: limits)
        }
        let inner: any Decompressor
        if resource.header.isCompressed {
            inner = try WIMResourceDecompressor(source: source, resource: resource.header, chunkSize: header.chunkSize,
                                                compression: compression, limits: limits)
        } else {
            guard resource.header.packedSize == resource.header.originalSize else { throw KaitoError.malformed("wim stored resource size") }
            inner = try CopyDecompressor(source: source, offset: resource.header.offset, compressedSize: resource.header.originalSize)
        }
        let hashing = WIMHashingDecompressor(inner)
        let expected = resource.hash
        let index = entry.index
        return try EntryStream(decompressor: hashing, length: resource.header.originalSize, expectedCRC32: nil, entryIndex: index,
                               limits: limits, completionCheck: { try hashing.verify(expected: expected, entryIndex: index) })
    }
}
