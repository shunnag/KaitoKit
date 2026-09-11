// Microsoft [MS-PATCH] v20160613 §2.4 の正準符号。外部の LZX 実装は参照していない。
struct LZXHuffmanTable {
    private static let fastBits = 10
    private let fast: [UInt32]
    private let counts: [Int]
    private let firstCodes: [Int]
    private let firstSymbols: [Int]
    private let symbols: [Int]

    init(lengths: [Int], allowEmpty: Bool = false) throws {
        guard !lengths.isEmpty, lengths.count <= 656 else {
            throw KaitoError.malformed("cab LZX Huffman alphabet")
        }
        var counts = [Int](repeating: 0, count: 17)
        for length in lengths {
            guard (0...16).contains(length) else { throw KaitoError.malformed("cab LZX Huffman length") }
            if length != 0 { counts[length] += 1 }
        }
        let populated = counts.reduce(0, +)
        var available = 1
        for length in 1...16 {
            available = (available << 1) - counts[length]
            guard available >= 0 else { throw KaitoError.malformed("cab LZX oversubscribed Huffman tree") }
        }
        // cabextract の実測で単一要素・長さ一の木は拒否された。未使用の空の補助木だけは許可する。
        guard available == 0 || (allowEmpty && populated == 0) else {
            throw KaitoError.malformed("cab LZX incomplete Huffman tree")
        }
        var firstCodes = [Int](repeating: 0, count: 17)
        var firstSymbols = [Int](repeating: 0, count: 17)
        var code = 0, index = 0
        for length in 1...16 {
            code = (code + counts[length - 1]) << 1
            firstCodes[length] = code
            firstSymbols[length] = index
            index += counts[length]
        }
        var nextCodes = firstCodes, nextSymbols = firstSymbols
        var symbols = [Int](repeating: 0, count: populated)
        var fast = [UInt32](repeating: 0, count: 1 << Self.fastBits)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let value = nextCodes[length]
            let index = nextSymbols[length]
            guard value < 1 << length, symbols.indices.contains(index) else {
                throw KaitoError.malformed("cab LZX Huffman code")
            }
            symbols[index] = symbol
            nextCodes[length] += 1
            nextSymbols[length] += 1
            if length <= Self.fastBits {
                let start = value << (Self.fastBits - length)
                let end = start + (1 << (Self.fastBits - length))
                guard end <= fast.count else { throw KaitoError.malformed("cab LZX Huffman table extent") }
                let record = UInt32(length << 16) | UInt32(symbol)
                for offset in start..<end { fast[offset] = record }
            }
        }
        self.fast = fast; self.counts = counts; self.firstCodes = firstCodes
        self.firstSymbols = firstSymbols; self.symbols = symbols
    }

    @inline(__always)
    func decode(_ bits: inout LZXBitReader) throws -> Int {
        let prefix = try bits.peekPadded(Self.fastBits)
        let record = fast[prefix]
        if record != 0 {
            try bits.consume(Int(record >> 16))
            return Int(record & 0xffff)
        }
        guard !symbols.isEmpty else { throw KaitoError.malformed("cab LZX empty Huffman tree used") }
        var code = 0
        for length in 1...16 {
            code = (code << 1) | (try bits.read(1))
            let relative = code - firstCodes[length]
            if relative >= 0, relative < counts[length] {
                let index = firstSymbols[length] + relative
                guard symbols.indices.contains(index) else { throw KaitoError.malformed("cab LZX Huffman symbol") }
                return symbols[index]
            }
        }
        throw KaitoError.malformed("cab LZX invalid Huffman code")
    }
}
