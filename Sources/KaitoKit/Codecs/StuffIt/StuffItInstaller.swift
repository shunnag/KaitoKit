// 指定レポート Ch.04 の installer の木記述・不安定 partition・距離式に基づく。
import Foundation

final class StuffItInstaller: Decompressor {
    private let input: StuffItPackedInput
    private let history: UnsafeMutablePointer<UInt8>
    private var literals: StuffItPrefixTree?
    private var distances: StuffItPrefixTree?
    private var blocks: Int
    private var blockRemaining: UInt64 = 0
    private var remaining: UInt64
    private var position = 0
    private var pending = 0
    private var copyDistance = 0
    static let maximumTreeDepth = 16
    var isFinished: Bool { remaining == 0 }

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        // 主木・距離木・入れ子の meta 木が同時に生存する最大領域を計上する。
        let nodes = (308 + 75 + Self.maximumTreeDepth * 32) * 38 + 2 + Self.maximumTreeDepth
        try Checked.size(UInt64(262_144 + nodes * 3 * MemoryLayout<Int>.stride), limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        blocks = try input.bits(16, lsb: true)
        history = .allocate(capacity: 262_144); history.initialize(repeating: 0, count: 262_144)
    }
    deinit { history.deallocate() }

    static func orderedSymbols(_ lengths: [Int]) -> [Int] {
        var symbols = Array(lengths.indices)
        var ranges: [(Int, Int)] = lengths.count > 1 ? [(0, lengths.count - 1)] : []
        while let (low, high) = ranges.popLast() {
            let pivot = lengths[symbols[low]]
            var left = low + 1, right = high
            while true {
                while left <= high && lengths[symbols[left]] < pivot { left += 1 }
                while right > low && lengths[symbols[right]] > pivot { right -= 1 }
                if left >= right { break }
                symbols.swapAt(left, right); left += 1; right -= 1
            }
            symbols.swapAt(low, right)
            if right - low > 1 { ranges.append((low, right - 1)) }
            if high - right > 1 { ranges.append((right + 1, high)) }
        }
        return symbols
    }

    private static func tree(_ count: Int, input: StuffItPackedInput, depth: Int = 0) throws -> StuffItPrefixTree {
        guard depth < maximumTreeDepth else { throw KaitoError.malformed("StuffIt installer meta depth") }
        let absent = try input.bits(1, lsb: true) != 0
        let width = try input.bits(2, lsb: true) + 2
        let bias = try input.bits(3, lsb: true) + 1
        let useMeta = try input.bits(2, lsb: true) & 1 != 0
        let meta = try useMeta ? tree(1 << width, input: input, depth: depth + 1) : nil
        func token() throws -> Int { try meta?.decode(input, lsb: true) ?? input.bits(width, lsb: true) }
        let maximum = (1 << width) - 1
        var lengths: [Int] = []
        lengths.reserveCapacity(count)
        while lengths.count < count {
            let value = try token()
            if value == maximum {
                guard let previous = lengths.last else { throw KaitoError.malformed("StuffIt installer initial repeat") }
                let run = try token() + 3
                guard run <= count - lengths.count else { throw KaitoError.malformed("StuffIt installer length run") }
                lengths.append(contentsOf: repeatElement(previous, count: run))
            } else { lengths.append(absent && value == maximum - 1 ? 0 : value + bias) }
        }
        input.alignToByte()
        let result = StuffItPrefixTree(capacity: count * 38 + 1)
        var code: UInt64 = 0, previousLength = 0
        for symbol in orderedSymbols(lengths) where lengths[symbol] > 0 {
            let length = lengths[symbol]
            code <<= length - previousLength
            try result.insert(symbol: symbol, code: code, length: length)
            code += 1; previousLength = length
        }
        return result
    }

    private func startBlock() throws {
        while blockRemaining == 0 {
            guard blocks > 0 else { throw KaitoError.truncated }
            input.alignToByte()
            _ = try input.bits(32, lsb: true)
            blockRemaining = UInt64(try input.bits(32, lsb: true)); blocks -= 1
            guard blockRemaining <= remaining else { throw KaitoError.malformed("StuffIt installer block extent") }
            // 前 block の表は破棄し、履歴だけを維持する。
            literals = nil; distances = nil
            literals = try Self.tree(308, input: input)
            distances = try Self.tree(75, input: input)
        }
    }

    private func value(_ symbol: Int, distance: Bool) throws -> Int {
        let threshold = distance ? 3 : 4
        var base = distance ? 1 : 4
        for i in 0..<symbol { base += 1 << (i < threshold ? 0 : (i - threshold) / 4) }
        let extra = symbol < threshold ? 0 : (symbol - threshold) / 4
        return try base + input.bits(extra, lsb: true)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            let byte: UInt8
            if pending == 0 {
                if blockRemaining == 0 { try startBlock() }
                guard let literals, let distances else { throw KaitoError.malformed("StuffIt installer missing trees") }
                let token = try literals.decode(input, lsb: true)
                if token < 256 { byte = UInt8(token) }
                else {
                    pending = try value(token - 256, distance: false)
                    copyDistance = try value(distances.decode(input, lsb: true), distance: true)
                    guard UInt64(pending) <= blockRemaining else { throw KaitoError.malformed("StuffIt installer match extent") }
                    byte = history[(position - copyDistance) & 262_143]; pending -= 1
                }
            } else { byte = history[(position - copyDistance) & 262_143]; pending -= 1 }
            destination[i] = byte; history[position] = byte; position = (position + 1) & 262_143
            remaining -= 1; blockRemaining -= 1
        }
        return count
    }
}
