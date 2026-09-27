// RFC 8878 §4.2 の重み表から最大 11 ビットの直接参照表を作る。
// D8: フレームが一つ所有し、type 2 でも領域を再利用する。type 3 は表と使用量も保持する。
final class ZstdHuffman {
    struct Cell {
        let symbol: UInt8
        let bits: UInt8
    }
    private struct Pair {
        let symbols: UInt16
        let bits: UInt8
        let count: UInt8
    }
    private var cells: UnsafeMutablePointer<Cell>?
    private var pairs: UnsafeMutablePointer<Pair>?
    private var pairCapacity = 0
    // D0/D8: 重み 256 個と rank count/start 各 12 個だけの固定上限。初回にのみ確保する。
    private var workspace: UnsafeMutableRawPointer?
    private static let workspaceBytes = 256 + 24 * MemoryLayout<Int>.stride
    private(set) var maximumBits = 0
    private var pairBits = 0
    private(set) var pairTableBuilt = false
    private(set) var decodedSymbols = 0

    var allocatedTableBytes: Int {
        (cells == nil ? 0 : 2_048 * MemoryLayout<Cell>.stride)
            + pairCapacity * MemoryLayout<Pair>.stride
            + (workspace == nil ? 0 : Self.workspaceBytes)
    }

    init() {}

    deinit {
        cells?.deallocate()
        pairs?.deallocate()
        workspace?.deallocate()
    }

