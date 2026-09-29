// ZipCentralDirectoryLocator と ZipEndRecordRecovery が使う ZIP32 / ZIP64 の位置を解決する。
// ZIP64 record の探索を含め、呼出元の上限と共有予算に従う。

enum ZipDirectoryLocationResolver {
    static func locateZIP32Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: ZipEndRecords.EndRecord,
        limits: ReadLimits
    ) throws -> ZipDirectoryLocation {
        if let diskLayout {
            try diskLayout.validate(end: end)
            guard end.entriesOnDisk <= end.totalEntries else {
                throw KaitoError.malformed("ZIP per-disk entry count exceeds total")
            }
        } else {
            guard end.diskNumber == 0,
                  end.centralDirectoryDisk == 0,
                  end.entriesOnDisk == end.totalEntries else {
                throw KaitoError.unsupportedMethod("spanned")
            }
        }
        let count = Int(end.totalEntries)
        guard count <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("ZIP entry count")
        }
        let size = UInt64(end.centralDirectorySize)
        // 中央ディレクトリは件数に比例し、単一確保の 16 MiB 上限では 100 万件と両立しない。
        // 既存の総 metadata 上限（既定 256 MiB）を使い、メモリ上限自体は引き上げない。
        try Checked.size(size, limit: limits.maxTotalMetadataSize)
        let relativeOffset = UInt64(end.centralDirectoryOffset)
        let beforeOffset = try Checked.sub(end.offset, size)
        let archiveBase = try diskLayout == nil ? Checked.sub(beforeOffset, relativeOffset) : 0
        let absoluteOffset = try diskLayout?.absoluteOffset(
            disk: UInt64(end.centralDirectoryDisk), relative: relativeOffset, allowEnd: size == 0
        ) ?? Checked.add(archiveBase, relativeOffset)
        let directoryEnd = try Checked.add(absoluteOffset, size)
        guard directoryEnd == end.offset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP central directory lies outside the file")
        }
        return ZipDirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteOffset,
            size: size,
            entryCount: count,
            diskLayout: diskLayout
        )
    }

    static func locateZIP64Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: ZipEndRecords.EndRecord,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> ZipDirectoryLocation {
        if let diskLayout {
            try diskLayout.validate(end: end)
        } else {
            guard (end.diskNumber == 0 || end.diskNumber == UInt16.max),
                  (end.centralDirectoryDisk == 0 || end.centralDirectoryDisk == UInt16.max) else {
                throw KaitoError.unsupportedMethod("spanned")
            }
        }
        guard end.offset >= UInt64(ZipRecordSize.zip64Locator) else { throw KaitoError.truncated }
        let locatorOffset = try Checked.sub(end.offset, UInt64(ZipRecordSize.zip64Locator))
        guard let locator = try ZipEndRecords.locator(source: source, end: end) else {
            throw KaitoError.malformed("ZIP64 locator is missing")
        }
        let relativeRecordOffset = locator.relativeRecordOffset
        let recordOffset: UInt64
        if let diskLayout {
            guard UInt64(locator.diskCount) == UInt64(diskLayout.disks.count),
                  locatorOffset >= diskLayout.disks[diskLayout.disks.count - 1].start else {
                throw KaitoError.malformed("ZIP64 locator disagrees with the volume set")
            }
            recordOffset = try diskLayout.absoluteOffset(
                disk: UInt64(locator.recordDisk), relative: relativeRecordOffset)
            try budget.chargeMetadataBytes(UInt64(ZipRecordSize.zip64EndFixed))
        } else {
            guard locator.recordDisk == 0, locator.diskCount == 1 else {
                throw KaitoError.unsupportedMethod("spanned")
            }
            try budget.chargeMetadataBytes(min(locatorOffset, limits.maxMetadataSize))
            recordOffset = try findZIP64RecordOffset(
                source: source, locatorOffset: locatorOffset, limits: limits)
        }
        let fixed = try readByteRange(source: source, offset: recordOffset, count: ZipRecordSize.zip64EndFixed)
        var record = ZipByteCursor(fixed)
        guard try record.readUInt32LE() == ZipSignature.zip64End else {
            throw KaitoError.malformed("invalid ZIP64 end record")
        }
        let payloadSize = try record.readUInt64LE()
        guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else {
            throw KaitoError.malformed("undersized ZIP64 end record")
        }
        let fullRecordSize = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
        try Checked.size(fullRecordSize, limit: limits.maxMetadataSize)
        guard try Checked.add(recordOffset, fullRecordSize) == locatorOffset else {
            throw KaitoError.malformed("ZIP64 end-record length is inconsistent")
        }
        _ = try record.readUInt16LE() // 作成元バージョン
        _ = try record.readUInt16LE() // 展開に必要なバージョン
        let disk = try record.readUInt32LE()
        let centralDisk = try record.readUInt32LE()
        let entriesOnDisk = try record.readUInt64LE()
        let totalEntries = try record.readUInt64LE()
        let directorySize = try record.readUInt64LE()
        let relativeDirectoryOffset = try record.readUInt64LE()
        if let diskLayout {
            guard UInt64(disk) == diskLayout.lastDiskIndex,
                  UInt64(centralDisk) <= diskLayout.lastDiskIndex,
                  entriesOnDisk <= totalEntries,
                  end.diskNumber == UInt16.max || UInt32(end.diskNumber) == disk,
                  end.centralDirectoryDisk == UInt16.max || UInt32(end.centralDirectoryDisk) == centralDisk else {
                throw KaitoError.malformed("ZIP32 and ZIP64 disk fields disagree with the volume set")
            }
        } else {
            guard disk == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
                throw KaitoError.unsupportedMethod("spanned")
            }
        }

        if end.entriesOnDisk != UInt16.max,
           UInt64(end.entriesOnDisk) != entriesOnDisk {
            throw KaitoError.malformed("ZIP32 and ZIP64 entry counts disagree")
        }
        if end.totalEntries != UInt16.max,
           UInt64(end.totalEntries) != totalEntries {
            throw KaitoError.malformed("ZIP32 and ZIP64 entry counts disagree")
        }
        if end.centralDirectorySize != UInt32.max,
           UInt64(end.centralDirectorySize) != directorySize {
            throw KaitoError.malformed("ZIP32 and ZIP64 directory sizes disagree")
        }
        if end.centralDirectoryOffset != UInt32.max,
           UInt64(end.centralDirectoryOffset) != relativeDirectoryOffset {
            throw KaitoError.malformed("ZIP32 and ZIP64 directory offsets disagree")
        }

        let count = try Checked.toInt(totalEntries)
        guard count <= limits.maxEntryCount else {
            throw KaitoError.limitExceeded("ZIP entry count")
        }
        // ZIP32 と同じく件数に比例する中央ディレクトリは、既存の総 metadata 上限で制限する。
        try Checked.size(directorySize, limit: limits.maxTotalMetadataSize)
        let archiveBase = try diskLayout == nil ? Checked.sub(recordOffset, relativeRecordOffset) : 0
        let absoluteDirectoryOffset = try diskLayout?.absoluteOffset(
            disk: UInt64(centralDisk), relative: relativeDirectoryOffset, allowEnd: directorySize == 0
        ) ?? Checked.add(archiveBase, relativeDirectoryOffset)
        let directoryEnd = try Checked.add(absoluteDirectoryOffset, directorySize)
        guard directoryEnd <= recordOffset, directoryEnd <= source.length else {
            throw KaitoError.malformed("ZIP64 central directory lies outside the file")
        }
        return ZipDirectoryLocation(
            archiveBase: archiveBase,
            offset: absoluteDirectoryOffset,
            size: directorySize,
            entryCount: count,
            diskLayout: diskLayout
        )
    }

    static func findZIP64RecordOffset(
        source: any ByteSource,
        locatorOffset: UInt64,
        limits: ReadLimits
    ) throws -> UInt64 {
        guard locatorOffset >= UInt64(ZipRecordSize.zip64EndFixed) else { throw KaitoError.truncated }
        guard limits.maxMetadataSize >= UInt64(ZipRecordSize.zip64EndFixed) else {
            throw KaitoError.limitExceeded("ZIP64 end record")
        }
        let searchSize = min(locatorOffset, limits.maxMetadataSize)
        let searchCount = try Checked.toInt(searchSize)
        let searchOffset = try Checked.sub(locatorOffset, searchSize)
        let bytes = try readByteRange(source: source, offset: searchOffset, count: searchCount)
        guard bytes.count >= ZipRecordSize.zip64EndFixed else { throw KaitoError.truncated }

        for index in stride(from: bytes.count - ZipRecordSize.zip64EndFixed, through: 0, by: -1) {
            try checkCancellation(every: index)
            guard LittleEndian.uint32(bytes, at: index) == ZipSignature.zip64End else { continue }
            let payloadSize = LittleEndian.uint64(bytes, at: index + 4)
            guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else { continue }
            let total: UInt64
            do {
                total = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
            } catch {
                continue
            }
            guard total <= limits.maxMetadataSize else { continue }
            let absolute = try Checked.add(searchOffset, UInt64(index))
            guard (try? Checked.add(absolute, total)) == locatorOffset else { continue }
            return absolute
        }
        throw KaitoError.malformed("ZIP64 end record was not found")
    }
}
