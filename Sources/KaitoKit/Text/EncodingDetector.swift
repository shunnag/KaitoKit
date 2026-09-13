import CoreFoundation
import Foundation

/// The result of resolving encoded name bytes.
public typealias EncodingDetection = (
    encoding: String.Encoding,
    string: String,
    confidence: Double
)

/// Detects and decodes archive entry names without sending valid UTF-8 to a guesser.
public enum EncodingDetector {
    // Archive-wide guessing is a heuristic. Bound both its representative
    // input and per-name scoring so unusually long central-directory names do
    // not make open time grow through repeated Foundation normalization.
    private static let maximumAutomaticDetectionSampleByteCount = 256 * 1_024
    private static let maximumAutomaticDetectionSampleNameCount = 512
    private static let maximumJapaneseScoringScalarCount = 256

    final class ArchiveEncodingDetectionMetrics {
        fileprivate(set) var ambiguousNameCount = 0
        fileprivate(set) var scoredAmbiguousNameCount = 0
        fileprivate(set) var foundationSampleCandidateCount = 0
        fileprivate(set) var foundationSampleNameCount = 0
        fileprivate(set) var foundationSampleByteCount = 0
        fileprivate(set) var plausibilityScalarCount = 0
        fileprivate(set) var halfWidthScalarCount = 0
    }

    private struct ArchiveNameFrequency {
        var bytes: [UInt8]
        var count: Int
        var stableHash: UInt64

        init(bytes: [UInt8], count: Int, stableHash: UInt64) {
            self.bytes = bytes
            self.count = count
            self.stableHash = stableHash
        }
    }

    /// Chooses one encoding for the undecorated names in an archive.
    ///
    /// Strict UTF-8 names do not participate in automatic detection, which
    /// returns `nil` when every supplied name is strict UTF-8. A fixed policy
    /// returns its encoding for every nonempty input so it applies consistently
    /// to every undecorated name. An empty input always returns `nil`.
    public static func detectArchiveEncoding(
        names: [[UInt8]],
        policy: EncodingPolicy = .automatic(),
        fromWindows: Bool = false
    ) -> String.Encoding? {
        detectArchiveEncodingImpl(
            names: names,
            policy: policy,
            fromWindows: fromWindows,
            maximumBatchByteCount: nil,
            metrics: nil
        )
    }

    // 名前全体が一つの形式 metadata 領域に収まらない reader 向けの
    // 内部用上限付き経路。
    static func detectArchiveEncoding(
        names: [[UInt8]],
        policy: EncodingPolicy,
        fromWindows: Bool = false,
        maximumBatchByteCount: Int
    ) -> String.Encoding? {
        detectArchiveEncodingImpl(
            names: names,
            policy: policy,
            fromWindows: fromWindows,
            maximumBatchByteCount: max(0, maximumBatchByteCount),
            metrics: nil
        )
    }

    // Internal diagnostics for deterministic complexity assertions in tests.
    static func detectArchiveEncodingWithMetrics(
        names: [[UInt8]],
        policy: EncodingPolicy = .automatic(),
        fromWindows: Bool = false
    ) -> (encoding: String.Encoding?, metrics: ArchiveEncodingDetectionMetrics) {
        let metrics = ArchiveEncodingDetectionMetrics()
        let encoding = detectArchiveEncodingImpl(
            names: names,
            policy: policy,
            fromWindows: fromWindows,
            maximumBatchByteCount: nil,
            metrics: metrics
        )
        return (encoding, metrics)
    }

