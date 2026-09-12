// Clean-room format inputs: 指定レポート Ch.04 の method 2 と共通 bit 規則に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItLZW: Decompressor {
    private let input: StuffItPackedInput
    private let prefixes: UnsafeMutablePointer<Int>
    private let suffixes: UnsafeMutablePointer<UInt8>
    private let expansion: UnsafeMutablePointer<UInt8>
    private var pending = 0
    private var width = 9
    private var next = 257
    private var previous = -1
    private var codeCount = 0
    private var remaining: UInt64
    var isFinished: Bool { remaining == 0 }

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(16_384 * UInt64(MemoryLayout<Int>.stride + 2), limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        prefixes = .allocate(capacity: 16_384); suffixes = .allocate(capacity: 16_384)
        expansion = .allocate(capacity: 16_384)
        prefixes.initialize(repeating: -1, count: 16_384)
        suffixes.initialize(repeating: 0, count: 16_384)
        for i in 0..<256 { suffixes[i] = UInt8(i) }
    }
    deinit { prefixes.deallocate(); suffixes.deallocate(); expansion.deallocate() }

    private func token() throws {
        var code: Int
        while true {
            code = try input.bits(width, lsb: true)
            codeCount = (codeCount + 1) & 7
            if code != 256 { break }
            if codeCount != 0 {
                for _ in codeCount..<8 { _ = try input.bits(width, lsb: true) }
            }
            width = 9; next = 257; previous = -1; codeCount = 0
        }
        if previous == -1 {
            guard code < 256 else { throw KaitoError.malformed("StuffIt LZW first code") }
            expansion[0] = UInt8(code); pending = 1; previous = code
            return
        }
        guard code <= next, code < 16_384 else { throw KaitoError.malformed("StuffIt LZW dictionary code") }
        let special = code == next
        var current = special ? previous : code
        pending = special ? 1 : 0
        // prefix は常に挿入位置より小さい。検査済みの辞書だけを辿り、展開領域も一語以内に収める。
        while current >= 256 {
            guard current > 256, current < next, pending < 16_383 else { throw KaitoError.malformed("StuffIt LZW prefix chain") }
            expansion[pending] = suffixes[current]; pending += 1
            let parent = prefixes[current]
            guard parent >= 0, parent < current else { throw KaitoError.malformed("StuffIt LZW prefix cycle") }
            current = parent
        }
        let first = UInt8(current)
        expansion[pending] = first; pending += 1
        if special { expansion[0] = first }
        if next < 16_384 {
            prefixes[next] = previous; suffixes[next] = first; next += 1
            if width < 14 && next == (1 << width) { width += 1 }
        }
        previous = code
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        var written = 0
        while written < count {
            if pending == 0 {
                try token()
                guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt LZW output length") }
            }
            let n = min(pending, count - written)
            for i in 0..<n { destination[written + i] = expansion[pending - i - 1] }
            pending -= n; written += n; remaining -= UInt64(n)
        }
        return written
    }
}
