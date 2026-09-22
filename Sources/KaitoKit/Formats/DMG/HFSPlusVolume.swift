import Foundation

// HFS Plus / HFSX の読み取り。実装入力は Apple Technote TN1150 "HFS Plus Volume Format"（`inbox/dmg/tn1150.html`）の
// 構造体と散文（volume header、fork data、B-tree node / header record、catalog key と folder / file / thread record、
// extents overflow key、BSD info、hard link と symbolic link の表現）。UF_COMPRESSED（ownerFlags 0x20）は
// chflags(2) の man page による。2026-09-22 の検証記録を参照。

enum HFSBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) << 32 | UInt64(u32(b, o + 4)) }

    /// HFS Plus の日時: 1904-01-01 00:00:00 UTC からの秒（createDate だけは local time だが公開は modification）。
    static func date(_ seconds: UInt32) -> Date? {
        guard seconds != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) - 2_082_844_800)
    }
}

/// HFSPlusExtentDescriptor: startBlock、blockCount。
struct HFSExtent {
    let startBlock: UInt32
    let blockCount: UInt32
}

/// HFSPlusForkData（80 byte）。
struct HFSForkData {
    let logicalSize: UInt64
    let totalBlocks: UInt32
    let firstExtentHasBlocks: Bool
    let extents: [HFSExtent]

    init(_ b: [UInt8], _ o: Int) {
        logicalSize = HFSBytes.u64(b, o)
        totalBlocks = HFSBytes.u32(b, o + 12)
        firstExtentHasBlocks = HFSBytes.u32(b, o + 20) != 0
        extents = (0..<8).map { HFSExtent(startBlock: HFSBytes.u32(b, o + 16 + $0 * 8), blockCount: HFSBytes.u32(b, o + 20 + $0 * 8)) }
            .filter { $0.blockCount > 0 }
    }
}

/// HFSPlusVolumeHeader（sector 2、512 byte）。
struct HFSVolumeHeader {
    static let signaturePlus: UInt16 = 0x482B   // 'H+'
    static let signatureX: UInt16 = 0x4858      // 'HX'
    let signature: UInt16
    let version: UInt16
    let attributes: UInt32
    let fileCount: UInt32
    let folderCount: UInt32
    let blockSize: UInt32
    let totalBlocks: UInt32
    let catalogFile: HFSForkData
    let extentsFile: HFSForkData
    let attributesFile: HFSForkData

    static func isPlausible(_ b: [UInt8]) -> Bool {
        guard b.count >= 512 else { return false }
        let signature = HFSBytes.u16(b, 0), version = HFSBytes.u16(b, 2), blockSize = HFSBytes.u32(b, 40)
        return (signature == signaturePlus && version == 4 || signature == signatureX && version == 5)
            && blockSize >= 512 && blockSize <= 1 << 24 && blockSize & (blockSize - 1) == 0
    }

    init(_ b: [UInt8]) throws {
        guard Self.isPlausible(b) else { throw KaitoError.unsupportedFormat }
        signature = HFSBytes.u16(b, 0)
        version = HFSBytes.u16(b, 2)
        attributes = HFSBytes.u32(b, 4)
        fileCount = HFSBytes.u32(b, 32)
        folderCount = HFSBytes.u32(b, 36)
        blockSize = HFSBytes.u32(b, 40)
        totalBlocks = HFSBytes.u32(b, 44)
        extentsFile = HFSForkData(b, 112 + 80)
        catalogFile = HFSForkData(b, 112 + 160)
        attributesFile = HFSForkData(b, 112 + 240)
    }
}

/// B-tree（catalog / extents overflow / attributes）。node を必要に応じて読む。
final class HFSBTree {
    let nodeSize: Int
    let rootNode: UInt32
    let firstLeafNode: UInt32
    let totalNodes: UInt32
    let keyCompareType: UInt8
    private let volume: HFSPlusVolume
    private let fork: HFSForkData
    private let forkID: UInt32
    private var extents: [HFSExtent]

