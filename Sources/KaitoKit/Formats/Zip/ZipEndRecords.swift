import Foundation

// APPNOTE 6.3.9 §4.3 / §8: 最終巻だけで読める EOCD と locator を共有する。
// ZIP64 本体は前の巻に置けるため、兄弟探索では読まない。
enum ZipEndRecords {
    static let endMinimumSize = 22
    static let maximumCommentSize = 65_535
    static let maximumTrailingDataSize = 1 * 1_024 * 1_024
    private static let endSignature: UInt32 = 0x0605_4b50

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
        guard end.offset >= 20 else { return nil }
        let bytes = try readExactly(source: source, offset: Checked.sub(end.offset, 20), count: 20)
        guard littleUInt32(bytes, at: 0) == 0x0706_4b50 else { return nil }
        return Locator(recordDisk: littleUInt32(bytes, at: 4),
                       relativeRecordOffset: littleUInt64(bytes, at: 8),
                       diskCount: littleUInt32(bytes, at: 16))
    }

    static func lastDiskIndex(source: any ByteSource, limits: ReadLimits) throws -> UInt64? {
        guard source.length >= UInt64(endMinimumSize) else { return nil }
        let candidates = try findEndRecords(source: source, maximumSearchSize:
            endMinimumSize + maximumCommentSize + maximumTrailingDataSize)
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
        var budget = ZipReader.EndRecordParseBudget(limits: limits)
        var fallback: UInt64?
        var candidateError: Error?
        var examined = 0
        for candidate in candidates {
            examined += 1
            guard examined <= 8_192 else {
                throw KaitoError.limitExceeded("ZIP end-record candidate attempts")
            }
            if enclosedOffsets.contains(candidate.offset) { continue }
            do {
                let last = try declaredLastDisk(source: source, end: candidate, budget: &budget)
                fallback = fallback ?? last
                // 中央ディレクトリを最終巻で確認できる場合だけ、偽の末尾候補を除く。
                // 前の巻にある索引の正当性は全巻を連結した後で検証する。
                if candidates.count > 1, candidate.centralDirectorySize != UInt32.max,
                   candidate.centralDirectoryOffset != UInt32.max {
                    if last == 0, candidate.totalEntries > 0,
                       try !ZipReader.hasCoherentZIP32End(source: source, end: candidate, budget: &budget) {
                        continue
                    }
                    if last > 0, UInt64(candidate.centralDirectoryDisk) == last,
                       try locator(source: source, end: candidate) == nil {
                        let directoryEnd = try Checked.add(UInt64(candidate.centralDirectoryOffset), UInt64(candidate.centralDirectorySize))
                        if directoryEnd != candidate.offset { continue }
                    }
                }
                return last
            } catch let error as KaitoError {
                if case .limitExceeded = error { throw error }
                candidateError = candidateError ?? error
            }
        }
        if let fallback { return fallback }
        if let candidateError { throw candidateError }
        return nil
    }

    private static func declaredLastDisk(source: any ByteSource, end: EndRecord,
                                         budget: inout ZipReader.EndRecordParseBudget) throws -> UInt64 {
        let hasSentinel = end.diskNumber == UInt16.max || end.centralDirectoryDisk == UInt16.max
            || end.entriesOnDisk == UInt16.max || end.totalEntries == UInt16.max
            || end.centralDirectorySize == UInt32.max || end.centralDirectoryOffset == UInt32.max
        // 通常の CD が EOCD まで届くなら、そのコメント内の locator 署名を採用しない。
        let isZIP32Directory = try !hasSentinel && (Checked.add(
            UInt64(end.centralDirectoryOffset), UInt64(end.centralDirectorySize))) == end.offset
        if !isZIP32Directory, let locator = try locator(source: source, end: end) {
            // SFX 単巻では相対位置だけでは判断できないため、既存の索引候補検査を共有する。
            if !hasSentinel, end.diskNumber == 0,
               try ZipReader.hasCoherentZIP32End(source: source, end: end, budget: &budget) {
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
        let tail = try readExactly(source: source, offset: tailOffset, count: count)

        var candidates: [EndRecord] = []
        for index in stride(from: tail.count - endMinimumSize, through: 0, by: -1) {
            guard littleUInt32(tail, at: index) == endSignature else { continue }
            let commentLength = Int(littleUInt16(tail, at: index + 20))
            let recordEnd = index + endMinimumSize + commentLength
            guard recordEnd <= tail.count,
                  tail.count - recordEnd <= maximumTrailingDataSize else { continue }
            let record = EndRecord(
                offset: try Checked.add(tailOffset, UInt64(index)),
                recordEnd: try Checked.add(tailOffset, UInt64(recordEnd)),
                diskNumber: littleUInt16(tail, at: index + 4),
                centralDirectoryDisk: littleUInt16(tail, at: index + 6),
                entriesOnDisk: littleUInt16(tail, at: index + 8),
                totalEntries: littleUInt16(tail, at: index + 10),
                centralDirectorySize: littleUInt32(tail, at: index + 12),
                centralDirectoryOffset: littleUInt32(tail, at: index + 16)
            )
            candidates.append(record)
        }
        return candidates
    }

    private static func readExactly(
        source: any ByteSource,
        offset: UInt64,
        count: Int
    ) throws -> [UInt8] {
        guard count >= 0 else {
            throw KaitoError.malformed("negative ZIP read size")
        }
        let end = try Checked.add(offset, UInt64(count))
        guard end <= source.length else { throw KaitoError.truncated }
        guard count > 0 else { return [] }
        return try readByteRange(source: source, offset: offset, count: count)
    }

    private static func littleUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func littleUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    private static func littleUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        UInt64(littleUInt32(bytes, at: index))
            | UInt64(littleUInt32(bytes, at: index + 4)) << 32
    }
}
