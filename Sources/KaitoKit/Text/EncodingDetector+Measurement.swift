import Foundation

extension EncodingDetector {
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
