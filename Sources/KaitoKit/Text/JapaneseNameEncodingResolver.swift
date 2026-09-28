import Foundation

/// CP932 と EUC-JP の二候補だけを比べる日本語の名前判定。
///
/// 多言語の採点（``NameEncodingScorer``）の勝者が日本語の候補のとき、単名は
/// ``automaticallyDetectJapanese(bytes:likelyLanguage:fromWindows:)``、書庫は ``ArchiveVote`` と
/// ``chooseAmbiguousJapanese(cp932:eucJP:bytes:foundation:metrics:)`` で決める。構造検査と半角カナ名の規則は
/// 採点器の CP932 / EUC-JP 候補も使う（設計書「採点 1、2」）。
enum JapaneseNameEncodingResolver {
    typealias Metrics = EncodingDetector.ArchiveEncodingDetectionMetrics

    private static let maximumJapaneseScoringScalarCount = 256

    /// 書庫の未宣言名の CP932 / EUC-JP の票。
    ///
    /// 一方の構造検査だけを通る名前は即座にその票、両方を通る名前は未解決票として数える。未解決票は
    /// ``chooseAmbiguousJapanese(cp932:eucJP:bytes:foundation:metrics:)`` の名前ごとの判定で解き、
    /// 残りは Foundation の hint で決める。
    struct ArchiveVote {
        private(set) var cp932Votes = 0
        private(set) var eucJPVotes = 0
        private(set) var unresolvedVotes: Int
        /// 両方の構造を通る名前。入力の順で重複を含む。
        let ambiguousNames: [[UInt8]]
        let hasCP932Support: Bool
        let hasEUCJPSupport: Bool

        init(names: [[UInt8]]) {
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
            cp932Votes = cp932Only
            eucJPVotes = eucJPOnly
            unresolvedVotes = ambiguousJapaneseNames.count
            ambiguousNames = ambiguousJapaneseNames
            hasCP932Support = cp932Only > 0 || !ambiguousJapaneseNames.isEmpty
            hasEUCJPSupport = eucJPOnly > 0 || !ambiguousJapaneseNames.isEmpty
        }

        /// 一方の構造を通る名前しかなければ、その encoding。
        var structurallyUnopposed: String.Encoding? {
            if hasCP932Support, !hasEUCJPSupport { return .shiftJIS }
            if hasEUCJPSupport, !hasCP932Support { return .japaneseEUC }
            return nil
        }

        /// 未解決票をすべて相手に足しても逆転しない差があれば、多い方。
        var decisiveMajority: String.Encoding? {
            if cp932Votes > eucJPVotes + unresolvedVotes { return .shiftJIS }
            if eucJPVotes > cp932Votes + unresolvedVotes { return .japaneseEUC }
            return nil
        }

        /// 未解決票が残らず、同数でもなければ、多い方。
        var resolvedMajority: String.Encoding? {
            if unresolvedVotes == 0, cp932Votes != eucJPVotes {
                return cp932Votes > eucJPVotes ? .shiftJIS : .japaneseEUC
            }
            return nil
        }

        /// Foundation に渡す代表の名前。EUC の 8E / 8F を含まない曖昧名が過半ならそれだけ、でなければ全名前。
        func foundationSampleNames(from names: [[UInt8]]) -> [[UInt8]] {
            let withoutEUCShift = ambiguousNames.filter {
                !containsEUCShiftPrefix($0)
            }
            return withoutEUCShift.count >
                ambiguousNames.count - withoutEUCShift.count
                ? withoutEUCShift
                : names
        }

        /// occurrenceCount 回現れる曖昧名一つを、名前ごとの判定の結果で票にする。
        mutating func resolve(_ occurrenceCount: Int, as encoding: String.Encoding) {
            if encoding == .japaneseEUC {
                eucJPVotes += occurrenceCount
            } else {
                cp932Votes += occurrenceCount
            }
            unresolvedVotes -= occurrenceCount
        }

        /// 最後の決定。Foundation の hint は残った未解決票をまとめて動かし、同数なら hint、hint もなければ CP932。
        func decision(foundationHint: String.Encoding?) -> String.Encoding {
            if !hasCP932Support, !hasEUCJPSupport {
                return foundationHint ?? .isoLatin1
            }
            var cp932Votes = cp932Votes
            var eucJPVotes = eucJPVotes
            if foundationHint == .shiftJIS {
                cp932Votes += unresolvedVotes
            } else if foundationHint == .japaneseEUC {
                eucJPVotes += unresolvedVotes
            }

            if cp932Votes != eucJPVotes {
                return cp932Votes > eucJPVotes ? .shiftJIS : .japaneseEUC
            }
            if foundationHint == .japaneseEUC { return .japaneseEUC }
            if foundationHint == .shiftJIS { return .shiftJIS }
            if hasCP932Support || hasEUCJPSupport {
                // 日本語候補の同点時は単名 detector と同じく CP932 を優先する。
                return .shiftJIS
            }
            return .isoLatin1
        }
    }

    // 既存の日本語決定処理を保持し、新候補の勝者が日本語の時だけ呼ぶ（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    static func automaticallyDetectJapanese(
        bytes: [UInt8], likelyLanguage: String?, fromWindows: Bool
    ) -> EncodingDetection {
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
        let latin1 = EncodingDetector.decode(bytes: bytes, as: .isoLatin1)
            ?? String(bytes.map { UnicodeScalar($0) }.map(Character.init))
        return (.isoLatin1, latin1, 0.2)
    }

    static func foundationDetection(
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
        return EncodingDetector.decode(bytes: bytes, as: .shiftJIS)
    }

    static func isStructurallyCP932(_ bytes: [UInt8]) -> Bool {
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
        return EncodingDetector.decode(bytes: bytes, as: .japaneseEUC)
    }

    static func isStructurallyEUCJP(_ bytes: [UInt8]) -> Bool {
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

    static func chooseAmbiguousJapanese(
        cp932: String,
        eucJP: String,
        bytes: [UInt8],
        foundation: EncodingDetection?,
        metrics: Metrics? = nil
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
        metrics: Metrics?
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
        metrics: Metrics?
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

    static func isLikelyHalfWidthName(
        _ string: String,
        metrics: Metrics? = nil
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
}
