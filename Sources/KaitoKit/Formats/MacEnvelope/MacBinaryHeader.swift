import Foundation

// 出典: MacBinary / MacBinary II の公開 standard proposal（128 byte header の field 位置、128 byte 単位の
// 詰め、header CRC）。実装 source は参照していない。

/// MacBinary header（128 byte、数値は big-endian）の field 位置と header CRC。
///
/// header を受け入れるかの判定は使う側が持つ。StuffIt の wrapper 解除（`MacEnvelopeParser`）と MacLHA の
/// data fork 抽出（`MacBinaryDataForkDecompressor`）は、CRC を持たない MacBinary I をそれぞれ別の
/// 追加検査で見分ける。
enum MacBinaryHeader {
    /// header の byte 数。
    static let size = 128
    /// secondary header・data fork・resource fork・comment は、この単位の倍数まで 0 で詰める。
    static let blockSize = 128
    /// どの版でも 0 の byte: 旧 version 番号（0）と二つの zero fill（74、82）。
    static let requiredZeroOffsets = [0, 74, 82]
    /// 名前の長さ（1 byte）。名前本体は `filenameOffset` から。
    static let filenameLengthOffset = 1
    static let filenameOffset = 2
    static let maximumFilenameLength = 63
    /// data fork の byte 数（UInt32）。
    static let dataForkSizeOffset = 83
    /// resource fork の byte 数（UInt32）。
    static let resourceForkSizeOffset = 87
    /// Get Info comment の byte 数（UInt16、MacBinary II）。
    static let commentSizeOffset = 99
    /// secondary header の byte 数（UInt16、MacBinary II）。
    static let secondaryHeaderSizeOffset = 120
    /// bytes 0..<124 の CRC（UInt16、MacBinary II）。MacBinary I はこの field を 0 のままにする。
    static let crcOffset = 124

    /// header に記録された CRC。`header` は `size` byte 以上。
    static func storedCRC(_ header: [UInt8]) -> UInt16 {
        BigEndian.uint16(header, at: crcOffset)
    }

    /// bytes 0..<124 から計算した CRC。MacBinary II の言う CRC-CCITT は CRC-16/XMODEM（`CRC16XModem`）。
    static func computedCRC(_ header: [UInt8]) -> UInt16 {
        CRC16XModem.checksum(header[..<crcOffset])
    }
}
