// 指定資料 Ch.08 と Ch.42。宣言指数は保持せず、native の固定上限 (64,64,256) を使用する。
import Foundation

final class StuffItXIron: Decompressor {
    private final class Model {
        let range: StuffItXRangeDecoder
        let weights: UnsafeMutablePointer<UInt32>
        let counts: UnsafeMutablePointer<UInt32>
        let list: UnsafeMutablePointer<UInt8>
        let ranks: UnsafeMutablePointer<Int>
        let scores: UnsafeMutablePointer<UInt32>
        let shifts: (Int, Int, Int, Int, Int, Int)
        var previousByte = 0
        var previousWidth = 0
        var classHistory = 0
        var runHistory = 0

        init(range: StuffItXRangeDecoder, shifts: (Int, Int, Int, Int, Int, Int)) {
            self.range = range; self.shifts = shifts
            weights = .allocate(capacity: 9352); weights.initialize(repeating: 2048, count: 9352)
            counts = .allocate(capacity: 5124); counts.initialize(repeating: 0, count: 5124)
            for i in 0..<4 { counts[i] = 1 }
            list = .allocate(capacity: 256); ranks = .allocate(capacity: 256); scores = .allocate(capacity: 256)
            scores.initialize(repeating: 0, count: 256)
            for i in 0..<256 { list[i] = UInt8(i); ranks[i] = i }
        }
        deinit { weights.deallocate(); counts.deallocate(); list.deallocate(); ranks.deallocate(); scores.deallocate() }
        @inline(__always) private func update(_ index: Int, shift: Int, bit: Int) {
            if bit == 0 { weights[index] += (4096 - weights[index]) >> shift }
            else { weights[index] -= weights[index] >> shift }
        }
        @inline(__always) func bit(_ a: Int, _ sa: Int, _ b: Int? = nil, _ sb: Int = 0) throws -> Int {
            let w = b.map { (weights[a] + weights[$0]) / 2 } ?? weights[a]
            let bit = try range.count(total: 4096) < w ? 0 : 1
            try range.select(start: bit == 0 ? 0 : w, frequency: bit == 0 ? w : 4096 - w)
            update(a, shift: sa, bit: bit)
            if let b { update(b, shift: sb, bit: bit) }; return bit
        }
        private func increment(_ base: Int, selected: Int, limit: UInt32, rounding: UInt32) {
            counts[base + selected] += 2
            let total = counts[base] + counts[base + 1] + counts[base + 2] + counts[base + 3]
            if total > limit { for i in 0..<4 { counts[base + i] = (counts[base + i] + rounding) / 2 } }
        }
        func rank() throws -> Int {
            let b = 4 + previousByte * 4, h = 1028 + ((runHistory & 3) * 256 + classHistory) * 4
            var total: UInt32 = 0
            for i in 0..<4 { total += counts[i] + counts[b + i] + counts[h + i] }
            let value = try range.count(total: total)
            var cumulative: UInt32 = 0, selected = 0
            for i in 0..<4 {
                let frequency = counts[i] + counts[b + i] + counts[h + i]
                if value < cumulative + frequency {
                    try range.select(start: cumulative, frequency: frequency); selected = i; break
                }
                cumulative += frequency
            }
            increment(0, selected: selected, limit: 64, rounding: 1)
            increment(b, selected: selected, limit: 64, rounding: 0)
            increment(h, selected: selected, limit: 256, rounding: 0)
            if selected < 3 { return selected }
            var k = 0
            while k < 6, try bit(k, shifts.0, 8 + previousWidth * 8 + k, shifts.1) != 0 { k += 1 }
            var node = 1
            for _ in 0...k { node = node * 2 + (try bit(72 + k * 128 + node, shifts.2)) }
            previousWidth = k; return node + 1
        }
        func select(_ index: Int, fancy: Bool, history: UnsafeMutablePointer<UInt8>, run: Int) -> UInt8 {
            let byte = list[index], x = Int(byte)
            if fancy { scores[x] &+= 0x4000 }
            var i = index
            while i > 0 { list[i] = list[i - 1]; ranks[Int(list[i])] = i; i -= 1 }
            list[0] = byte; ranks[x] = 0; history[run] = byte
            if fancy {
                for j in 0..<12 where run >= 1 << j {
                    let old = Int(history[run - (1 << j)])
                    scores[old] &-= j == 0 ? 0x3801 : 0x800 >> j
                    if old == x { continue }
                    var p = ranks[old]
                    while p < 255, scores[Int(list[p + 1])] > scores[old] {
                        list[p] = list[p + 1]; ranks[Int(list[p])] = p; p += 1
                    }
                    list[p] = UInt8(old); ranks[old] = p
                }
            }
            return byte
        }
        func runLength(byte: UInt8, rank: Int) throws -> Int {
            let c = min(rank, 3), x = Int(byte)
            var q = 0
            while try bit(1096 + (c * 16 + runHistory) * 24 + q, shifts.3, 2632 + x * 24 + q, shifts.4) != 0 {
                q += 1
                guard q < 24 else { throw KaitoError.malformed("StuffIt X Iron run width") }
            }
            var length = 1
            for j in 0..<q { length = length * 2 + (try bit(8776 + q * 24 + j, shifts.5)) }
            classHistory = (classHistory * 4 + c) & 255
            runHistory = ((runHistory * 2) & 15) + (q > 1 ? 1 : 0); previousByte = x
            return length
        }
    }
    private let input: StuffItXBitReader
    private let limits: ReadLimits
    private let st4: Bool
    private let fancy: Bool
    private let shifts: (Int, Int, Int, Int, Int, Int)
    private var remaining: UInt64?
    private var produced: UInt64 = 0
    private var column: UnsafeMutablePointer<UInt8>?
    private var links: UnsafeMutablePointer<UInt32>?
    private var count = 0
    private var blockRemaining = 0
    private var index = 0
    private var raw = false
    private(set) var isFinished = false