    private static func detectArchiveEncodingImpl(
        names: [[UInt8]],
        policy: EncodingPolicy,
        fromWindows: Bool,
        maximumBatchByteCount: Int?,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> String.Encoding? {
        guard !names.isEmpty else { return nil }

        switch policy {
        case let .fixed(encoding):
            // 固定ポリシーは、従来どおり未宣言名すべてに適用する。
            return encoding
        case .utf8Only:
            return names.contains(where: { !isStrictUTF8($0) }) ? .utf8 : nil
        case let .automatic(likelyLanguage):
            let legacyNames = names.filter { !isStrictUTF8($0) }
            guard !legacyNames.isEmpty else { return nil }
            return automaticallyDetectArchiveEncoding(
                names: legacyNames,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows,
                maximumBatchByteCount: maximumBatchByteCount,
                metrics: metrics
            )
        }
    }

    /// Detects and decodes name bytes according to a policy.
    public static func detect(
        bytes: [UInt8],
        policy: EncodingPolicy = .automatic(),
        fromWindows: Bool = false
    ) -> EncodingDetection {
        switch policy {
        case let .fixed(encoding):
            if let string = decode(bytes: bytes, as: encoding) {
                return (encoding, string, 1.0)
            }
            return (encoding, replacementDecode(bytes, encoding: encoding), 0.0)

        case .utf8Only:
            if let string = decode(bytes: bytes, as: .utf8) {
                return (.utf8, string, 1.0)
            }
            return (.utf8, String(decoding: bytes, as: UTF8.self), 0.0)

        case let .automatic(likelyLanguage):
            return automaticallyDetect(
                bytes: bytes,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows
            )
        }
    }

    /// Strictly decodes bytes using a caller-selected encoding.
    public static func decode(bytes: [UInt8], as encoding: String.Encoding) -> String? {
        String(data: Data(bytes), encoding: encoding)
    }

    // StuffIt の Shift_JIS 名だけに用いる、旧 Mac 固有バイトの再試行。
    static func decodeMacJapanese(bytes: [UInt8]) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.macJapanese.rawValue)
        )
        // CoreFoundation は 0xFF を U+2026 + round-trip 用の私用タグ U+F87F にする。
        // ファイル名には表示文字の ellipsis だけを保持する。
        return decode(bytes: bytes, as: String.Encoding(rawValue: encoding))?
            .replacingOccurrences(of: "\u{2026}\u{F87F}", with: "\u{2026}")
    }

    // 各入力と同じ並びを保ちながら、書庫名をまとめて変換する。
    // 結合変換に失敗した範囲は分割し、変換できない単名だけを nil にする。
    static func decodeArchiveNames(
        _ names: [[UInt8]],
        as encoding: String.Encoding
    ) -> [String?] {
        decodeArchiveNamesImpl(
            names,
            as: encoding,
            maximumBatchByteCount: nil
        )
    }

    // 複数の metadata record から名前を集める形式向けの上限付き経路。
    static func decodeArchiveNames(
        _ names: [[UInt8]],
        as encoding: String.Encoding,
        maximumBatchByteCount: Int
    ) -> [String?] {
        decodeArchiveNamesImpl(
            names,
            as: encoding,
            maximumBatchByteCount: max(0, maximumBatchByteCount)
        )
    }

    private static func decodeArchiveNamesImpl(
        _ names: [[UInt8]],
        as encoding: String.Encoding,
        maximumBatchByteCount: Int?
    ) -> [String?] {
        guard !names.isEmpty else { return [] }
        let canCombine = encoding == .shiftJIS ||
            encoding == .japaneseEUC ||
            encoding == .utf8 ||
            encoding == .windowsCP1252 ||
            encoding == .isoLatin1
        guard canCombine, names.allSatisfy({ !$0.contains(0) }) else {
            return names.map { decode(bytes: $0, as: encoding) }
        }

        var results = [String?](repeating: nil, count: names.count)
        guard let maximumBatchByteCount else {
            decodeArchiveRange(
                names,
                range: names.indices,
                encoding: encoding,
                results: &results
            )
            return results
        }

        var batchStart = names.startIndex
        while let batch = nextArchiveNameBatch(
            names,
            from: batchStart,
            maximumByteCount: maximumBatchByteCount
        ) {
            if batch.combinedByteCount == nil || batch.range.count == 1 {
                let index = batch.range.lowerBound
                results[index] = decode(bytes: names[index], as: encoding)
            } else {
                decodeArchiveRange(
                    names,
                    range: batch.range,
                    encoding: encoding,
                    results: &results
                )
            }
            batchStart = batch.range.upperBound
        }
        return results
    }

    // 区切り付きの一バッファを共有できる次の範囲を返す。
    // byte 数が nil なら、上限を超える単名として処理する。
    static func nextArchiveNameBatch(
        _ names: [[UInt8]],
        from start: Int,
        maximumByteCount: Int
    ) -> (range: Range<Int>, combinedByteCount: Int?)? {
        guard names.indices.contains(start) else { return nil }
        let limit = max(0, maximumByteCount)
        let firstByteCount = names[start].count
        guard firstByteCount <= limit else {
            return (start..<(start + 1), nil)
        }

        var byteCount = firstByteCount
        var end = start + 1
        while end < names.endIndex {
            // 2 個目以降の名前は区切り 1 byte も必要。減算で判定し、
            // Int.max を上限とする場合も加算 overflow を避ける。
            let remaining = limit - byteCount
            guard remaining > 0,
                  names[end].count <= remaining - 1 else {
                break
            }
            byteCount += 1 + names[end].count
            end += 1
        }
        return (start..<end, byteCount)
    }

    private static func decodeArchiveRange(
        _ names: [[UInt8]],
        range: Range<Int>,
        encoding: String.Encoding,
        results: inout [String?]
    ) {
        guard !range.isEmpty else { return }
        let combined = concatenate(names, range: range, separator: 0)
        if let decoded = decode(bytes: combined, as: encoding) {
            let pieces = decoded.utf8.split(separator: 0, omittingEmptySubsequences: false)
            if pieces.count == range.count {
                for (index, piece) in zip(range, pieces) {
                    results[index] = String(decoding: piece, as: UTF8.self)
                }
                return
            }
        }

        if range.count == 1 {
            results[range.lowerBound] = decode(
                bytes: names[range.lowerBound],
                as: encoding
            )
            return
        }
        let middle = range.lowerBound + range.count / 2
        decodeArchiveRange(
            names,
            range: range.lowerBound..<middle,
            encoding: encoding,
            results: &results
        )
        decodeArchiveRange(
            names,
            range: middle..<range.upperBound,
            encoding: encoding,
            results: &results
        )
    }

    // 形式 reader が archive 単位で選んだ encoding を使い、失敗した名前だけ
    // 従来の単名 detector に戻すための共通経路。
    static func resolveUndeclaredName(
        bytes: [UInt8],
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        fromWindows: Bool = false
    ) -> EncodingDetection {
        if case .automatic = policy, isStrictUTF8(bytes) {
            return (.utf8, String(decoding: bytes, as: UTF8.self), 1.0)
        }
        if let archiveEncoding,
           let decoded = decode(bytes: bytes, as: archiveEncoding) {
            return (archiveEncoding, decoded, 0.9)
        }
        return detect(bytes: bytes, policy: policy, fromWindows: fromWindows)
    }

    // String の生成なしで RFC 3629 の最短形・scalar 範囲まで検証する。
    static func isStrictUTF8(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            if first <= 0x7F {
                index += 1
                continue
            }

            switch first {
            case 0xC2...0xDF:
                guard index + 1 < bytes.count,
                      isUTF8Continuation(bytes[index + 1]) else { return false }
                index += 2
            case 0xE0:
                guard index + 2 < bytes.count,
                      (0xA0...0xBF).contains(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]) else { return false }
                index += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard index + 2 < bytes.count,
                      isUTF8Continuation(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]) else { return false }
                index += 3
            case 0xED:
                guard index + 2 < bytes.count,
                      (0x80...0x9F).contains(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]) else { return false }
                index += 3
            case 0xF0:
                guard index + 3 < bytes.count,
                      (0x90...0xBF).contains(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]),
                      isUTF8Continuation(bytes[index + 3]) else { return false }
                index += 4
            case 0xF1...0xF3:
                guard index + 3 < bytes.count,
                      isUTF8Continuation(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]),
                      isUTF8Continuation(bytes[index + 3]) else { return false }
                index += 4
            case 0xF4:
                guard index + 3 < bytes.count,
                      (0x80...0x8F).contains(bytes[index + 1]),
                      isUTF8Continuation(bytes[index + 2]),
                      isUTF8Continuation(bytes[index + 3]) else { return false }
                index += 4
            default:
                return false
            }
        }
        return true
    }

    private static func automaticallyDetectArchiveEncoding(
        names: [[UInt8]],
        likelyLanguage: String?,
        fromWindows: Bool,
        maximumBatchByteCount: Int?,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> String.Encoding {
        var ambiguousJapaneseNames: [[UInt8]] = []
        var cp932Only = 0
        var eucJPOnly = 0

        for bytes in names {
            let isCP932 = isStructurallyCP932(bytes)
            let isEUCJP = isStructurallyEUCJP(bytes)
            if isCP932, !isEUCJP {
                cp932Only += 1
            } else if isEUCJP, !isCP932 {
                eucJPOnly += 1
            } else if isCP932, isEUCJP {
                ambiguousJapaneseNames.append(bytes)
            }
        }
        metrics?.ambiguousNameCount = ambiguousJapaneseNames.count

        let hasCP932Support = cp932Only > 0 || !ambiguousJapaneseNames.isEmpty
        let hasEUCJPSupport = eucJPOnly > 0 || !ambiguousJapaneseNames.isEmpty
        if hasCP932Support, !hasEUCJPSupport { return .shiftJIS }
        if hasEUCJPSupport, !hasCP932Support { return .japaneseEUC }
        if cp932Only > eucJPOnly + ambiguousJapaneseNames.count { return .shiftJIS }
        if eucJPOnly > cp932Only + ambiguousJapaneseNames.count { return .japaneseEUC }

        // 両構造を通る名前が勝敗を変え得る場合だけ、archive の代表列を
        // Foundation に一度渡し、その hint を各名前の一票へ反映する。
        var foundation: EncodingDetection?
        var calledFoundation = false
        if !ambiguousJapaneseNames.isEmpty {
            let withoutEUCShift = ambiguousJapaneseNames.filter {
                !containsEUCShiftPrefix($0)
            }
            let representativeNames = withoutEUCShift.count >
                ambiguousJapaneseNames.count - withoutEUCShift.count
                ? withoutEUCShift
                : names
            let sample = concatenate(
                representativeNames,
                separator: 0x0A,
                maximumByteCount: maximumBatchByteCount,
                metrics: metrics
            )
            foundation = foundationDetection(
                bytes: sample,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows
            )
            calledFoundation = true
        }

        let ambiguousNameFrequencies = archiveNameFrequencies(ambiguousJapaneseNames)
        let uniqueAmbiguousNames = ambiguousNameFrequencies.map(\.bytes)
        var cp932Votes = cp932Only
        var eucJPVotes = eucJPOnly
        var unresolvedVotes = ambiguousJapaneseNames.count
        let cp932Decoded = decodeArchiveNamesImpl(
            uniqueAmbiguousNames,
            as: .shiftJIS,
            maximumBatchByteCount: maximumBatchByteCount
        )
        let eucJPDecoded = decodeArchiveNamesImpl(
            uniqueAmbiguousNames,
            as: .japaneseEUC,
            maximumBatchByteCount: maximumBatchByteCount
        )
        // Every structurally ambiguous name contributes a vote. Per-name
        // scoring is prefix-bounded, while the single archive-wide Foundation
        // hint comes from an order-independent, frequency-weighted sample.
        for index in uniqueAmbiguousNames.indices {
            guard let cp932 = cp932Decoded[index],
                  let eucJP = eucJPDecoded[index] else { continue }
            metrics?.scoredAmbiguousNameCount += 1
            let choice = chooseAmbiguousJapanese(
                cp932: cp932,
                eucJP: eucJP,
                bytes: uniqueAmbiguousNames[index],
                foundation: foundation,
                metrics: metrics
            )
            let occurrenceCount = ambiguousNameFrequencies[index].count
            if choice.encoding == .japaneseEUC {
                eucJPVotes += occurrenceCount
            } else {
                cp932Votes += occurrenceCount
            }
            unresolvedVotes -= occurrenceCount
        }

        if unresolvedVotes == 0, cp932Votes != eucJPVotes {
            return cp932Votes > eucJPVotes ? .shiftJIS : .japaneseEUC
        }
        if cp932Votes > eucJPVotes + unresolvedVotes { return .shiftJIS }
        if eucJPVotes > cp932Votes + unresolvedVotes { return .japaneseEUC }

        // 構造候補がない archive、または未解決票が残った archive だけがここへ来る。
        if !calledFoundation {
            let sample = concatenate(
                names,
                separator: 0x0A,
                maximumByteCount: maximumBatchByteCount,
                metrics: metrics
            )
            foundation = foundationDetection(
                bytes: sample,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows
            )
        }
        if !hasCP932Support, !hasEUCJPSupport {
            return foundation?.encoding ?? .isoLatin1
        }
        if foundation?.encoding == .shiftJIS {
            cp932Votes += unresolvedVotes
            unresolvedVotes = 0
        } else if foundation?.encoding == .japaneseEUC {
            eucJPVotes += unresolvedVotes
            unresolvedVotes = 0
        }

        if cp932Votes != eucJPVotes {
            return cp932Votes > eucJPVotes ? .shiftJIS : .japaneseEUC
        }
        if foundation?.encoding == .japaneseEUC { return .japaneseEUC }
        if foundation?.encoding == .shiftJIS { return .shiftJIS }
        if hasCP932Support || hasEUCJPSupport {
            // 日本語候補の同点時は単名 detector と同じく CP932 を優先する。
            return .shiftJIS
        }
        return .isoLatin1
    }

    private static func concatenate(
        _ names: [[UInt8]],
        separator: UInt8,
        maximumByteCount: Int?,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> [UInt8] {
        orderStableArchiveNameSample(
            names,
            separator: separator,
            maximumByteCount: maximumByteCount
                ?? maximumAutomaticDetectionSampleByteCount,
            metrics: metrics
        )
    }

    // Builds a bounded, order-independent sample for the one Foundation call.
    // Exact occurrence weights keep repeated majority evidence represented;
    // stable hashes provide a cheap canonical order for distinct names.
    private static func orderStableArchiveNameSample(
        _ names: [[UInt8]],
        separator: UInt8,
        maximumByteCount: Int,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> [UInt8] {
        let byteLimit = max(0, maximumByteCount)
        guard byteLimit > 0, !names.isEmpty else { return [] }

        let frequencies = archiveNameFrequencies(names)
        let sampleCount = min(names.count, maximumAutomaticDetectionSampleNameCount)
        metrics?.foundationSampleCandidateCount += sampleCount

        var result: [UInt8] = []
        result.reserveCapacity(byteLimit)
        var frequencyIndex = 0
        var cumulativeCount = frequencies[0].count
        var appendedCount = 0
        for sampleIndex in 0..<sampleCount {
            let lower = scaledPosition(sampleIndex, total: names.count, parts: sampleCount)
            let upper = scaledPosition(sampleIndex + 1, total: names.count, parts: sampleCount)
            let position = lower + (upper - lower) / 2
            while position >= cumulativeCount, frequencyIndex + 1 < frequencies.count {
                frequencyIndex += 1
                cumulativeCount += frequencies[frequencyIndex].count
            }

            let name = frequencies[frequencyIndex].bytes
            let separatorCount = appendedCount == 0 ? 0 : 1
            guard separatorCount <= byteLimit - result.count,
                  name.count <= byteLimit - result.count - separatorCount else {
                continue
            }
            if separatorCount == 1 { result.append(separator) }
            result.append(contentsOf: name)
            appendedCount += 1
        }
        metrics?.foundationSampleNameCount += appendedCount
        metrics?.foundationSampleByteCount += result.count
        return result
    }

    private static func archiveNameFrequencies(
        _ names: [[UInt8]]
    ) -> [ArchiveNameFrequency] {
        var counts: [[UInt8]: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        return counts.map { bytes, count in
            ArchiveNameFrequency(
                bytes: bytes,
                count: count,
                stableHash: stableArchiveNameHash(bytes)
            )
        }.sorted {
            if $0.stableHash != $1.stableHash {
                return $0.stableHash > $1.stableHash
            }
            return $1.bytes.lexicographicallyPrecedes($0.bytes)
        }
    }

    private static func scaledPosition(_ value: Int, total: Int, parts: Int) -> Int {
        let quotient = total / parts
        let remainder = total % parts
        return quotient * value + (remainder * value) / parts
    }

    private static func stableArchiveNameHash(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        hash ^= UInt64(bytes.count)
        hash &*= 0x0000_0100_0000_01B3
        return hash
    }

    // 呼出側の byte 上限内で代表入力を作る。構造投票はすべての名前を
    // 検査済みで、この sample は書庫で一度だけの Foundation hint に使う。
    static func boundedArchiveNameSample(
        _ names: [[UInt8]],
        separator: UInt8,
        maximumByteCount: Int
    ) -> [UInt8] {
        let limit = max(0, maximumByteCount)
        guard limit > 0 else { return [] }

        var byteCount = 0
        var includedNameCount = 0
        for name in names {
            let separatorCount = includedNameCount == 0 ? 0 : 1
            let remaining = limit - byteCount
            guard separatorCount <= remaining,
                  name.count <= remaining - separatorCount else {
                continue
            }
            byteCount += separatorCount + name.count
            includedNameCount += 1
        }

        var combined: [UInt8] = []
        combined.reserveCapacity(byteCount)
        var remainingByteCount = byteCount
        var appendedNameCount = 0
        for name in names where remainingByteCount > 0 {
            let separatorCount = appendedNameCount == 0 ? 0 : 1
            guard separatorCount <= remainingByteCount,
                  name.count <= remainingByteCount - separatorCount else {
                continue
            }
            if separatorCount == 1 { combined.append(separator) }
            combined.append(contentsOf: name)
            remainingByteCount -= separatorCount + name.count
            appendedNameCount += 1
        }
        return combined
    }

    private static func concatenate(
        _ names: [[UInt8]],
        range: Range<Int>,
        separator: UInt8
    ) -> [UInt8] {
        var combined: [UInt8] = []
        var capacity = max(0, range.count - 1)
        for index in range {
            let next = capacity.addingReportingOverflow(names[index].count)
            guard !next.overflow else {
                capacity = 0
                break
            }
            capacity = next.partialValue
        }
        if capacity > 0 { combined.reserveCapacity(capacity) }
        for index in range {
            if index > range.lowerBound { combined.append(separator) }
            combined.append(contentsOf: names[index])
        }
        return combined
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }

    private static func automaticallyDetect(
        bytes: [UInt8],
        likelyLanguage: String?,
        fromWindows: Bool
    ) -> EncodingDetection {
        // 空列と ASCII は曖昧さがなく、推測器へ渡さない。
        if bytes.isEmpty || bytes.allSatisfy({ $0 < 0x80 }) {
            return (.utf8, String(decoding: bytes, as: UTF8.self), 1.0)
        }

        // 厳密 UTF-8 を最優先し、短い日本語名の誤判定を防ぐ。
        if let string = decode(bytes: bytes, as: .utf8) {
            return (.utf8, string, 1.0)
        }

        // Foundation の結果は先に取得し、構造検査が両方通る曖昧列では品質評価のヒントにも使う。
        let foundation = foundationDetection(
            bytes: bytes,
            likelyLanguage: likelyLanguage,
            fromWindows: fromWindows
        )
        let cp932 = cp932Candidate(bytes)
        let eucJP = eucJPCandidate(bytes)
        if let cp932, let eucJP {
            return chooseAmbiguousJapanese(
                cp932: cp932,
                eucJP: eucJP,
                bytes: bytes,
                foundation: foundation
            )
        }
        if let cp932 {
            if foundation?.encoding == .shiftJIS {
                return (.shiftJIS, cp932, 0.9)
            }
            return (.shiftJIS, cp932, 0.78)
        }
        if let eucJP {
            if foundation?.encoding == .japaneseEUC {
                return (.japaneseEUC, eucJP, 0.9)
            }
            return (.japaneseEUC, eucJP, 0.75)
        }
        if let foundation {
            return foundation
        }

        // ISO Latin-1 は全バイトを保持できる最後のフォールバック。
        let latin1 = decode(bytes: bytes, as: .isoLatin1)
            ?? String(bytes.map { UnicodeScalar($0) }.map(Character.init))
        return (.isoLatin1, latin1, 0.2)
    }

    private static func foundationDetection(
        bytes: [UInt8],
        likelyLanguage: String?,
        fromWindows: Bool
    ) -> EncodingDetection? {
        let candidates: [UInt] = [
            String.Encoding.shiftJIS.rawValue,
            String.Encoding.japaneseEUC.rawValue,
            String.Encoding.utf8.rawValue,
            String.Encoding.iso2022JP.rawValue,
            String.Encoding.windowsCP1252.rawValue,
        ]
        var options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: candidates,
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ]
        if let likelyLanguage {
            options[.likelyLanguageKey] = likelyLanguage
        }
        if fromWindows {
            options[.fromWindowsKey] = true
        }

        var converted: NSString?
        var usedLossyConversion = ObjCBool(false)
        // 二つの出力変数は呼び出し完了まで生存し、Foundation はその間だけ参照する。
        let rawEncoding = NSString.stringEncoding(
            for: Data(bytes),
            encodingOptions: options,
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )
        guard rawEncoding != 0,
              !usedLossyConversion.boolValue,
              let converted
        else {
            return nil
        }

        let encoding = String.Encoding(rawValue: rawEncoding)
        guard candidates.contains(encoding.rawValue) else {
            return nil
        }
        return (encoding, converted as String, 0.9)
    }

    private static func cp932Candidate(_ bytes: [UInt8]) -> String? {
        guard isStructurallyCP932(bytes) else { return nil }
        return decode(bytes: bytes, as: .shiftJIS)
    }

    private static func isStructurallyCP932(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 0x7F || (0xA1...0xDF).contains(byte) {
                index += 1
                continue
            }

            let isLead = (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte)
            guard isLead, index + 1 < bytes.count else {
                return false
            }
            let trail = bytes[index + 1]
            let isTrail = (0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail)
            guard isTrail, trail != 0x7F else {
                return false
            }
            index += 2
        }
        return true
    }

    private static func eucJPCandidate(_ bytes: [UInt8]) -> String? {
        guard isStructurallyEUCJP(bytes) else { return nil }
        return decode(bytes: bytes, as: .japaneseEUC)
    }

    private static func isStructurallyEUCJP(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 0x7F {
                index += 1
                continue
            }
            if byte == 0x8E {
                guard index + 1 < bytes.count, (0xA1...0xDF).contains(bytes[index + 1]) else {
                    return false
                }
                index += 2
                continue
            }
            if byte == 0x8F {
                guard index + 2 < bytes.count,
                      (0xA1...0xFE).contains(bytes[index + 1]),
                      (0xA1...0xFE).contains(bytes[index + 2])
                else {
                    return false
                }
                index += 3
                continue
            }
            guard (0xA1...0xFE).contains(byte),
                  index + 1 < bytes.count,
                  (0xA1...0xFE).contains(bytes[index + 1])
            else {
                return false
            }
            index += 2
        }
        return true
    }

    private static func chooseAmbiguousJapanese(
        cp932: String,
        eucJP: String,
        bytes: [UInt8],
        foundation: EncodingDetection?,
        metrics: ArchiveEncodingDetectionMetrics? = nil
    ) -> EncodingDetection {
        // 0x8E は「車」「社」等の CP932 の先頭にもなるため、単独では EUC と断定しない。
        let eucHasOneCharacter = !eucJP.isEmpty
            && eucJP.index(after: eucJP.startIndex) == eucJP.endIndex
        let likelyHalfWidthName = isLikelyHalfWidthName(cp932, metrics: metrics)
        if eucHasOneCharacter, likelyHalfWidthName {
            return (.shiftJIS, cp932, 0.8)
        }

        var cpScore = japanesePlausibility(cp932, metrics: metrics)
        var eucScore = japanesePlausibility(eucJP, metrics: metrics)
        if foundation?.encoding == .shiftJIS {
            cpScore += 0.15
        } else if foundation?.encoding == .japaneseEUC {
            eucScore += 0.15
        }
        if likelyHalfWidthName {
            cpScore += 0.9
        }
        if containsEUCShiftPrefix(bytes),
           isLikelyHalfWidthName(eucJP, metrics: metrics)
            || isPredominantlyEUCHalfWidthName(eucJP, metrics: metrics) {
            eucScore += 0.9
        }

        if eucScore > cpScore {
            return (.japaneseEUC, eucJP, 0.72)
        }
        // 同点時は仕様上先に検査する CP932 を選ぶ。
        return (.shiftJIS, cp932, 0.72)
    }

    private static func containsEUCShiftPrefix(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x8E || bytes[index] == 0x8F {
                return true
            }
            index += 1
        }
        return false
    }

    private static func isPredominantlyEUCHalfWidthName(
        _ string: String,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> Bool {
        // This candidate has already passed strict EUC-JP validation: each
        // half-width scalar represents an 8E A1...DF pair. Several such pairs
        // dominating the non-ASCII name are evidence even without a known word.
        // A single 8E-led CP932 kanji (車 / 社 / 者) is not enough.
        var kana = 0
        var nonASCII = 0
        var inspected = 0
        for scalar in string.unicodeScalars.prefix(maximumJapaneseScoringScalarCount) {
            inspected += 1
            if scalar.value > 0x7F { nonASCII += 1 }
            if (0xFF61...0xFF9F).contains(scalar.value) { kana += 1 }
        }
        metrics?.halfWidthScalarCount += inspected
        return kana >= 4 && kana * 2 > nonASCII
    }

    private static func japanesePlausibility(
        _ string: String,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> Double {
        var score = 0.0
        var count = 0.0
        for scalar in string.unicodeScalars.prefix(maximumJapaneseScoringScalarCount) {
            count += 1.0
            switch scalar.value {
            case 0x3040...0x30FF: // ひらがな・カタカナ
                score += 2.0
            case 0x3400...0x9FFF, 0xF900...0xFAFF: // CJK 統合漢字・互換漢字
                score += 2.0
            case 0xFF61...0xFF9F: // 半角カナ
                score += 1.25
            case 0x20...0x7E: // 一般的なファイル名 ASCII
                score += 0.25
            case 0x00...0x1F, 0x7F...0x9F:
                score -= 4.0
            default:
                score -= 0.25
            }
        }
        metrics?.plausibilityScalarCount += Int(count)
        return count > 0 ? score / count : 0
    }

    private static func isLikelyHalfWidthName(
        _ string: String,
        metrics: ArchiveEncodingDetectionMetrics?
    ) -> Bool {
        var sawKana = false
        var sampledScalars: [Unicode.Scalar] = []
        sampledScalars.reserveCapacity(maximumJapaneseScoringScalarCount)
        var inspectedScalarCount = 0
        defer { metrics?.halfWidthScalarCount += inspectedScalarCount }
        for scalar in string.unicodeScalars.prefix(maximumJapaneseScoringScalarCount) {
            inspectedScalarCount += 1
            if (0xFF61...0xFF9F).contains(scalar.value) {
                sawKana = true
            } else if !(0x20...0x7E).contains(scalar.value) {
                return false
            }
            sampledScalars.append(scalar)
        }
        guard sawKana else {
            return false
        }

        let sampled = String(sampledScalars.map(Character.init))
        let commonTerms = [
            "ｶﾅ", "ｶﾀｶﾅ", "ﾃｽﾄ", "ﾍﾟｰｼﾞ", "ﾌｧｲﾙ", "ｺﾐｯｸ",
            "ﾏﾝｶﾞ", "ﾀｲﾄﾙ", "ｻﾝﾌﾟﾙ", "ｲﾗｽﾄ",
        ]
        return commonTerms.contains { sampled.contains($0) }
    }

    private static func replacementDecode(
        _ bytes: [UInt8],
        encoding: String.Encoding
    ) -> String {
        if encoding == .utf8 {
            return String(decoding: bytes, as: UTF8.self)
        }
        // 固定エンコーディングが不正な場合も、生バイトは RawName 側に保持される。
        return decode(bytes: bytes, as: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }
}
