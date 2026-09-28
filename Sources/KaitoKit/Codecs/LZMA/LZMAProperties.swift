import Foundation

// 参照仕様: LZMA SDK の lzma-specification.txt。

/// lc / lp / pb を一 byte に詰めた LZMA の property（`(pb * 5 + lp) * 9 + lc`）。
/// LZMA1 の 5 byte property の先頭 byte と、LZMA2 chunk の property byte がこの形をとる。
struct LZMAProperties {
    /// 一つの literal coder の確率数（通常の 8 bit 木 0x100 と、matched literal の 0x200）。
    static let literalCoderSize = 0x300

    let literalContextBits: Int
    let literalPositionBits: Int
    let positionBits: Int

    var positionStateMask: UInt64 {
        (UInt64(1) << UInt64(positionBits)) - 1
    }

    /// `requireLZMA2LiteralLimit` は LZMA2 の lc + lp <= 4 も課す。
    init(packed: UInt8, requireLZMA2LiteralLimit: Bool) throws {
        let value = Int(packed)
        guard value < 9 * 5 * 5 else {
            throw KaitoError.malformed("invalid LZMA lc/lp/pb properties")
        }
        literalContextBits = value % 9
        let remainder = value / 9
        literalPositionBits = remainder % 5
        positionBits = remainder / 5
        if requireLZMA2LiteralLimit,
           literalContextBits + literalPositionBits > 4 {
            throw KaitoError.malformed("invalid LZMA2 literal properties")
        }
    }

    func literalProbabilityCount() throws -> Int {
        let shift = try Checked.add(
            UInt64(literalContextBits),
            UInt64(literalPositionBits)
        )
        let contextCount = try Checked.shiftLeft(1, by: shift)
        let probabilityCount = try Checked.mul(UInt64(Self.literalCoderSize), contextCount)
        return try Checked.toInt(probabilityCount)
    }
}
