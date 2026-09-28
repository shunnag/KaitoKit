import Foundation

// 参照仕様: LZMA SDK の公開ドメイン文書 lzma-specification.txt。
// 7-Zip の実装ソースは参照していない。

/// LZMA2 chunk の header。control byte に続く size と property byte を読み、
/// stream の reset 規則に照らして検証した結果。
///
/// control byte:
/// - `0x00`: stream 終端。
/// - `0x01`: 非圧縮 chunk。dictionary を reset する。
/// - `0x02`: 非圧縮 chunk。dictionary を保つ。
/// - `0x80...0xFF`: LZMA chunk。bit 5–6 が reset の段階（`0x80` なし、`0xA0` coding state、
///   `0xC0` coding state と新しい property、`0xE0` dictionary まで全部）、bit 0–4 が
///   展開サイズ - 1 の bit 16–20。
///
/// dictionary reset 点の index を作る走査（`LZMA2Decoder.makeDictionaryResetIndex`）と
/// live decoder が同じ読み方と同じ検査順を使う。
enum LZMA2ChunkHeader {
    case end
    case uncompressed(size: UInt64, resetsDictionary: Bool)
    case compressed(
        unpackedSize: UInt64,
        packedSize: UInt64,
        resetsDictionary: Bool,
        resetsState: Bool,
        properties: UInt8?
    )

    /// LZMA chunk の展開サイズの上限。
    static let maximumUnpackedChunkSize: UInt64 = 2 * 1_024 * 1_024
    /// LZMA chunk の圧縮サイズの上限。
    static let maximumPackedChunkSize: UInt64 = 64 * 1_024
    /// 非圧縮 chunk の大きさの上限。
    static let maximumRawChunkSize: UInt64 = 64 * 1_024

    static let endControl: UInt8 = 0x00
    /// dictionary を reset する非圧縮 chunk。
    static let rawDictionaryResetControl: UInt8 = 0x01
    /// dictionary を保つ非圧縮 chunk。
    static let rawControl: UInt8 = 0x02
    private static let firstCompressedControl: UInt8 = 0x80
    private static let stateResetControl: UInt8 = 0xA0
    private static let propertiesResetControl: UInt8 = 0xC0
    private static let dictionaryResetControl: UInt8 = 0xE0
    private static let unpackedSizeHighBitsMask: UInt8 = 0x1F

    /// `control` の chunk が dictionary を reset するかどうか（`0x01` または `0xE0...`）。
    static func resetsDictionary(control: UInt8) -> Bool {
        control == rawDictionaryResetControl || control >= dictionaryResetControl
    }

    /// `controlOffset` の control byte `control` を読んだ直後の `reader` から残りの header を
    /// 読み、`resets` を更新する。
    ///
    /// 検査順は size、dictionary reset、property byte、coding state の順で、どの失敗が
    /// 先に報告されるかは両方の呼出元で同じになる。
    init(
        control: UInt8,
        controlOffset: UInt64,
        reader: inout ByteReader,
        resets: inout LZMA2ResetTracker
    ) throws {
        if control == Self.endControl {
            self = .end
            return
        }

        if control < Self.firstCompressedControl {
            guard control == Self.rawDictionaryResetControl || control == Self.rawControl else {
                throw KaitoError.malformed("invalid LZMA2 control byte")
            }
            let resetsDictionary = control == Self.rawDictionaryResetControl
            try resets.recordDictionary(reset: resetsDictionary)
            let size = UInt64(try reader.readUInt16BE()) + 1
            guard size <= Self.maximumRawChunkSize else {
                throw KaitoError.malformed("invalid LZMA2 uncompressed chunk size")
            }
            self = .uncompressed(size: size, resetsDictionary: resetsDictionary)
            return
        }

        let low = UInt64(try reader.readUInt16BE())
        let high = UInt64(control & Self.unpackedSizeHighBitsMask) << 16
        let unpackedSize = try Checked.add(try Checked.add(high, low), 1)
        guard unpackedSize > 0, unpackedSize <= Self.maximumUnpackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 unpacked chunk size")
        }
        let packedSize = UInt64(try reader.readUInt16BE()) + 1
        guard packedSize <= Self.maximumPackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 packed chunk size")
        }

        let resetsDictionary = control >= Self.dictionaryResetControl
        try resets.recordDictionary(reset: resetsDictionary)

        let properties: UInt8?
        if control >= Self.propertiesResetControl {
            let value = try reader.readUInt8()
            _ = try LZMAProperties(packed: value, requireLZMA2LiteralLimit: true)
            properties = value
        } else {
            properties = nil
        }
        try resets.recordProperties(present: properties != nil)

        let resetsState = control >= Self.stateResetControl
        try resets.recordState(reset: resetsState, control: control, controlOffset: controlOffset)

        self = .compressed(
            unpackedSize: unpackedSize,
            packedSize: packedSize,
            resetsDictionary: resetsDictionary,
            resetsState: resetsState,
            properties: properties
        )
    }
}

/// LZMA2 stream が最初の使用より前に要求する三つの初期化（dictionary reset、LZMA property、
/// coding state reset）が済んだかどうかを stream の順に追う。
struct LZMA2ResetTracker {
    private var needsDictionaryReset = true
    private var needsProperties = true
    private var needsStateReset = true

    /// reset 点から再開する decoder は、その点に記録された property を読み込み済みで始める。
    mutating func acceptPreloadedProperties() {
        needsProperties = false
    }

    mutating func recordDictionary(reset: Bool) throws {
        if reset {
            needsDictionaryReset = false
        } else if needsDictionaryReset {
            throw KaitoError.malformed("LZMA2 stream starts without a dictionary reset")
        }
    }

    mutating func recordProperties(present: Bool) throws {
        if present {
            needsProperties = false
        } else if needsProperties {
            throw KaitoError.malformed("LZMA2 stream uses LZMA before properties")
        }
    }

    mutating func recordState(reset: Bool, control: UInt8, controlOffset: UInt64) throws {
        if reset {
            needsStateReset = false
        } else if needsStateReset {
            throw KaitoError.malformed(
                "LZMA2 control 0x\(String(control, radix: 16)) at byte \(controlOffset) "
                    + "uses coding state before it is initialized"
            )
        }
    }
}
