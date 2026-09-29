// ZipCentralDirectoryLocator の再試行と整合性検査を、共有予算内で判定する。
// 位置は ZipDirectoryLocationResolver で解決し、単巻 ZIP32 の検査を巻の発見にも提供する。

/// EOCD 候補の試行回数と、試行・整合性検査が読む metadata 量の共有予算。
/// 上限は試行 8,192 回と `maxMetadataSize` の 2 倍。予算の枯渇は再試行できない停止として扱う。
struct ZipEndRecordParseBudget {
    static let maximumAttempts = 8_192

    var remainingAttempts: Int
    var remainingMetadataBytes: UInt64
    private var exemptsFirstAttempt: Bool
    private var attemptCount = 0

    init(limits: ReadLimits, exemptsFirstAttempt: Bool = false) {
        self.exemptsFirstAttempt = exemptsFirstAttempt
        remainingAttempts = Self.maximumAttempts
        let doubled = limits.maxMetadataSize.multipliedReportingOverflow(by: 2)
        remainingMetadataBytes = doubled.overflow ? UInt64.max : doubled.partialValue
    }

    mutating func chargeAttempt() throws {
        guard remainingAttempts > 0 else {
            throw KaitoError.limitExceeded("ZIP end-record candidate attempts")
        }
        remainingAttempts -= 1
        attemptCount += 1
    }

    mutating func endFirstAttemptExemption() {
        exemptsFirstAttempt = false
    }

    mutating func chargeMetadataBytes(_ count: UInt64) throws {
        // 初回の通常解析だけを免除し、エラー後の整合性検査にも累積予算を適用する。
        if exemptsFirstAttempt, attemptCount == 1 { return }
        guard count <= remainingMetadataBytes else {
            throw KaitoError.limitExceeded("ZIP end-record candidate metadata work")
        }
        remainingMetadataBytes -= count
    }
}

enum ZipEndRecordRecovery {
    private typealias EndRecord = ZipEndRecords.EndRecord

    static func shouldRetryEndRecordCandidateError(
        _ error: Error,
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: ZipEndRecords.EndRecord,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> Bool {
        if isRetryableEndRecordError(error) { return true }
        guard let kaitoError = error as? KaitoError else { return false }
        switch kaitoError {
        case let .limitExceeded(reason):
            // どちらかの候補予算の枯渇は、敵対的な再試行を抑える停止そのもの。再試行可能にしない。
            guard reason != "ZIP end-record candidate attempts",
                  reason != "ZIP end-record candidate metadata work" else {
                return false
            }
        case .unsupportedMethod:
            break
        default:
            return false
        }

        // disk の欄と設定上限は中央ディレクトリを読む前に検査する。本当に整合した新しい連結書庫では
        // その policy error を保つが、対応する中央ディレクトリの無い EOCD 形の末尾 byte 列に古い書庫を隠させない。
        // 整合性の検査は policy 上限を意図して緩めるので、最初の解析試行の後も共有の作業予算へ課金する。
        budget.endFirstAttemptExemption()
        do {
            return try !hasCoherentDirectoryClaim(
                source: source,
                diskLayout: diskLayout,
                end: end,
                limits: limits,
                budget: &budget
            )
        } catch {
            // 古い候補へ進む根拠になるのは、上限内で完了した検査だけ。作業予算が尽きたら元の policy error で止める。
            if case let KaitoError.limitExceeded(reason) = error,
               reason == "ZIP end-record candidate metadata work" {
                return false
            }
            if isRetryableEndRecordError(error) { return true }
            throw error
        }
    }

    private static func hasCoherentDirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> Bool {
        if let diskLayout {
            var claimLimits = limits
            claimLimits.maxEntryCount = Int.max
            claimLimits.maxMetadataSize = UInt64.max
            claimLimits.maxTotalMetadataSize = UInt64.max
            let location: ZipDirectoryLocation
            if try end.diskNumber == UInt16.max || end.centralDirectoryDisk == UInt16.max
                || end.entriesOnDisk == UInt16.max || end.totalEntries == UInt16.max
                || end.centralDirectorySize == UInt32.max || end.centralDirectoryOffset == UInt32.max
                || ZipEndRecords.locator(source: source, end: end) != nil {
                location = try ZipDirectoryLocationResolver.locateZIP64Directory(source: source, diskLayout: diskLayout,
                    end: end, limits: claimLimits, budget: &budget)
            } else {
                location = try ZipDirectoryLocationResolver.locateZIP32Directory(source: source, diskLayout: diskLayout,
                    end: end, limits: claimLimits)
            }
            return try hasCoherentCentralDirectoryClaim(source: source, diskLayout: diskLayout,
                archiveBase: 0, directoryStart: location.offset, directorySize: location.size,
                entryCount: location.entryCount, upperBound: end.offset, budget: &budget)
        }
        let usesZIP64 = end.diskNumber == UInt16.max
            || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max
            || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max
            || end.centralDirectoryOffset == UInt32.max
        if usesZIP64 {
            do {
                return try hasCoherentZIP64DirectoryClaim(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                )
            } catch {
                if isRetryableEndRecordError(error) { return false }
                throw error
            }
        }

        // ZIP32 の番兵値なしに ZIP64 record と locator を書く作成元がある。その根拠のある解釈を ZIP32 の検査より先に試す。
        if try ZipEndRecords.locator(source: source, end: end) != nil {
            do {
                if try hasCoherentZIP64DirectoryClaim(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                ) {
                    return true
                }
            } catch {
                guard isRetryableEndRecordError(error) else { throw error }
            }
        }
        return try hasCoherentZIP32DirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            end: end,
            budget: &budget
        )
    }