    init(volume: HFSPlusVolume, fork: HFSForkData, forkID: UInt32, label: String) throws {
        self.volume = volume
        self.fork = fork
        self.forkID = forkID
        // catalog（ID 4）や attributes は自身が 8 extent を超えて overflow することがある。extents file（ID 3）を先に
        // 読んでいれば、その追加 extent も使う。
        extents = fork.extents + (volume.overflow[UInt64(forkID) << 8] ?? [])
        // header node（node 0）: node descriptor 14 byte + BTHeaderRec。node size は header から分かるので
        // 最小 512 byte を読んで確かめる。
        let head = try volume.readFork(fork: fork, extents: extents, offset: 0, count: 512)
        guard head[8] == 1 else { throw KaitoError.malformed("hfs+ \(label) header node kind") }     // kind 1 = header
        nodeSize = Int(HFSBytes.u16(head, 14 + 18))
        guard nodeSize >= 512, nodeSize <= 1 << 16, nodeSize & (nodeSize - 1) == 0 else { throw KaitoError.malformed("hfs+ \(label) node size") }
        rootNode = HFSBytes.u32(head, 14 + 2)
        firstLeafNode = HFSBytes.u32(head, 14 + 10)
        totalNodes = HFSBytes.u32(head, 14 + 22)
        keyCompareType = head[14 + 37]
        guard UInt64(totalNodes) * UInt64(nodeSize) <= fork.logicalSize else { throw KaitoError.malformed("hfs+ \(label) node count") }
    }

    /// overflow した extent（catalog / extents file 自身は 8 個で足りる前提。足りなければ extents file から補う）。
    func node(_ number: UInt32) throws -> [UInt8] {
        guard number < totalNodes else { throw KaitoError.malformed("hfs+ node \(number) out of range") }
        return try volume.readFork(fork: fork, extents: extents, offset: UInt64(number) * UInt64(nodeSize), count: nodeSize)
    }

    /// node の record（offset 表は末尾から 2 byte ずつ）。
    func records(in node: [UInt8]) throws -> (kind: Int8, forwardLink: UInt32, records: [ArraySlice<UInt8>]) {
        let count = Int(HFSBytes.u16(node, 10))
        guard count <= (nodeSize - 14) / 2 else { throw KaitoError.malformed("hfs+ node record count") }
        var offsets: [Int] = []
        for index in 0...count {
            let offset = Int(HFSBytes.u16(node, nodeSize - 2 * (index + 1)))
            guard offset >= 14, offset <= nodeSize - 2 * (count + 1) else { throw KaitoError.malformed("hfs+ node record offset") }
            if let last = offsets.last, offset < last { throw KaitoError.malformed("hfs+ node record order") }
            offsets.append(offset)
        }
        var result: [ArraySlice<UInt8>] = []
        for index in 0..<count { result.append(node[offsets[index]..<offsets[index + 1]]) }
        return (Int8(bitPattern: node[8]), HFSBytes.u32(node, 0), result)
    }

    /// 葉 node を firstLeafNode から fLink で順に辿る。
    func forEachLeafRecord(budget: inout UInt64, limits: ReadLimits, _ body: (ArraySlice<UInt8>) throws -> Void) throws {
        var number = firstLeafNode
        var visited = Set<UInt32>()
        while number != 0 {
            guard visited.insert(number).inserted else { throw KaitoError.malformed("hfs+ leaf chain cycle") }
            budget = try Checked.add(budget, UInt64(nodeSize))
            try Checked.size(budget, limit: limits.maxMetadataSize)
            let data = try node(number)
            let (kind, next, records) = try self.records(in: data)
            guard kind == -1 else { throw KaitoError.malformed("hfs+ leaf chain reaches a non-leaf node") }
            for record in records { try body(record) }
            number = next
        }
    }
}

