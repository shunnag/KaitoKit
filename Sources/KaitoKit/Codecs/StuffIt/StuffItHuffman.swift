// Clean-room format inputs: 指定レポート Ch.04 の method 3・13 の木と canonical 規則に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

// 復号中の木は固定領域とし、各枝の値は構築時に検証する。
final class StuffItPrefixTree {
    private let children: UnsafeMutablePointer<Int>
    private let symbols: UnsafeMutablePointer<Int>
    private let capacity: Int
    private var count = 1

    init(capacity: Int) {
        self.capacity = capacity
        children = .allocate(capacity: capacity * 2); children.initialize(repeating: -1, count: capacity * 2)
        symbols = .allocate(capacity: capacity); symbols.initialize(repeating: -1, count: capacity)
    }
    deinit { children.deallocate(); symbols.deallocate() }
    private func newNode() throws -> Int {
        guard count < capacity else { throw KaitoError.malformed("StuffIt Huffman node limit") }
        let result = count; count += 1; return result
    }
    func explicit(input: StuffItPackedInput) throws {
        var stack = [(node: 0, depth: 0)]
        while let item = stack.popLast() {
            guard item.depth <= 256 else { throw KaitoError.malformed("StuffIt Huffman depth") }
            if try input.bits(1, lsb: false) == 1 {
                symbols[item.node] = try input.bits(8, lsb: false)
            } else {
                let zero = try newNode(), one = try newNode()
                children[item.node * 2] = zero; children[item.node * 2 + 1] = one
                stack.append((one, item.depth + 1)); stack.append((zero, item.depth + 1))
            }
        }
    }
    func insert(symbol: Int, code: UInt64, length: Int, lowBitFirst: Bool = false) throws {
        guard (1...38).contains(length), code < (UInt64(1) << length) else { throw KaitoError.malformed("StuffIt Huffman code") }
        var node = 0
        for i in 0..<length {
            guard symbols[node] < 0 else { throw KaitoError.malformed("StuffIt Huffman prefix collision") }
            let bit = Int((code >> (lowBitFirst ? i : length - 1 - i)) & 1)
            let slot = node * 2 + bit
            if children[slot] < 0 { children[slot] = try newNode() }
            node = children[slot]
        }
        guard symbols[node] < 0, children[node * 2] < 0, children[node * 2 + 1] < 0 else {
            throw KaitoError.malformed("StuffIt Huffman duplicate code")
        }
        symbols[node] = symbol
    }
    static func canonical(_ lengths: [Int]) throws -> StuffItPrefixTree {
        let tree = StuffItPrefixTree(capacity: 1 + lengths.count * 32)
        guard lengths.allSatisfy({ (-1...32).contains($0) }) else { throw KaitoError.malformed("StuffIt Huffman length") }
        var code: UInt64 = 0, previousLength = 0
        for symbol in lengths.indices.filter({ lengths[$0] > 0 }).sorted(by: { (lengths[$0], $0) < (lengths[$1], $1) }) {
            let length = lengths[symbol]
            code <<= length - previousLength
            try tree.insert(symbol: symbol, code: code, length: length)
            code += 1; previousLength = length
        }
        return tree
    }
    @inline(__always) func decode(_ input: StuffItPackedInput, lsb: Bool) throws -> Int {
        var node = 0
        while symbols[node] < 0 {
            node = children[node * 2 + (try input.bits(1, lsb: lsb))]
            guard node >= 0 else { throw KaitoError.malformed("StuffIt Huffman absent branch") }
        }
        return symbols[node]
    }
}

final class StuffItHuffman: Decompressor {
    private let input: StuffItPackedInput
    private let tree: StuffItPrefixTree
    private var remaining: UInt64
    var isFinished: Bool { remaining == 0 }
    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(1023 * 3 * UInt64(MemoryLayout<Int>.stride), limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        tree = StuffItPrefixTree(capacity: 1023)
        if size > 0 { try tree.explicit(input: input) }
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { destination[i] = UInt8(try tree.decode(input, lsb: false)) }
        remaining -= UInt64(count)
        return count
    }
}
