import Foundation

// APPNOTE 6.3.9 §4.3 / §8: 最終巻だけで読める EOCD と locator を共有する。
// ZIP64 本体は前の巻に置けるため、兄弟探索では読まない。
enum ZipEndRecords {
    static let endMinimumSize = 22
    static let maximumCommentSize = 65_535
    static let maximumTrailingDataSize = 1 * 1_024 * 1_024

    struct EndRecord {
        let offset: UInt64
        let recordEnd: UInt64
        let diskNumber: UInt16
        let centralDirectoryDisk: UInt16
        let entriesOnDisk: UInt16
        let totalEntries: UInt16
        let centralDirectorySize: UInt32
        let centralDirectoryOffset: UInt32
    }

    struct Locator {
        let recordDisk: UInt32
        let relativeRecordOffset: UInt64
        let diskCount: UInt32
    }

    static func locator(source: any ByteSource, end: EndRecord) throws -> Locator? {
        let size = ZipRecordSize.zip64Locator
        guard end.offset >= UInt64(size) else { return nil }
        let bytes = try readByteRange(source: source, offset: Checked.sub(end.offset, UInt64(size)), count: size)
        guard LittleEndian.uint32(bytes, at: 0) == ZipSignature.zip64Locator else { return nil }
        return Locator(recordDisk: LittleEndian.uint32(bytes, at: 4),
                       relativeRecordOffset: LittleEndian.uint64(bytes, at: 8),
                       diskCount: LittleEndian.uint32(bytes, at: 16))
    }

    private struct DiscoveryState {
        var budget: ZipEndRecordParseBudget
        var attemptedOffsets: Set<UInt64> = []
        var fallback: UInt64?
        var candidateError: Error?
    }

    static func lastDiskIndex(source: any ByteSource, limits: ReadLimits) throws -> UInt64? {
        guard source.length >= UInt64(endMinimumSize) else { return nil }
        let standardSearchSize = endMinimumSize + maximumCommentSize
        var state = DiscoveryState(budget: ZipEndRecordParseBudget(limits: limits))
        let initial = try findEndRecords(source: source, maximumSearchSize: standardSearchSize)
        if let last = try selectLastDiskIndex(initial, source: source, state: &state) {
            return last
        }
        // 通常の URL open で大きな末尾読取を増やさず、有効候補がないときだけ探索を広げる。
        if source.length > UInt64(standardSearchSize) {
            let expanded = try findEndRecords(source: source, maximumSearchSize:
                standardSearchSize + maximumTrailingDataSize)
            if let last = try selectLastDiskIndex(expanded, source: source, state: &state) {
                return last
            }
        }
        if let fallback = state.fallback { return fallback }
        if let error = state.candidateError { throw error }
        return nil
    }

    private static func selectLastDiskIndex(
        _ candidates: [EndRecord], source: any ByteSource, state: inout DiscoveryState
    ) throws -> UInt64? {
        // 候補を昇順に走査して包含を記録し、多数の署名でも二重ループにしない。
        let ascending = Array(candidates.reversed())
        var enclosedOffsets: Set<UInt64> = []
        var eligible = 0
        var enclosingEnd: UInt64 = 0
        for candidate in ascending {
            while eligible < ascending.count,
                  try Checked.add(ascending[eligible].offset, UInt64(endMinimumSize)) <= candidate.offset {
                enclosingEnd = max(enclosingEnd, ascending[eligible].recordEnd)
                eligible += 1
            }
            if candidate.recordEnd <= enclosingEnd { enclosedOffsets.insert(candidate.offset) }
        }
        for candidate in candidates {
            // 二つの窓で同じ候補を重複計上せず、予算自体は探索全体で共有する。
            guard state.attemptedOffsets.insert(candidate.offset).inserted else { continue }
            try state.budget.chargeAttempt()
            if enclosedOffsets.contains(candidate.offset) { continue }
            do {
                let last = try declaredLastDisk(source: source, end: candidate, budget: &state.budget)
                state.fallback = state.fallback ?? last
                // 中央ディレクトリを最終巻で確認できる場合だけ、偽の末尾候補を除く。
                // 前の巻にある索引の正当性は全巻を連結した後で検証する。
                if candidate.centralDirectorySize != UInt32.max,
                   candidate.centralDirectoryOffset != UInt32.max {
                    let directoryEnd = try Checked.add(
                        UInt64(candidate.centralDirectoryOffset), UInt64(candidate.centralDirectorySize))
                    // 標準窓に偽候補が一つだけ見える場合も、通常の ZIP32 位置と異なれば検証する。
                    // 通常の単巻は追加読取なしで進み、ZIP64 locator がある候補は従来どおり扱う。
                    let needsCoherenceCheck = try candidates.count > 1
                        || (directoryEnd != candidate.offset && locator(source: source, end: candidate) == nil)
                    if last == 0, candidate.totalEntries > 0, needsCoherenceCheck,
                       try !ZipCentralDirectoryLocator.hasCoherentZIP32End(source: source, end: candidate, budget: &state.budget) {
                        continue
                    }
                    if needsCoherenceCheck, last > 0, UInt64(candidate.centralDirectoryDisk) == last,
                       try locator(source: source, end: candidate) == nil {
                        if directoryEnd != candidate.offset { continue }
                    }
                }
                return last
            } catch let error as KaitoError {
                if case .limitExceeded = error { throw error }
                state.candidateError = state.candidateError ?? error
            }
        }
        return nil
    }

