import Foundation

// ECMA-119 / Joliet 仕様 / IEEE P1281 (SUSP) / IEEE P1282 (Rock Ridge) の
// 公開仕様だけを参照したクリーンルーム実装。
final class ISOReader: FormatReader {
    private struct Record {
        var sections: [ISOSection]
        var totalLength: UInt64
        var unsupported: String?
    }
    private struct Pending {
        let parent: Int?
        let bytes: [UInt8]
        let rrName: Bool
        let kind: EntryKind
        let date: Date?
        let permissions: UInt16?
        let link: [UInt8]?
        var specific: [String: String]
        let record: Record
    }
    private struct Node {
        let record: ISODirectoryRecord
        let parent: Int?
        let depth: Int
        let ancestors: Set<UInt32>
        var directoryRecords: [ISODirectoryRecord]? = nil
        var nextRecord = 0
    }
    private struct Tree {
        let volume: ISOVolume
        let rootRecords: [ISODirectoryRecord]
        let skip: Int?
    }

    let format: ArchiveFormat = .iso
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let source: any ByteSource
    private let records: [Record]

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let budget = ISOMetadataBudget(options.limits)
        var primary: [UInt8]?
        var supplementary: [UInt8]?
        for index in 0..<64 {
            let offset = UInt64(32768 + index * 2048)
            guard offset + 2048 <= source.length else { break }
            let b = try readByteRange(source: source, offset: offset, count: 2048)
            guard Array(b[1..<6]) == Array("CD001".utf8) else { break }
            if b[0] == 255 { break }
            if b[0] == 1, primary == nil { primary = b }
            if b[0] == 2, b[6] == 1, b[88] == 37, b[89] == 47,
               [64, 67, 69].contains(b[90]), supplementary == nil { supplementary = b }
        }
        guard let primary else { throw KaitoError.unsupportedFormat }
        var pvd: Tree?
        var rootError: Error?
        do { pvd = try Self.prepare(primary, source: source, budget: budget) }
        catch KaitoError.malformed(let reason) { rootError = KaitoError.malformed(reason) }
        catch KaitoError.truncated { rootError = KaitoError.truncated }
        var pending: [Pending] = []
        var pvdHasNM = false
        if let pvd {
            let walked = try Self.walk(pvd, joliet: false, source: source, budget: budget)
            pending = walked.entries
            pvdHasNM = walked.hasNM
        }
        var joliet = false
        // NM ありの Rock Ridge は POSIX 名・symlink を保持するため Joliet より優先する。
        // XADMaster の Joliet 優先では両方ある画像の symlink が消えるので意図的に異なる。
        // hdiutil の PX/TF だけの RR には NM が無く、そこでは Joliet の Unicode 名を選ぶ。
        if !pvdHasNM, let supplementary {
            var svd: Tree?
            do { svd = try Self.prepare(supplementary, source: source, budget: budget) }
            catch KaitoError.malformed { if pvd == nil { throw rootError! } }
            catch KaitoError.truncated { if pvd == nil { throw rootError! } }
            if let svd {
                pending = try Self.walk(svd, joliet: true, source: source, budget: budget).entries
                joliet = true
            }
        }
        if pvd == nil, !joliet { throw rootError ?? KaitoError.unsupportedFormat }
        // PVD の volume-level 診断は Joliet を選んだ場合にも失わない。
        if ISOBytes.mismatch(primary, 80, width: 4)
            || [120, 124, 128].contains(where: { ISOBytes.mismatch(primary, $0, width: 2) }) {
            for index in pending.indices { pending[index].specific["bothEndianMismatch"] = "true" }
        }
        let finalized = try Self.finalize(pending, joliet: joliet, options: options, budget: budget)
        entries = finalized.0
        records = finalized.1
        nameEncoding = finalized.2
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else {
            throw KaitoError.notFound("iso entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let reason = record.unsupported { throw KaitoError.unsupportedMethod("ISO 9660 \(reason)") }
        if record.sections.count == 1 {
            return try EntryStream(source: source, offset: record.sections[0].offset,
                                   length: record.sections[0].length, limits: limits)
        }
        return try EntryStream(decompressor: ISOSectionDecompressor(source: source, sections: record.sections),
                               length: record.totalLength, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }

    static func isPlausibleVolumeDescriptor(_ b: [UInt8]) -> Bool {
        // 検出は構造だけを見る。数値の妥当性は parser の責務。
        b.count >= 7 && Array(b[1..<6]) == Array("CD001".utf8) && [0, 1, 2, 3, 255].contains(b[0])
    }

    private static func prepare(_ b: [UInt8], source: any ByteSource, budget: ISOMetadataBudget) throws -> Tree {
        let volume = try ISOVolume(b, sourceLength: source.length)
        let records = try directory(volume.root, volume: volume, source: source, budget: budget)
        let skip = records.first.flatMap { $0.identifier == [0] ? ISORockRidge.skip(in: $0.systemUse) : nil }
        return Tree(volume: volume, rootRecords: records, skip: skip)
    }

    private static func directory(_ record: ISODirectoryRecord, volume: ISOVolume,
                                  source: any ByteSource, budget: ISOMetadataBudget) throws -> [ISODirectoryRecord] {
        let range = try volume.range(lba: record.lba, ea: record.ea, length: UInt64(record.length))
        try Checked.size(range.length, limit: budget.limits.maxMetadataSize)
        try budget.charge(range.length)
        // 入力範囲と上限を確認した後だけ確保する。
        let bytes = try readByteRange(source: source, offset: range.offset, count: Checked.toInt(range.length))
        var pos = 0
        var result: [ISODirectoryRecord] = []
        while pos < bytes.count {
            let length = Int(bytes[pos])
            let remaining = 2048 - Int((range.offset + UInt64(pos)) % 2048)
            if length == 0 { pos += remaining; continue }
            guard length >= 34 else { throw KaitoError.malformed("iso directory record length") }
            guard length <= remaining else { throw KaitoError.malformed("iso directory record crosses sector") }
            guard length <= bytes.count - pos else { throw KaitoError.truncated }
            guard result.count < budget.limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("iso directory record count")
            }
            result.append(try ISODirectoryRecord(Array(bytes[pos..<pos+length])))
            pos += length
        }
        return result
    }

    private static func walk(_ tree: Tree, joliet: Bool, source: any ByteSource,
                             budget: ISOMetadataBudget) throws -> (entries: [Pending], hasNM: Bool) {
        let volume = tree.volume
        var result: [Pending] = []
        var stack = [Node(record: volume.root, parent: nil, depth: 0, ancestors: [])]
        var hasNM = false
        var directoryCount = 0
        while let node = stack.popLast() {
            let directoryRecords: [ISODirectoryRecord]
            if let retained = node.directoryRecords {
                directoryRecords = retained
            } else {
                directoryCount += 1
                guard directoryCount <= 65536 else { throw KaitoError.limitExceeded("iso directory count") }
                directoryRecords = try node.parent == nil ? tree.rootRecords
                    : directory(node.record, volume: volume, source: source, budget: budget)
            }
            var ancestors = node.ancestors
            ancestors.insert(node.record.lba)
            var i = node.nextRecord
            while i < directoryRecords.count {
                let first = directoryRecords[i]
                i += 1
                // root '.' の CE も検証する。特殊名・associated fork は公開しない。
                var rr = try ISORockRidge.parse(first.systemUse, skip: tree.skip, source: source, volume: volume, budget: budget,
                                                 isRoot: node.parent == nil && first.identifier == [0])
                hasNM = hasNM || rr.name != nil
                if first.special || first.flags & 4 != 0 || (!joliet && rr.relocated) { continue }
                var sections = [first]
                let isDirectory = first.flags & 2 != 0 || (!joliet && rr.child != nil) || rr.mode.map { $0 & 0o170000 == 0o040000 } == true
                if !isDirectory {
                    while sections.last!.flags & 128 != 0, i < directoryRecords.count,
                          directoryRecords[i].identifier == first.identifier,
                          directoryRecords[i].flags & 0x0F == first.flags & 0x0F {
                        guard sections.count < 64 else { throw KaitoError.limitExceeded("iso file section count") }
                        sections.append(directoryRecords[i]); i += 1
                        // RRIP: 最終 section の SUSP だけが file 全体に適用される。
                        rr = try ISORockRidge.parse(sections.last!.systemUse, skip: tree.skip, source: source, volume: volume, budget: budget)
                        hasNM = hasNM || rr.name != nil
                    }
                }
                var child = first
                if !joliet, let lba = rr.child {
                    // CL placeholder の extent/length は未定義。移転先 '.' から実体を読む。
                    let range = try volume.range(lba: lba, length: 1)
                    let length = try readByteRange(source: source, offset: range.offset, count: 1)[0]
                    guard length >= 34, Int(range.offset % 2048) + Int(length) <= 2048 else {
                        throw KaitoError.malformed("iso CL target")
                    }
                    _ = try volume.range(lba: lba, length: UInt64(length))
                    try budget.charge(UInt64(length))
                    child = try ISODirectoryRecord(readByteRange(source: source, offset: range.offset, count: Int(length)))
                    guard child.identifier == [0], child.flags & 2 != 0 else { throw KaitoError.malformed("iso CL target") }
                    let targetRR = try ISORockRidge.parse(child.systemUse, skip: tree.skip, source: source, volume: volume, budget: budget, isRoot: child.lba == volume.root.lba)
                    let logicalName = rr.name
                    rr = targetRR
                    rr.name = logicalName
                    rr.child = lba
                    sections = [child]
                }
                let kind: EntryKind = isDirectory ? .directory
                    : (rr.mode.map { $0 & 0o170000 == 0o120000 } == true || rr.link != nil ? .symlink : .file)
                var specific: [String: String] = [:]
                var unsupported = rr.unsupported
                let foreign = volume.setSize > 1 && sections.contains { $0.sequence != volume.sequence }
                if foreign { unsupported = "otherVolume" }
                else if sections.contains(where: { $0.unit != 0 }) { unsupported = "interleaved" }
                if let unsupported { specific["unsupported"] = unsupported }
                if let size = rr.virtualSize { specific["virtualSize"] = String(size) }
                if child.flags & 1 != 0 { specific["hidden"] = "true" }
                if volume.mismatch || sections.contains(where: { $0.mismatch }) { specific["bothEndianMismatch"] = "true" }
                let rrName = !joliet && rr.name != nil
                specific["nameSource"] = joliet ? "joliet" : (rrName ? "rockRidge" : "iso9660")
                let name = rrName ? rr.name! : first.identifier
                var ranges: [ISOSection] = []
                var total: UInt64 = 0
                if kind == .file {
                    for section in sections {
                        total = try Checked.add(total, UInt64(section.length))
                        if !foreign { ranges.append(try volume.range(lba: section.lba, ea: section.ea, length: UInt64(section.length))) }
                    }
                    try Checked.size(total, limit: budget.limits.maxEntrySize)
                } else if !foreign, kind == .directory {
                    _ = try volume.range(lba: child.lba, ea: child.ea, length: UInt64(child.length))
                } else if !foreign {
                    // symlink も不正な extent を許さない (通常 dataLength は 0)。
                    _ = try volume.range(lba: first.lba, ea: first.ea, length: UInt64(first.length))
                }
                if kind != .file { ranges = [ISOSection(offset: 0, length: 0)] }
                let index = result.count
                guard index < budget.limits.maxEntryCount else { throw KaitoError.limitExceeded("iso entry count") }
                var descent: Node?
                if kind == .directory, !foreign {
                    if ancestors.contains(child.lba) || (!joliet && rr.child.map { ancestors.contains($0) } == true) {
                        specific["cycleSkipped"] = "true"
                    } else {
                        guard node.depth < budget.limits.maxPathComponentCount else {
                            throw KaitoError.limitExceeded("iso directory depth")
                        }
                        descent = Node(record: child, parent: index, depth: node.depth + 1, ancestors: ancestors)
                    }
                }
                try budget.charge(UInt64(256 + name.count + (rr.link?.count ?? 0) + ranges.count * 16))
                result.append(Pending(parent: node.parent, bytes: name, rrName: rrName, kind: kind,
                                      date: rr.modified ?? child.date, permissions: rr.mode.map { UInt16($0 & 0o7777) },
                                      link: rr.link, specific: specific,
                                      record: Record(sections: ranges, totalLength: total, unsupported: unsupported)))
                if let descent {
                    // 親の再開位置を保存し、子を即座に辿る先行順。兄弟は ISO record 順を保つ。
                    // 再開時は既読 record を使い、directory 数・metadata 予算を二重加算しない。
                    stack.append(Node(record: node.record, parent: node.parent, depth: node.depth,
                                      ancestors: node.ancestors, directoryRecords: directoryRecords, nextRecord: i))
                    stack.append(descent)
                    break
                }
            }
        }
        return (result, hasNM)
    }

    private static func finalize(_ pending: [Pending], joliet: Bool, options: ReaderOptions,
                                 budget: ISOMetadataBudget) throws -> ([ArchiveEntry], [Record], String.Encoding?) {
        let names = joliet ? [] : pending.map(\.bytes).filter {
            if case .fixed = options.encodingPolicy { return true }
            return !EncodingDetector.isStrictUTF8($0)
        }
        let encoding = EncodingDetector.detectArchiveEncoding(names: names, policy: options.encodingPolicy,
                                                              maximumBatchByteCount: Int(clamping: options.limits.maxMetadataSize))
        var decoded: [[UInt8]: String] = [:]
        if let encoding {
            let strings = EncodingDetector.decodeArchiveNames(names, as: encoding, maximumBatchByteCount: Int(clamping: options.limits.maxMetadataSize))
            for (bytes, string) in zip(names, strings) { if let string { decoded[bytes] = string } }
        }
        func resolve(_ bytes: [UInt8]) -> String {
            decoded[bytes] ?? EncodingDetector.resolveUndeclaredName(bytes: bytes, policy: options.encodingPolicy, archiveEncoding: encoding).string
        }
        var paths: [Int: [String]] = [:]
        var rawPaths: [Int: [UInt8]] = [:]
        var kept: [Int] = []
        var duplicates: [Int: Int] = [:]
        var seen: [String: Int] = [:]
        var specificByIndex: [Int: [String: String]] = [:]
        for (index, item) in pending.enumerated() {
            if let parent = item.parent, paths[parent] == nil { continue }
            var name = joliet ? ISOBytes.joliet(item.bytes) : resolve(item.bytes)
            if !item.rrName {
                if let semicolon = name.lastIndex(of: ";") {
                    let tail = name[name.index(after: semicolon)...]
                    if !tail.isEmpty, tail.utf8.allSatisfy({ (48...57).contains($0) }) { name = String(name[..<semicolon]) }
                }
                if name.hasSuffix(".") { name.removeLast() }
            }
            name = name.precomposedStringWithCanonicalMapping
            guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/") else {
                throw KaitoError.malformed("iso name")
            }
            var components = item.parent.flatMap { paths[$0] } ?? []
            components.append(name)
            guard components.count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("iso path component count") }
            let path = components.joined(separator: "/")
            if let prior = seen[path] { duplicates[prior, default: 0] += 1; continue }
            seen[path] = index
            var raw = item.parent.flatMap { rawPaths[$0] } ?? []
            if !raw.isEmpty { raw += joliet ? [0, 47] : [47] }
            raw += item.bytes
            var specific = item.specific
            if let link = item.link {
                let target = resolve(link)
                guard target.split(separator: "/").count <= options.limits.maxPathComponentCount else { throw KaitoError.limitExceeded("iso link component count") }
                guard !target.utf8.contains(0) else { throw KaitoError.malformed("iso link") }
                specific["linkPath"] = target
            }
            var cost = UInt64(256 + raw.count + path.utf8.count + components.count * MemoryLayout<String>.stride)
            for component in components { cost = try Checked.add(cost, UInt64(component.utf8.count)) }
            for (key, value) in specific { cost = try Checked.add(cost, UInt64(key.utf8.count + value.utf8.count)) }
            try budget.charge(cost)
            paths[index] = components; rawPaths[index] = raw; specificByIndex[index] = specific
            kept.append(index)
        }
        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        for index in kept {
            let item = pending[index]
            let components = paths[index]!
            var specific = specificByIndex[index]!
            if let count = duplicates[index] { specific["skippedOlderVersions"] = String(count) }
            entries.append(ArchiveEntry(index: entries.count,
                rawName: RawName(bytes: rawPaths[index]!, declaredEncoding: joliet ? .utf16BigEndian : nil, isDirectoryHint: item.kind == .directory),
                name: components.joined(separator: "/"), pathComponents: components, kind: item.kind,
                uncompressedSize: item.record.totalLength, compressedSize: item.record.totalLength,
                modificationDate: item.date, posixPermissions: item.permissions, isEncrypted: false, solidGroup: -1,
                crc32: nil, methodDescription: "ISO 9660 (stored)", formatSpecific: specific,
                isIncomplete: item.record.unsupported == "otherVolume"))
            records.append(item.record)
        }
        return (entries, records, joliet ? .utf16BigEndian : encoding)
    }
}
