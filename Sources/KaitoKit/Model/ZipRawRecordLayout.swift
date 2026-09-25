/// GyoshukuKit の ZIP 編集用。公開 rawRecord と同じ検証を通った範囲。
@_spi(ZipRawLayout)
public struct ZipRawRecordLayout: Sendable, Equatable {
    /// local header から descriptor の終端までの絶対範囲（SFX を含む）。
    public let recordRange: Range<UInt64>
    /// 保存された payload の絶対範囲。
    public let payloadRange: Range<UInt64>
    /// 検証済み local header の bit 3。
    public let hasDataDescriptor: Bool
    /// CD の extra に 0x0001 がある。
    public let centralHasZIP64Extra: Bool
    /// local の extra に 0x0001 がある。
    public let localHasZIP64Extra: Bool
    /// 公開 rawRecord の isZIP64 と同じ descriptor 幅の判定。
    public var isZIP64: Bool { centralHasZIP64Extra || localHasZIP64Extra }
}
