/// GyoshukuKit の ZIP 編集用。CD の暗号 flag と 0x9901 extra から得た暗号方式。
/// `strength`（1 / 2 / 3 = AES-128 / 192 / 256）と `vendorVersion`（1 = AE-1、2 = AE-2）は 0x9901 の生値。
@_spi(ZipRawLayout)
public enum ZipRawEncryption: Sendable, Equatable {
    case none, zipCrypto
    case winZipAES(strength: UInt8, vendorVersion: UInt16)
}

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
    /// CD の暗号 flag と 0x9901 から得た暗号方式。
    public let encryption: ZipRawEncryption
    /// CD の CRC 欄。AE-2 は 0。
    public let storedCRC32: UInt32
    /// 実際の圧縮方式。AES は 0x9901 の方式。
    public let compressionMethod: UInt16
    /// 公開 rawRecord の isZIP64 と同じ descriptor 幅の判定。
    public var isZIP64: Bool { centralHasZIP64Extra || localHasZIP64Extra }
}
