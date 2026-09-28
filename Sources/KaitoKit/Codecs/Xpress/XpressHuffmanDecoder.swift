import Foundation

// Microsoft [MS-XCA] v20240423 §2.1〜2.2 "LZ77+Huffman"（Xpress Huffman）の公開仕様に基づくクリーンルーム実装。
// WIM の chunk は 1 chunk = 1 block（先頭 256 byte の符号長表 + 16 bit word 単位の bit stream）。
enum XpressHuffmanDecoder {
    private static let maximumCodeLength = 15

    /// 1 block（WIM では 1 chunk）を展開する。`outputSize` は宣言された展開後サイズ。
    static func decode(_ input: [UInt8], outputSize: Int) throws -> [UInt8] {
        guard input.count >= 256 else { throw KaitoError.truncated }
        // §2.1.4.3: 512 symbol の符号長を 4 bit ずつ（偶数 symbol が下位、奇数が上位）。
        var lengths = [Int](repeating: 0, count: 512)
        for index in 0..<256 {
            lengths[index * 2] = Int(input[index] & 0x0F)
            lengths[index * 2 + 1] = Int(input[index] >> 4)
        }
        let table = try canonicalTable(lengths)
        var output = [UInt8]()
        output.reserveCapacity(outputSize)

        // §2.2.4: 32 bit register に常に 16 bit 以上を保つ。
        var position = 256
        func read16() -> UInt32 {
            guard position + 2 <= input.count else { position += 2; return 0 }
            let value = UInt32(input[position]) | UInt32(input[position + 1]) << 8
            position += 2
            return value
        }
        var bits: UInt32 = read16() << 16 | read16()
        var extra = 16
        func consume(_ count: Int) {
            bits <<= UInt32(count)
            extra -= count
            if extra < 0 {
                bits |= read16() << UInt32(-extra)
                extra += 16
            }
        }
        while output.count < outputSize {
            let entry = table[Int(bits >> 17)]
            let symbol = Int(entry & 0x1FF)
            let length = Int(entry >> 9)
            guard length > 0 else { throw KaitoError.malformed("xpress Huffman code") }
            consume(length)
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            // symbol 256 は「長さ 3・距離 1 の match」と終端の両方を表す（§2.1.4.1 の式と §2.2.4）。出力が
            // 揃うまでは match として扱い、終端は出力完了後に読まれない。
            let match = symbol - 256
            var matchLength = match & 15
            let offsetBits = match >> 4
            if matchLength == 15 {
                guard position < input.count else { throw KaitoError.truncated }
                matchLength = Int(input[position]); position += 1
                if matchLength == 255 {
                    guard position + 2 <= input.count else { throw KaitoError.truncated }
                    matchLength = Int(input[position]) | Int(input[position + 1]) << 8
                    position += 2
                    guard matchLength >= 15 else { throw KaitoError.malformed("xpress long match length") }
                    matchLength -= 15
                }
                matchLength += 15
            }
            matchLength += 3
            var offset = Int(bits >> UInt32(32 - offsetBits))
            if offsetBits == 0 { offset = 0 }
            offset += 1 << offsetBits
            consume(offsetBits)
            guard offset <= output.count else { throw KaitoError.malformed("xpress match offset exceeds history") }
            guard matchLength <= outputSize - output.count else { throw KaitoError.malformed("xpress match exceeds the block") }
            let start = output.count - offset
            for index in 0..<matchLength { output.append(output[start + index]) }
        }
        // 入力を使い切らずに終わる block は許す（終端 symbol と padding が続く）。
        guard position <= input.count + 4 else { throw KaitoError.malformed("xpress bit stream overrun") }
        return output
    }

    /// §2.2.4 の 2^15 entry の復号表。entry は (符号長 << 9) | symbol。
    private static func canonicalTable(_ lengths: [Int]) throws -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 1 << maximumCodeLength)
        var position = 0
        for length in 1...maximumCodeLength {
            for symbol in 0..<512 where lengths[symbol] == length {
                let count = 1 << (maximumCodeLength - length)
                guard position + count <= table.count else { throw KaitoError.malformed("xpress Huffman table overflow") }
                let entry = UInt32(length) << 9 | UInt32(symbol)
                for index in position..<(position + count) { table[index] = entry }
                position += count
            }
        }
        guard position == table.count else { throw KaitoError.malformed("xpress Huffman table incomplete") }
        return table
    }
}