    init(input: StuffItXBitReader, size: UInt64?, limits: ReadLimits) throws {
        self.input = input; self.limits = limits; remaining = size
        st4 = try input.bits(1) != 0; fancy = try input.bits(1) != 0
        // native は宣言指数から頻度上限を再計算しない。巨大な shift に変換しない。
        for _ in 0..<3 {
            guard try input.p2() <= 0x7fff_ffff else { throw KaitoError.malformed("StuffIt X Iron declared exponent") }
        }
        func shift() throws -> Int {
            let s = try input.p2()
            guard (1...31).contains(s) else { throw KaitoError.malformed("StuffIt X Iron probability shift") }
            return Int(s)
        }
        shifts = try (shift(), shift(), shift(), shift(), shift(), shift())
    }
    deinit { column?.deallocate(); links?.deallocate() }
    private func block() throws {
        input.align()
        if try input.bits(1) != 0 {
            guard remaining == nil || remaining == 0 else { throw KaitoError.truncated }
            input.align()
            guard input.isAtEnd else { throw KaitoError.malformed("StuffIt X Iron trailing bytes") }
            isFinished = true; return
        }
        let n = try input.p2()
        guard n <= 0x7fff_ffff else { throw KaitoError.malformed("StuffIt X Iron block size") }
        guard n <= (remaining ?? (limits.maxTotalUncompressedSize - produced)) else { throw KaitoError.malformed("StuffIt X Iron output length") }
        raw = try input.bits(1) != 0
        if raw {
            input.align()
            guard n <= input.source.length - input.offset else { throw KaitoError.truncated }
            count = Int(n); blockRemaining = count; return
        }
        let primary = try input.p2()
        guard n > 0, primary < n, !st4 || n < 1 << 23 else { throw KaitoError.malformed("StuffIt X Iron sort parameters") }
        try Checked.size(Checked.mul(n, 6), limit: limits.maxDictionarySize)
        input.align(); _ = try input.byte()
        let model = Model(range: try StuffItXRangeDecoder(input: input, explicitLower: false), shifts: shifts)
        column?.deallocate(); links?.deallocate()
        count = Int(n)
        let column = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        let links = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        self.column = column; self.links = links
        defer { scratch.deallocate() }
        var written = 0, run = 0
        while written < count {
            let rank = try model.rank(), byte = model.select((rank + 1) & 255, fancy: fancy, history: scratch, run: run)
            let length = try model.runLength(byte: byte, rank: rank)
            guard length <= count - written else { throw KaitoError.malformed("StuffIt X Iron run overrun") }
            (column + written).initialize(repeating: byte, count: length); written += length; run += 1
        }
        if st4 { try Self.inverseST4(column: column, links: links, marks: scratch, count: count) }
        else {
            withUnsafeTemporaryAllocation(of: Int.self, capacity: 256) { counts in
                counts.initialize(repeating: 0)
                for i in 0..<count { counts[Int(column[i])] += 1 }
                var sum = 0
                for b in 0..<256 { let n = counts[b]; counts[b] = sum; sum += n }
                for i in 0..<count { let b = Int(column[i]); links[counts[b]] = UInt32(i); counts[b] += 1 }
            }
        }
        index = Int(primary); blockRemaining = count
    }
    // pair bucket ごとの最初の出現で group を切り、alias は direct entry の可変 cursor を共有する。
    static func inverseST4(column: UnsafePointer<UInt8>, links: UnsafeMutablePointer<UInt32>, marks: UnsafeMutablePointer<UInt8>, count: Int) throws {
        let pairs = UnsafeMutablePointer<Int>.allocate(capacity: 65536)
        pairs.initialize(repeating: 0, count: 65536)
        defer { pairs.deallocate() }
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 256 * 4) { work in
            work.initialize(repeating: 0)
            let starts = work.baseAddress!, cursors = starts + 256, seen = cursors + 256, owners = seen + 256
            for i in 0..<count { cursors[Int(column[i])] += 1 }
            var sum = 0
            for b in 0..<256 { starts[b] = sum; sum += cursors[b] }
            for b in 0..<256 {
                for i in starts[b]..<(starts[b] + cursors[b]) { pairs[Int(column[i]) * 256 + b] += 1 }
                cursors[b] = starts[b]; seen[b] = -1
            }
            marks.update(repeating: 0, count: count)
            var begin = 0
            for pair in 0..<65536 {
                let end = begin + pairs[pair]
                for i in begin..<end {
                    let b = Int(column[i])
                    if seen[b] != pair { marks[cursors[b]] = 1; seen[b] = pair }
                    cursors[b] += 1
                }
                begin = end
            }
            for b in 0..<256 { cursors[b] = starts[b]; seen[b] = -1 }
            var group = 0
            for i in 0..<count {
                if marks[i] != 0 { group = i }
                let b = Int(column[i])
                if seen[b] != group { seen[b] = group; owners[b] = i; links[i] = UInt32(cursors[b]) }
                else { links[i] = UInt32(owners[b]) | 0x800000 }
                cursors[b] += 1
            }
        }
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        // 空の raw block は終端ではない。次の flag まで反復する。
        while blockRemaining == 0, !isFinished { try block() }
        if isFinished { return 0 }
        let n = min(buffer.count, blockRemaining), output = buffer.bindMemory(to: UInt8.self)
        for i in 0..<n {
            if raw { output[i] = try input.byte(); continue }
            if st4 {
                let entry = links![index], owner = entry & 0x800000 == 0 ? index : Int(entry & 0x7fffff)
                guard owner < count else { throw KaitoError.malformed("StuffIt X ST4 alias") }
                let target = links![owner]
                guard target < count else { throw KaitoError.malformed("StuffIt X ST4 cursor") }
                links![owner] += 1; index = Int(target)
            } else { index = Int(links![index]) }
            output[i] = column![index]
        }
        blockRemaining -= n; if remaining != nil { remaining! -= UInt64(n) }; produced += UInt64(n)
        return n
    }
}