    private static func declaredLastDisk(source: any ByteSource, end: EndRecord,
                                         budget: inout ZipEndRecordParseBudget) throws -> UInt64 {
        let hasSentinel = end.diskNumber == UInt16.max || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max || end.centralDirectoryOffset == UInt32.max
        // 通常の CD が EOCD まで届くなら、そのコメント内の locator 署名を採用しない。
        let isZIP32Directory = try !hasSentinel && (Checked.add(
            UInt64(end.centralDirectoryOffset), UInt64(end.centralDirectorySize))) == end.offset
        if !isZIP32Directory, let locator = try locator(source: source, end: end) {
            // SFX 単巻では相対位置だけでは判断できないため、既存の索引候補検査を共有する。
            if !hasSentinel, end.diskNumber == 0,
               try ZipCentralDirectoryLocator.hasCoherentZIP32End(source: source, end: end, budget: &budget) {
                return 0
            }
            guard locator.diskCount > 0 else {
                throw KaitoError.malformed("ZIP64 disk count is zero")
            }
            let last = try Checked.sub(UInt64(locator.diskCount), 1)
            guard end.diskNumber == UInt16.max || UInt64(end.diskNumber) == last else {
                throw KaitoError.malformed("ZIP32 and ZIP64 disk counts disagree")
            }
            guard UInt64(locator.recordDisk) <= last else {
                throw KaitoError.malformed("ZIP64 record disk is outside the volume set")
            }
            return last
        }
        guard end.diskNumber != UInt16.max else {
            throw KaitoError.malformed("ZIP64 locator is missing")
        }
        return UInt64(end.diskNumber)
    }

    static func findEndRecords(
        source: any ByteSource,
        maximumSearchSize: Int
    ) throws -> [EndRecord] {
        guard source.length >= UInt64(endMinimumSize) else {
            throw KaitoError.truncated
        }
        let count = try Checked.toInt(
            min(source.length, UInt64(max(endMinimumSize, maximumSearchSize)))
        )
        let tailOffset = try Checked.sub(source.length, UInt64(count))
        let tail = try readByteRange(source: source, offset: tailOffset, count: count)

        var candidates: [EndRecord] = []
        for index in stride(from: tail.count - endMinimumSize, through: 0, by: -1) {
            guard LittleEndian.uint32(tail, at: index) == ZipSignature.endOfCentralDirectory else { continue }
            let commentLength = Int(LittleEndian.uint16(tail, at: index + 20))
            let recordEnd = index + endMinimumSize + commentLength
            guard recordEnd <= tail.count,
                  tail.count - recordEnd <= maximumTrailingDataSize else { continue }
            let record = EndRecord(
                offset: try Checked.add(tailOffset, UInt64(index)),
                recordEnd: try Checked.add(tailOffset, UInt64(recordEnd)),
                diskNumber: LittleEndian.uint16(tail, at: index + 4),
                centralDirectoryDisk: LittleEndian.uint16(tail, at: index + 6),
                entriesOnDisk: LittleEndian.uint16(tail, at: index + 8),
                totalEntries: LittleEndian.uint16(tail, at: index + 10),
                centralDirectorySize: LittleEndian.uint32(tail, at: index + 12),
                centralDirectoryOffset: LittleEndian.uint32(tail, at: index + 16)
            )
            candidates.append(record)
        }
        return candidates
    }
}
