import Foundation

/// file の本文を構成する区間。未記録・未割当の extent は #00（4/12）。
enum UDFDataExtent {
    case recorded(ISOSection)
    case zero(UInt64)
    case inline([UInt8])

    var length: UInt64 {
        switch self {
        case .recorded(let section): return section.length
        case .zero(let count): return count
        case .inline(let bytes): return UInt64(bytes.count)
        }
    }
}

/// ECMA-167 Part 4 の file 構造: FSD、ICB 階層、directory、named stream を辿って entry を作る。
/// UDF 専用 image では `UDFReader` が、ISO 9660 との hybrid では `ISOReader` が使う。
final class UDFFileSystem {
    struct Record {
        var extents: [UDFDataExtent]
        var length: UInt64
        var unsupported: String?
    }
    private struct Pending {
        let parent: Int?
        let name: String
        let kind: EntryKind
        let date: Date?
        let permissions: UInt16?
        var specific: [String: String]
        let record: Record
    }
    private struct Node {
        let entry: UDFFileEntry
        let partition: Int
        let icbBlock: UInt32
        let parent: Int?
        let depth: Int
        let ancestors: Set<UInt64>
    }

    static let resourceForkStreamName = "*UDF Macintosh Resource Fork"

    let volume: UDFVolume
    let entries: [ArchiveEntry]
    private let records: [Record]
    private let options: ReaderOptions
    private var budget: UDFMetadataBudget { volume.budget }