    /// 兄弟探索の段階でも、末尾ゴミにある単巻 EOCD の候補を区別する。
    static func hasCoherentZIP32End(source: any ByteSource, end: ZipEndRecords.EndRecord,
                                   budget: inout ZipEndRecordParseBudget) throws -> Bool {
        return try hasCoherentZIP32DirectoryClaim(source: source, end: end, budget: &budget)
    }

    private static func hasCoherentZIP32DirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        budget: inout ZipEndRecordParseBudget
    ) throws -> Bool {
        let entryCount = Int(end.totalEntries)
        let size = UInt64(end.centralDirectorySize)

        // 空の EOCD には、本物の書庫と EOCD 形の末尾 byte 列を区別する中央ディレクトリの根拠が無い。
        // 候補の順序に従い、根拠のある古い書庫へ進ませる。
        guard entryCount != 0, size != 0 else { return false }

        let directoryStart: UInt64
        let archiveBase: UInt64
        do {
            directoryStart = try Checked.sub(end.offset, size)
            archiveBase = try Checked.sub(
                directoryStart,
                UInt64(end.centralDirectoryOffset)
            )
        } catch {
            return false
        }
        guard (try? Checked.add(directoryStart, size)) == end.offset else {
            return false
        }
        return try hasCoherentCentralDirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            archiveBase: archiveBase,
            directoryStart: directoryStart,
            directorySize: size,
            entryCount: entryCount,
            upperBound: end.offset,
            budget: &budget
        )
    }

    private static func hasCoherentZIP64DirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> Bool {
        guard end.offset >= UInt64(ZipRecordSize.zip64Locator) else { return false }
        let locatorOffset = try Checked.sub(end.offset, UInt64(ZipRecordSize.zip64Locator))
        let locatorBytes = try readByteRange(
            source: source,
            offset: locatorOffset,
            count: ZipRecordSize.zip64Locator
        )
        var locator = ZipByteCursor(locatorBytes)
        guard try locator.readUInt32LE() == ZipSignature.zip64Locator else {
            return false
        }
        _ = try locator.readUInt32LE() // locator の disk 番号（policy 検査の欄で、ここでは見ない）
        let relativeRecordOffset = try locator.readUInt64LE()
        _ = try locator.readUInt32LE() // disk 数（同上）

        // 上限付きの後方探索で、ZIP64 record が実際にこの locator の直前で終わることを確かめる。
        // locator の形をした末尾だけでは根拠にならない。
        guard limits.maxMetadataSize >= UInt64(ZipRecordSize.zip64EndFixed) else { return false }
        try budget.chargeMetadataBytes(min(locatorOffset, limits.maxMetadataSize))
        let recordOffset = try ZipDirectoryLocationResolver.findZIP64RecordOffset(
            source: source,
            locatorOffset: locatorOffset,
            limits: limits
        )
        let fixed = try readByteRange(source: source, offset: recordOffset, count: ZipRecordSize.zip64EndFixed)
        var record = ZipByteCursor(fixed)
        guard try record.readUInt32LE() == ZipSignature.zip64End else { return false }
        let payloadSize = try record.readUInt64LE()
        guard payloadSize >= UInt64(ZipRecordSize.zip64EndMinimumPayload) else { return false }
        let fullRecordSize: UInt64
        do {
            fullRecordSize = try Checked.add(payloadSize, UInt64(ZipRecordSize.zip64EndLeadingFields))
        } catch {
            return false
        }
        guard fullRecordSize <= limits.maxMetadataSize,
              (try? Checked.add(recordOffset, fullRecordSize)) == locatorOffset else {
            return false
        }

        _ = try record.readUInt16LE()
        _ = try record.readUInt16LE()
        _ = try record.readUInt32LE() // record の disk 番号（policy 検査の欄で、ここでは見ない）
        _ = try record.readUInt32LE() // 中央ディレクトリの disk 番号（同上）
        _ = try record.readUInt64LE() // disk ごとの件数（同上）
        let totalEntries = try record.readUInt64LE()
        let directorySize = try record.readUInt64LE()
        let relativeDirectoryOffset = try record.readUInt64LE()

        if end.totalEntries != UInt16.max,
           UInt64(end.totalEntries) != totalEntries {
            return false
        }
        if end.centralDirectorySize != UInt32.max,
           UInt64(end.centralDirectorySize) != directorySize {
            return false
        }
        if end.centralDirectoryOffset != UInt32.max,
           UInt64(end.centralDirectoryOffset) != relativeDirectoryOffset {
            return false
        }

        let archiveBase: UInt64
        let directoryStart: UInt64
        let directoryEnd: UInt64
        do {
            archiveBase = try Checked.sub(recordOffset, relativeRecordOffset)
            directoryStart = try Checked.add(archiveBase, relativeDirectoryOffset)
            directoryEnd = try Checked.add(directoryStart, directorySize)
        } catch {
            return false
        }
        guard directoryEnd <= recordOffset,
              directoryEnd <= source.length else { return false }
        // 最小の中央 entry でも 46 byte 必要なので、Int に収まらない件数を収める ByteSource は無い。
        guard totalEntries <= UInt64(Int.max) else { return false }
        return try hasCoherentCentralDirectoryClaim(
            source: source,
            diskLayout: diskLayout,
            archiveBase: archiveBase,
            directoryStart: directoryStart,
            directorySize: directorySize,
            entryCount: Int(totalEntries),
            upperBound: recordOffset,
            budget: &budget
        )
    }

    private static func hasCoherentCentralDirectoryClaim(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        archiveBase: UInt64,
        directoryStart: UInt64,
        directorySize: UInt64,
        entryCount: Int,
        upperBound: UInt64,
        budget: inout ZipEndRecordParseBudget
    ) throws -> Bool {
        guard entryCount >= 0 else { return false }
        if entryCount == 0 { return directorySize == 0 }
        guard directorySize != 0 else { return false }
        let directoryEnd: UInt64
        let minimumSize: UInt64
        do {
            directoryEnd = try Checked.add(directoryStart, directorySize)
            minimumSize = try Checked.mul(UInt64(entryCount), UInt64(ZipRecordSize.centralHeader))
        } catch {
            return false
        }
        guard directoryEnd <= upperBound,
              directoryEnd <= source.length,
              minimumSize <= directorySize else { return false }
        var cursor = directoryStart

        // 読むのは固定部だけで、可変部は宣言長で範囲を確かめて飛ばす。最初の試行の後の検査も含め、
        // どの読取も行う前に共有の作業予算へ課金する。
        for index in 0..<entryCount {
            try checkCancellation(every: index)
            guard cursor <= directoryEnd,
                  directoryEnd - cursor >= UInt64(ZipRecordSize.centralHeader) else { return false }
            try budget.chargeMetadataBytes(UInt64(ZipRecordSize.centralHeader))
            let fixed = try readByteRange(
                source: source,
                offset: cursor,
                count: ZipRecordSize.centralHeader
            )
            guard LittleEndian.uint32(fixed, at: 0) == ZipSignature.centralHeader else {
                return false
            }

            let nameLength = UInt64(LittleEndian.uint16(fixed, at: 28))
            let extraLength = UInt64(LittleEndian.uint16(fixed, at: 30))
            let commentLength = UInt64(LittleEndian.uint16(fixed, at: 32))
            guard nameLength > 0 else { return false }
            let recordSize: UInt64
            let next: UInt64
            do {
                let nameAndExtra = try Checked.add(nameLength, extraLength)
                let variableLength = try Checked.add(nameAndExtra, commentLength)
                recordSize = try Checked.add(UInt64(ZipRecordSize.centralHeader), variableLength)
                next = try Checked.add(cursor, recordSize)
            } catch {
                return false
            }
            guard next <= directoryEnd else { return false }

            let localOffset32 = LittleEndian.uint32(fixed, at: 42)
            let localOffset: UInt64
            var diskStart = UInt32(LittleEndian.uint16(fixed, at: 34))
            if localOffset32 == UInt32.max || (diskLayout != nil && diskStart == UInt16.max) {
                let extraOffset: UInt64
                do {
                    extraOffset = try Checked.add(
                        try Checked.add(cursor, UInt64(ZipRecordSize.centralHeader)),
                        nameLength
                    )
                } catch {
                    return false
                }
                try budget.chargeMetadataBytes(extraLength)
                let extra = try readByteRange(
                    source: source,
                    offset: extraOffset,
                    count: Int(extraLength)
                )
                let fields: [ZipExtraField]
                do {
                    fields = try ZipExtraFields.parse(
                        extra,
                        recordLimit: extra.count / 4 + 1,
                        tailPolicy: .ignoreUnparsableTail
                    )
                    let values = try ZipExtraFields.resolveZIP64Values(
                        compressed32: LittleEndian.uint32(fixed, at: 20),
                        uncompressed32: LittleEndian.uint32(fixed, at: 24),
                        localOffset32: localOffset32,
                        diskStart16: LittleEndian.uint16(fixed, at: 34),
                        fields: fields
                    )
                    localOffset = values.localHeaderOffset
                    diskStart = values.diskStart
                } catch {
                    return false
                }
            } else {
                localOffset = UInt64(localOffset32)
            }

            let absoluteLocalOffset: UInt64
            do {
                absoluteLocalOffset = try diskLayout?.absoluteOffset(disk: UInt64(diskStart), relative: localOffset)
                    ?? Checked.add(archiveBase, localOffset)
            } catch {
                return false
            }
            guard absoluteLocalOffset < directoryStart else { return false }
            cursor = next
        }
        return cursor == directoryEnd
    }

    static func isRetryableEndRecordError(_ error: Error) -> Bool {
        guard let kaitoError = error as? KaitoError else { return false }
        switch kaitoError {
        case .malformed, .truncated:
            return true
        default:
            return false
        }
    }
}
