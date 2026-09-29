import Foundation
import Darwin

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

    static let bitsPerByte: UInt64 = 8
    static let magicBitCount: UInt64 = 48
    static let crcBitCount: UInt64 = 32
    static let trailerBitCount = magicBitCount + crcBitCount
    static let framingByteCount = streamHeaderLength + Int(trailerBitCount / bitsPerByte)

    /// 先頭・末尾の部分 byte を含め、全ての bit 整列の候補を返す。
    /// baseBit と窓の終端の加算は呼出側で検査する。
    static func blockMagicPositions(in bytes: UnsafeRawBufferPointer, baseBit: UInt64) -> [UInt64] {
        magicPositions(blockMagic, in: bytes, baseBit: baseBit)
    }

    static func endMagicPositions(in bytes: UnsafeRawBufferPointer, baseBit: UInt64) -> [UInt64] {
        magicPositions(endOfStreamMagic, in: bytes, baseBit: baseBit)
    }

    private static func magicPositions(_ magic: [UInt8], in bytes: UnsafeRawBufferPointer,
                                       baseBit: UInt64) -> [UInt64] {
        guard bytes.count >= magic.count, let base = bytes.baseAddress else { return [] }
        let value = magic.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var positions: [UInt64] = []
        for alignment in 0..<8 {
            let length = alignment == 0 ? magic.count : magic.count + 1
            guard bytes.count >= length else { continue }
            let shifted = value << (alignment == 0 ? 0 : 8 - alignment)
            let pattern = (0..<length).map { UInt8(truncatingIfNeeded: shifted >> ((length - 1 - $0) * 8)) }
            let firstMask = UInt8.max >> alignment
            let lastMask = alignment == 0 ? UInt8.max : UInt8.max << (8 - alignment)
            // 部分 byte の次の完全な byte を memchr で探してから残りを照合する。
            var cursor = 1
            let last = bytes.count - length + 1
            while cursor <= last {
                guard let found = memchr(base.advanced(by: cursor), Int32(pattern[1]), last - cursor + 1) else { break }
                let offset = base.distance(to: found) - 1
                if bytes[offset] & firstMask == pattern[0],
                   bytes[offset + length - 1] & lastMask == pattern[length - 1],
                   (2..<(length - 1)).allSatisfy({ bytes[offset + $0] == pattern[$0] }) {
                    positions.append(baseBit + UInt64(offset) * bitsPerByte + UInt64(alignment))
                }
                cursor = offset + 2
            }
        }
        return positions.sorted()
    }

    static func combinedCRC(_ combined: UInt32, blockCRC: UInt32) -> UInt32 {
        ((combined << 1) | (combined >> 31)) ^ blockCRC
    }

    /// 呼出側が 32 bit 全体の存在を保証する。
    static func crc(in bytes: UnsafeRawBufferPointer, atBit bit: UInt64) -> UInt32 {
        let offset = Int(bit / bitsPerByte), shift = Int(bit % bitsPerByte)
        var value: UInt32 = 0
        for index in 0..<4 {
            var byte = bytes[offset + index] << shift
            if shift != 0 { byte |= bytes[offset + index + 1] >> (8 - shift) }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    /// 範囲と確保量は呼出側で検査する。level は ASCII 桁ではなく 1...9。
    static func reframe(stream headerLevel: UInt8, bits: UnsafeRawBufferPointer, firstBit: UInt64,
                        bitCount: UInt64, blockCRCs: [UInt32]) -> [UInt8] {
        let payloadCount = Int((bitCount + 7) / bitsPerByte)
        var result = [UInt8](repeating: 0, count: framingByteCount + payloadCount)
        result.replaceSubrange(0..<signature.count, with: signature)
        result[streamHeaderLength - 1] = headerLevel + levelDigitBase
        let firstByte = Int(firstBit / bitsPerByte), shift = Int(firstBit % bitsPerByte)
        for index in 0..<payloadCount {
            var byte = bits[firstByte + index] << shift
            if shift != 0, firstByte + index + 1 < bits.count {
                byte |= bits[firstByte + index + 1] >> (8 - shift)
            }
            result[streamHeaderLength + index] = byte
        }
        let remainder = Int(bitCount % bitsPerByte)
        if remainder != 0 { result[streamHeaderLength + payloadCount - 1] &= UInt8.max << (8 - remainder) }
        let combined = blockCRCs.reduce(UInt32(0)) { combinedCRC($0, blockCRC: $1) }
        let trailer = endOfStreamMagic + (0..<4).map { UInt8(truncatingIfNeeded: combined >> ((3 - $0) * 8)) }
        let trailerStart = streamHeaderLength + Int(bitCount / bitsPerByte)
        for (index, byte) in trailer.enumerated() {
            result[trailerStart + index] |= byte >> remainder
            if remainder != 0 { result[trailerStart + index + 1] |= byte << (8 - remainder) }
        }
        return result
    }

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