    var revisionDescription: String {
        String(format: "%X.%02X", volume.revision >> 8, volume.revision & 0xFF)
    }

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.options = options
        volume = try UDFVolume(source: source, limits: options.limits)
        let root = try Self.rootDirectory(volume: volume)
        let pending = try Self.walk(root, volume: volume, options: options)
        (entries, records) = try Self.finalize(pending, revision: volume.revision, options: options, budget: volume.budget)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("udf entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let reason = record.unsupported { throw KaitoError.unsupportedMethod(reason) }
        if record.extents.count == 1, case .recorded(let section) = record.extents[0] {
            return try EntryStream(source: volume.source, offset: section.offset, length: section.length, limits: limits)
        }
        return try EntryStream(decompressor: UDFExtentDecompressor(source: volume.source, extents: record.extents),
                               length: record.length, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }

    // MARK: - file set and ICB hierarchy

    /// 4/14.1: LVD の Logical Volume Contents Use が指す最初の FSD から root directory の ICB を得る。
    private static func rootDirectory(volume: UDFVolume) throws -> Node {
        let location = volume.fileSetLocation
        guard location.length >= UInt32(volume.blockSize), let partition = location.partition else {
            throw KaitoError.malformed("udf file set descriptor location")
        }
        var block = location.block
        var rootICB: UDFAllocation?
        // 4/8.3.1: 末尾の FSD が Next Extent を持てば続きを辿る。file set number 0 の最後の物を採用する。
        for _ in 0..<64 {
            let b = try volume.readBlock(partition: Int(partition), block: block)
            guard let tag = try UDFTag.parse(b, expectedLocation: block, label: "file set descriptor") else { break }
            if tag.identifier == 8 { break }
            guard tag.identifier == 256 else { throw KaitoError.malformed("udf file set descriptor tag \(tag.identifier)") }
            if UDFBytes.u32(b, 40) == 0 { rootICB = UDFAllocation.long(b, 400) }
            let next = UDFAllocation.long(b, 448)
            if next.length > 0, let nextPartition = next.partition, Int(nextPartition) == Int(partition) {
                block = next.block
                continue
            }
            break
        }
        guard let icb = rootICB, icb.length > 0 else { throw KaitoError.malformed("udf root directory ICB missing") }
        let (entry, icbBlock) = try directEntry(icb: icb, volume: volume)
        guard entry.fileType == 4 else { throw KaitoError.malformed("udf root directory file type \(entry.fileType)") }
        return Node(entry: entry, partition: Int(icb.partition ?? partition), icbBlock: icbBlock, parent: nil, depth: 0, ancestors: [])
    }

    /// 4/8.10 と UDF §6.6: ICB extent の entry を順に読み、indirect entry（tag 259）を辿って最新の
    /// direct entry（FE / EFE）を返す。strategy 4 は 1 entry、4096 は DE + IE の連結リスト。
    static func directEntry(icb: UDFAllocation, volume: UDFVolume) throws -> (UDFFileEntry, UInt32) {
        guard let partition = icb.partition else { throw KaitoError.malformed("udf ICB without a partition") }
        var current = icb
        var latest: (UDFFileEntry, UInt32)?
        var hops = 0
        while true {
            let blocks = max(1, min(Int(current.length) / volume.blockSize, 16))
            var indirect: UDFAllocation?
            for index in 0..<blocks {
                let block = try UInt32(Checked.add(UInt64(current.block), UInt64(index)))
                let b = try volume.readBlock(partition: Int(partition), block: block, charge: UDFVolume.entryCharge)
                guard let tag = try UDFTag.parse(b, expectedLocation: block, label: "ICB entry") else { break }
                switch tag.identifier {
                case 261, 266:
                    latest = (try UDFFileEntry(b, tag: tag, blockSize: volume.blockSize), block)
                case 259:
                    // 4/14.7 indirect entry: 続きの ICB。
                    indirect = UDFAllocation.long(b, 36)
                case 260:
                    break
                default:
                    throw KaitoError.malformed("udf ICB entry tag \(tag.identifier)")
                }
                if indirect != nil || tag.identifier == 260 { break }
            }
            guard let next = indirect, next.length > 0 else { break }
            hops += 1
            guard hops <= 64 else { throw KaitoError.malformed("udf ICB indirect chain") }
            guard next.partition == partition else { throw KaitoError.unsupportedMethod("UDF ICB on another partition") }
            current = next
        }
        guard let entry = latest else { throw KaitoError.malformed("udf ICB has no direct entry") }
        return entry
    }

    /// FE の allocation descriptor から本文区間と partition 空間の block 列を作る。
    /// `blocks` は directory の FID 位置検証用（partition 内 block 番号、inline は ICB の block）。
    private static func extents(of entry: UDFFileEntry, partition reference: Int, icbBlock: UInt32,
                                volume: UDFVolume, blockTable: Bool = false) throws -> (extents: [UDFDataExtent], blocks: [UInt32], unsupported: String?) {
        let length = entry.informationLength
        switch entry.allocationType {
        case 3:
            // 4/14.6.8 flags = 3: Allocation Descriptors field 自体が本文。
            guard UInt64(entry.allocationDescriptors.count) >= length else {
                throw KaitoError.malformed("udf inline data shorter than the information length")
            }
            return ([.inline(Array(entry.allocationDescriptors.prefix(Int(length))))], [icbBlock], nil)
        case 2:
            return ([], [], "UDF extended allocation descriptors")
        case 0, 1:
            break
        default:
            return ([], [], "UDF allocation descriptor type \(entry.allocationType)")
        }
        guard volume.partitions.indices.contains(reference) else { throw KaitoError.malformed("udf partition reference \(reference)") }
        let partition = volume.partitions[reference]
        let allocations = try volume.allocations(of: entry, partition: partition) { block in
            try volume.readBlock(partition: reference, block: block)
        }
        var result: [UDFDataExtent] = []
        var blocks: [UInt32] = []
        var remaining = length
        for allocation in allocations where remaining > 0 {
            // 4/12.1: 本文の後ろの file tail（未記録・割当済）は情報長を超えるので読まない。
            let bytes = min(UInt64(allocation.length), remaining)
            remaining -= bytes
            let target = Int(allocation.partition ?? UInt16(reference))
            switch allocation.type {
            case 0:
                let sections = try volume.physicalRanges(partition: target, block: allocation.block, length: bytes)
                result.append(contentsOf: sections.map { .recorded($0) })
                if blockTable {
                    let count = (bytes + UInt64(volume.blockSize) - 1) / UInt64(volume.blockSize)
                    for index in 0..<count { blocks.append(try UInt32(Checked.add(UInt64(allocation.block), index))) }
                }
            case 1, 2:
                result.append(.zero(bytes))
                if blockTable {
                    let count = (bytes + UInt64(volume.blockSize) - 1) / UInt64(volume.blockSize)
                    for _ in 0..<count { blocks.append(UInt32.max) }
                }
            default:
                throw KaitoError.malformed("udf allocation descriptor type \(allocation.type)")
            }
            guard result.count <= volume.budget.limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("udf extent count")
            }
        }
        guard remaining == 0 else { throw KaitoError.malformed("udf allocation descriptors shorter than the information length") }
        return (result, blocks, nil)
    }