    private func weightStorage() -> UnsafeMutablePointer<UInt8> {
        if workspace == nil {
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: Self.workspaceBytes,
                                                              alignment: MemoryLayout<Int>.alignment)
            allocation.bindMemory(to: UInt8.self, capacity: 256)
            allocation.advanced(by: 256).bindMemory(to: Int.self, capacity: 24)
            workspace = allocation
        }
        return workspace!.assumingMemoryBound(to: UInt8.self)
    }

    convenience init(weights: [Int]) throws {
        self.init()
        guard !weights.isEmpty, weights.count <= 255 else {
            throw KaitoError.malformed("zstd Huffman weights")
        }
        let target = weightStorage()
        for index in weights.indices {
            guard (0...11).contains(weights[index]) else { throw KaitoError.malformed("zstd Huffman weights") }
            // 検証済みの個数 <= 255、target の容量は 256。
            target[index] = UInt8(weights[index])
        }
        try buildTable(weightCount: weights.count)
    }

    private func buildTable(weightCount: Int) throws {
        guard weightCount > 0, weightCount <= 255 else { throw KaitoError.malformed("zstd Huffman weights") }
        let weights = weightStorage()
        let ranks = workspace!.advanced(by: 256).assumingMemoryBound(to: Int.self)
        let starts = ranks.advanced(by: 12)
        // D8: 各 rank は 0...11。小さい集計領域だけを初期化し、表全体は fill 時に一度書く。
        ranks.initialize(repeating: 0, count: 12)
        var sum = 0
        for index in 0..<weightCount {
            let weight = Int(weights[index])
            guard weight <= 11 else { throw KaitoError.malformed("zstd Huffman weights") }
            ranks[weight] += 1
            if weight > 0 { sum += 1 << (weight - 1) }
        }
        guard sum > 0 else { throw KaitoError.malformed("zstd empty Huffman tree") }
        let log = Int.bitWidth - sum.leadingZeroBitCount
        guard log <= 11 else { throw KaitoError.malformed("zstd Huffman depth") }
        let remainder = (1 << log) - sum
        guard remainder > 0, remainder & (remainder - 1) == 0 else {
            throw KaitoError.malformed("zstd Huffman weight sum")
        }
        let lastWeight = remainder.trailingZeroBitCount + 1
        // remainder < 2^log、従って lastWeight <= log <= 11。末尾の推定重みも確保内。
        weights[weightCount] = UInt8(lastWeight)
        ranks[lastWeight] += 1
        // 最深段には兄弟の葉が必要。重み 1 が無い表は、導出した深度と符号長が一致しない。
        guard ranks[1] >= 2, ranks[1].isMultiple(of: 2) else {
            throw KaitoError.malformed("zstd Huffman deepest rank")
        }
        var offset = 0
        for weight in 1...log {
            starts[weight] = offset
            offset += ranks[weight] << (weight - 1)
        }
        guard offset == 1 << log else { throw KaitoError.malformed("zstd Huffman table") }
        if cells == nil {
            // D0: 2-byte cell の上限自体が 4 KiB。初回の必要時にのみ確保し、全体のゼロ埋めはしない。
            cells = .allocate(capacity: 2_048)
        }
        let table = cells!
        for symbol in 0...weightCount {
            let weight = Int(weights[symbol])
            if weight == 0 { continue }
            let span = 1 << (weight - 1)
            // D8: rank ごとの互いに素な範囲で [0,2^log) を埋める。各 start + span <= 2^log <= 2048。
            table.advanced(by: starts[weight]).initialize(
                repeating: Cell(symbol: UInt8(symbol), bits: UInt8(log + 1 - weight)), count: span)
            starts[weight] += span
        }
        maximumBits = log
        pairBits = min(12, log * 2)
        // D9: 新しい type 2 は旧 pair を絶対に参照しない。割当だけ残し、使用量と有効フラグを戻す。
        pairTableBuilt = false
        decodedSymbols = 0
    }

    static func read(from reader: inout ZstdByteReader) throws -> ZstdHuffman {
        let result = ZstdHuffman()
        try result.readTable(from: &reader)
        return result
    }

    func readTable(from reader: inout ZstdByteReader) throws {
        let header = try reader.byte()
        let weights = weightStorage()
        var count = 0
        if header >= 128 {
            count = header - 127
            for index in 0..<((count + 1) / 2) {
                let byte = try reader.byte()
                // 直接記述の count <= 128、両 nibble の書込先は [0,count)。値は buildTable で検証する。
                weights[index * 2] = UInt8(byte >> 4)
                if index * 2 + 1 < count { weights[index * 2 + 1] = UInt8(byte & 15) }
            }
        } else {
            var section = try reader.subreader(header)
            // D8: FSE 重みの復号は従来の検査付き実装を維持する。
            let table = try ZstdFSE.read(from: &section, maximumLog: 6, maximumSymbol: 11)
            var bits = try ZstdBitReader(section.bytes, range: section.position..<section.end)
            var state1 = try bits.read(table.accuracyLog)
            var state2 = try bits.read(table.accuracyLog)
            var terminated = false
            while count < 255 {
                let cell = try table.cell(state1)
                // count < 255。終端のもう一記号も index <= 255 に収まり、総数は直後に検証する。
                weights[count] = UInt8(cell.symbol)
                count += 1
                if cell.bits > bits.remaining {
                    weights[count] = UInt8(try table.cell(state2).symbol)
                    count += 1
                    terminated = true
                    break
                }
                state1 = cell.baseline + (try bits.read(cell.bits))
                swap(&state1, &state2)
            }
            guard terminated, count <= 255 else { throw KaitoError.malformed("zstd Huffman weight count") }
        }
        try buildTable(weightCount: count)
    }

    private func buildPairs() {
        let needed = 1 << pairBits
        if needed > pairCapacity {
            // D0/D9: 4 KiB から必要量で倍増、上限 4096 cells。既存値は新しい表では不要。
            var capacity = max(1_024, pairCapacity)
            while capacity < needed { capacity *= 2 }
            pairs?.deallocate()
            pairs = .allocate(capacity: capacity)
            pairCapacity = capacity
        }
        let table = cells!, target = pairs!
        let mask = needed - 1
        for code in 0..<needed {
            // pairBits >= maximumBits、mask 後の index は構築済み単記号表の範囲内。
            let first = table[code >> (pairBits - maximumBits)]
            let next = ((code << Int(first.bits)) & mask) >> (pairBits - maximumBits)
            let second = table[next]
            let combined = Int(first.bits) + Int(second.bits)
            target[code] = combined <= pairBits
                ? Pair(symbols: UInt16(first.symbol) | (UInt16(second.symbol) << 8), bits: UInt8(combined), count: 2)
                : Pair(symbols: UInt16(first.symbol), bits: first.bits, count: 1)
        }
        pairTableBuilt = true
    }

    func decode(from reader: inout ZstdByteReader, count: Int, fourStreams: Bool,
                tuning: ZstdTuning = .default) throws -> [UInt8] {
        var result = try [UInt8](unsafeUninitializedCapacity: count + ZstdScratchBuffer.backPad) { output, initialized in
            try decode(from: &reader, count: count, fourStreams: fourStreams, tuning: tuning, into: output)
            initialized = count + ZstdScratchBuffer.backPad
        }
        result.removeLast(ZstdScratchBuffer.backPad)
        return result
    }

    func decode(from reader: inout ZstdByteReader, count: Int, fourStreams: Bool,
                tuning: ZstdTuning = .default, into output: UnsafeMutableBufferPointer<UInt8>) throws {
        precondition(count >= 0 && count <= output.count - ZstdScratchBuffer.backPad)
        defer { withExtendedLifetime(reader) {} }
        let sizes: (Int, Int, Int, Int)
        if fourStreams {
            let a = Int(try reader.integer(2)), b = Int(try reader.integer(2)), c = Int(try reader.integer(2))
            let used = a + b + c
            guard used < reader.remaining else { throw KaitoError.malformed("zstd Huffman jump table") }
            sizes = (a, b, c, reader.remaining - used)
        } else {
            sizes = (reader.remaining, 0, 0, 0)
        }
        let segment = fourStreams ? (count + 3) / 4 : count
        guard !fourStreams || 3 * segment <= count else { throw KaitoError.malformed("zstd Huffman segment sizes") }
        let total = decodedSymbols.addingReportingOverflow(count)
        let lifetimeCount = total.overflow ? Int.max : total.partialValue
        if !pairTableBuilt, tuning.pairTableThreshold != Int.max, lifetimeCount >= tuning.pairTableThreshold {
            buildPairs()
        }
        let input = reader.bytes
        let target = output.baseAddress!
        let table = cells!, pairs = pairTableBuilt ? self.pairs : nil
        if fourStreams {
            var a = try ZstdPaddedBitReader(input, range: reader.take(sizes.0))
            var b = try ZstdPaddedBitReader(input, range: reader.take(sizes.1))
            var c = try ZstdPaddedBitReader(input, range: reader.take(sizes.2))
            var d = try ZstdPaddedBitReader(input, range: reader.take(sizes.3))
            var p0 = 0, p1 = segment, p2 = segment * 2, p3 = segment * 3
            if tuning.huffmanFastLoop {
                if let pairs {
                    let width = pairBits, mask = (1 << width) - 1
                    while true {
                        let bits = min(a.remaining, b.remaining, c.remaining, d.remaining) / (4 * width)
                        let room = min(segment - p0, segment * 2 - p1, segment * 3 - p2, count - p3) / 8
                        let k = min(bits, room)
                        if k == 0 { break }
                        // D10: 各反復は最大 4*width <= 48 bits と 8 bytes。refill 後の未消費部 >= 57 bits。
                        for _ in 0..<k {
                            try a.refill(); try b.refill(); try c.refill(); try d.refill()
                            for _ in 0..<4 {
                                Self.decodePair(&a, output: target, position: &p0, pairs: pairs, width: width, mask: mask)
                                Self.decodePair(&b, output: target, position: &p1, pairs: pairs, width: width, mask: mask)
                                Self.decodePair(&c, output: target, position: &p2, pairs: pairs, width: width, mask: mask)
                                Self.decodePair(&d, output: target, position: &p3, pairs: pairs, width: width, mask: mask)
                            }
                        }
                    }
                } else {
                    let width = maximumBits, mask = (1 << width) - 1
                    while true {
                        let bits = min(a.remaining, b.remaining, c.remaining, d.remaining) / (5 * width)
                        let room = min(segment - p0, segment * 2 - p1, segment * 3 - p2, count - p3) / 5
                        let k = min(bits, room)
                        if k == 0 { break }
                        // D10: 単記号は各反復最大 5*width <= 55 bits、5 bytes。全 stream の最小 K を使う。
                        for _ in 0..<k {
                            try a.refill(); try b.refill(); try c.refill(); try d.refill()
                            for _ in 0..<5 {
                                Self.decodeSingle(&a, output: target, position: &p0, table: table, width: width, mask: mask)
                                Self.decodeSingle(&b, output: target, position: &p1, table: table, width: width, mask: mask)
                                Self.decodeSingle(&c, output: target, position: &p2, table: table, width: width, mask: mask)
                                Self.decodeSingle(&d, output: target, position: &p3, table: table, width: width, mask: mask)
                            }
                        }
                    }
                }
            }
            try finishStream(&a, output: target, position: p0, end: segment, table: table, pairs: pairs)
            try finishStream(&b, output: target, position: p1, end: segment * 2, table: table, pairs: pairs)
            try finishStream(&c, output: target, position: p2, end: segment * 3, table: table, pairs: pairs)
            try finishStream(&d, output: target, position: p3, end: count, table: table, pairs: pairs)
        } else {
            var bits = try ZstdPaddedBitReader(input, range: reader.take(sizes.0))
            var position = 0
            if tuning.huffmanFastLoop {
                if let pairs {
                    let width = pairBits, mask = (1 << width) - 1
                    while true {
                        let k = min(bits.remaining / (4 * width), (count - position) / 8)
                        if k == 0 { break }
                        // D10: 1 stream でも K は bits と出力の両方で制限し、4 lookup ごとに refill。
                        for _ in 0..<k {
                            try bits.refill()
                            for _ in 0..<4 {
                                Self.decodePair(&bits, output: target, position: &position, pairs: pairs, width: width, mask: mask)
                            }
                        }
                    }
                } else {
                    let width = maximumBits, mask = (1 << width) - 1
                    while true {
                        let k = min(bits.remaining / (5 * width), (count - position) / 5)
                        if k == 0 { break }
                        for _ in 0..<k {
                            try bits.refill()
                            for _ in 0..<5 {
                                Self.decodeSingle(&bits, output: target, position: &position, table: table, width: width, mask: mask)
                            }
                        }
                    }
                }
            }
            try finishStream(&bits, output: target, position: position, end: count, table: table, pairs: pairs)
        }
        // D0/D10: 全 stream の exact-end 検証後、有効出力直後の 32 bytes だけを初期化する。
        target.advanced(by: count).initialize(repeating: 0, count: ZstdScratchBuffer.backPad)
        decodedSymbols = lifetimeCount
    }

    @inline(__always)
    private static func decodePair(_ bits: inout ZstdPaddedBitReader, output: UnsafeMutablePointer<UInt8>,
                                   position: inout Int, pairs: UnsafePointer<Pair>, width: Int, mask: Int) {
        // D10: mask が構築済み表内を保証。K または tail の条件が最大 width bits と出力 2 bytes を予約する。
        let pair = pairs[bits.peekUnchecked(width) & mask]
        bits.dropUnchecked(Int(pair.bits))
        UnsafeMutableRawPointer(output).storeBytes(of: pair.symbols.littleEndian, toByteOffset: position, as: UInt16.self)
        position += Int(pair.count)
    }

    @inline(__always)
    private static func decodeSingle(_ bits: inout ZstdPaddedBitReader, output: UnsafeMutablePointer<UInt8>,
                                     position: inout Int, table: UnsafePointer<Cell>, width: Int, mask: Int) {
        // D10: K は単記号の最大 width bits と 1 byte を予約し、mask 後の index は表内。
        let cell = table[bits.peekUnchecked(width) & mask]
        bits.dropUnchecked(Int(cell.bits))
        output[position] = cell.symbol
        position += 1
    }

    private func finishStream(_ bits: inout ZstdPaddedBitReader, output: UnsafeMutablePointer<UInt8>,
                              position: Int, end: Int, table: UnsafePointer<Cell>, pairs: UnsafePointer<Pair>?) throws {
        var position = position
        if let pairs {
            let width = pairBits, mask = (1 << width) - 1
            while end - position >= 2, bits.remaining >= width {
                try bits.refill()
                Self.decodePair(&bits, output: output, position: &position, pairs: pairs, width: width, mask: mask)
            }
        }
        let width = maximumBits, mask = (1 << width) - 1
        while position < end {
            try bits.refill()
            let remaining = bits.remaining
            let available = min(width, remaining)
            // D10 tail: stream より前の byte は符号に含めずゼロを補う。実符号長 <= remaining の検証後だけ進む。
            let code = (bits.peekUnchecked(available) << (width - available)) & mask
            let cell = table[code]
            guard Int(cell.bits) <= remaining else { throw KaitoError.malformed("zstd bitstream underflow") }
            bits.dropUnchecked(Int(cell.bits))
            // position < end、end は検証済み segment 境界以内。
            output[position] = cell.symbol
            position += 1
        }
        guard bits.remaining == 0 else { throw KaitoError.malformed("zstd Huffman trailing bits") }
    }
}
