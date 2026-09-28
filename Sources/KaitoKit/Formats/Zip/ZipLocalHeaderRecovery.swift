import Foundation

// 中央ディレクトリを使えない書庫の復旧（`ReaderOptions.recoverDamagedArchives` で EOCD が見つからないとき）。
// local header を先頭から辿り、中央 header と同じ形の byte 列に組み直して
// ZipCentralDirectoryParser の名前・暗号・上限の検証を共用する。

/// 復旧した entry の local header の位置と、source に実在する本文の大きさ。
struct ZipRecoveryExtent {
    let headerOffset: UInt64
    let availableSize: UInt64
    let unknownSize: Bool
    let isIncomplete: Bool
}

enum ZipLocalHeaderRecovery {
    /// 見つけた local header ごとに一つの entry を作る。bit 3 で本文長が 0 の entry は次の署名までを本文とし、
    /// 末尾の data descriptor が長さと合えばその値を使う。合わなければ大きさ不明の未完 entry にする。
    static func recover(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> ZipParsedDirectory {
        var offset: UInt64 = 0
        var scanned: UInt64 = 0
        var metadata: [UInt8] = []
        var recovery: [ZipRecoveryExtent] = []
        while offset < source.length {
            try checkCancellation(every: recovery.count)
            offset = try nextMarker(
                source: source, from: offset, scanned: &scanned, limits: limits
            )
            guard source.length - offset >= 4 else { break }
            let signature = try readByteRange(source: source, offset: offset, count: 4)
            guard LittleEndian.uint32(signature, at: 0) == ZipSignature.localHeader else { break }
            guard source.length - offset >= UInt64(ZipRecordSize.localHeader) else { break }
            guard recovery.count < limits.maxEntryCount else {
                throw KaitoError.limitExceeded("archive entry count")
            }
            try Checked.size(
                Checked.mul(UInt64(recovery.count + 1), 256),
                limit: limits.maxTotalMetadataSize
            )
            let header = try readByteRange(source: source, offset: offset, count: ZipRecordSize.localHeader)
            let flags = LittleEndian.uint16(header, at: 6)
            let nameSize = Int(LittleEndian.uint16(header, at: 26))
            let extraSize = Int(LittleEndian.uint16(header, at: 28))
            let variableSize = nameSize + extraSize
            try Checked.size(UInt64(ZipRecordSize.localHeader + variableSize), limit: limits.maxMetadataSize)
            let dataOffset = try Checked.add(offset, UInt64(ZipRecordSize.localHeader + variableSize))
            guard dataOffset <= source.length else { break }
            let variable = try readByteRange(
                source: source, offset: offset + UInt64(ZipRecordSize.localHeader), count: variableSize
            )
            let fields = try ZipExtraFields.parse(
                Array(variable.dropFirst(nameSize)),
                recordLimit: limits.maxMetadataRecordCount,
                tailPolicy: .zeroPadding
            )
            let sizes = try ZipExtraFields.resolveZIP64Values(
                compressed32: LittleEndian.uint32(header, at: 18),
                uncompressed32: LittleEndian.uint32(header, at: 22),
                localOffset32: 0, diskStart16: 0, fields: fields
            )
            var compressed = sizes.compressedSize
            var uncompressed = sizes.uncompressedSize
            var crc = LittleEndian.uint32(header, at: 14)
            try Checked.size(compressed, limit: limits.maxEntrySize)
            try Checked.size(uncompressed, limit: limits.maxEntrySize)
            var unknownSize = false
            var nextOffset: UInt64
            if flags & ZipGeneralPurposeFlag.dataDescriptor != 0, compressed == 0 {
                nextOffset = try nextMarker(
                    source: source, from: dataOffset, scanned: &scanned, limits: limits
                )
                compressed = nextOffset - dataOffset
                unknownSize = true
                // descriptor の署名あり・なし、ZIP32・ZIP64 の終端候補を範囲内で検査する。
                for descriptorSize in [16, 24, 12, 20] {
                    guard UInt64(descriptorSize) <= compressed else { continue }
                    let descriptor = try readByteRange(
                        source: source, offset: nextOffset - UInt64(descriptorSize),
                        count: descriptorSize
                    )
                    let signed = descriptorSize == 16 || descriptorSize == 24
                    if signed, LittleEndian.uint32(descriptor, at: 0) != ZipSignature.dataDescriptor { continue }
                    let base = signed ? 4 : 0
                    let wide = descriptorSize == 24 || descriptorSize == 20
                    let packed = wide ? LittleEndian.uint64(descriptor, at: base + 4)
                        : UInt64(LittleEndian.uint32(descriptor, at: base + 4))
                    guard packed == compressed - UInt64(descriptorSize) else { continue }
                    compressed = packed
                    uncompressed = wide ? LittleEndian.uint64(descriptor, at: base + 12)
                        : UInt64(LittleEndian.uint32(descriptor, at: base + 8))
                    crc = LittleEndian.uint32(descriptor, at: base)
                    unknownSize = false
                    break
                }
            } else {
                nextOffset = try Checked.add(dataOffset, compressed)
            }
            try Checked.size(compressed, limit: limits.maxEntrySize)
            try Checked.size(uncompressed, limit: limits.maxEntrySize)
            let available = min(compressed, source.length - dataOffset)
            // ローカル情報を既存の中央 entry 検証へ渡し、名前・暗号・上限の検証を共用する。
            var extra: [UInt8] = []
            for field in fields where field.identifier != ZipExtraFieldID.zip64 {
                appendLittleEndian(UInt64(field.identifier), width: 2, to: &extra)
                appendLittleEndian(UInt64(field.data.count), width: 2, to: &extra)
                extra += field.data
            }
            if compressed >= UInt64(UInt32.max) || uncompressed >= UInt64(UInt32.max) {
                var wide: [UInt8] = []
                if uncompressed >= UInt64(UInt32.max) {
                    appendLittleEndian(uncompressed, width: 8, to: &wide)
                }
                if compressed >= UInt64(UInt32.max) {
                    appendLittleEndian(compressed, width: 8, to: &wide)
                }
                appendLittleEndian(UInt64(ZipExtraFieldID.zip64), width: 2, to: &extra)
                appendLittleEndian(UInt64(wide.count), width: 2, to: &extra)
                extra += wide
            }
            guard extra.count <= Int(UInt16.max) else {
                throw KaitoError.limitExceeded("ZIP recovery extra size")
            }
            let nextMetadataSize = try Checked.add(
                UInt64(metadata.count), UInt64(ZipRecordSize.centralHeader + nameSize + extra.count)
            )
            try Checked.size(nextMetadataSize, limit: limits.maxMetadataSize)
            try Checked.size(nextMetadataSize, limit: limits.maxTotalMetadataSize)
            appendLittleEndian(UInt64(ZipSignature.centralHeader), width: 4, to: &metadata)
            appendLittleEndian(20, width: 2, to: &metadata) // 作成元バージョン 2.0
            metadata += header[4..<14]
            appendLittleEndian(UInt64(crc), width: 4, to: &metadata)
            appendLittleEndian(min(compressed, UInt64(UInt32.max)), width: 4, to: &metadata)
            appendLittleEndian(min(uncompressed, UInt64(UInt32.max)), width: 4, to: &metadata)
            appendLittleEndian(UInt64(nameSize), width: 2, to: &metadata)
            appendLittleEndian(UInt64(extra.count), width: 2, to: &metadata)
            metadata += [UInt8](repeating: 0, count: 14)
            metadata += variable.prefix(nameSize)
            metadata += extra
            recovery.append(ZipRecoveryExtent(
                headerOffset: offset, availableSize: available, unknownSize: unknownSize,
                isIncomplete: unknownSize || available < compressed
            ))
            offset = nextOffset
        }
        let location = ZipDirectoryLocation(
            archiveBase: 0, offset: source.length, size: UInt64(metadata.count),
            entryCount: recovery.count
        )
        return try ZipCentralDirectoryParser.parse(
            source: source, location: location, policy: policy, limits: limits,
            recoveredBytes: metadata, recovery: recovery
        )
    }

    private static func appendLittleEndian(
        _ value: UInt64, width: Int, to bytes: inout [UInt8]
    ) {
        for index in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }

    /// `start` 以降で最初の local / 中央 header・EOCD・ZIP64 EOCD の署名の位置。無ければ source の長さ。
    private static func nextMarker(
        source: any ByteSource,
        from start: UInt64,
        scanned: inout UInt64,
        limits: ReadLimits
    ) throws -> UInt64 {
        var offset = start
        while source.length - offset >= 4 {
            guard scanned < limits.maxTotalMetadataSize, limits.maxMetadataSize >= 4 else {
                throw KaitoError.limitExceeded("ZIP recovery scan bytes")
            }
            let budget = limits.maxTotalMetadataSize - scanned
            let count = min(source.length - offset, 65_536, limits.maxMetadataSize, budget)
            guard count >= 4 else { throw KaitoError.limitExceeded("ZIP recovery scan bytes") }
            let bytes = try readByteRange(source: source, offset: offset, count: Int(count))
            for index in 0...(bytes.count - 4) {
                try checkCancellation(every: index)
                let signature = LittleEndian.uint32(bytes, at: index)
                if signature == ZipSignature.localHeader || signature == ZipSignature.centralHeader
                    || signature == ZipSignature.endOfCentralDirectory || signature == ZipSignature.zip64End {
                    scanned = try Checked.add(scanned, UInt64(index + 4))
                    return offset + UInt64(index)
                }
            }
            let advance = count - 3
            scanned = try Checked.add(scanned, advance)
            offset += advance
        }
        return source.length
    }
}
