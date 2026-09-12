// 指定資料 Ch.07 §3。category 60〜63 は strict profile として拒否する。
import Foundation

final class StuffItXDarkhorse: Decompressor {
    let input: StuffItXBitReader
    private let range: StuffItXRangeDecoder
    private let weights: UnsafeMutablePointer<UInt32>
    private let history: UnsafeMutablePointer<UInt8>
    private let mask: Int
    private var remaining: UInt64
    private let knownLength: Bool
    private var position: UInt64 = 0
    private var cache = (0, 0, 0, 0)
    private var prediction: UInt8?
    private var pending = 0
    private var distance = 0
    private(set) var isFinished = false

    init(input: StuffItXBitReader, exponent: Int, size: UInt64?, limits: ReadLimits) throws {
        guard exponent >= 0, exponent < 31 else { throw KaitoError.malformed("StuffIt X Darkhorse window exponent") }
        let capacity = max(1 << exponent, 1 << 20)
        try Checked.size(UInt64(capacity), limit: limits.maxDictionarySize)
        self.input = input; remaining = size ?? limits.maxTotalUncompressedSize; knownLength = size != nil; mask = capacity - 1
        _ = try input.byte(); range = try StuffItXRangeDecoder(input: input, explicitLower: false)
        history = .allocate(capacity: capacity); history.initialize(repeating: 0, count: capacity)
        weights = .allocate(capacity: 13_017)
        weights.initialize(repeating: 2048, count: 13_017)
    }
    deinit { weights.deallocate(); history.deallocate() }
    @inline(__always) private func bit(_ index: Int) throws -> Int { try range.modeled(weights.advanced(by: index)) }
    @inline(__always) private func tree(_ start: Int, _ width: Int) throws -> Int { try range.tree(weights.advanced(by: start), width: width) }
    @inline(__always) private func length() throws -> Int {
        if try bit(5) == 0 { return try tree(13 + Int(position & 3) * 16, 4) + 2 }
        return try tree(77, 8) + 18
    }
    @inline(__always) private func literal() throws -> UInt8 {
        let context = Int(history[(Int(truncatingIfNeeded: position) - 1) & mask] >> 4)
        let normal = 729 + context * 256
        guard let prediction else { return UInt8(try tree(normal, 8)) }
        var matching = true, node = 1
        for shift in (0..<8).reversed() {
            let predicted = Int((prediction >> shift) & 1)
            let selected = try bit(matching ? 4825 + context * 512 + node * 2 + predicted : normal + node)
            if selected != predicted { matching = false }
            node = node * 2 + selected
        }
        self.prediction = nil
        return UInt8(node - 256)
    }
    private func match() throws -> Bool {
        let n: Int, offset: Int
        if try bit(4) == 0 {
            n = try length()
            if n == 273 { return false }
            let category = try tree(333 + min(n - 2, 3) * 64, 6)
            guard category < 60 else { throw KaitoError.malformed("StuffIt X Darkhorse reserved distance category") }
            if category < 4 { offset = category }
            else {
                let e = category / 2 - 1, base = (2 + category % 2) << e
                let extra: Int
                if category < 14 {
                    var start = 589
                    for c in 4..<category { start += 1 << (c / 2 - 1) }
                    extra = try tree(start, e)
                } else { extra = try (range.fair(e - 4) << 4) | tree(713, 4) }
                offset = base + extra
            }
            cache = (offset, cache.0, cache.1, cache.2)
        } else {
            if try bit(6) == 0 {
                offset = cache.0
                n = try bit(9 + Int(position & 3)) == 0 ? 1 : length()
            } else {
                if try bit(7) == 0 { offset = cache.1; cache = (offset, cache.0, cache.2, cache.3) }
                else if try bit(8) == 0 { offset = cache.2; cache = (offset, cache.0, cache.1, cache.3) }
                else { offset = cache.3; cache = (offset, cache.0, cache.1, cache.2) }
                n = try length()
            }
        }
        guard UInt64(n) <= remaining else { throw KaitoError.malformed("StuffIt X Darkhorse match length") }
        distance = offset + 1; pending = n
        prediction = history[(Int(truncatingIfNeeded: position) - distance + n % distance) & mask]
        return true
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if buffer.isEmpty || isFinished { return 0 }
        if remaining == 0 {
            if !knownLength {
                guard pending == 0, try bit(Int(position & 3)) != 0, try !match() else { throw KaitoError.limitExceeded("StuffIt X Darkhorse output") }
            }
            isFinished = true; return 0
        }
        let count = Int(min(UInt64(buffer.count), remaining))
        let destination = buffer.bindMemory(to: UInt8.self)
        var written = 0
        while written < count {
            if pending == 0, try bit(Int(position & 3)) != 0 {
                if try !match() {
                    guard !knownLength else { throw KaitoError.truncated }
                    isFinished = true; break
                }
            }
            let value: UInt8
            if pending > 0 { value = history[(Int(truncatingIfNeeded: position) - distance) & mask]; pending -= 1 }
            else { value = try literal(); prediction = nil }
            history[Int(truncatingIfNeeded: position) & mask] = value
            destination[written] = value; written += 1; position += 1; remaining -= 1
        }
        return written
    }
}
