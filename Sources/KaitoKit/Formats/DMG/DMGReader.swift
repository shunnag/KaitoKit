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

    /// UEFI GPT の header（LBA 1）と partition entry の field offset。
    private enum GPTOffset {
        static let partitionEntryLBA = 72
        static let entryCount = 80
        static let entrySize = 84
        static let entryStartingLBA = 32
    }

    /// volume の開始 offset（byte）の候補: bare volume、GPT / APM の partition、UDIF の blkx。
    static func volumeCandidates(disk: any ByteSource) throws -> [UInt64] {
        var candidates: [UInt64] = [0]
        guard disk.length >= 1024 else { return candidates }
        let sector1 = try readByteRange(source: disk, offset: 512, count: 512)
        if Array(sector1[0..<8]) == Array("EFI PART".utf8) {
            // UEFI GPT header（little-endian）。entry の ending LBA（@40）は使わない。
            let entryLBA = LittleEndian.uint64(sector1, at: GPTOffset.partitionEntryLBA)
            let count = Int(LittleEndian.uint32(sector1, at: GPTOffset.entryCount))
            let size = Int(LittleEndian.uint32(sector1, at: GPTOffset.entrySize))
            if size >= 128, size <= 4096, count > 0, count <= 1024, entryLBA > 0,
               (try? Checked.add(Checked.mul(entryLBA, 512), UInt64(count * size))) ?? UInt64.max <= disk.length {
                let table = try readByteRange(source: disk, offset: entryLBA * 512, count: count * size)
                for index in 0..<count {
                    let o = index * size
                    guard table[o..<(o + 16)].contains(where: { $0 != 0 }) else { continue }     // 空 entry
                    let start = LittleEndian.uint64(table, at: o + GPTOffset.entryStartingLBA)
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
            if try UDFVolume.detectRecognitionSequence(source: volumeSource, pureOnly: true) {
                let inner = try UDFReader(source: volumeSource, options: options)
                body = .inner(inner)
                entries = inner.entries
                return
            }
        }
        // APFS（container superblock の signature "NXSB" が block 0）は範囲外。候補は必ず disk 先頭（0）から始まる。
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