/// catalog の file / folder record から取り出した情報。
struct HFSCatalogItem {
    enum Kind { case folder, file }
    let kind: Kind
    let parentID: UInt32
    let name: String
    let nodeID: UInt32
    let modificationDate: Date?
    let createDate: UInt32
    let fileMode: UInt16
    let ownerFlags: UInt8
    let special: UInt32          // iNodeNum / linkCount
    let fileType: [UInt8]        // FinderInfo fdType
    let creator: [UInt8]
    let dataFork: HFSForkData?
    let resourceFork: HFSForkData?
}

enum HFSDecmpfsAttribute {
    case inline([UInt8])
    case fork
}

/// 1 つの HFS Plus volume。
final class HFSPlusVolume {
    let source: any ByteSource
    let baseOffset: UInt64        // disk 内での volume の開始位置
    let header: HFSVolumeHeader
    let blockSize: UInt64
    private(set) var overflow: [UInt64: [HFSExtent]] = [:]   // (fileID << 8 | forkType) → 追加 extent（startBlock 順）

    init(source: any ByteSource, baseOffset: UInt64) throws {
        self.source = source
        self.baseOffset = baseOffset
        let bytes = try readByteRange(source: source, offset: Checked.add(baseOffset, 1024), count: 512)
        header = try HFSVolumeHeader(bytes)
        blockSize = UInt64(header.blockSize)
        guard try Checked.add(baseOffset, Checked.mul(UInt64(header.totalBlocks), blockSize)) <= source.length + blockSize else {
            throw KaitoError.truncated
        }
    }

    /// fork の `offset` から `count` byte を読む（extent の切れ目をまたぐ）。
    func readFork(fork: HFSForkData, extents: [HFSExtent], offset: UInt64, count: Int) throws -> [UInt8] {
        guard try Checked.add(offset, UInt64(count)) <= max(fork.logicalSize, UInt64(fork.totalBlocks) * blockSize) else {
            throw KaitoError.truncated
        }
        var result = [UInt8](repeating: 0, count: count)
        var filled = 0
        var cursor = offset
        while filled < count {
            guard let (physical, available) = locate(extents: extents, offset: cursor) else { throw KaitoError.truncated }
            let take = Int(min(UInt64(count - filled), available))
            let bytes = try readByteRange(source: source, offset: Checked.add(baseOffset, physical), count: take)
            result.replaceSubrange(filled..<(filled + take), with: bytes)
            filled += take
            cursor += UInt64(take)
        }
        return result
    }

    /// fork 内 offset → (volume 内 byte offset、その extent に残る byte 数)。
    func locate(extents: [HFSExtent], offset: UInt64) -> (UInt64, UInt64)? {
        var position: UInt64 = 0
        for extent in extents {
            let length = UInt64(extent.blockCount) * blockSize
            if offset < position + length {
                let inExtent = offset - position
                return (UInt64(extent.startBlock) * blockSize + inExtent, length - inExtent)
            }
            position += length
        }
        return nil
    }

    /// extents overflow file を全部読み、file ごとの追加 extent を集める。
    func loadOverflowExtents(limits: ReadLimits, budget: inout UInt64) throws {
        guard header.extentsFile.logicalSize > 0, !header.extentsFile.extents.isEmpty else { return }
        let tree = try HFSBTree(volume: self, fork: header.extentsFile, forkID: 3, label: "extents")
        try tree.forEachLeafRecord(budget: &budget, limits: limits) { record in
            // key: keyLength(2) forkType(1) pad(1) fileID(4) startBlock(4) → data: 8 extent。
            let b = Array(record)
            guard b.count >= 12, HFSBytes.u16(b, 0) == 10 else { throw KaitoError.malformed("hfs+ extents key") }
            let forkType = UInt64(b[2]), fileID = UInt64(HFSBytes.u32(b, 4))
            guard b.count >= 12 + 64 else { throw KaitoError.malformed("hfs+ extents record") }
            let extents = (0..<8).map { HFSExtent(startBlock: HFSBytes.u32(b, 12 + $0 * 8), blockCount: HFSBytes.u32(b, 16 + $0 * 8)) }
                .filter { $0.blockCount > 0 }
            overflow[fileID << 8 | forkType, default: []].append(contentsOf: extents)
        }
    }

