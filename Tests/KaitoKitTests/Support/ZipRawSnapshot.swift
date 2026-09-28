import KaitoKit

/// 公開の `RawEntryRecord` から、差分試験で比べる record・payload の範囲と形式固有の値だけを取り出したもの。
struct ZipRawSnapshot: Equatable {
    let record: Range<UInt64>
    let payload: Range<UInt64>
    let specific: [String: String]
    init(_ raw: RawEntryRecord) { record = raw.recordRange; payload = raw.payloadRange; specific = raw.formatSpecific }
}
