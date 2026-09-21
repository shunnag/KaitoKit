import Foundation

typealias UDFMetadataBudget = ISOMetadataBudget

/// 論理 volume を構成する partition（3/8.8 の partition reference number 順）。
struct UDFPartition {
    enum Kind {
        /// 3/10.7.2 type 1: PD の開始 sector からの線形写像。
        case physical
        /// UDF §2.2.10 / §2.2.13: metadata file の extent を通した写像。`runs` は metadata 空間の
        /// block 番号順に並び、`mirror` は main が読めないときの代替。
        case metadata(runs: [UDFMetadataRun], mirror: [UDFMetadataRun]?)
        /// UDF §2.2.9 / §2.2.12: packet 単位の再配置表を通した線形写像。`table` は partition 内の packet
        /// 先頭 block から絶対 sector への写像（有効な entry だけ）。
        case sparable(packetLength: UInt32, table: [UDFSparingEntry])
        /// UDF §2.2.8 / §2.2.11: VAT を通した写像。`table[v]` は物理 partition（reference `physical`）内の
        /// block 番号、#FFFFFFFF は未使用。
        case virtual(table: [UInt32], physical: Int)
    }
    let number: UInt16
    /// 物理 partition の開始 sector と block 数（metadata partition は対応する物理 partition のもの）。
    let start: UInt32
    let length: UInt32
    var kind: Kind
}

struct UDFMetadataRun {
    let metadataBlock: UInt32
    let physicalBlock: UInt32
    let blocks: UInt32
}

struct UDFSparingEntry {
    let original: UInt32
    let mapped: UInt32
}

/// ECMA-167 Part 2 / Part 3 の volume 構造: 認識列、anchor、volume descriptor sequence、partition map。
final class UDFVolume {
    let source: any ByteSource
    let blockSize: Int
    let budget: UDFMetadataBudget
    private(set) var partitions: [UDFPartition] = []
    private(set) var fileSetLocation = UDFAllocation(length: 0, type: 0, block: 0, partition: 0)
    private(set) var revision: UInt16 = 0
    private(set) var volumeIdentifier: String?
    private(set) var logicalVolumeIdentifier: String?

    static let recognitionOffset: UInt64 = 32768
    static let recognitionSectorSize = 2048
    private static let candidateBlockSizes = [2048, 512, 1024, 4096]

    /// 2/8.3.1: byte 32768 から 2048 byte ごとの volume structure descriptor 列。CD001 の集合（ECMA-119）を
    /// 読み飛ばし、BEA01 … NSR02|NSR03 … TEA01 の拡張領域を確認する。`pureOnly` は CD001 を持たない
    /// image（UDF 専用）にだけ true を返す。
    static func hasRecognitionSequence(source: any ByteSource, pureOnly: Bool) throws -> Bool {
        var offset = recognitionOffset
        var sawBeginning = false
        var sawNSR = false
        for _ in 0..<64 {
            guard offset + UInt64(recognitionSectorSize) <= source.length else { return false }
            let b = try readByteRange(source: source, offset: offset, count: 7)
            let identifier = Array(b[1..<6])
            offset += UInt64(recognitionSectorSize)
            if identifier == Array("CD001".utf8) {
                if pureOnly || sawBeginning { return false }
                continue
            }
            guard b[0] == 0, b[6] == 1 else { return false }
            switch identifier {
            case Array("BEA01".utf8): sawBeginning = true
            case Array("NSR02".utf8), Array("NSR03".utf8): sawNSR = sawBeginning
            case Array("TEA01".utf8): return sawBeginning && sawNSR
            case Array("BOOT2".utf8), Array("CDW02".utf8): continue
            default: return false
            }
        }
        return false
    }

