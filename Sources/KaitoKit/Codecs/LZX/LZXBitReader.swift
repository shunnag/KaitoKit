// Microsoft [MS-PATCH] v20160613 §2.1.1 に基づく。CAB では CFDATA がフレームを区切る。
struct LZXBitReader {
    private let input: [UInt8]
    private var byteOffset = 0
    private var buffer: UInt64 = 0
    private var bitCount = 0

    init(_ input: [UInt8]) { self.input = input }

    // 先読みは実在するワードだけを取り込み、不足分は参照用にだけゼロで埋める。
    // 実際の消費時には必ずビット数を検査するため、末尾の短い符号も切断も区別できる。
    @inline(__always)
    mutating func peekPadded(_ count: Int) throws -> Int {
        guard (0...24).contains(count) else { throw KaitoError.malformed("cab LZX bit count") }
        while bitCount < count, input.count - byteOffset >= 2 {
            let word = UInt64(input[byteOffset]) | (UInt64(input[byteOffset + 1]) << 8)
            buffer = (buffer << 16) | word
            bitCount += 16
            byteOffset += 2
        }
        if bitCount >= count {
            return Int((buffer >> (bitCount - count)) & ((1 << count) - 1))
        }
        return Int((buffer << (count - bitCount)) & ((1 << count) - 1))
    }

    @inline(__always)
    mutating func consume(_ count: Int) throws {
        guard count >= 0, count <= bitCount else { throw KaitoError.truncated }
        bitCount -= count
        buffer &= (1 << bitCount) - 1
    }

    @inline(__always)
    mutating func read(_ count: Int) throws -> Int {
        let value = try peekPadded(count)
        try consume(count)
        return value
    }

    mutating func beginRaw() throws {
        // 生データの直前は、既に整列していても一ワードのパディングを消費する。
        let padding = bitCount & 15
        guard try read(padding == 0 ? 16 : padding) == 0 else {
            throw KaitoError.malformed("cab LZX uncompressed alignment")
        }
        // Huffman の先読みで取り込んだ完全なワードをバイト列へ戻す。
        byteOffset -= bitCount / 8
        bitCount = 0
        buffer = 0
    }

    var remainingRawBytes: Int { input.count - byteOffset }

    mutating func readRawByte() throws -> UInt8 {
        guard bitCount == 0 else { throw KaitoError.malformed("cab LZX raw alignment") }
        guard byteOffset < input.count else { throw KaitoError.truncated }
        let byte = input[byteOffset]
        byteOffset += 1
        return byte
    }

    mutating func readRawOffset() throws -> Int {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try readRawByte()) << shift
        }
        return Int(value)
    }

    mutating func finishFrame() throws {
        // フレーム末尾の未使用ビットだけを捨て、次フレームへ先読みを持ち越さない。
        guard bitCount < 16, byteOffset == input.count else {
            throw KaitoError.malformed("cab LZX trailing frame data")
        }
        bitCount = 0
        buffer = 0
    }
}
