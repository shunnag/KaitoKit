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
    }

    struct Block: Sendable {
        let compressedRange: Range<UInt64>
        let headerSize: UInt64
        let payloadSize: UInt64
        let unpaddedSize: UInt64
        let outputSize: UInt64
    }
}
