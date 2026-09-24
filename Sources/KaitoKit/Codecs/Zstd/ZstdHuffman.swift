// RFC 8878 §4.2 の重み表から最大 11 ビットの直接参照表を作る。
struct ZstdHuffman {
    struct Cell {
        let symbol: UInt8
        let bits: UInt8
    }
    private struct Pair {
        let first: UInt8
        let second: UInt8
        let bits: UInt8
        let count: UInt8
    }
    let maximumBits: Int
    let cells: [Cell]
    private let pairs: [Pair]
    private let pairBits: Int

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
                    Cell(symbol: UInt8(symbol), bits: UInt8(log + 1 - weight)), count: 1 << (weight - 1)
                ))
            }
        }
        guard table.count == 1 << log else { throw KaitoError.malformed("zstd Huffman table") }
        maximumBits = log
        cells = table
        let width = min(12, log * 2)
        pairBits = width
        pairs = (0..<(1 << width)).map { code in
            let first = table[code >> (width - log)]
            let next = ((code << Int(first.bits)) & ((1 << width) - 1)) >> (width - log)
            let second = table[next]
            let combined = Int(first.bits) + Int(second.bits)
            return combined <= width
                ? Pair(first: first.symbol, second: second.symbol, bits: UInt8(combined), count: 2)
                : Pair(first: first.symbol, second: 0, bits: first.bits, count: 1)
        }
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
            try section.bytes.withUnsafeBytes { bytes in
                var bits = try ZstdBitReader(bytes, range: section.position..<section.end)
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
        let bytes = reader.bytes
        return try [UInt8](unsafeUninitializedCapacity: count) { output, initialized in
            try bytes.withUnsafeBytes { input in
                try cells.withUnsafeBufferPointer { table in
                    try pairs.withUnsafeBufferPointer { pairs in
                        if fourStreams {
                            var a = try ZstdBitReader(input, range: reader.take(sizes[0]))
                            var b = try ZstdBitReader(input, range: reader.take(sizes[1]))
                            var c = try ZstdBitReader(input, range: reader.take(sizes[2]))
                            var d = try ZstdBitReader(input, range: reader.take(sizes[3]))
                            var p0 = 0, p1 = segment, p2 = segment * 2, p3 = segment * 3
                            // 独立な四つの状態を交互に進める。各書込みに 2 バイトの空きを保証する。
                            while p0 + 2 <= segment, p1 + 2 <= segment * 2,
                                  p2 + 2 <= segment * 3, p3 + 2 <= count,
                                  a.remaining >= pairBits, b.remaining >= pairBits,
                                  c.remaining >= pairBits, d.remaining >= pairBits {
                                decodePair(&a, output: output, position: &p0, pairs: pairs)
                                decodePair(&b, output: output, position: &p1, pairs: pairs)
                                decodePair(&c, output: output, position: &p2, pairs: pairs)
                                decodePair(&d, output: output, position: &p3, pairs: pairs)
                            }
                            try finishStream(&a, output: output, position: p0, end: segment, table: table, pairs: pairs)
                            try finishStream(&b, output: output, position: p1, end: segment * 2, table: table, pairs: pairs)
                            try finishStream(&c, output: output, position: p2, end: segment * 3, table: table, pairs: pairs)
                            try finishStream(&d, output: output, position: p3, end: count, table: table, pairs: pairs)
                        } else {
                            var bits = try ZstdBitReader(input, range: reader.take(sizes[0]))
                            try finishStream(&bits, output: output, position: 0, end: count, table: table, pairs: pairs)
                        }
                        initialized = count
                    }
                }
            }
        }
    }

    @inline(__always)
    private func decodePair(_ bits: inout ZstdBitReader, output: UnsafeMutableBufferPointer<UInt8>,
                            position: inout Int, pairs: UnsafeBufferPointer<Pair>) {
        // 呼出側で残り pairBits ビットと出力 2 バイトを保証。code < 2^pairBits == pairs.count。
        let pair = pairs[bits.peekPadded(pairBits)]
        bits.dropUnchecked(Int(pair.bits))
        output[position] = pair.first
        output[position + 1] = pair.second
        position += Int(pair.count)
    }

    private func finishStream(_ bits: inout ZstdBitReader, output: UnsafeMutableBufferPointer<UInt8>,
                              position: Int, end: Int, table: UnsafeBufferPointer<Cell>,
                              pairs: UnsafeBufferPointer<Pair>) throws {
        var position = position
        while end - position >= 2, bits.remaining >= pairBits {
            decodePair(&bits, output: output, position: &position, pairs: pairs)
        }
        while position < end {
            // code < table.count、position < end <= output.count。
            let cell = table[bits.peekPadded(maximumBits)]
            _ = try bits.read(Int(cell.bits))
            output[position] = cell.symbol
            position += 1
        }
        guard bits.remaining == 0 else { throw KaitoError.malformed("zstd Huffman trailing bits") }
    }

}