    /// directory の本文を読み、FID の列に分ける。
    private static func directoryEntries(_ node: Node, volume: UDFVolume) throws -> [UDFFileIdentifier] {
        let (extents, blocks, unsupported) = try extents(of: node.entry, partition: node.partition, icbBlock: node.icbBlock,
                                                         volume: volume, blockTable: true)
        if let unsupported { throw KaitoError.unsupportedMethod(unsupported) }
        try Checked.size(node.entry.informationLength, limit: volume.budget.limits.maxMetadataSize)
        try volume.budget.charge(node.entry.informationLength)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(node.entry.informationLength))
        for extent in extents {
            switch extent {
            case .inline(let inline): bytes += inline
            case .zero(let count): bytes += [UInt8](repeating: 0, count: Int(count))
            case .recorded(let section):
                bytes += try readByteRange(source: volume.source, offset: section.offset, count: Int(section.length))
            }
        }
        var result: [UDFFileIdentifier] = []
        var offset = 0
        while offset < bytes.count {
            let blockIndex = offset / volume.blockSize
            guard blockIndex < blocks.count else { throw KaitoError.malformed("udf directory block index") }
            guard let identifier = try UDFFileIdentifier.parse(bytes, offset: offset, location: blocks[blockIndex]) else { break }
            guard result.count < volume.budget.limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("udf directory record count")
            }
            result.append(identifier)
            offset += identifier.totalLength
        }
        return result
    }

    // MARK: - walk

    private static func walk(_ root: Node, volume: UDFVolume, options: ReaderOptions) throws -> [Pending] {
        var result: [Pending] = []
        var stack = [root]
        var directoryCount = 0
        while let node = stack.popLast() {
            directoryCount += 1
            guard directoryCount <= 65536 else { throw KaitoError.limitExceeded("udf directory count") }
            var ancestors = node.ancestors
            ancestors.insert(UInt64(node.partition) << 32 | UInt64(node.icbBlock))
            var children: [Node] = []
            for identifier in try directoryEntries(node, volume: volume) where !identifier.isParent && !identifier.isDeleted {
                guard result.count < volume.budget.limits.maxEntryCount else { throw KaitoError.limitExceeded("udf entry count") }
                guard identifier.icb.length > 0 else { throw KaitoError.malformed("udf file identifier without an ICB") }
                let (entry, icbBlock) = try directEntry(icb: identifier.icb, volume: volume)
                let partition = Int(identifier.icb.partition ?? UInt16(node.partition))
                var specific: [String: String] = [:]
                if identifier.isHidden { specific["hidden"] = "true" }
                if entry.uid != 0xFFFF_FFFF { specific["uid"] = String(entry.uid) }
                if entry.gid != 0xFFFF_FFFF { specific["gid"] = String(entry.gid) }
                var kind: EntryKind
                var record = Record(extents: [], length: entry.informationLength, unsupported: nil)
                switch entry.fileType {
                case 4: kind = .directory
                case 5, 0, 249: kind = .file
                case 12: kind = .symlink
                case 6, 7, 9, 10:
                    kind = .other
                    specific["unsupported"] = "UDF file type \(entry.fileType)"
                    record.unsupported = "UDF file type \(entry.fileType)"
                default:
                    kind = .other
                    specific["unsupported"] = "UDF file type \(entry.fileType)"
                    record.unsupported = "UDF file type \(entry.fileType)"
                }
                if identifier.isDirectory != (kind == .directory), kind != .other {
                    throw KaitoError.malformed("udf directory bit disagrees with the file type")
                }
                if kind == .file || kind == .symlink {
                    let (extents, _, unsupported) = try extents(of: entry, partition: partition, icbBlock: icbBlock, volume: volume)
                    record.extents = extents
                    if let unsupported {
                        record.unsupported = unsupported
                        specific["unsupported"] = unsupported
                    }
                    try Checked.size(entry.informationLength, limit: volume.budget.limits.maxEntrySize)
                }
                if kind == .symlink {
                    // 4/8.7 と 4/14.16: 本文は path component 列。hdiutil の UDF 1.02 / 1.50 は生の path を書く
                    // ので、component として読めなければ生 byte 列を名前として解釈する。
                    let target = try symlinkTarget(record: record, volume: volume, options: options)
                    specific["linkPath"] = target.path
                    if target.raw { specific["linkTargetStoredAsData"] = "true" }
                    record.extents = []
                    record.length = 0
                }
                if kind == .directory { record.length = 0 }
                try volume.budget.charge(UInt64(256 + identifier.name.utf8.count + record.extents.count * 24))
                let index = result.count
                // node.parent は node が表す directory 自身の entry index（root は nil）。
                result.append(Pending(parent: node.parent, name: identifier.name, kind: kind, date: entry.modificationDate,
                                      permissions: entry.posixPermissions, specific: specific, record: record))
                if let streams = entry.streamDirectory, kind == .file || kind == .directory {
                    try appendNamedStreams(streams, owner: index, ownerPartition: partition, volume: volume, into: &result)
                }
                if kind == .directory {
                    let key = UInt64(partition) << 32 | UInt64(icbBlock)
                    if ancestors.contains(key) {
                        result[index].specific["cycleSkipped"] = "true"
                    } else {
                        guard node.depth < options.limits.maxPathComponentCount else {
                            throw KaitoError.limitExceeded("udf directory depth")
                        }
                        children.append(Node(entry: entry, partition: partition, icbBlock: icbBlock, parent: index,
                                             depth: node.depth + 1, ancestors: ancestors))
                    }
                }
            }
            // stack は LIFO なので、directory 順を保つために逆順に積む。
            stack.append(contentsOf: children.reversed())
        }
        return result
    }

    /// UDF §3.3.5 / §3.3.8.1: EFE の stream directory から Macintosh resource fork の stream を
    /// `name/..namedfork/rsrc` として公開する。metadata bit の立つ stream と他の名前付き stream は数だけ記録する。
    private static func appendNamedStreams(_ icb: UDFAllocation, owner: Int, ownerPartition: Int,
                                           volume: UDFVolume, into result: inout [Pending]) throws {
        let (directory, icbBlock) = try directEntry(icb: icb, volume: volume)
        guard directory.fileType == 13 else { throw KaitoError.malformed("udf stream directory file type \(directory.fileType)") }
        let node = Node(entry: directory, partition: Int(icb.partition ?? UInt16(ownerPartition)), icbBlock: icbBlock,
                        parent: owner, depth: 0, ancestors: [])
        var others = 0
        for identifier in try directoryEntries(node, volume: volume) where !identifier.isParent && !identifier.isDeleted {
            if identifier.isMetadataStream || identifier.name != resourceForkStreamName {
                others += 1
                continue
            }
            guard identifier.icb.length > 0 else { continue }
            let (stream, streamBlock) = try directEntry(icb: identifier.icb, volume: volume)
            guard stream.fileType == 5 else { throw KaitoError.malformed("udf named stream file type \(stream.fileType)") }
            let partition = Int(identifier.icb.partition ?? UInt16(node.partition))
            let (extents, _, unsupported) = try extents(of: stream, partition: partition, icbBlock: streamBlock, volume: volume)
            try Checked.size(stream.informationLength, limit: volume.budget.limits.maxEntrySize)
            var specific: [String: String] = ["fork": "resource"]
            if let unsupported { specific["unsupported"] = unsupported }
            result.append(Pending(parent: owner, name: "..namedfork/rsrc", kind: .file, date: result[owner].date,
                                  permissions: result[owner].permissions, specific: specific,
                                  record: Record(extents: extents, length: stream.informationLength,
                                                 unsupported: unsupported)))
        }
        if others > 0 { result[owner].specific["namedStreams"] = String(others) }
    }

    private static func symlinkTarget(record: Record, volume: UDFVolume, options: ReaderOptions) throws -> (path: String, raw: Bool) {
        try Checked.size(record.length, limit: min(volume.budget.limits.maxMetadataSize, 65536))
        var bytes: [UInt8] = []
        for extent in record.extents {
            switch extent {
            case .inline(let inline): bytes += inline
            case .zero(let count): bytes += [UInt8](repeating: 0, count: Int(count))
            case .recorded(let section):
                try volume.budget.charge(section.length)
                bytes += try readByteRange(source: volume.source, offset: section.offset, count: Int(section.length))
            }
        }
        if let components = pathComponents(bytes) {
            return (components, false)
        }
        let resolved = EncodingDetector.resolveUndeclaredName(bytes: bytes, policy: options.encodingPolicy, archiveEncoding: nil).string
        return (resolved, true)
    }

    /// 4/14.16.1 Path Component: type、L_CI、version、identifier（compressed unicode）。
    private static func pathComponents(_ bytes: [UInt8]) -> String? {
        var offset = 0
        var parts: [String] = []
        var absolute = false
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { return nil }
            let type = bytes[offset]
            let length = Int(bytes[offset + 1])
            guard offset + 4 + length <= bytes.count else { return nil }
            let identifier = bytes[(offset + 4)..<(offset + 4 + length)]
            switch type {
            case 1, 2:
                guard parts.isEmpty, !absolute else { return nil }
                absolute = true
                if type == 1, length > 0, let name = UDFBytes.compressedUnicode(identifier) { parts.append(name) }
            case 3: parts.append("..")
            case 4: parts.append(".")
            case 5:
                guard length > 0, let name = UDFBytes.compressedUnicode(identifier), !name.isEmpty else { return nil }
                parts.append(name)
            default: return nil
            }
            offset += 4 + length
        }
        guard absolute || !parts.isEmpty else { return nil }
        return (absolute ? "/" : "") + parts.joined(separator: "/")
    }

    // MARK: - finalize

    private static func finalize(_ pending: [Pending], revision: UInt16, options: ReaderOptions,
                                 budget: UDFMetadataBudget) throws -> ([ArchiveEntry], [Record]) {
        var paths: [Int: [String]] = [:]
        var seen: [String: Int] = [:]
        var duplicates: [Int: Int] = [:]
        var kept: [Int] = []
        let revisionText = String(format: "%X.%02X", revision >> 8, revision & 0xFF)
        for (index, item) in pending.enumerated() {
            if let parent = item.parent, paths[parent] == nil { continue }
            var components = item.parent.flatMap { paths[$0] } ?? []
            if item.name == "..namedfork/rsrc" {
                components += ["..namedfork", "rsrc"]
            } else {
                var name = item.name
                if name.utf8.contains(where: { $0 >= 0x80 }) { name = name.precomposedStringWithCanonicalMapping }
                guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(where: { $0 == 0 || $0 == 0x2F }) else {
                    throw KaitoError.malformed("udf name")
                }
                components.append(name)
            }
            guard components.count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("udf path component count") }
            let path = components.joined(separator: "/")
            if let prior = seen[path] { duplicates[prior, default: 0] += 1; continue }
            seen[path] = index
            var cost = UInt64(256 + path.utf8.count * 2)
            for (key, value) in item.specific { cost = try Checked.add(cost, UInt64(key.utf8.count + value.utf8.count)) }
            try budget.charge(cost)
            paths[index] = components
            kept.append(index)
        }
        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        for index in kept {
            let item = pending[index]
            let components = paths[index]!
            var specific = item.specific
            specific["fileSystem"] = "udf"
            specific["udfRevision"] = revisionText
            specific["nameSource"] = "udf"
            if let count = duplicates[index] { specific["skippedDuplicates"] = String(count) }
            if let link = specific["linkPath"] {
                guard link.split(separator: "/").count <= options.limits.maxPathComponentCount else {
                    throw KaitoError.limitExceeded("udf link component count")
                }
                guard !link.utf8.contains(0) else { throw KaitoError.malformed("udf link") }
            }
            let path = components.joined(separator: "/")
            let size: UInt64? = item.kind == .file ? item.record.length : (item.kind == .directory ? 0 : item.record.length)
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: Array(path.utf8), declaredEncoding: .utf8, isDirectoryHint: item.kind == .directory),
                name: path, pathComponents: components, kind: item.kind,
                uncompressedSize: size, compressedSize: size,
                modificationDate: item.date, posixPermissions: item.permissions, isEncrypted: false, solidGroup: -1,
                crc32: nil, methodDescription: "UDF (stored)", formatSpecific: specific))
            records.append(item.record)
        }
        return (entries, records)
    }
}

