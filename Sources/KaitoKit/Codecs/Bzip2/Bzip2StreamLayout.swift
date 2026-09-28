import Foundation

/// bzip2 stream の byte 境界に現れる framing。直列 decoder の連結 stream 判定と、
/// 並列 decoder の区間走査が同じ定義を使う。
///
/// stream は `"BZh"` と block size 桁（`'1'...'9'`、100 000 byte 単位）の 4 byte header で
/// 始まり、直後に最初の block の magic（BCD の π）か、空 stream なら終端 magic（BCD の √π）が
/// 続く。以後の block と終端は bit 単位で詰められるため、byte 境界に並ぶのは stream 先頭だけ。
enum Bzip2StreamLayout {
    /// stream 先頭の `"BZh"`。
    static let signature: [UInt8] = [0x42, 0x5a, 0x68]

    /// signature 直後の block size 桁 `'1'...'9'`。
    static let levelDigits: ClosedRange<UInt8> = 0x31...0x39

    /// block size 桁から引くと level 1...9 になる ASCII `'0'`。
    static let levelDigitBase: UInt8 = 0x30

    /// signature と block size 桁からなる stream header の長さ。
    static let streamHeaderLength = 4

    /// block 先頭の 48 bit magic（BCD の π）。
    static let blockMagic: [UInt8] = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59]

    /// stream 終端 trailer の 48 bit magic（BCD の √π）。
    static let endOfStreamMagic: [UInt8] = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90]

    /// stream header と、それに続く最初の block magic または終端 magic の長さ。
    static let headerLength = 10

    /// `bytes` の `offset` から stream header（`"BZh"` と block size 桁）が始まるかどうか。
    /// 呼出側が `offset + streamHeaderLength <= bytes.count` を保証する。
    @inline(__always)
    static func isStreamHeader(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        bytes[offset] == signature[0] && bytes[offset + 1] == signature[1]
            && bytes[offset + 2] == signature[2] && levelDigits.contains(bytes[offset + 3])
    }

    /// `bytes` の `offset` から stream header と block magic または終端 magic の
    /// `headerLength` byte が始まるかどうか。範囲外なら false。
    @inline(__always)
    static func isStreamStart(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        guard offset >= 0, offset + headerLength <= bytes.count,
              isStreamHeader(bytes, at: offset) else { return false }
        let magic = bytes[(offset + streamHeaderLength)..<(offset + headerLength)]
        return magic.elementsEqual(blockMagic) || magic.elementsEqual(endOfStreamMagic)
    }
}
