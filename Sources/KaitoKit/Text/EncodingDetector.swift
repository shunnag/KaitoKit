import Foundation

/// The result of resolving encoded name bytes.
public typealias EncodingDetection = (
    encoding: String.Encoding,
    string: String,
    confidence: Double
)

/// Detects and decodes archive entry names without sending valid UTF-8 to a guesser.
public enum EncodingDetector {
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
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 0x7F || (0xA1...0xDF).contains(byte) {
                index += 1
                continue
            }

            let isLead = (0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte)
            guard isLead, index + 1 < bytes.count else {
                return nil
            }
            let trail = bytes[index + 1]
            let isTrail = (0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail)
            guard isTrail, trail != 0x7F else {
                return nil
            }
            index += 2
        }
        return decode(bytes: bytes, as: .shiftJIS)
    }

    private static func eucJPCandidate(_ bytes: [UInt8]) -> String? {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 0x7F {
                index += 1
                continue
            }
            if byte == 0x8E {
                guard index + 1 < bytes.count, (0xA1...0xDF).contains(bytes[index + 1]) else {
                    return nil
                }
                index += 2
                continue
            }
            if byte == 0x8F {
                guard index + 2 < bytes.count,
                      (0xA1...0xFE).contains(bytes[index + 1]),
                      (0xA1...0xFE).contains(bytes[index + 2])
                else {
                    return nil
                }
                index += 3
                continue
            }
            guard (0xA1...0xFE).contains(byte),
                  index + 1 < bytes.count,
                  (0xA1...0xFE).contains(bytes[index + 1])
            else {
                return nil
            }
            index += 2
        }
        return decode(bytes: bytes, as: .japaneseEUC)
    }

    private static func chooseAmbiguousJapanese(
        cp932: String,
        eucJP: String,
        bytes: [UInt8],
        foundation: EncodingDetection?
    ) -> EncodingDetection {
        // EUC-JP の補助面・半角カナ接頭辞は CP932 の偶然一致より強い証拠になる。
        if containsEUCShiftPrefix(bytes) {
            return (.japaneseEUC, eucJP, 0.82)
        }

        if isLikelyHalfWidthName(cp932), eucJP.count == 1 {
            return (.shiftJIS, cp932, 0.8)
        }

        var cpScore = japanesePlausibility(cp932)
        var eucScore = japanesePlausibility(eucJP)
        if foundation?.encoding == .shiftJIS {
            cpScore += 0.15
        } else if foundation?.encoding == .japaneseEUC {
            eucScore += 0.15
        }
        if isLikelyHalfWidthName(cp932) {
            cpScore += 0.9
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

    private static func japanesePlausibility(_ string: String) -> Double {
        var score = 0.0
        var count = 0.0
        for scalar in string.unicodeScalars {
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
        return count > 0 ? score / count : 0
    }

    private static func isLikelyHalfWidthName(_ string: String) -> Bool {
        var sawKana = false
        for scalar in string.unicodeScalars {
            if (0xFF61...0xFF9F).contains(scalar.value) {
                sawKana = true
                continue
            }
            if (0x20...0x7E).contains(scalar.value) {
                continue
            }
            return false
        }
        guard sawKana else {
            return false
        }

        let normalized = string.precomposedStringWithCompatibilityMapping
        let commonTerms = [
            "カナ", "カタカナ", "テスト", "ページ", "ファイル", "コミック",
            "マンガ", "タイトル", "サンプル", "イラスト",
        ]
        return commonTerms.contains { normalized.contains($0) }
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
