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

    final class ArchiveEncodingDetectionMetrics {
        fileprivate(set) var ambiguousNameCount = 0
        fileprivate(set) var scoredAmbiguousNameCount = 0
        fileprivate(set) var foundationSampleCandidateCount = 0
        fileprivate(set) var foundationSampleNameCount = 0
        fileprivate(set) var foundationSampleByteCount = 0
        // 日本語の採点（JapaneseNameEncodingResolver）が加算する。
        var plausibilityScalarCount = 0
        var halfWidthScalarCount = 0
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
        // 設計書「書庫単位」: 重複数を保持した有界 sample の加重和で、先に全候補から選ぶ。
        let multilingual = scoreArchiveNames(
            names, likelyLanguage: likelyLanguage, fromWindows: fromWindows,
            maximumByteCount: maximumBatchByteCount
        )
        if let multilingual, multilingual != .shiftJIS, multilingual != .japaneseEUC {
            return multilingual
        }
        // 日本語の二候補は構造検査の票で決め、決まらない分だけ名前ごとの採点と Foundation の hint で決める。
        var vote = JapaneseNameEncodingResolver.ArchiveVote(names: names)
        metrics?.ambiguousNameCount = vote.ambiguousNames.count
        if let encoding = vote.structurallyUnopposed { return encoding }
        if let encoding = vote.decisiveMajority { return encoding }

        // 両構造を通る名前が勝敗を変え得る場合だけ、archive の代表列を
        // Foundation に一度渡し、その hint を各名前の一票へ反映する。
        var foundation: EncodingDetection?
        var calledFoundation = false
        if !vote.ambiguousNames.isEmpty {
            let sample = orderStableArchiveNameSample(
                vote.foundationSampleNames(from: names),
                separator: 0x0A,
                maximumByteCount: maximumBatchByteCount
                    ?? maximumAutomaticDetectionSampleByteCount,
                metrics: metrics
            )
            foundation = JapaneseNameEncodingResolver.foundationDetection(
                bytes: sample,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows
            )
            calledFoundation = true
        }

        let ambiguousNameFrequencies = archiveNameFrequencies(vote.ambiguousNames)
        let uniqueAmbiguousNames = ambiguousNameFrequencies.map(\.bytes)
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
            let choice = JapaneseNameEncodingResolver.chooseAmbiguousJapanese(
                cp932: cp932,
                eucJP: eucJP,
                bytes: uniqueAmbiguousNames[index],
                foundation: foundation,
                metrics: metrics
            )
            vote.resolve(ambiguousNameFrequencies[index].count, as: choice.encoding)
        }
        if let encoding = vote.resolvedMajority { return encoding }
        if let encoding = vote.decisiveMajority { return encoding }

        // 構造候補がない archive、または未解決票が残った archive だけがここへ来る。
        if !calledFoundation {
            let sample = orderStableArchiveNameSample(
                names,
                separator: 0x0A,
                maximumByteCount: maximumBatchByteCount
                    ?? maximumAutomaticDetectionSampleByteCount,
                metrics: metrics
            )
            foundation = JapaneseNameEncodingResolver.foundationDetection(
                bytes: sample,
                likelyLanguage: likelyLanguage,
                fromWindows: fromWindows
            )
        }
        return vote.decision(foundationHint: foundation?.encoding)
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

        // 先に全候補の勝者を固定し、日本語の時だけ既存経路へ委ねる（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
        let ranked = NameEncodingScorer.ranked(
            NameEncodingScorer.allScores(bytes, fromWindows: fromWindows),
            likelyLanguage: likelyLanguage, fromWindows: fromWindows
        )
        if let winner = ranked.first {
            let candidate = NameEncodingCandidates.all[winner.candidateIndex]
            if !candidate.isJapanese {
                // CP1256 の補完と Mac Arabic / Farsi の方向制御の除去は採点専用。返す名前は既存の CF 復号を通す
                // （Documentation/verification/2026-09-14-name-encoding-languages.md）。
                let string: String
                if candidate.name == "windows-1256" || candidate.name == "x-mac-arabic" || candidate.name == "x-mac-farsi" {
                    string = decode(bytes: bytes, as: candidate.encoding) ?? replacementDecode(bytes, encoding: candidate.encoding)
                } else { string = winner.string }
                return (candidate.encoding, string, NameEncodingScorer.confidence(ranked))
            }
        } else {
            let latin1 = decode(bytes: bytes, as: .isoLatin1)
                ?? String(bytes.map { UnicodeScalar($0) }.map(Character.init))
            return (.isoLatin1, latin1, 0.2)
        }

        let japanese = JapaneseNameEncodingResolver.automaticallyDetectJapanese(
            bytes: bytes, likelyLanguage: likelyLanguage, fromWindows: fromWindows
        )
        return (japanese.encoding, japanese.string, NameEncodingScorer.confidence(ranked))
    }

    // 設計書「書庫単位」「性能」: 既存 sample と同じ順序・中点抽出・byte 上限を使う。
    private static func scoreArchiveNames(
        _ names: [[UInt8]], likelyLanguage: String?, fromWindows: Bool,
        maximumByteCount: Int?
    ) -> String.Encoding? {
        let frequencies = archiveNameFrequencies(names)
        guard !frequencies.isEmpty else { return nil }
        let sampleCount = min(names.count, maximumAutomaticDetectionSampleNameCount)
        let byteLimit = min(maximumAutomaticDetectionSampleByteCount, max(0, maximumByteCount ?? maximumAutomaticDetectionSampleByteCount))
        var selected: [Int: Int] = [:]
        var frequencyIndex = 0
        var cumulativeCount = frequencies[0].count
        var byteCount = 0
        for sampleIndex in 0..<sampleCount {
            let lower = scaledPosition(sampleIndex, total: names.count, parts: sampleCount)
            let upper = scaledPosition(sampleIndex + 1, total: names.count, parts: sampleCount)
            let position = lower + (upper - lower) / 2
            while position >= cumulativeCount, frequencyIndex + 1 < frequencies.count {
                frequencyIndex += 1
                cumulativeCount += frequencies[frequencyIndex].count
            }
            let separatorCount = byteCount == 0 ? 0 : 1
            let size = frequencies[frequencyIndex].bytes.count
            guard separatorCount <= byteLimit - byteCount,
                  size <= byteLimit - byteCount - separatorCount else { continue }
            byteCount += separatorCount + size
            selected[frequencyIndex, default: 0] += 1
        }
        guard !selected.isEmpty else { return .isoLatin1 }
        let candidates = NameEncodingCandidates.all
        var totals = [SIMD16<Double>](repeating: .zero, count: candidates.count)
        var decoded = [Int](repeating: 0, count: candidates.count)
        var evidenceCounts = [Int](repeating: 0, count: candidates.count)
        var hanOnly = [Bool](repeating: true, count: candidates.count)
        let weight = selected.values.reduce(0, +)
        var vietnameseEvidence = false
        for index in selected.keys.sorted() {
            let count = selected[index]!
            let results = NameEncodingScorer.allScores(frequencies[index].bytes, fromWindows: fromWindows, includeHKSCS: true, archive: true)
            // 全候補で同じ byte 尺度を使い、復号不能名も分母から落とさない（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
            let n = frequencies[index].bytes.reduce(0) { $0 + ($1 >= 128 ? 1 : 0) }
            var values = [SIMD16<Double>](repeating: SIMD16(repeating: -3 * Double(n)), count: candidates.count)
            for result in results {
                if !vietnameseEvidence, candidates[result.candidateIndex].name == "windows-1258",
                   NameEncodingScorer.vietnameseEvidence(result.string) { vietnameseEvidence = true }
                values[result.candidateIndex] = result.languageScores * Double(n)
                decoded[result.candidateIndex] += count
                hanOnly[result.candidateIndex] = hanOnly[result.candidateIndex] && result.hanOnly
            }
            for i in totals.indices {
                totals[i] += values[i] * Double(count)
                evidenceCounts[i] += n * count
            }
        }
        let results = candidates.indices.compactMap { i -> NameEncodingScorer.Result? in
            guard decoded[i] > 0 else { return nil }
            if candidates[i].name == "windows-1258", !vietnameseEvidence { return nil }
            if candidates[i].name == "big5-hkscs", decoded[NameEncodingCandidates.cp950Index] == weight { return nil }
            // 名前ごとの最大ではなく、同じ言語の証拠を全 sample で合算してから選ぶ（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
            let best = candidates[i].languages.indices.reduce(-Double.infinity) { max($0, totals[i][$1]) }
            return NameEncodingScorer.Result(candidateIndex: i, string: "", score: best / Double(max(1, evidenceCounts[i])), hanOnly: hanOnly[i], byteCount: evidenceCounts[i])
        }
        guard let winner = NameEncodingScorer.ranked(results, likelyLanguage: likelyLanguage, fromWindows: fromWindows).first else { return .isoLatin1 }
        return candidates[winner.candidateIndex].encoding
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
