// RFC 8878 §4.1.1 の正規化分布、状態配置、状態遷移を実装する。
struct ZstdFSE: Sendable {
    struct Cell: Sendable {
        let symbol: Int
        let bits: Int
        let baseline: Int
    }

    let accuracyLog: Int
    let cells: [Cell]

    init(symbol: Int) {
        accuracyLog = 0
        cells = [Cell(symbol: symbol, bits: 0, baseline: 0)]
    }

    init(probabilities: [Int], accuracyLog: Int) throws {
        guard (5...9).contains(accuracyLog), !probabilities.isEmpty, probabilities.count <= 256,
              probabilities.allSatisfy({ (-1...(1 << accuracyLog)).contains($0) }),
              probabilities.reduce(0, { $0 + abs($1) }) == 1 << accuracyLog,
              probabilities.filter({ $0 != 0 }).count >= 2 else {
            throw KaitoError.malformed("zstd FSE probability sum")
        }
        self.accuracyLog = accuracyLog
        let size = 1 << accuracyLog
        var symbols = [Int](repeating: 0, count: size)
        var high = size - 1
        for (symbol, count) in probabilities.enumerated() where count == -1 {
            symbols[high] = symbol
            high -= 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        // 奇数の歩幅は 2 の冪の全セルを巡回する。正の確率があれば high 以下のセルが必ず残る。
        var position = 0
        for (symbol, count) in probabilities.enumerated() where count > 0 {
            for _ in 0..<count {
                symbols[position] = symbol
                repeat { position = (position + step) & (size - 1) } while position > high
            }
        }
        guard position == 0 else { throw KaitoError.malformed("zstd FSE spread") }
        var next = probabilities.map { max(1, $0) }
        var table: [Cell] = []
        table.reserveCapacity(size)
        for symbol in symbols {
            let state = next[symbol]
            next[symbol] += 1
            let bits = accuracyLog - (Int.bitWidth - 1 - state.leadingZeroBitCount)
            table.append(Cell(symbol: symbol, bits: bits, baseline: (state << bits) - size))
        }
        cells = table
    }

    static func read(from reader: inout ZstdByteReader, maximumLog: Int, maximumSymbol: Int) throws -> Self {
        var bits = ZstdForwardBits(reader)
        let log = try bits.read(4) + 5
        guard log <= maximumLog else { throw KaitoError.malformed("zstd FSE accuracy log") }
        var remaining = 1 << log
        var probabilities: [Int] = []
        while remaining > 0 {
            guard probabilities.count <= maximumSymbol else {
                throw KaitoError.malformed("zstd FSE symbol count")
            }
            let maximum = remaining + 1
            let width = Int.bitWidth - maximum.leadingZeroBitCount
            let shortCount = (1 << width) - 1 - maximum
            var value = try bits.read(width - 1)
            if value >= shortCount {
                value += try bits.read(1) << (width - 1)
                if value >= 1 << (width - 1) { value -= shortCount }
            }
            let probability = value - 1
            guard abs(probability) <= remaining else {
                throw KaitoError.malformed("zstd FSE probability overflow")
            }
            probabilities.append(probability)
            remaining -= abs(probability)
            if probability == 0 {
                var repeatCount: Int
                repeat {
                    repeatCount = try bits.read(2)
                    guard repeatCount <= maximumSymbol + 1 - probabilities.count else {
                        throw KaitoError.malformed("zstd FSE zero run")
                    }
                    probabilities.append(contentsOf: repeatElement(0, count: repeatCount))
                } while repeatCount == 3
            }
        }
        _ = try reader.take((bits.position + 7) / 8 - reader.position)
        return try Self(probabilities: probabilities, accuracyLog: log)
    }

    @inline(__always)
    func cell(_ state: Int) throws -> Cell {
        guard cells.indices.contains(state) else { throw KaitoError.malformed("zstd FSE state") }
        return cells[state]
    }

    // RFC 8878 §3.1.1.3.2.2 の確率表。実装ソースからの転記ではない。
    static let literalDistribution = [
        4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1
    ]
    static let matchDistribution = [
        1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
        1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1
    ]
    static let offsetDistribution = [
        1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1
    ]
}
