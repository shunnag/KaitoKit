// 指定レポート Ch.04 の LZAH の散文と独立 vector に基づく。
import Foundation

final class StuffItLZAH: Decompressor {
    private struct Node {
        var weight = 1
        var left = -1
        var right = -1
        var parent = -1
        var slot = 0
        var symbol = -1
    }
    private let input: StuffItPackedInput
    private let nodes: UnsafeMutablePointer<Node>
    private let order: UnsafeMutablePointer<Int>
    private let history: UnsafeMutablePointer<UInt8>
    private let distance: StuffItPrefixTree
    private var position = 0
    private var remaining: UInt64
    private var pending = 0
    private var copyDistance = 0
    var isFinished: Bool { remaining == 0 }

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(UInt64(627 * (MemoryLayout<Node>.stride + MemoryLayout<Int>.stride)
                               + (64 * 32 + 1) * 3 * MemoryLayout<Int>.stride + 4096), limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        distance = try .canonical([3] + Array(repeating: 4, count: 3) + Array(repeating: 5, count: 8)
                                  + Array(repeating: 6, count: 12) + Array(repeating: 7, count: 24) + Array(repeating: 8, count: 16))
        nodes = .allocate(capacity: 627); nodes.initialize(repeating: Node(), count: 627)
        order = .allocate(capacity: 627)
        for i in 0..<627 {
            order[i] = i; nodes[i].slot = i
            if i > 0 { nodes[i].parent = (i - 1) / 2 }
            if i >= 313 { nodes[i].symbol = 626 - i }
        }
        for i in stride(from: 312, through: 0, by: -1) {
            nodes[i].left = 2 * i + 1; nodes[i].right = 2 * i + 2
            nodes[i].weight = nodes[2 * i + 1].weight + nodes[2 * i + 2].weight
        }
        history = .allocate(capacity: 4096); history.initialize(repeating: 0, count: 4096)
        for b in 0..<256 {
            for j in 0..<13 { history[18 + 13 * b + j] = UInt8(b) }
            history[3346 + b] = UInt8(b); history[3602 + b] = UInt8(255 - b)
        }
        for i in 3986..<4096 { history[i] = 32 }
    }
    deinit { nodes.deallocate(); order.deallocate(); history.deallocate() }

    private func exchange(_ a: Int, _ b: Int) {
        let pa = nodes[a].parent, pb = nodes[b].parent
        let aLeft = nodes[pa].left == a, bLeft = nodes[pb].left == b
        if aLeft { nodes[pa].left = b } else { nodes[pa].right = b }
        if bLeft { nodes[pb].left = a } else { nodes[pb].right = a }
        nodes[a].parent = pb; nodes[b].parent = pa
        let sa = nodes[a].slot, sb = nodes[b].slot
        order[sa] = b; order[sb] = a; nodes[a].slot = sb; nodes[b].slot = sa
    }

    private func rescale() {
        // 低重み側から既存 leaf 順を保つ。同重みの新 parent は既存項目の後に入れる。
        var available: [Int] = []
        available.reserveCapacity(314)
        for slot in stride(from: 626, through: 0, by: -1) {
            let node = order[slot]
            if nodes[node].symbol >= 0 {
                nodes[node].weight = (nodes[node].weight + 1) / 2
                available.append(node)
            }
        }
        var slot = 626
        for parent in 0..<313 {
            let right = available.removeFirst(), left = available.removeFirst()
            for child in [right, left] {
                order[slot] = child; nodes[child].slot = slot; nodes[child].parent = parent; slot -= 1
            }
            nodes[parent].left = left; nodes[parent].right = right
            nodes[parent].weight = nodes[left].weight + nodes[right].weight
            let insertion = available.firstIndex { nodes[$0].weight > nodes[parent].weight } ?? available.count
            available.insert(parent, at: insertion)
        }
        let root = available[0]
        order[0] = root; nodes[root].slot = 0; nodes[root].parent = -1
    }

    private func symbol() throws -> Int {
        var node = order[0]
        while nodes[node].symbol < 0 {
            node = try input.bits(1, lsb: false) == 1 ? nodes[node].left : nodes[node].right
        }
        let result = nodes[node].symbol
        if nodes[order[0]].weight == 0x8000 { rescale() }
        while node >= 0 {
            nodes[node].weight += 1
            var slot = nodes[node].slot
            while slot > 0 && nodes[order[slot - 1]].weight < nodes[node].weight { slot -= 1 }
            if slot != nodes[node].slot { exchange(node, order[slot]) }
            node = nodes[node].parent
        }
        return result
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            let byte: UInt8
            if pending == 0 {
                let token = try symbol()
                if token < 256 { byte = UInt8(token) }
                else {
                    pending = token - 253
                    copyDistance = 64 * (try distance.decode(input, lsb: false)) + (try input.bits(6, lsb: false)) + 1
                    guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt LZAH match extent") }
                    byte = history[(position - copyDistance) & 4095]; pending -= 1
                }
            } else { byte = history[(position - copyDistance) & 4095]; pending -= 1 }
            destination[i] = byte; history[position] = byte; position = (position + 1) & 4095; remaining -= 1
        }
        return count
    }
}