/// 記録済み extent、#00 の extent、inline data を順に返す。
final class UDFExtentDecompressor: Decompressor {
    private let source: any ByteSource
    private let extents: [UDFDataExtent]
    private var index = 0
    private var current: CopyDecompressor?
    private var zeroRemaining: UInt64 = 0

    init(source: any ByteSource, extents: [UDFDataExtent]) {
        self.source = source
        self.extents = extents.filter { $0.length > 0 }
    }

    var isFinished: Bool { index == extents.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        switch extents[index] {
        case .recorded(let section):
            if current == nil {
                current = try CopyDecompressor(source: source, offset: section.offset, compressedSize: section.length)
            }
        case .inline(let bytes):
            if current == nil {
                current = try CopyDecompressor(source: DataByteSource(Data(bytes)), offset: 0, compressedSize: UInt64(bytes.count))
            }
        case .zero(let count):
            if zeroRemaining == 0 { zeroRemaining = count }
            let produced = Int(min(UInt64(buffer.count), zeroRemaining))
            buffer.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: produced)
            zeroRemaining -= UInt64(produced)
            if zeroRemaining == 0 { index += 1 }
            return produced
        }
        let count = try current!.read(into: buffer)
        if current!.isFinished { current = nil; index += 1 }
        return count
    }
}
