// D4: 各セルは 8 バイト。基底値は Int に拡張してから追加ビットと加算する。
struct ZstdSequenceCell: Sendable {
    var base: UInt32
    var nextBaseline: UInt16
    var stateBits: UInt8
    var extraBits: UInt8
}

// 3 種の表はフレームごとに所有し、初回の table mode でだけ確保する。
final class ZstdSequenceTable {
    private let maximumLog: Int
    private(set) var cells: UnsafeMutablePointer<ZstdSequenceCell>?
    private(set) var accuracyLog: Int?
    var allocatedBytes: Int { cells == nil ? 0 : (1 << maximumLog) * MemoryLayout<ZstdSequenceCell>.stride }

    init(maximumLog: Int) { self.maximumLog = maximumLog }
    deinit { cells?.deallocate() }

    private func reserve() -> UnsafeMutablePointer<ZstdSequenceCell> {
        if cells == nil { cells = .allocate(capacity: 1 << maximumLog) }
        return cells!
    }

    func predefined(_ table: [ZstdSequenceCell], log: Int) {
        let target = reserve()
        table.withUnsafeBufferPointer {
            // 固定表は kind の容量以下。全セルを初期化してから log を公開する。
            target.initialize(from: $0.baseAddress!, count: $0.count)
        }
        accuracyLog = log
    }

    func rle(symbol: Int, bases: [Int], bits: [Int]) throws {
        guard symbol < bases.count else { throw KaitoError.malformed("zstd RLE sequence symbol") }
        // byte 由来の symbol >= 0。基底と幅の配列長は同一で、1 セルを確保済み。
        reserve().initialize(to: ZstdSequenceCell(base: UInt32(bases[symbol]), nextBaseline: 0,
                                                  stateBits: 0, extraBits: UInt8(bits[symbol])))
        accuracyLog = 0
    }

    func build(probabilities: UnsafeMutableBufferPointer<Int>, count: Int, log: Int,
               bases: [Int], bits: [Int]) throws {
        guard (5...maximumLog).contains(log), count > 0, count <= bases.count,
              count <= probabilities.count else { throw KaitoError.malformed("zstd FSE probability sum") }
        let size = 1 << log
        var sum = 0, nonzero = 0
        for symbol in 0..<count {
            // count <= scratch.count。parse 済み領域だけを読む。
            let probability = probabilities[symbol]
            guard (-1...size).contains(probability) else { throw KaitoError.malformed("zstd FSE probability sum") }
            sum += abs(probability)
            if probability != 0 { nonzero += 1 }
        }
        guard sum == size, nonzero >= 2 else { throw KaitoError.malformed("zstd FSE probability sum") }
        let cells = reserve()
        var high = size - 1
        for symbol in 0..<count where probabilities[symbol] == -1 {
            // 確率総和 == size。-1 の個数は size 以下で high は必ず表内。
            cells[high] = ZstdSequenceCell(base: UInt32(symbol), nextBaseline: 0, stateBits: 0, extraBits: 0)
            high -= 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for symbol in 0..<count where probabilities[symbol] > 0 {
            for _ in 0..<probabilities[symbol] {
                // 奇数の step は全セルを巡回。正の確率があれば high 以下が必ず残る。
                cells[position] = ZstdSequenceCell(base: UInt32(symbol), nextBaseline: 0, stateBits: 0, extraBits: 0)
                repeat { position = (position + step) & (size - 1) } while position > high
            }
        }
        guard position == 0 else { throw KaitoError.malformed("zstd FSE spread") }
        // spread 後は正規化 scratch を次状態カウンタに再利用する。中間 symbols / Cell 配列は不要。
        for symbol in 0..<count { probabilities[symbol] = max(1, probabilities[symbol]) }
        for index in 0..<size {
            // 全 size セルを spread で初期化済み。仮の base は 0..<count の symbol。
            let symbol = Int(cells[index].base)
            let state = probabilities[symbol]
            probabilities[symbol] += 1
            let width = log - (Int.bitWidth - 1 - state.leadingZeroBitCount)
            let baseline = (state << width) - size
            guard width >= 0, width <= log, baseline >= 0, baseline + (1 << width) <= size else {
                throw KaitoError.malformed("zstd FSE state")
            }
            cells[index] = ZstdSequenceCell(base: UInt32(bases[symbol]), nextBaseline: UInt16(baseline),
                                             stateBits: UInt8(width), extraBits: UInt8(bits[symbol]))
        }
        accuracyLog = log
    }

    static func predefinedCells(_ fse: ZstdFSE, bases: [Int], bits: [Int]) -> [ZstdSequenceCell] {
        fse.cells.map {
            ZstdSequenceCell(base: UInt32(bases[$0.symbol]), nextBaseline: UInt16($0.baseline),
                             stateBits: UInt8($0.bits), extraBits: UInt8(bits[$0.symbol]))
        }
    }
}

// D-T: テストと計測から instance 単位で渡す経路選択。既定の pair 閾値 32768 は threshold sweep で選んだ値。
struct ZstdTuning: Sendable {
    enum MatchPath: Sendable { case automatic, eightByteChunks, byteThenPeriod }
    static let defaultPairTableThreshold: Int = 32768
    var pairTableThreshold: Int = Self.defaultPairTableThreshold
    var huffmanFastLoop = true
    var matchPath: MatchPath = .automatic
    static let `default` = Self()
}
