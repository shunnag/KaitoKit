// RFC 8878 §4.2 の重み表から最大 11 ビットの直接参照表を作る。
struct ZstdHuffman {
    struct Cell {
        let symbol: UInt8
        let bits: Int
    }
    let maximumBits: Int
    let cells: [Cell]

    init(weights: [Int]) throws {
        guard !weights.isEmpty, weights.count <= 255,
              weights.allSatisfy({ (0...11).contains($0) }) else {
            throw KaitoError.malformed("zstd Huffman weights")
        }
        let sum = weights.reduce(0) { $0 + ($1 == 0 ? 0 : 1 << ($1 - 1)) }
        guard sum > 0 else { throw KaitoError.malformed("zstd empty Huffman tree") }
        let log = Int.bitWidth - sum.leadingZeroBitCount
        guard log <= 11 else { throw KaitoError.malformed("zstd Huffman depth") }
        let remainder = (1 << log) - sum
        guard remainder > 0, remainder & (remainder - 1) == 0 else {
            throw KaitoError.malformed("zstd Huffman weight sum")
        }
        let allWeights = weights + [remainder.trailingZeroBitCount + 1]
        // 最深段には兄弟の葉が必要。重み 1 が無い表は、導出した深度と符号長が一致しない。
        let deepest = allWeights.filter { $0 == 1 }.count
        guard deepest >= 2, deepest.isMultiple(of: 2) else {
            throw KaitoError.malformed("zstd Huffman deepest rank")
        }
        var table: [Cell] = []
        table.reserveCapacity(1 << log)
        for weight in 1...log {
            for (symbol, value) in allWeights.enumerated() where value == weight {
                table.append(contentsOf: repeatElement(
                    Cell(symbol: UInt8(symbol), bits: log + 1 - weight), count: 1 << (weight - 1)
                ))
            }
        }
        guard table.count == 1 << log else { throw KaitoError.malformed("zstd Huffman table") }
        maximumBits = log
        cells = table
    }

    static func read(from reader: inout ZstdByteReader) throws -> Self {
        let header = try reader.byte()
        var weights: [Int] = []
        weights.reserveCapacity(255)
        if header >= 128 {
            let count = header - 127
            for index in 0..<((count + 1) / 2) {
                let byte = try reader.byte()
                weights.append(byte >> 4)
                if index * 2 + 1 < count { weights.append(byte & 15) }
            }
        } else {
            var section = try reader.subreader(header)
            let table = try ZstdFSE.read(from: &section, maximumLog: 6, maximumSymbol: 11)
            var bits = try ZstdBitReader(section.bytes, range: section.position..<section.end)
            var state1 = try bits.read(table.accuracyLog)
            var state2 = try bits.read(table.accuracyLog)
            var terminated = false
            while weights.count < 255 {
                let cell = try table.cell(state1)
                weights.append(cell.symbol)
                if cell.bits > bits.remaining {
                    // 最後の二状態は遷移に必要なビットを持たない。もう一方の記号で終わる。
                    weights.append(try table.cell(state2).symbol)
                    terminated = true
                    break
                }
                state1 = cell.baseline + (try bits.read(cell.bits))
                swap(&state1, &state2)
            }
            guard terminated, weights.count <= 255 else { throw KaitoError.malformed("zstd Huffman weight count") }
        }
        return try Self(weights: weights)
    }

    func decode(from reader: inout ZstdByteReader, count: Int, fourStreams: Bool) throws -> [UInt8] {
        var sizes: [Int]
        if fourStreams {
            sizes = [Int(try reader.integer(2)), Int(try reader.integer(2)), Int(try reader.integer(2))]
            let used = sizes.reduce(0, +)
            guard used < reader.remaining else { throw KaitoError.malformed("zstd Huffman jump table") }
            sizes.append(reader.remaining - used)
        } else {
            sizes = [reader.remaining]
        }
        let segment = fourStreams ? (count + 3) / 4 : count
        guard !fourStreams || 3 * segment <= count else {
            throw KaitoError.malformed("zstd Huffman segment sizes")
        }
        var output: [UInt8] = []
        output.reserveCapacity(count)
        for (index, size) in sizes.enumerated() {
            var bits = try ZstdBitReader(reader.bytes, range: reader.take(size))
            let length = index == sizes.count - 1 ? count - output.count : segment
            for _ in 0..<length {
                let code = bits.peekPadded(maximumBits)
                let cell = cells[code]
                _ = try bits.read(cell.bits)
                output.append(cell.symbol)
            }
            guard bits.remaining == 0 else { throw KaitoError.malformed("zstd Huffman trailing bits") }
        }
        return output
    }
}
