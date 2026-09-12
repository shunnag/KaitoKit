// 指定レポート Ch.04 の pair 辞書と reset / end 規則に基づく。
import Foundation

final class StuffItMW: Decompressor {
    private let input: StuffItPackedInput
    private let pairs: UnsafeMutablePointer<Int>
    private let stack: UnsafeMutablePointer<Int>
    private var stackCount = 0
    private var next = 256
    private var previous = -1
    private var width = 9
    private var remaining: UInt64
    private let dictionaryCapacity = 16_385
    private let stackCapacity = 16_384
    var isFinished: Bool { remaining == 0 }

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(UInt64((16_385 * 2 + 16_384) * MemoryLayout<Int>.stride), limit: limits.maxDictionarySize)
        self.input = input; remaining = size
        pairs = .allocate(capacity: dictionaryCapacity * 2); stack = .allocate(capacity: stackCapacity)
    }
    deinit { pairs.deallocate(); stack.deallocate() }

    private func token() throws {
        while true {
            let reference = try input.bits(width, lsb: true)
            if reference == next { next = 256; previous = -1; width = 9; continue }
            if reference > next { throw KaitoError.truncated }
            if previous >= 0 {
                guard next < dictionaryCapacity else { throw KaitoError.malformed("StuffIt MW dictionary capacity") }
                pairs[2 * next] = previous; pairs[2 * next + 1] = reference; next += 1
                if next == 1 << width && width < 15 { width += 1 }
            }
            previous = reference; stack[0] = reference; stackCount = 1
            return
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            if stackCount == 0 { try token() }
            stackCount -= 1
            var reference = stack[stackCount]
            while reference >= 256 {
                guard reference < next, reference < dictionaryCapacity, stackCount < stackCapacity else {
                    throw KaitoError.malformed("StuffIt MW expansion capacity")
                }
                let left = pairs[reference * 2], right = pairs[reference * 2 + 1]
                guard left >= 0, right >= 0, left < reference, right < reference else {
                    throw KaitoError.malformed("StuffIt MW recursive pair")
                }
                stack[stackCount] = right; stackCount += 1; reference = left
            }
            destination[i] = UInt8(reference); remaining -= 1
        }
        guard remaining != 0 || stackCount == 0 else { throw KaitoError.malformed("StuffIt MW output extent") }
        return count
    }
}
