// EOCD 候補の選択と ZIP64 / ZIP32 の切替を担い、ZipCentralDirectoryParser へ渡す。
// 位置は ZipDirectoryLocationResolver、再試行の判定は ZipEndRecordRecovery に委ねる。

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
                            guard try ZipEndRecordRecovery.shouldRetryEndRecordCandidateError(
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
                guard try ZipEndRecordRecovery.shouldRetryEndRecordCandidateError(
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
            let location = try ZipDirectoryLocationResolver.locateZIP64Directory(
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
                let location = try ZipDirectoryLocationResolver.locateZIP64Directory(
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
                    let location = try ZipDirectoryLocationResolver.locateZIP32Directory(
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
                    if !ZipEndRecordRecovery.isRetryableEndRecordError(zip64Error) { throw zip64Error }
                    if !ZipEndRecordRecovery.isRetryableEndRecordError(error) { throw error }
                    throw zip64Error
                }
            }
        }

        let location = try ZipDirectoryLocationResolver.locateZIP32Directory(
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

}