    init(source: any ByteSource, limits: ReadLimits) throws {
        self.source = source
        self.budget = UDFMetadataBudget(limits)
        guard try Self.hasRecognitionSequence(source: source, pureOnly: false) else {
            throw KaitoError.unsupportedFormat
        }
        // 3/8.4.2.1 と UDF §2.2.3: anchor は sector 256、N − 256、N のうち 2 つ以上。block size は
        // 512 の倍数で、tag location が sector 番号に一致する anchor が見つかった候補を採用する。
        var anchor: [UInt8]?
        var chosenBlockSize = 0
        search: for candidate in Self.candidateBlockSizes {
            let sectors = source.length / UInt64(candidate)
            guard sectors > 257 else { continue }
            for lba in [UInt64(256), sectors - 1, sectors - 257] {
                let offset = lba * UInt64(candidate)
                guard offset + 512 <= source.length else { continue }
                let b = try readByteRange(source: source, offset: offset, count: 512)
                if let tag = try? UDFTag.parse(b, expectedLocation: UInt32(truncatingIfNeeded: lba), label: "anchor"),
                   tag.identifier == 2, lba <= UInt64(UInt32.max) {
                    anchor = b
                    chosenBlockSize = candidate
                    break search
                }
            }
        }
        guard let anchor else { throw KaitoError.malformed("udf anchor volume descriptor pointer not found") }
        blockSize = chosenBlockSize
        try budget.charge(UInt64(blockSize))

        let main = UDFExtent(anchor, 16)
        let reserve = UDFExtent(anchor, 24)
        do {
            try parseDescriptorSequence(main)
        } catch let error as KaitoError {
            guard reserve.length > 0 else { throw error }
            do { try parseDescriptorSequence(reserve) } catch { throw error }
        }
    }

    private struct Prevailing<T> {
        var sequenceNumber: UInt32 = 0
        var value: T?
        mutating func offer(_ number: UInt32, _ candidate: T) {
            if value == nil || number >= sequenceNumber { sequenceNumber = number; value = candidate }
        }
    }

    /// 3/8.4: extent 内の descriptor を順に読み、種類ごとに最大 Volume Descriptor Sequence Number を採用する。
    private func parseDescriptorSequence(_ first: UDFExtent) throws {
        var extent = first
        var primary = Prevailing<[UInt8]>()
        var logical = Prevailing<[UInt8]>()
        var partitionDescriptors: [UInt16: Prevailing<[UInt8]>] = [:]
        var hops = 0
        sequence: while extent.length > 0 {
            guard hops < 8 else { throw KaitoError.malformed("udf volume descriptor pointer chain") }
            hops += 1
            let count = Int(extent.length) / blockSize
            guard count > 0 else { throw KaitoError.malformed("udf volume descriptor sequence extent") }
            var next: UDFExtent?
            for index in 0..<min(count, 256) {
                let lba = try Checked.add(UInt64(extent.location), UInt64(index))
                let b = try readSector(lba)
                guard let tag = try UDFTag.parse(b, expectedLocation: UInt32(truncatingIfNeeded: lba), label: "volume descriptor") else {
                    break
                }
                let sequenceNumber = UDFBytes.u32(b, 16)
                switch tag.identifier {
                case 1: primary.offer(sequenceNumber, b)
                case 5: partitionDescriptors[UDFBytes.u16(b, 22), default: Prevailing()].offer(sequenceNumber, b)
                case 6: logical.offer(sequenceNumber, b)
                case 3:
                    // 3/10.3 volume descriptor pointer: 次の extent へ続く。
                    next = UDFExtent(b, 20)
                    break
                case 8: break sequence
                case 2, 4, 7, 9: continue
                default: throw KaitoError.malformed("udf volume descriptor tag \(tag.identifier)")
                }
                if next != nil { break }
            }
            guard let following = next else { break }
            extent = following
        }
        guard let lvd = logical.value else { throw KaitoError.malformed("udf logical volume descriptor missing") }
        guard !partitionDescriptors.isEmpty else { throw KaitoError.malformed("udf partition descriptor missing") }
        if let pvd = primary.value {
            volumeIdentifier = UDFBytes.dstring(pvd, 24, length: 32)
        }
        try parseLogicalVolume(lvd, partitionDescriptors: partitionDescriptors.compactMapValues(\.value))
    }

