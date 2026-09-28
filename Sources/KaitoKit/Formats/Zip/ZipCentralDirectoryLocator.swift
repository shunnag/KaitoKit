import Foundation

// 通常の open で EOCD 候補から中央ディレクトリを一つ選び、ZipCentralDirectoryParser で解析する。APPNOTE §4.3.14–16。
// 候補は ZipEndRecords.findEndRecords が末尾から集め、ここで ZIP32 / ZIP64 の位置を解決して整合性を確かめる。
// ZipEndRecords.lastDiskIndex（分割巻の発見）も単巻 EOCD の整合性検査 hasCoherentZIP32End をここから使う。

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

enum ZipCentralDirectoryLocator {
    private typealias EndRecord = ZipEndRecords.EndRecord

    /// EOCD 候補を新しい順に試し、最初に整合した中央ディレクトリを解析して返す。
    /// 標準の窓（EOCD と最大の comment）で書庫が見つからないか、見つかった書庫が空で source の末尾まで届かないときだけ、
    /// 1 MiB の末尾 data を含む窓へ広げて試し直す。どちらも失敗したら標準の窓の error を優先して投げる。
    static func locate(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> ZipParsedDirectory {
        // 二つの探索窓と包含候補の再試行で共有する。兄弟探索の予算は免除しない。
        var budget = ZipEndRecordParseBudget(limits: limits, exemptsFirstAttempt: true)
        var attemptedEndRecordOffsets: Set<UInt64> = []
        let standardSearchSize = ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize
        let initialCandidates = try ZipEndRecords.findEndRecords(
            source: source,
            maximumSearchSize: standardSearchSize
        )
        let initial = try parseDirectoryCandidates(
            initialCandidates,
            source: source,
            diskLayout: diskLayout,
            policy: policy,
            limits: limits,
            budget: &budget,
            attemptedOffsets: &attemptedEndRecordOffsets
        )

        if let directory = initial.directory,
           !directory.entries.isEmpty
               || initial.end?.recordEnd == source.length
               || source.length <= UInt64(standardSearchSize) {
            return directory
        }

        let expandedSearchSize = standardSearchSize + ZipEndRecords.maximumTrailingDataSize
        if source.length > UInt64(standardSearchSize) {
            let expandedCandidates = try ZipEndRecords.findEndRecords(
                source: source,
                maximumSearchSize: expandedSearchSize
            )
            let expanded = try parseDirectoryCandidates(
                expandedCandidates,
                source: source,
                diskLayout: diskLayout,
                policy: policy,
                limits: limits,
                budget: &budget,
                attemptedOffsets: &attemptedEndRecordOffsets
            )
            if let directory = expanded.directory {
                return directory
            }
            if let directory = initial.directory {
                return directory
            }
            throw initial.error
                ?? expanded.error
                ?? KaitoError.malformed(
                    "ZIP end-of-central-directory record was not found"
                )
        }

        if let directory = initial.directory {
            return directory
        }
        throw initial.error
            ?? KaitoError.malformed("ZIP end-of-central-directory record was not found")
    }

    private static func parseDirectoryCandidates(
        _ candidates: [EndRecord],
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget,
        attemptedOffsets: inout Set<UInt64>
    ) throws -> (directory: ZipParsedDirectory?, end: EndRecord?, error: Error?) {
        var candidateError: Error?

        for (candidateIndex, end) in candidates.enumerated() {
            guard attemptedOffsets.insert(end.offset).inserted else { continue }
            do {
                let parsed = try parseDirectoryCandidate(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    policy: policy,
                    limits: limits,
                    budget: &budget
                )

                // 空の EOCD の形をした byte 列は、どこにあっても構造としては自己整合する。
                // 採用する前に、宣言した comment がそれを丸ごと含む、整合した空でない EOCD を優先する。
                // これで PK\x05\x06 を含む本物の comment を保ち、任意の SFX 前置きに後ろの書庫を捨てさせない。
                if parsed.entries.isEmpty,
                   candidateIndex + 1 < candidates.count {
                    for enclosing in candidates[(candidateIndex + 1)...]
                        where enclosing.totalEntries != 0
                            || enclosing.centralDirectorySize != 0
                    {
                        let commentStart = enclosing.offset + UInt64(ZipEndRecords.endMinimumSize)
                        guard end.offset >= commentStart,
                              end.recordEnd <= enclosing.recordEnd else { continue }
                        guard attemptedOffsets.insert(enclosing.offset).inserted else {
                            continue
                        }
                        do {
                            let enclosingParsed = try parseDirectoryCandidate(
                                source: source,
                                diskLayout: diskLayout,
                                end: enclosing,
                                policy: policy,
                                limits: limits,
                                budget: &budget
                            )
                            if !enclosingParsed.entries.isEmpty {
                                return (enclosingParsed, enclosing, nil)
                            }
                        } catch {
                            guard try shouldRetryEndRecordCandidateError(
                                error,
                                source: source,
                                diskLayout: diskLayout,
                                end: enclosing,
                                limits: limits,
                                budget: &budget
                            ) else {
                                throw error
                            }
                        }
                    }
                }
                return (parsed, end, nil)
            } catch {
                // 末尾 data は EOCD の形をした byte 列を含み得る。中央ディレクトリ全体が整合しない限り
                // 候補として使えないので、最新の失敗を報告する前に上限内の一つ前の候補へ進む。
                guard try shouldRetryEndRecordCandidateError(
                    error,
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                ) else {
                    throw error
                }
                candidateError = candidateError ?? error
            }
        }
        return (nil, nil, candidateError)
    }

    private static func shouldRetryEndRecordCandidateError(
        _ error: Error,
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
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
                location = try locateZIP64Directory(source: source, diskLayout: diskLayout,
                    end: end, limits: claimLimits, budget: &budget)
            } else {
                location = try locateZIP32Directory(source: source, diskLayout: diskLayout,
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
        let recordOffset = try findZIP64RecordOffset(
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

    private static func isRetryableEndRecordError(_ error: Error) -> Bool {
        guard let kaitoError = error as? KaitoError else { return false }
        switch kaitoError {
        case .malformed, .truncated:
            return true
        default:
            return false
        }
    }

    private static func parseDirectoryCandidate(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> ZipParsedDirectory {
        try budget.chargeAttempt()
        let usesZIP64 = end.diskNumber == UInt16.max
            || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max
            || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max
            || end.centralDirectoryOffset == UInt32.max
        if usesZIP64 {
            let location = try locateZIP64Directory(
                source: source,
                diskLayout: diskLayout,
                end: end,
                limits: limits,
                budget: &budget
            )
            return try parseDirectory(
                source: source,
                location: location,
                policy: policy,
                limits: limits,
                budget: &budget
            )
        }

        let hasZIP64Locator = try ZipEndRecords.locator(source: source, end: end) != nil
        if hasZIP64Locator {
            do {
                let location = try locateZIP64Directory(
                    source: source,
                    diskLayout: diskLayout,
                    end: end,
                    limits: limits,
                    budget: &budget
                )
                return try parseDirectory(
                    source: source,
                    location: location,
                    policy: policy,
                    limits: limits,
                    budget: &budget
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let zip64Error = error
                // 4 byte の locator 署名は、ZIP32 の最後の中央 entry の comment の先頭にも正当に現れ得る。
                // ZIP32 と読む解釈は、その中央ディレクトリ全体が整合して解析できるときだけ採る。
                do {
                    let location = try locateZIP32Directory(
                        source: source,
                        diskLayout: diskLayout,
                        end: end,
                        limits: limits
                    )
                    return try parseDirectory(
                        source: source,
                        location: location,
                        policy: policy,
                        limits: limits,
                        budget: &budget
                    )
                } catch {
                    if !isRetryableEndRecordError(zip64Error) { throw zip64Error }
                    if !isRetryableEndRecordError(error) { throw error }
                    throw zip64Error
                }
            }
        }

        let location = try locateZIP32Directory(
            source: source,
            diskLayout: diskLayout,
            end: end,
            limits: limits
        )
        return try parseDirectory(
            source: source,
            location: location,
            policy: policy,
            limits: limits,
            budget: &budget
        )
    }

    private static func parseDirectory(
        source: any ByteSource,
        location: ZipDirectoryLocation,
        policy: EncodingPolicy,
        limits: ReadLimits,
        budget: inout ZipEndRecordParseBudget
    ) throws -> ZipParsedDirectory {
        try budget.chargeMetadataBytes(location.size)
        return try ZipCentralDirectoryParser.parse(
            source: source,
            location: location,
            policy: policy,
            limits: limits
        )
    }

    private static func locateZIP32Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
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

    private static func locateZIP64Directory(
        source: any ByteSource,
        diskLayout: ZipDiskLayout? = nil,
        end: EndRecord,
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

    private static func findZIP64RecordOffset(
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
