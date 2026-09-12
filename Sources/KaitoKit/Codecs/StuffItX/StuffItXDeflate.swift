// 指定資料 Ch.07 §5・Ch.37 から独立に実装した 6 bit 距離個数の Deflate。
import Foundation

final class StuffItXDeflate: Decompressor {
    private final class Huffman {
        let width: Int
        private let table: UnsafeMutablePointer<UInt32>
        init(_ lengths: [Int]) throws {
            width = lengths.max() ?? 0
            guard width <= 15, lengths.allSatisfy({ $0 >= 0 }) else { throw KaitoError.malformed("StuffIt X Deflate code length") }
            var counts = [Int](repeating: 0, count: 16), next = counts, available = 1, code = 0
            for length in lengths where length != 0 { counts[length] += 1 }
            for bits in 1...15 {
                available = available * 2 - counts[bits]
                guard available >= 0 else { throw KaitoError.malformed("StuffIt X Deflate oversubscribed tree") }
                code = (code + counts[bits - 1]) << 1; next[bits] = code
            }
            table = .allocate(capacity: 1 << width); table.initialize(repeating: 0, count: 1 << width)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                var word = next[length], reversed = 0
                next[length] += 1
                for _ in 0..<length { reversed = (reversed << 1) | (word & 1); word >>= 1 }
                let value = UInt32((symbol << 5) | length)
                for i in stride(from: reversed, to: 1 << width, by: 1 << length) { table[i] = value }
            }
        }
        deinit { table.deallocate() }
        @inline(__always) func symbol(_ input: StuffItXBitReader) throws -> Int {
            let value = table[try input.peek(width)], length = Int(value & 31)
            guard length > 0 else { throw KaitoError.malformed("StuffIt X Deflate undefined code") }
            _ = try input.bits(length)
            return Int(value >> 5)
        }
    }
    private let input: StuffItXBitReader
    private let history: UnsafeMutablePointer<UInt8>
    private let mask: Int
    private var remaining: UInt64
    private let knownLength: Bool
    private var position: UInt64 = 0
    private var needHeader = true
    private var finalBlock = false
    private var stored = 0
    private var storedBlock = false
    private var pending = 0
    private var distance = 0
    private var literals: Huffman?
    private var distances: Huffman?
    private(set) var isFinished = false

    init(input: StuffItXBitReader, exponent: Int, size: UInt64?, limits: ReadLimits) throws {
        guard (10...25).contains(exponent) else { throw KaitoError.malformed("StuffIt X Deflate window exponent") }
        let capacity = 1 << exponent
        try Checked.size(UInt64(capacity), limit: limits.maxDictionarySize)
        self.input = input; remaining = size ?? limits.maxTotalUncompressedSize; knownLength = size != nil; mask = capacity - 1
        history = .allocate(capacity: capacity)
    }
    deinit { history.deallocate() }
    private func header() throws {
        finalBlock = try input.bits(1) != 0
        let type = try input.bits(2)
        needHeader = false; storedBlock = type == 0
        switch type {
        case 0:
            input.align()
            let count = try input.bits(16), complement = try input.bits(16)
            guard count ^ complement == 0xffff else { throw KaitoError.malformed("StuffIt X Deflate stored complement") }
            stored = Int(count)
            guard count <= remaining else { throw KaitoError.malformed("StuffIt X Deflate stored length") }
        case 1:
            literals = try Huffman((0..<288).map { $0 <= 143 ? 8 : ($0 <= 255 ? 9 : ($0 <= 279 ? 7 : 8)) })
            distances = try Huffman([Int](repeating: 5, count: 32))
        case 2:
            let nl = Int(try input.bits(5)) + 257, nd = Int(try input.bits(6)) + 1, nc = Int(try input.bits(4)) + 4
            guard nl <= 286, nd <= 50 else { throw KaitoError.malformed("StuffIt X Deflate alphabet count") }
            let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
            var lengths = [Int](repeating: 0, count: 19)
            for i in 0..<nc { lengths[order[i]] = Int(try input.bits(3)) }
            let tree = try Huffman(lengths)
            lengths = []; lengths.reserveCapacity(nl + nd)
            while lengths.count < nl + nd {
                let symbol = try tree.symbol(input)
                if symbol < 16 { lengths.append(symbol); continue }
                let value: Int, count: Int
                switch symbol {
                case 16:
                    guard let last = lengths.last else { throw KaitoError.malformed("StuffIt X Deflate missing repeat predecessor") }
                    value = last; count = Int(try input.bits(2)) + 3
                case 17: value = 0; count = Int(try input.bits(3)) + 3
                case 18: value = 0; count = Int(try input.bits(7)) + 11
                default: throw KaitoError.malformed("StuffIt X Deflate secondary symbol")
                }
                guard count <= nl + nd - lengths.count else { throw KaitoError.malformed("StuffIt X Deflate repeat overflow") }
                lengths.append(contentsOf: repeatElement(value, count: count))
            }
            guard lengths[256] > 0 else { throw KaitoError.malformed("StuffIt X Deflate missing end code") }
            literals = try Huffman(Array(lengths[..<nl])); distances = try Huffman(Array(lengths[nl...]))
        default: throw KaitoError.malformed("StuffIt X Deflate block type")
        }
    }
    private func endBlock() throws {
        if finalBlock {
            guard !knownLength || remaining == 0 else { throw KaitoError.truncated }
            input.align()
            guard input.isAtEnd else { throw KaitoError.malformed("StuffIt X Deflate trailing bytes") }
            isFinished = true
        } else { needHeader = true }
    }
    @inline(__always) private func emit(_ byte: UInt8, to output: UnsafeMutableBufferPointer<UInt8>, at index: Int) {
        history[Int(truncatingIfNeeded: position) & mask] = byte; output[index] = byte
        remaining -= 1; position += 1
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        let output = buffer.bindMemory(to: UInt8.self)
        var written = 0
        while written < buffer.count || remaining == 0 {
            if isFinished { break }
            if pending > 0 {
                while pending > 0 && written < buffer.count {
                    let byte = history[(Int(truncatingIfNeeded: position) - distance) & mask]
                    emit(byte, to: output, at: written); written += 1; pending -= 1
                }
                if pending > 0 { break }
                continue
            }
            if needHeader { try header() }
            if storedBlock {
                while stored > 0 && written < buffer.count {
                    emit(try input.byte(), to: output, at: written); written += 1; stored -= 1
                }
                if stored > 0 { break }
                try endBlock(); continue
            }
            guard let literals, let distances else { throw KaitoError.malformed("StuffIt X Deflate missing tree") }
            let symbol = try literals.symbol(input)
            if symbol == 256 { try endBlock(); continue }
            guard remaining > 0 else { throw KaitoError.malformed("StuffIt X Deflate excess output") }
            if symbol < 256 {
                emit(UInt8(symbol), to: output, at: written); written += 1; continue
            }
            guard symbol <= 285 else { throw KaitoError.malformed("StuffIt X Deflate reserved length") }
            if symbol <= 264 { pending = symbol - 254 }
            else if symbol == 285 { pending = 258 }
            else {
                let bases = [11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227]
                pending = bases[symbol - 265] + Int(try input.bits((symbol - 261) / 4))
            }
            guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt X Deflate match length") }
            let d = try distances.symbol(input)
            guard d < 50 else { throw KaitoError.malformed("StuffIt X Deflate distance symbol") }
            if d < 4 { distance = d + 1 }
            else {
                let width = d / 2 - 1
                distance = 1 + ((2 + d % 2) << width) + Int(try input.bits(width))
            }
            guard distance <= mask + 1, UInt64(distance) <= position else { throw KaitoError.malformed("StuffIt X Deflate history distance") }
        }
        return written
    }
}
