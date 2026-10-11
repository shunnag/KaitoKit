/// 辞書上限と枠構造を検証済みの XZ stream と block の配置。
struct XZStreamLayout: Sendable {
    let streams: [Stream]

    struct Stream: Sendable {
        let headerRange: Range<UInt64>
        let flags: UInt16
        let checkSize: UInt64
        let blocks: [Block]
        let indexRange: Range<UInt64>
        let footerRange: Range<UInt64>

        /// Stream Flags の check 種別（0 none、1 CRC32、4 CRC64、10 SHA-256、他は予約）。
        var checkType: UInt8 { UInt8(truncatingIfNeeded: flags >> 8) & 0x0f }
    }

    struct Block: Sendable {
        let compressedRange: Range<UInt64>
        let headerSize: UInt64
        let payloadSize: UInt64
        let unpaddedSize: UInt64
        let outputSize: UInt64
        let dictionarySize: UInt64
        /// 最終 filter（LZMA2）の property byte。
        let dictionaryProperty: UInt8
        /// filter chain の長さ。1 なら LZMA2 だけで、前置 filter（BCJ・Delta）がない。
        let filterCount: Int

        /// LZMA2 payload（先頭 control byte から end control まで）の絶対 offset。
        var payloadOffset: UInt64 { compressedRange.lowerBound + headerSize }
    }
}
