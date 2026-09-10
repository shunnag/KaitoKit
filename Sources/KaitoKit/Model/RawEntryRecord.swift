/// そのまま運べる entry の生レコード範囲。
public struct RawEntryRecord: Sendable {
    /// 書き出し先へ verbatim でコピーすべき範囲。ZIP では
    /// [local header][name][extra][payload] と、bit 3 のときは data descriptor まで。
    /// offset は source の先頭からの絶対値（SFX prefix も含めた実 offset）。
    public let recordRange: Range<UInt64>

    /// 検証用。圧縮データ本体だけの範囲。
    /// 暗号化 ZIP では暗号ヘッダ・salt・認証コードも含む保存済み payload 全体。
    public let payloadRange: Range<UInt64>

    /// 形式固有の値。ZIP は ArchiveEntry の情報に crc32（0x 付き 8 桁の 16 進数）、
    /// headerMethod（保存された方式番号）、hasDataDescriptor、isZIP64 を加える。
    /// 真偽値は "true" / "false"。encryption は "none" / "ZipCrypto" / "AES-128" など。
    public let formatSpecific: [String: String]
}
