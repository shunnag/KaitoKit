// D4: 各セルは 16 バイト。基底値は Int に拡張してから追加ビットと加算する。
// 状態遷移に使う値は hot loop が shift と mask だけで次 cell の pointer を得られる形で持つ:
// stateMask は (2^stateBits - 1) << 4（値 × 16 = cell の byte offset）、next は遷移先 baseline の cell。
// field ごとの narrow load のまま使う（1 word に詰めて shift で取り出す形は依存鎖を延ばし wall clock で劣った）。
struct ZstdSequenceCell {
    var base: UInt32
    var extraBits: UInt8
    var stateBits: UInt8
    var stateMask: UInt16
    var next: UnsafePointer<ZstdSequenceCell>
}

/// 固定表と RLE が持つ frame に依存しない cell の記述。表へ写すときに next pointer を解決する。
struct ZstdSequenceCellTemplate: Sendable {
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
        // 一度だけ確保し、cell 内の next pointer が表の寿命中ずっと有効になる。
        if cells == nil { cells = .allocate(capacity: 1 << maximumLog) }
        return cells!
    }

    /// stateBits <= 9、baseline < 2^maximumLog を呼出側が検証済み。
    private static func cell(base: UInt32, extraBits: UInt8, stateBits: Int, baseline: Int,
                             in table: UnsafeMutablePointer<ZstdSequenceCell>) -> ZstdSequenceCell {
        ZstdSequenceCell(base: base, extraBits: extraBits, stateBits: UInt8(truncatingIfNeeded: stateBits),
                         stateMask: UInt16(truncatingIfNeeded: ((1 << stateBits) - 1) << 4),
                         next: UnsafePointer(table + baseline))
    }

    func predefined(_ table: [ZstdSequenceCellTemplate], log: Int) {
        let target = reserve()
        // 固定表は kind の容量以下。全セルを初期化してから log を公開する。
        for (index, template) in table.enumerated() {
            (target + index).initialize(to: Self.cell(base: template.base, extraBits: template.extraBits,
                                                      stateBits: Int(template.stateBits),
                                                      baseline: Int(template.nextBaseline), in: target))
        }
        accuracyLog = log
    }

    func rle(symbol: Int, bases: [Int], bits: [Int]) throws {
        guard symbol < bases.count else { throw KaitoError.malformed("zstd RLE sequence symbol") }
        // byte 由来の symbol >= 0。基底と幅の配列長は同一で、1 セルを確保済み。遷移先は常に自分自身。
        let target = reserve()
        target.initialize(to: Self.cell(base: UInt32(bases[symbol]), extraBits: UInt8(bits[symbol]),
                                        stateBits: 0, baseline: 0, in: target))
        accuracyLog = 0
    }

    func build(probabilities: UnsafeMutableBufferPointer<Int>, count: Int, log: Int,
               bases: [Int], bits: [Int]) throws {
        guard (5...maximumLog).contains(log), count > 0, count <= bases.count,
              count <= probabilities.count else { throw KaitoError.malformed("zstd FSE probability sum") }
        let size = 1 << log
        // count <= scratch.count。parse 済み領域だけを読む。
        let distribution = probabilities.baseAddress!
        var sum = 0, nonzero = 0
        for symbol in 0..<count {
            let probability = distribution[symbol]
            guard (-1...size).contains(probability) else { throw KaitoError.malformed("zstd FSE probability sum") }
            sum &+= abs(probability)
            if probability != 0 { nonzero &+= 1 }
        }
        guard sum == size, nonzero >= 2 else { throw KaitoError.malformed("zstd FSE probability sum") }
        let cells = reserve()
        var high = size - 1
        for symbol in 0..<count where distribution[symbol] == -1 {
            // 確率総和 == size。-1 の個数は size 以下で high は必ず表内。
            cells[high] = Self.cell(base: UInt32(truncatingIfNeeded: symbol), extraBits: 0, stateBits: 0, baseline: 0, in: cells)
            high &-= 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for symbol in 0..<count {
            let probability = distribution[symbol]
            if probability <= 0 { continue }
            let cell = Self.cell(base: UInt32(truncatingIfNeeded: symbol), extraBits: 0, stateBits: 0, baseline: 0, in: cells)
            for _ in 0..<probability {
                // 奇数の step は全セルを巡回。正の確率があれば high 以下が必ず残る。
                cells[position] = cell
                repeat { position = (position &+ step) & (size - 1) } while position > high
            }
        }
        guard position == 0 else { throw KaitoError.malformed("zstd FSE spread") }
        // spread 後は正規化 scratch を次状態カウンタに再利用する。中間 symbols / Cell 配列は不要。
        for symbol in 0..<count { distribution[symbol] = max(1, distribution[symbol]) }
        try bases.withUnsafeBufferPointer { bases in
            try bits.withUnsafeBufferPointer { bits in
                for index in 0..<size {
                    // 全 size セルを spread で初期化済み。仮の base は 0..<count の symbol で、bases / bits の添字内。
                    let symbol = Int(cells[index].base)
                    let state = distribution[symbol]
                    distribution[symbol] = state &+ 1
                    let width = log &- (Int.bitWidth &- 1 &- state.leadingZeroBitCount)
                    let baseline = (state &<< width) &- size
                    guard width >= 0, width <= log, baseline >= 0, baseline + (1 << width) <= size else {
                        throw KaitoError.malformed("zstd FSE state")
                    }
                    // guard により baseline < size <= 512、width <= 9。基底値は RFC の表の定数で 2^31 以下。
                    cells[index] = Self.cell(base: UInt32(truncatingIfNeeded: bases[symbol]),
                                             extraBits: UInt8(truncatingIfNeeded: bits[symbol]),
                                             stateBits: width, baseline: baseline, in: cells)
                }
            }
        }
        accuracyLog = log
    }

    static func predefinedCells(_ fse: ZstdFSE, bases: [Int], bits: [Int]) -> [ZstdSequenceCellTemplate] {
        fse.cells.map {
            ZstdSequenceCellTemplate(base: UInt32(bases[$0.symbol]), nextBaseline: UInt16($0.baseline),
                                     stateBits: UInt8($0.bits), extraBits: UInt8(bits[$0.symbol]))
        }
    }
}
