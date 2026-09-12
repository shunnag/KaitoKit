// Clean-room format inputs: 指定レポート Ch.04 の method 15 と arsenic-randomization.json に基づく。
// randomization 定数の転記の出自は research/THIRD_PARTY_DATA.md に記載されている。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItArsenic: Decompressor {
    private let arithmetic: StuffItArsenicArithmetic
    private let exponent: Int
    private let capacity: Int
    private let column: UnsafeMutablePointer<UInt8>
    private let mtf: UnsafeMutablePointer<UInt8>
    private let steps: UnsafeMutablePointer<Int>
    private var permutation: UnsafeMutablePointer<UInt32>?
    private var blockLength = 0
    private var blockPosition = 0
    private var bwtIndex = 0
    private var finalBlock = false
    private var randomized = false
    private var randomStep = 0
    private var randomPosition = 238
    private var equalCount = 0
    private var remembered: UInt8 = 0
    private var pending = 0
    private var remaining: UInt64
    private var expectedCRC: UInt32 = 0
    private var checksum = CRC32()
    private(set) var isFinished = false

    init(input: StuffItPackedInput, size: UInt64, limits: ReadLimits) throws {
        try Checked.size(4096, limit: limits.maxDictionarySize)
        arithmetic = try StuffItArsenicArithmetic(input: input)
        guard try arithmetic.integer(8) == 0x41, try arithmetic.integer(8) == 0x73 else {
            throw KaitoError.malformed("StuffIt Arsenic signature")
        }
        exponent = try arithmetic.integer(4) + 9
        capacity = 1 << exponent
        try Checked.size(UInt64(capacity) * 5 + 8192, limit: limits.maxDictionarySize)
        remaining = size
        column = .allocate(capacity: capacity)
        mtf = .allocate(capacity: 256)
        steps = .allocate(capacity: 256)
        StuffItTables.randomization.withUnsafeBufferPointer { steps.initialize(from: $0.baseAddress!, count: 256) }
        finalBlock = try arithmetic.symbol(0) == 1
        if finalBlock {
            guard size == 0 else { throw KaitoError.truncated }
            isFinished = true
        }
    }
    deinit { column.deallocate(); mtf.deallocate(); steps.deallocate(); permutation?.deallocate() }

    private func loadBlock() throws {
        guard !finalBlock else { throw KaitoError.truncated }
        arithmetic.resetBlockModels()
        for i in 0..<256 { mtf[i] = UInt8(i) }
        randomized = try arithmetic.symbol(0) != 0
        let primary = try arithmetic.integer(exponent)
        var count = 0
        var selector = try arithmetic.symbol(1)
        while selector != 10 {
            if selector < 2 {
                var run: UInt64 = 0, weight: UInt64 = 1
                repeat {
                    run = try Checked.add(run, Checked.mul(UInt64(selector + 1), weight))
                    guard run <= UInt64(capacity - count) else { throw KaitoError.malformed("StuffIt Arsenic zero-rank run") }
                    weight = try Checked.mul(weight, 2)
                    selector = try arithmetic.symbol(1)
                } while selector < 2
                (column + count).initialize(repeating: mtf[0], count: Int(run))
                count += Int(run)
                continue
            }
            let rank = selector == 2 ? 1 : try arithmetic.symbol(selector - 1)
            guard count < capacity, rank < 256 else { throw KaitoError.malformed("StuffIt Arsenic rank extent") }
            let byte = mtf[rank]
            for i in stride(from: rank, to: 0, by: -1) { mtf[i] = mtf[i - 1] }
            mtf[0] = byte; column[count] = byte; count += 1
            selector = try arithmetic.symbol(1)
        }
        guard count > 0, primary < count else { throw KaitoError.malformed("StuffIt Arsenic BWT primary index") }
        finalBlock = try arithmetic.symbol(0) != 0
        if finalBlock { expectedCRC = UInt32(try arithmetic.integer(32)) }
        permutation?.deallocate()
        let next = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        permutation = next
        try withUnsafeTemporaryAllocation(of: Int.self, capacity: 256) { counts in
            counts.initialize(repeating: 0)
            for i in 0..<count { counts[Int(column[i])] += 1 }
            var sum = 0
            for byte in 0..<256 { let n = counts[byte]; counts[byte] = sum; sum += n }
            guard sum == count else { throw KaitoError.malformed("StuffIt Arsenic rank count") }
            for i in 0..<count {
                let byte = Int(column[i]), slot = counts[byte]
                next[slot] = UInt32(i); counts[byte] = slot + 1
            }
        }
        blockLength = count; blockPosition = 0; bwtIndex = primary
        randomStep = 0; randomPosition = steps[0]; equalCount = 0; pending = 0
    }
    @inline(__always) private func transformedByte() -> UInt8 {
        // 構築済み permutation の各値は 0..<blockLength。移動後の列要素を出力する。
        bwtIndex = Int(permutation![bwtIndex])
        var byte = column[bwtIndex]
        if randomized && blockPosition == randomPosition {
            byte ^= 1; randomStep = (randomStep + 1) & 255; randomPosition += steps[randomStep]
        }
        blockPosition += 1
        return byte
    }
    private func finish() throws {
        // 最後の四連続 literal の後にある count=0 も消費して構文と CRC を確定する。
        if blockPosition < blockLength && equalCount == 4 {
            let count = transformedByte(); equalCount = 0
            guard count == 0 else { throw KaitoError.malformed("StuffIt Arsenic output length") }
        }
        guard pending == 0, blockPosition == blockLength, equalCount != 4, finalBlock else {
            throw KaitoError.malformed("StuffIt Arsenic final output length")
        }
        guard checksum.value == expectedCRC else { throw KaitoError.malformed("StuffIt Arsenic CRC32") }
        isFinished = true
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        if remaining == 0 { try finish(); return 0 }
        let count = Int(min(UInt64(buffer.count), remaining))
        guard let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        var written = 0
        while written < count {
            if pending > 0 {
                let n = min(pending, count - written)
                destination.advanced(by: written).update(repeating: remembered, count: n)
                pending -= n; written += n; remaining -= UInt64(n)
                continue
            }
            if blockPosition == blockLength {
                guard equalCount != 4 else { throw KaitoError.malformed("StuffIt Arsenic missing run count") }
                try loadBlock()
            }
            let byte = transformedByte()
            if equalCount == 4 {
                equalCount = 0; pending = Int(byte)
                guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt Arsenic run output length") }
                continue
            }
            equalCount = byte == remembered ? equalCount + 1 : 1
            remembered = byte
            destination[written] = byte; written += 1; remaining -= 1
        }
        checksum.update(UnsafeRawBufferPointer(start: destination, count: written))
        if remaining == 0 { try finish() }
        return written
    }
}
