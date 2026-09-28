import Foundation

/// 宣言の無い名前を書庫全体で一度に推定・復号し、名前の byte 列ごとの文字列を返す（cpio・ar・ISO 9660・CAB）。
///
/// `.fixed` 以外の方針では strict UTF-8 の名前を推定と一括復号から外す。推定した encoding で候補をまとめて
/// 復号するのが性能の要で、表に無い名前だけを `EncodingDetector.resolveUndeclaredName` に委ねる。
struct ArchiveNameResolver {
    /// 書庫全体で推定した encoding（reader の `nameEncoding`）。
    let archiveEncoding: String.Encoding?
    private let policy: EncodingPolicy
    private let decoded: [[UInt8]: String]

    init(undeclaredNames names: [[UInt8]], policy: EncodingPolicy, limits: ReadLimits) {
        let candidates = names.filter {
            if case .fixed = policy { return true }
            return !EncodingDetector.isStrictUTF8($0)
        }
        let batchLimit = Int(clamping: limits.maxMetadataSize)
        let encoding = EncodingDetector.detectArchiveEncoding(names: candidates, policy: policy,
                                                              maximumBatchByteCount: batchLimit)
        var decoded: [[UInt8]: String] = [:]
        if let encoding {
            let strings = EncodingDetector.decodeArchiveNames(candidates, as: encoding, maximumBatchByteCount: batchLimit)
            for (bytes, string) in zip(candidates, strings) { if let string { decoded[bytes] = string } }
        }
        archiveEncoding = encoding
        self.policy = policy
        self.decoded = decoded
    }

    func resolve(_ bytes: [UInt8]) -> String {
        decoded[bytes] ?? EncodingDetector.resolveUndeclaredName(bytes: bytes, policy: policy,
                                                                 archiveEncoding: archiveEncoding).string
    }
}