    /// catalog record と overflow を合わせた fork の extent 列。
    func extents(of fork: HFSForkData, fileID: UInt32, forkType: UInt8) throws -> [HFSExtent] {
        var result = fork.extents
        if let more = overflow[UInt64(fileID) << 8 | UInt64(forkType)] { result.append(contentsOf: more) }
        var total: UInt64 = 0
        for extent in result {
            guard UInt64(extent.startBlock) + UInt64(extent.blockCount) <= UInt64(header.totalBlocks) else {
                throw KaitoError.malformed("hfs+ extent beyond the volume")
            }
            total = try Checked.add(total, UInt64(extent.blockCount) * blockSize)
        }
        guard total >= fork.logicalSize else { throw KaitoError.truncated }
        return result
    }

    /// com.apple.decmpfs だけを保持する。fork 格納の属性は一覧用の印に留める。
    func decmpfsAttributes(limits: ReadLimits, budget: inout UInt64) throws -> [UInt32: HFSDecmpfsAttribute] {
        guard header.attributesFile.firstExtentHasBlocks else { return [:] }
        let tree = try HFSBTree(volume: self, fork: header.attributesFile, forkID: 8, label: "attributes")
        guard tree.nodeSize >= 4096 else { throw KaitoError.malformed("hfs+ attributes node size") }
        let expectedName = Array("com.apple.decmpfs".utf8)
        var attributes: [UInt32: HFSDecmpfsAttribute] = [:]
        var retainedSize: UInt64 = 0
        try tree.forEachLeafRecord(budget: &budget, limits: limits) { record in
            let b = Array(record)
            guard b.count >= 14 else { throw KaitoError.malformed("hfs+ attributes key") }
            let keyLength = Int(HFSBytes.u16(b, 0))
            guard keyLength >= 12, 2 + keyLength <= b.count, HFSBytes.u16(b, 2) == 0 else {
                throw KaitoError.malformed("hfs+ attributes key length or pad")
            }
            let nameLength = Int(HFSBytes.u16(b, 12))
            guard nameLength <= 255, 14 + nameLength * 2 <= 2 + keyLength else {
                throw KaitoError.malformed("hfs+ attributes name length")
            }
            var dataOffset = 2 + keyLength
            if dataOffset & 1 == 1 { dataOffset += 1 }
            guard dataOffset <= b.count else { throw KaitoError.malformed("hfs+ attributes key padding") }
            // 他の名前の data は解釈しない。大文字小文字を含め UTF-16 code unit が一致するものだけ。
            guard nameLength == expectedName.count,
                  (0..<nameLength).allSatisfy({ HFSBytes.u16(b, 14 + $0 * 2) == UInt16(expectedName[$0]) }) else { return }
            guard dataOffset + 4 <= b.count else {
                throw KaitoError.malformed("hfs+ decmpfs attribute record")
            }
            let fileID = HFSBytes.u32(b, 4)
            let recordType = HFSBytes.u32(b, dataOffset)
            let startBlock = HFSBytes.u32(b, 8)
            if attributes[fileID] == nil {
                guard attributes.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("hfs+ decmpfs attribute count") }
            }
            if startBlock != 0 || recordType == 0x20 || recordType == 0x30 {
                if startBlock == 0, recordType == 0x20, dataOffset + 88 > b.count {
                    throw KaitoError.malformed("hfs+ decmpfs fork attribute")
                }
                // 続きの extent も同じ CNID を使う。順序にかかわらず fork の印を残す。
                attributes[fileID] = .fork
                return
            }
            if case .fork? = attributes[fileID] { return }
            guard attributes[fileID] == nil else { throw KaitoError.malformed("hfs+ duplicate decmpfs attribute") }
            switch recordType {
            case 0x10:
                guard dataOffset + 16 <= b.count else { throw KaitoError.malformed("hfs+ decmpfs inline record") }
                let size = UInt64(HFSBytes.u32(b, dataOffset + 12))
                guard size <= 65_536, size <= UInt64(b.count - dataOffset - 16) else {
                    throw KaitoError.malformed("hfs+ decmpfs attribute size")
                }
                try Checked.size(size, limit: limits.maxMetadataSize)
                retainedSize = try Checked.add(retainedSize, size)
                try Checked.size(retainedSize, limit: limits.maxTotalMetadataSize)
                let count = try Checked.toInt(size)
                attributes[fileID] = .inline(Array(b[(dataOffset + 16)..<(dataOffset + 16 + count)]))
            default: throw KaitoError.malformed("hfs+ decmpfs attribute record type")
            }
        }
        return attributes
    }

    /// catalog の葉を全部読む。
    func catalogItems(limits: ReadLimits, budget: inout UInt64) throws -> [HFSCatalogItem] {
        let tree = try HFSBTree(volume: self, fork: header.catalogFile, forkID: 4, label: "catalog")
        var items: [HFSCatalogItem] = []
        try tree.forEachLeafRecord(budget: &budget, limits: limits) { record in
            let b = Array(record)
            guard b.count >= 8 else { throw KaitoError.malformed("hfs+ catalog record") }
            let keyLength = Int(HFSBytes.u16(b, 0))
            guard keyLength >= 6, 2 + keyLength <= b.count else { throw KaitoError.malformed("hfs+ catalog key length") }
            let parentID = HFSBytes.u32(b, 2)
            let nameLength = Int(HFSBytes.u16(b, 6))
            guard nameLength <= 255, 8 + nameLength * 2 <= 2 + keyLength else { throw KaitoError.malformed("hfs+ catalog name length") }
            let units = (0..<nameLength).map { HFSBytes.u16(b, 8 + $0 * 2) }
            let name = String(decoding: units, as: UTF16.self)
            // data は key の直後。key 長が奇数なら 1 byte の pad（TN1150: 偶数境界）。
            var dataOffset = 2 + keyLength
            if dataOffset & 1 == 1 { dataOffset += 1 }
            guard dataOffset + 2 <= b.count else { throw KaitoError.malformed("hfs+ catalog data") }
            let recordType = HFSBytes.u16(b, dataOffset)
            switch recordType {
            case 1:      // folder
                guard dataOffset + 88 <= b.count else { throw KaitoError.malformed("hfs+ folder record") }
                let o = dataOffset
                items.append(HFSCatalogItem(kind: .folder, parentID: parentID, name: name, nodeID: HFSBytes.u32(b, o + 8),
                    modificationDate: HFSBytes.date(HFSBytes.u32(b, o + 16)), createDate: HFSBytes.u32(b, o + 12),
                    fileMode: HFSBytes.u16(b, o + 42), ownerFlags: b[o + 41], special: HFSBytes.u32(b, o + 44),
                    fileType: Array(b[(o + 48)..<(o + 52)]), creator: Array(b[(o + 52)..<(o + 56)]), dataFork: nil, resourceFork: nil))
            case 2:      // file
                guard dataOffset + 248 <= b.count else { throw KaitoError.malformed("hfs+ file record") }
                let o = dataOffset
                items.append(HFSCatalogItem(kind: .file, parentID: parentID, name: name, nodeID: HFSBytes.u32(b, o + 8),
                    modificationDate: HFSBytes.date(HFSBytes.u32(b, o + 16)), createDate: HFSBytes.u32(b, o + 12),
                    fileMode: HFSBytes.u16(b, o + 42), ownerFlags: b[o + 41], special: HFSBytes.u32(b, o + 44),
                    fileType: Array(b[(o + 48)..<(o + 52)]), creator: Array(b[(o + 52)..<(o + 56)]),
                    dataFork: HFSForkData(b, o + 88), resourceFork: HFSForkData(b, o + 168)))
            case 3, 4:   // thread record: 一覧には使わない
                break
            default:
                throw KaitoError.malformed("hfs+ catalog record type \(recordType)")
            }
        }
        return items
    }
}