    /// 3/10.6 と UDF §2.2.4: block size、domain の UDF revision、FSD の位置、partition map。
    private func parseLogicalVolume(_ b: [UInt8], partitionDescriptors: [UInt16: [UInt8]]) throws {
        guard Int(UDFBytes.u32(b, 212)) == blockSize else {
            throw KaitoError.malformed("udf logical block size \(UDFBytes.u32(b, 212)) differs from the anchor block size \(blockSize)")
        }
        logicalVolumeIdentifier = UDFBytes.dstring(b, 84, length: 128)
        revision = UDFBytes.u16(b, 240)
        fileSetLocation = UDFAllocation.long(b, 248)
        let mapTableLength = Int(UDFBytes.u32(b, 264))
        let mapCount = Int(UDFBytes.u32(b, 268))
        guard mapCount >= 1, mapCount <= 64, mapTableLength <= blockSize - 440 else {
            throw KaitoError.malformed("udf partition map table")
        }
        var offset = 440
        var pending: [(UDFPartition, map: [UInt8]?)] = []
        for _ in 0..<mapCount {
            guard offset + 2 <= 440 + mapTableLength else { throw KaitoError.malformed("udf partition map table") }
            let type = b[offset]
            let length = Int(b[offset + 1])
            guard length >= 2, offset + length <= 440 + mapTableLength else { throw KaitoError.malformed("udf partition map length") }
            let map = Array(b[offset..<(offset + length)])
            offset += length
            switch type {
            case 1:
                guard length == 6 else { throw KaitoError.malformed("udf type 1 partition map length") }
                let number = UDFBytes.u16(map, 4)
                pending.append((try physicalPartition(number: number, descriptors: partitionDescriptors), nil))
            case 2:
                guard length == 64 else { throw KaitoError.malformed("udf type 2 partition map length") }
                let identifier = String(decoding: UDFBytes.identifier(map, 4), as: UTF8.self)
                let number = UDFBytes.u16(map, 38)
                switch identifier {
                case "*UDF Metadata Partition", "*UDF Virtual Partition", "*UDF Sparable Partition":
                    pending.append((try physicalPartition(number: number, descriptors: partitionDescriptors), map))
                default:
                    throw KaitoError.unsupportedMethod("UDF partition map \(identifier)")
                }
            default:
                throw KaitoError.malformed("udf partition map type \(type)")
            }
        }
        partitions = pending.map(\.0)
        // sparable は自身の sparing table を、metadata / virtual は物理 partition が確定した後に
        // metadata file / VAT を読む。virtual は同じ partition 番号の type 1 map を物理側とする。
        for (index, item) in pending.enumerated() {
            guard let map = item.map else { continue }
            let identifier = String(decoding: UDFBytes.identifier(map, 4), as: UTF8.self)
            switch identifier {
            case "*UDF Sparable Partition":
                partitions[index].kind = try sparableKind(map: map, physical: item.0)
            case "*UDF Metadata Partition":
                partitions[index].kind = try metadataKind(map: map, physical: item.0)
            default:
                guard let physical = pending.indices.first(where: { $0 != index && pending[$0].map == nil && pending[$0].0.number == item.0.number }) else {
                    throw KaitoError.malformed("udf virtual partition without a type 1 partition map")
                }
                partitions[index].kind = try virtualKind(physical: physical)
            }
        }
    }

