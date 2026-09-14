import Foundation

extension EncodingDetector {
    // 設計書「正書法」: CLI と採点器で同じ規則を検査し、scalar 位置を報告する。
    package static func checkNameOrthography(
        _ text: String, language: String
    ) -> [(rule: String, offset: Int, scalar: UInt32)] {
        let properties = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
        let repeated = NameEncodingScorer.repeatedScalars(properties)
        let filtered = properties.enumerated().map { repeated[$0.offset] ? NameEncodingScorer.traits(32) : $0.element }
        let checked = String(String.UnicodeScalarView(filtered.map { Unicode.Scalar($0.scalar)! }))
        var violations = NameEncodingScorer.orthography(checked, language: language).violations.map {
            (rule: $0.rule, offset: $0.offset, scalar: $0.scalar)
        }
        // 第4回レビュー E: 文字得点を置換する無母音規則も、同じ判定関数で自己検査へ出す。
        if language == "th" {
            let excessive = NameEncodingScorer.excessiveLetters(filtered)
            for i in filtered.indices where excessive[i] && filtered[i].script == .thai {
                violations.append((rule: "th-vowelless-run", offset: i, scalar: filtered[i].scalar))
            }
        }
        return violations
    }

    // 測定用 CLI から既存の書庫名解決経路を呼ぶ。公開 API と判定処理は変えない。
    package static func resolveUndeclaredNameForMeasurement(
        bytes: [UInt8],
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        fromWindows: Bool
    ) -> EncodingDetection {
        resolveUndeclaredName(
            bytes: bytes,
            policy: policy,
            archiveEncoding: archiveEncoding,
            fromWindows: fromWindows
        )
    }
}
