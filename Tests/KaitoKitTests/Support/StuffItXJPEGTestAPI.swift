// StuffIt X JPEG の内部型に対するテスト専用の逆変換。本番の復元経路は符号化方向だけを使い、ここは呼ばない。
@testable import KaitoKit

extension StuffItXJPEGInput {
    /// `wz()` の逆。7 bit 単位の big-endian で、最後の byte 以外に継続 bit 0x80 を立てる。
    static func writeWZ(_ value: UInt64) -> [UInt8] {
        var value = value, result = [UInt8(value & 127)]
        value >>= 7
        while value != 0 { result.append(128 | UInt8(value & 127)); value >>= 7 }
        return result.reversed()
    }
}

extension JPEGHuffman {
    /// 符号表を線形に探す Huffman 復号。bit ごとに 16 × 256 を走査するので、検証専用。
    func read(_ bit: () throws -> Int) throws -> Int {
        var code = 0
        for length in 1...16 {
            code = try code*2+bit()
            for symbol in 0..<256 where codes.p[256+symbol] == length && codes.p[symbol] == code { return symbol }
        }
        throw jpegMalformed("unknown Huffman code")
    }
}
