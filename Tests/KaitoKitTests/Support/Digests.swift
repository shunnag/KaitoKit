import CryptoKit
import Foundation

/// テストで期待値と比べる SHA-256 の 16 進表記（小文字 64 文字）。
extension Data {
    var sha256Hex: String { sha256HexString(SHA256.hash(data: self)) }
}

extension Array where Element == UInt8 {
    var sha256Hex: String { sha256HexString(SHA256.hash(data: self)) }
}

private func sha256HexString(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