    /// UDF §2.2.9 / §2.2.12: sparing table（tag identifier 0）の再配置 entry を読む。複数の表は
    /// 最初に読めたものを使う。実装確認は macOS の UDF driver が同じ表で再配置 packet を読むことによる。
    private func sparableKind(map: [UInt8], physical: UDFPartition) throws -> UDFPartition.Kind {
        let packetLength = UInt32(UDFBytes.u16(map, 40))
        let tableCount = Int(map[42])
        let tableSize = Int(UDFBytes.u32(map, 44))
        guard packetLength > 0, (1...4).contains(tableCount), tableSize >= 56 else {
            throw KaitoError.malformed("udf sparable partition map")
        }
        try Checked.size(UInt64(tableSize), limit: budget.limits.maxMetadataSize)
        var firstError: Error?
        for index in 0..<tableCount {
            let location = UDFBytes.u32(map, 48 + 4 * index)
            do {
                let offset = try Checked.mul(UInt64(location), UInt64(blockSize))
                try budget.charge(UInt64(tableSize))
                let b = try readByteRange(source: source, offset: offset, count: tableSize)
                guard let tag = try UDFTag.parse(b, expectedLocation: location, label: "sparing table", allowIdentifierZero: true),
                      tag.identifier == 0,
                      String(decoding: UDFBytes.identifier(b, 16), as: UTF8.self) == "*UDF Sparing Table" else {
                    throw KaitoError.malformed("udf sparing table tag")
                }
                let count = Int(UDFBytes.u16(b, 48))
                guard 56 + count * 8 <= tableSize else { throw KaitoError.malformed("udf sparing table length") }
                var entries: [UDFSparingEntry] = []
                for entry in 0..<count {
                    let original = UDFBytes.u32(b, 56 + entry * 8)
                    let mapped = UDFBytes.u32(b, 60 + entry * 8)
                    // #FFFFFFFF は空き、#FFFFFFF0 は不良の予備。どちらも写像に使わない。
                    guard original < 0xFFFF_FFF0 else { continue }
                    guard original % packetLength == 0, original < physical.length else {
                        throw KaitoError.malformed("udf sparing table original location")
                    }
                    entries.append(UDFSparingEntry(original: original, mapped: mapped))
                }
                return .sparable(packetLength: packetLength, table: entries)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? KaitoError.malformed("udf sparing table")
    }

    /// UDF §2.2.11（2.x の header 形式、file type 248）と UDF 1.50 §2.2.10（末尾に regid、file type 0）の
    /// VAT。ICB は最後に記録された sector（UDF §6.11.2、閉じた session では AVDP の直後）にあるので、
    /// partition の末尾（image の末尾に run-out の padding があればそれより手前）から 512 sector 手前まで探す。
    private func virtualKind(physical reference: Int) throws -> UDFPartition.Kind {
        let physical = partitions[reference]
        let last = min(source.length / UInt64(blockSize) - 1, UInt64(physical.start) + UInt64(physical.length) - 1)
        var found: (UDFFileEntry, UInt64)?
        var candidate = last
        for _ in 0..<512 {
            guard candidate >= UInt64(physical.start) else { break }
            let block = UInt32(candidate - UInt64(physical.start))
            let b = try readSector(candidate)
            if let tag = try? UDFTag.parse(b, expectedLocation: block, label: "VAT ICB"),
               tag.identifier == 261 || tag.identifier == 266,
               let entry = try? UDFFileEntry(b, tag: tag, blockSize: blockSize),
               entry.fileType == 248 || entry.fileType == 0 {
                found = (entry, candidate)
                break
            }
            guard candidate > 0 else { break }
            candidate -= 1
        }
        guard let (entry, _) = found else { throw KaitoError.malformed("udf VAT ICB not found") }
        try Checked.size(entry.informationLength, limit: budget.limits.maxMetadataSize)
        try budget.charge(entry.informationLength)
        var bytes: [UInt8] = []
        if entry.allocationType == 3 {
            bytes = Array(entry.allocationDescriptors.prefix(Int(entry.informationLength)))
        } else {
            guard entry.allocationType == 0 || entry.allocationType == 1 else { throw KaitoError.malformed("udf VAT allocation descriptors") }
            var remaining = entry.informationLength
            for allocation in try allocations(of: entry, partition: physical, continuationReader: { block in
                try self.readBlock(partition: reference, block: block)
            }) where remaining > 0 {
                let length = min(UInt64(allocation.length), remaining)
                remaining -= length
                guard allocation.type == 0 else { throw KaitoError.malformed("udf VAT has an unrecorded extent") }
                for section in try physicalRanges(partition: Int(allocation.partition ?? UInt16(reference)), block: allocation.block, length: length) {
                    bytes += try readByteRange(source: source, offset: section.offset, count: Int(section.length))
                }
            }
            guard remaining == 0 else { throw KaitoError.malformed("udf VAT shorter than its information length") }
        }
        guard bytes.count >= 36 else { throw KaitoError.malformed("udf VAT too short") }
        let start: Int
        let end: Int
        if entry.fileType == 248 {
            let headerLength = Int(UDFBytes.u16(bytes, 0))
            guard headerLength >= 152, headerLength <= bytes.count else { throw KaitoError.malformed("udf VAT header length") }
            start = headerLength
            end = bytes.count
        } else {
            guard String(decoding: UDFBytes.identifier(bytes, bytes.count - 36), as: UTF8.self) == "*UDF Virtual Alloc Tbl" else {
                throw KaitoError.malformed("udf VAT trailer")
            }
            start = 0
            end = bytes.count - 36
        }
        guard (end - start) % 4 == 0 else { throw KaitoError.malformed("udf VAT entry alignment") }
        // entry 数は VAT の大きさ（maxMetadataSize）で既に抑えている。
        let count = (end - start) / 4
        var table: [UInt32] = []
        table.reserveCapacity(count)
        for index in 0..<count { table.append(UDFBytes.u32(bytes, start + index * 4)) }
        return .virtual(table: table, physical: reference)
    }

    private func physicalPartition(number: UInt16, descriptors: [UInt16: [UInt8]]) throws -> UDFPartition {
        guard let pd = descriptors[number] else { throw KaitoError.malformed("udf partition \(number) has no descriptor") }
        let start = UDFBytes.u32(pd, 188)
        let length = UDFBytes.u32(pd, 192)
        guard length > 0 else { throw KaitoError.malformed("udf partition \(number) is empty") }
        return UDFPartition(number: number, start: start, length: length, kind: .physical)
    }

    /// UDF §2.2.10: metadata file / mirror file の FE は物理 partition 内の block。file type 250 / 251。
    private func metadataKind(map: [UInt8], physical: UDFPartition) throws -> UDFPartition.Kind {
        let fileLocation = UDFBytes.u32(map, 40)
        let mirrorLocation = UDFBytes.u32(map, 44)
        var runs: [UDFMetadataRun]?
        var mirror: [UDFMetadataRun]?
        var firstError: Error?
        do { runs = try metadataRuns(fileEntryBlock: fileLocation, physical: physical, expectedType: 250) }
        catch { firstError = error }
        if mirrorLocation != 0xFFFF_FFFF {
            do { mirror = try metadataRuns(fileEntryBlock: mirrorLocation, physical: physical, expectedType: 251) }
            catch { if runs == nil { throw firstError ?? error } }
        }
        guard let main = runs ?? mirror else { throw firstError ?? KaitoError.malformed("udf metadata file") }
        return .metadata(runs: main, mirror: runs == nil ? nil : mirror)
    }

    private func metadataRuns(fileEntryBlock: UInt32, physical: UDFPartition, expectedType: UInt8) throws -> [UDFMetadataRun] {
        guard fileEntryBlock < physical.length else { throw KaitoError.malformed("udf metadata file entry location") }
        let b = try readSector(UInt64(physical.start) + UInt64(fileEntryBlock))
        guard let tag = try UDFTag.parse(b, expectedLocation: fileEntryBlock, label: "metadata file entry"),
              tag.identifier == 261 || tag.identifier == 266 else {
            throw KaitoError.malformed("udf metadata file entry tag")
        }
        let entry = try UDFFileEntry(b, tag: tag, blockSize: blockSize)
        guard entry.fileType == expectedType else { throw KaitoError.malformed("udf metadata file type \(entry.fileType)") }
        guard entry.allocationType == 0 else { throw KaitoError.malformed("udf metadata file allocation descriptor type") }
        var runs: [UDFMetadataRun] = []
        var metadataBlock: UInt32 = 0
        for allocation in try allocations(of: entry, partition: physical, continuationReader: { block in
            try self.readSector(UInt64(physical.start) + UInt64(block))
        }) {
            guard allocation.length % UInt32(blockSize) == 0 else { throw KaitoError.malformed("udf metadata file extent length") }
            let blocks = allocation.length / UInt32(blockSize)
            guard allocation.type == 0 else { throw KaitoError.malformed("udf metadata file has an unrecorded extent") }
            guard allocation.block < physical.length, blocks <= physical.length - allocation.block else {
                throw KaitoError.malformed("udf metadata file extent outside the partition")
            }
            runs.append(UDFMetadataRun(metadataBlock: metadataBlock, physicalBlock: allocation.block, blocks: blocks))
            metadataBlock = try UInt32(Checked.add(UInt64(metadataBlock), UInt64(blocks)))
        }
        guard !runs.isEmpty else { throw KaitoError.malformed("udf metadata file is empty") }
        return runs
    }

    // MARK: - block access

    /// ICB entry の読み取りで予算に加算する量。block 全体ではなく保持する descriptor 相当。
    static let entryCharge: UInt64 = 512

    /// 論理 sector（絶対位置）を 1 つ読む。metadata 予算に `charge`（既定は block 全体）を加算する。
    func readSector(_ lba: UInt64, charge: UInt64? = nil) throws -> [UInt8] {
        let offset = try Checked.mul(lba, UInt64(blockSize))
        try budget.charge(charge ?? UInt64(blockSize))
        return try readByteRange(source: source, offset: offset, count: blockSize)
    }

    /// partition 内の論理 block を 1 つ読む（metadata partition は写像を通す）。
    func readBlock(partition reference: Int, block: UInt32, charge: UInt64? = nil) throws -> [UInt8] {
        let physical = try physicalSector(partition: reference, block: block)
        return try readSector(physical, charge: charge)
    }

    /// partition 内の block 番号を絶対 sector 番号に写す。
    func physicalSector(partition reference: Int, block: UInt32) throws -> UInt64 {
        guard partitions.indices.contains(reference) else { throw KaitoError.malformed("udf partition reference \(reference)") }
        let partition = partitions[reference]
        switch partition.kind {
        case .physical:
            guard block < partition.length else { throw KaitoError.malformed("udf block \(block) outside partition \(reference)") }
            return UInt64(partition.start) + UInt64(block)
        case .metadata(let runs, let mirror):
            if let run = runs.first(where: { block >= $0.metadataBlock && block - $0.metadataBlock < $0.blocks }) {
                return UInt64(partition.start) + UInt64(run.physicalBlock) + UInt64(block - run.metadataBlock)
            }
            if let mirror, let run = mirror.first(where: { block >= $0.metadataBlock && block - $0.metadataBlock < $0.blocks }) {
                return UInt64(partition.start) + UInt64(run.physicalBlock) + UInt64(block - run.metadataBlock)
            }
            throw KaitoError.malformed("udf metadata block \(block) outside the metadata file")
        case .sparable(let packetLength, let table):
            guard block < partition.length else { throw KaitoError.malformed("udf block \(block) outside partition \(reference)") }
            let packet = block - block % packetLength
            if let entry = table.first(where: { $0.original == packet }) {
                return UInt64(entry.mapped) + UInt64(block - packet)
            }
            return UInt64(partition.start) + UInt64(block)
        case .virtual(let table, let physical):
            guard Int(block) < table.count else { throw KaitoError.malformed("udf virtual block \(block) outside the VAT") }
            let mapped = table[Int(block)]
            guard mapped != 0xFFFF_FFFF else { throw KaitoError.malformed("udf virtual block \(block) is unused") }
            return try physicalSector(partition: physical, block: mapped)
        }
    }

    /// partition 内の連続 block 範囲を、物理的に連続する byte 範囲の列に分ける（metadata 空間は run 境界で切る）。
    func physicalRanges(partition reference: Int, block: UInt32, length: UInt64) throws -> [ISOSection] {
        guard length > 0 else { return [] }
        guard partitions.indices.contains(reference) else { throw KaitoError.malformed("udf partition reference \(reference)") }
        let partition = partitions[reference]
        let blockSize64 = UInt64(blockSize)
        let blocks = try Checked.add(length, blockSize64 - 1) / blockSize64
        switch partition.kind {
        case .physical:
            guard block < partition.length, blocks <= UInt64(partition.length - block) else {
                throw KaitoError.malformed("udf extent outside partition \(reference)")
            }
            let offset = try Checked.mul(UInt64(partition.start) + UInt64(block), blockSize64)
            return [ISOSection(offset: offset, length: length)]
        case .metadata, .sparable, .virtual:
            var sections: [ISOSection] = []
            var current = block
            var remaining = length
            while remaining > 0 {
                let sector = try physicalSector(partition: reference, block: current)
                // 同じ run の残り block 数まで一括にする。
                var contiguous: UInt64 = 1
                while contiguous < (remaining + blockSize64 - 1) / blockSize64,
                      let next = try? physicalSector(partition: reference, block: current + UInt32(truncatingIfNeeded: contiguous)),
                      next == sector + contiguous {
                    contiguous += 1
                }
                let bytes = min(remaining, contiguous * blockSize64)
                sections.append(ISOSection(offset: try Checked.mul(sector, blockSize64), length: bytes))
                remaining -= bytes
                current = try UInt32(Checked.add(UInt64(current), contiguous))
            }
            return sections
        }
    }

    // MARK: - allocation descriptors

    /// 4/12 と 4/14.5: FE の allocation descriptor 列を、type 3 の継続 extent（AED、tag 258）を辿って集める。
    /// `continuationReader` は同じ partition の block を読む closure。
    func allocations(of entry: UDFFileEntry, partition: UDFPartition,
                     continuationReader: (UInt32) throws -> [UInt8]) throws -> [UDFAllocation] {
        var result: [UDFAllocation] = []
        var bytes = entry.allocationDescriptors
        var hops = 0
        while true {
            var continuation: UDFAllocation?
            let stride = entry.allocationType == 0 ? 8 : 16
            var offset = 0
            while offset + stride <= bytes.count {
                let allocation = entry.allocationType == 0 ? UDFAllocation.short(bytes, offset) : UDFAllocation.long(bytes, offset)
                offset += stride
                if allocation.length == 0 { break }
                if allocation.type == 3 { continuation = allocation; break }
                guard result.count < budget.limits.maxMetadataRecordCount else {
                    throw KaitoError.limitExceeded("udf allocation descriptor count")
                }
                result.append(allocation)
            }
            guard let next = continuation else { return result }
            hops += 1
            guard hops <= 64 else { throw KaitoError.malformed("udf allocation extent chain") }
            let block = try continuationReader(next.block)
            guard let tag = try UDFTag.parse(block, expectedLocation: next.block, label: "allocation extent"), tag.identifier == 258 else {
                throw KaitoError.malformed("udf allocation extent descriptor tag")
            }
            let length = Int(UDFBytes.u32(block, 20))
            guard length <= blockSize - 24 else { throw KaitoError.malformed("udf allocation extent descriptor length") }
            bytes = Array(block[24..<(24 + length)])
        }
    }
}
