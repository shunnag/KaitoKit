// 指定資料 Ch.07 §4。モデルと M1FFN は block ごとに初期化する。
import Foundation

final class StuffItXCyanide: Decompressor {
    private final class Model {
        let size: Int
        let frequencies: UnsafeMutablePointer<UInt32>
        let meanings: UnsafeMutablePointer<Int>
        var total: UInt32
        init(_ size: Int) {
            self.size = size; total = UInt32(size)
            frequencies = .allocate(capacity: size); frequencies.initialize(repeating: 1, count: size)
            meanings = .allocate(capacity: size)
            for i in 0..<size { meanings[i] = size - 1 - i }
        }
        deinit { frequencies.deallocate(); meanings.deallocate() }
        func decode(_ range: StuffItXRangeDecoder) throws -> (Int, Int) {
            let count = try range.count(total: total)
            var start: UInt32 = 0
            for i in 0..<size {
                if count < start + frequencies[i] {
                    try range.select(start: start, frequency: frequencies[i]); return (meanings[i], i)
                }
                start += frequencies[i]
            }
            throw KaitoError.malformed("StuffIt X Cyanide model count")
        }
        @discardableResult func bump(_ slot: Int, limit: UInt32) -> Int {
            if total >= limit {
                total = 0
                for i in 0..<size { frequencies[i] = (frequencies[i] + 1) / 2; total += frequencies[i] }
            }
            var last = slot
            while last + 1 < size, frequencies[last + 1] == frequencies[slot] { last += 1 }
            let meaning = meanings[slot]; meanings[slot] = meanings[last]; meanings[last] = meaning
            frequencies[last] += 1; total += 1
            return last
        }
    }
    let input: StuffItXBitReader
    private let limits: ReadLimits
    private var remaining: UInt64
    private let knownLength: Bool
    private var column: UnsafeMutablePointer<UInt8>?
    private var permutation: UnsafeMutablePointer<UInt32>?
    private var blockRemaining = 0
    private var bwtIndex = 0
    private(set) var isFinished = false
    private static let groups = [0,1,2,3,4,5,6,7,8,3,9,10,3,4,5,11,11,8,6,2,5,6,7,8,12,12,13]

    init(input: StuffItXBitReader, size: UInt64?, limits: ReadLimits) throws {
        self.input = input; remaining = size ?? limits.maxTotalUncompressedSize; knownLength = size != nil; self.limits = limits; _ = try input.byte()
    }
    deinit { column?.deallocate(); permutation?.deallocate() }
    private func block() throws {
        let marker = try input.byte()
        if marker == 0xff && !knownLength { isFinished = true; return }
        guard marker == 0x77 else { throw KaitoError.malformed("StuffIt X Cyanide block marker") }
        let count = try Checked.toInt(input.packedBE(4)), primary = try Checked.toInt(input.packedBE(4))
        // n は全 byte 値を受け入れ、実際に復号した rank が 256 以上のときだけ拒否する。
        let n = Int(try input.byte())
        guard count > 0, primary < count, UInt64(count) <= remaining else {
            throw KaitoError.malformed("StuffIt X Cyanide block parameters")
        }
        try Checked.size(Checked.mul(UInt64(count), 6), limit: limits.maxDictionarySize)
        column?.deallocate(); permutation?.deallocate()
        let column = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        let permutation = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        self.column = column; self.permutation = permutation
        var lows: [Model] = [], remainder = n, h = 1
        while remainder > 0 {
            let size = remainder < 3 << h ? remainder : 1 << h
            lows.append(Model(size)); remainder -= size; h += 1
        }
        let high = Model(lows.count + 1), range = try StuffItXRangeDecoder(input: input, explicitLower: true)
        try withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 42) { counts in
            counts.initialize(repeating: 0)
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { list in
                for i in 0..<256 { list[i] = UInt8(i) }
                var history = 0, longZero = true, t = 1
                for i in 0..<count {
                    let group = Self.groups[history], start = group * 3
                    let a = counts[start], b = counts[start + 1], c = counts[start + 2]
                    let order: (Int, Int, Int)
                    if a < b {
                        if a < c { order = b < c ? (0,1,2) : (0,2,1) } else { order = (2,0,1) }
                    } else if b < c { order = c < a ? (1,2,0) : (1,0,2) }
                    else { order = (2,1,0) }
                    let total = a + b + c + 3, value = try range.count(total: total)
                    let first = counts[start + order.0] + 1, second = counts[start + order.1] + 1
                    let outcome: Int, cumulative: UInt32
                    if value < first { outcome = order.0; cumulative = 0 }
                    else if value < first + second { outcome = order.1; cumulative = first }
                    else { outcome = order.2; cumulative = first + second }
                    try range.select(start: cumulative, frequency: counts[start + outcome] + 1)
                    if outcome == 0 && !longZero && group == 0 {
                        longZero = true
                        for j in 0..<3 { counts[start + j] /= 2 }; counts[start] += 3
                    } else {
                        if outcome != 0 { longZero = false }
                        if total > (longZero ? 4096 : 128) { for j in 0..<3 { counts[start + j] /= 2 } }
                        counts[start + outcome] += 2
                    }
                    history = (history % 9) * 3 + outcome
                    let rank: Int
                    if outcome < 2 { rank = outcome }
                    else {
                        let (meaning, slot) = try high.decode(range)
                        high.bump(high.bump(slot, limit: 256), limit: 65_536)
                        if meaning == 0 { rank = 2 }
                        else {
                            let low = lows[meaning - 1], (value, slot) = try low.decode(range)
                            low.bump(slot, limit: UInt32(min(128 * low.size, 16_384)))
                            rank = (1 << meaning) + value + 1
                        }
                    }
                    guard rank < 256 else { throw KaitoError.malformed("StuffIt X Cyanide rank") }
                    let byte = list[rank]; column[i] = byte
                    if rank == 0 { t = 0 }
                    else if rank == 1 {
                        if t >= 2 { list[1] = list[0]; list[0] = byte }
                    } else {
                        for j in stride(from: rank, through: 2, by: -1) { list[j] = list[j - 1] }
                        list[1] = byte
                    }
                    t += 1
                }
            }
        }
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 256) { counts in
            counts.initialize(repeating: 0)
            for i in 0..<count { counts[Int(column[i])] += 1 }
            var total = 0
            for i in 0..<256 { let n = counts[i]; counts[i] = total; total += n }
            for i in 0..<count {
                let byte = Int(column[i]); permutation[counts[byte]] = UInt32(i); counts[byte] += 1
            }
        }
        blockRemaining = count; bwtIndex = primary
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        if remaining == 0 {
            guard blockRemaining == 0, try input.byte() == 0xff else { throw KaitoError.malformed("StuffIt X Cyanide terminator") }
            isFinished = true; return 0
        }
        if blockRemaining == 0 { try block() }
        if isFinished { return 0 }
        let n = min(buffer.count, blockRemaining), output = buffer.bindMemory(to: UInt8.self)
        for i in 0..<n {
            bwtIndex = Int(permutation![bwtIndex]); output[i] = column![bwtIndex]
        }
        blockRemaining -= n; remaining -= UInt64(n)
        return n
    }
}
