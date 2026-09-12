// Clean-room format inputs: 指定レポート Ch.04 の method 13、method13.json の固定表と meta code に基づく。
// 表の転記の出自は research/THIRD_PARTY_DATA.md に記載されている。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItMethod13: Decompressor {
    private let input: StuffItPackedInput
    private let first: StuffItPrefixTree
    private let second: StuffItPrefixTree
    private let distance: StuffItPrefixTree
    private let history: UnsafeMutablePointer<UInt8>
    private var position = 0
    private var remaining: UInt64
    private var afterMatch = false
    private var pending = 0
    private var copyDistance = 0
    var isFinished: Bool { remaining == 0 }

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        // 木の未使用枝も含め、構築時の最大領域を先に予算へ計上する。
        try Checked.size(UInt64((2 * (321 * 32 + 1) + 17 * 32 + 1 + 37 * 12 + 1) * 3 * MemoryLayout<Int>.stride + 65_536),
                         limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        let h = Int(try input.byte()), preset = h >> 4
        guard preset <= 5 else { throw KaitoError.malformed("StuffIt method 13 table selector") }
        if preset > 0 {
            first = try .canonical(StuffItTables.first[preset - 1])
            second = try .canonical(StuffItTables.second[preset - 1])
            distance = try .canonical(StuffItTables.distance[preset - 1])
        } else {
            let meta = StuffItPrefixTree(capacity: 37 * 12 + 1)
            for symbol in 0..<37 {
                try meta.insert(symbol: symbol, code: UInt64(StuffItTables.metaCodes[symbol]),
                                length: StuffItTables.metaLengths[symbol], lowBitFirst: true)
            }
            first = try .canonical(Self.lengths(321, input: input, meta: meta))
            second = h & 8 != 0 ? first : try .canonical(Self.lengths(321, input: input, meta: meta))
            distance = try .canonical(Self.lengths((h & 7) + 10, input: input, meta: meta))
        }
        history = .allocate(capacity: 65_536); history.initialize(repeating: 0, count: 65_536)
    }
    deinit { history.deallocate() }

    private static func lengths(_ count: Int, input: StuffItPackedInput, meta: StuffItPrefixTree) throws -> [Int] {
        var result: [Int] = [], length = 0
        result.reserveCapacity(count)
        while result.count < count {
            let symbol = try meta.decode(input, lsb: true)
            var run = 1
            switch symbol {
            case 0...30: length = symbol + 1
            case 31: length = -1
            case 32: length += 1
            case 33: length -= 1
            case 34: run = 1 + (try input.bits(1, lsb: true))
            case 35: run = 3 + (try input.bits(3, lsb: true))
            case 36: run = 11 + (try input.bits(6, lsb: true))
            default: throw KaitoError.malformed("StuffIt method 13 meta symbol")
            }
            guard (-1...32).contains(length), run <= count - result.count else { throw KaitoError.malformed("StuffIt method 13 length run") }
            result.append(contentsOf: repeatElement(length, count: run))
        }
        return result
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        var written = 0
        while written < count {
            if pending == 0 {
                let symbol = try (afterMatch ? second : first).decode(input, lsb: true)
                if symbol < 256 {
                    let literal = UInt8(symbol)
                    destination[written] = literal; history[position] = literal
                    position = (position + 1) & 65_535; written += 1; remaining -= 1; afterMatch = false
                    continue
                }
                if symbol == 320 { throw KaitoError.truncated }
                pending = symbol <= 317 ? symbol - 253 : 65 + (try input.bits(symbol == 318 ? 10 : 15, lsb: true))
                let category = try distance.decode(input, lsb: true)
                copyDistance = category < 2 ? category + 1 : (1 << (category - 1)) + (try input.bits(category - 1, lsb: true)) + 1
                guard copyDistance <= 65_536, UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt method 13 match extent") }
                afterMatch = true
            }
            let n = min(pending, count - written)
            for i in 0..<n {
                let byte = history[(position - copyDistance) & 65_535]
                destination[written + i] = byte; history[position] = byte; position = (position + 1) & 65_535
            }
            written += n; remaining -= UInt64(n); pending -= n
        }
        return written
    }
}
