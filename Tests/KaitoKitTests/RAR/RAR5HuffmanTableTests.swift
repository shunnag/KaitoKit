import Foundation
@testable import KaitoKit
import XCTest

final class RAR5HuffmanTableTests: XCTestCase {
    func testBuildAndDecodeMatchOriginalForRandomLengthSets() throws {
        let table = RAR5HuffmanTable()
        let reference = RAR5ReferenceHuffmanTable()
        var random = Random(state: 0x5241_5235_4855_4646)
        var cases: [[UInt8]] = [[], [0], [1], [15], [16], [1, 1, 1], [1, 15, 15],
            Array(repeating: 15, count: 306), Array(repeating: 0, count: 306),
            Array(UInt8(1)...UInt8(14)) + [15, 15, 15]]
        // Split leaves of a binary tree to obtain valid complete tables, then
        // remove leaves and permute symbols to include incomplete tables.
        for iteration in 0..<128 {
            var leaves: [UInt8] = [1, 1]
            let target = 2 + random.next(305)
            while leaves.count < target {
                let candidates = leaves.indices.filter { leaves[$0] < 15 }
                let index = candidates[random.next(candidates.count)]
                leaves[index] += 1
                leaves.append(leaves[index])
            }
            if iteration.isMultiple(of: 2) {
                for index in leaves.indices where random.next(4) == 0 { leaves[index] = 0 }
            }
            for index in leaves.indices.reversed() {
                leaves.swapAt(index, random.next(index + 1))
            }
            cases.append(leaves)
            // Alternate invalid Kraft sums with out-of-range lengths, so
            // validation order and the final fifteen-bit overflow are covered.
            let bound = iteration.isMultiple(of: 2) ? 16 : 18
            cases.append((0..<random.next(307)).map { _ in UInt8(random.next(bound)) })
        }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 24)
        storage.initialize(repeating: 0, count: 24)
        defer { storage.deinitialize(count: 24); storage.deallocate() }
        var valid = 0
        var invalid = 0
        for (caseIndex, lengths) in cases.enumerated() {
            for required in [false, true] {
                let actualError = build(table, lengths: lengths, required: required)
                let expectedError = build(reference, lengths: lengths, required: required)
                XCTAssertEqual(actualError, expectedError, "case \(caseIndex), \(lengths)")
                if actualError != nil { invalid += 1; continue }
                valid += 1
                // Every 15-bit prefix exercises both the quick table and long
                // fallback, including unused code space after a rebuild.
                for prefix in 0..<(1 << 15) {
                    storage[0] = UInt8(prefix >> 7)
                    storage[1] = UInt8((prefix & 127) << 1)
                    var actual = RAR5RawBitReader(pointer: UnsafePointer(storage), bitLimit: 15)
                    var expected = actual
                    let a = table.decode(from: &actual)
                    let e = reference.decode(from: &expected)
                    if a != e || actual.bitPosition != expected.bitPosition {
                        return XCTFail("case \(caseIndex), prefix \(prefix): \(String(describing: a)) != \(String(describing: e))")
                    }
                }
                // Logical truncation and an unaligned starting position must
                // advance identically, even with nonzero physical padding.
                for _ in 0..<64 {
                    for byte in 0..<8 { storage[byte] = UInt8(random.next(256)) }
                    let position = random.next(8)
                    let limit = position + random.next(17)
                    var actual = RAR5RawBitReader(
                        pointer: UnsafePointer(storage), bitLimit: limit, bitPosition: position
                    )
                    var expected = actual
                    XCTAssertEqual(table.decode(from: &actual), reference.decode(from: &expected))
                    XCTAssertEqual(actual.bitPosition, expected.bitPosition)
                }
            }
        }
        XCTAssertGreaterThan(valid, 200)
        XCTAssertGreaterThan(invalid, 200)
    }

    private func build(_ table: RAR5HuffmanTable, lengths: [UInt8], required: Bool) -> KaitoError? {
        do {
            let storage = lengths.isEmpty ? [0] : lengths
            try storage.withUnsafeBufferPointer {
                try table.build(lengths: $0.baseAddress!, count: lengths.count, requireSymbol: required)
            }
            return nil
        } catch {
            XCTAssertTrue(error is KaitoError)
            return error as? KaitoError
        }
    }

    private func build(_ table: RAR5ReferenceHuffmanTable, lengths: [UInt8], required: Bool) -> KaitoError? {
        do {
            let storage = lengths.isEmpty ? [0] : lengths
            try storage.withUnsafeBufferPointer {
                try table.build(lengths: $0.baseAddress!, count: lengths.count, requireSymbol: required)
            }
            return nil
        } catch {
            XCTAssertTrue(error is KaitoError)
            return error as? KaitoError
        }
    }

    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(bound))
        }
    }
}

// Test-only, verbatim implementation from perf/kk-integrate 3d992c4. This is
// KaitoKit's own baseline; no third-party decoder source is used.
private final class RAR5ReferenceHuffmanTable {
    private static let primaryBits = 10
    private static let primaryCount = 1 << primaryBits
    private static let lookupBits = 15
    private static let lookupCount = 1 << lookupBits
    private let lookup: UnsafeMutablePointer<UInt32>
    private let primary: UnsafeMutablePointer<UInt32>

    init() {
        primary = .allocate(capacity: Self.primaryCount)
        primary.initialize(repeating: 0, count: Self.primaryCount)
        lookup = .allocate(capacity: Self.lookupCount)
        lookup.initialize(repeating: 0, count: Self.lookupCount)
    }

    deinit {
        primary.deinitialize(count: Self.primaryCount)
        primary.deallocate()
        lookup.deinitialize(count: Self.lookupCount)
        lookup.deallocate()
    }

    func build(
        lengths: UnsafePointer<UInt8>,
        count: Int,
        requireSymbol: Bool
    ) throws {
        primary.update(repeating: 0, count: Self.primaryCount)
        lookup.update(repeating: 0, count: Self.lookupCount)
        var counts = [Int](repeating: 0, count: Self.lookupBits + 1)
        var symbolCount = 0
        for index in 0..<count {
            let length = Int(lengths[index])
            guard length <= Self.lookupBits else {
                throw KaitoError.malformed("RAR5 Huffman length exceeds 15")
            }
            if length > 0 {
                counts[length] += 1
                symbolCount += 1
            }
        }
        if requireSymbol, symbolCount == 0 {
            throw KaitoError.malformed("RAR5 Huffman table is empty")
        }
        guard symbolCount > 0 else { return }

        var next = [Int](repeating: 0, count: Self.lookupBits + 1)
        var code = 0
        for length in 1...Self.lookupBits {
            let (sum, overflow) = code.addingReportingOverflow(counts[length - 1])
            guard !overflow else { throw KaitoError.malformed("RAR5 Huffman count overflow") }
            let (shifted, shiftOverflow) = sum.multipliedReportingOverflow(by: 2)
            guard !shiftOverflow, shifted <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman table is oversubscribed")
            }
            code = shifted
            next[length] = code
        }

        for symbol in 0..<count {
            let length = Int(lengths[symbol])
            guard length > 0 else { continue }
            let prefix = next[length]
            next[length] += 1
            guard next[length] <= 1 << length else {
                throw KaitoError.malformed("RAR5 Huffman code is oversubscribed")
            }
            let repetitions = 1 << (Self.lookupBits - length)
            let start = prefix << (Self.lookupBits - length)
            guard start >= 0, repetitions <= Self.lookupCount - start else {
                throw KaitoError.malformed("RAR5 Huffman lookup range is invalid")
            }
            let entry = UInt32(length << 16 | symbol)
            lookup.advanced(by: start).update(repeating: entry, count: repetitions)
            if length <= Self.primaryBits {
                let primaryStart = prefix << (Self.primaryBits - length)
                let primaryRepetitions = 1 << (Self.primaryBits - length)
                // The canonical prefix was validated above; truncating its
                // padding from fifteen to ten bits preserves the table bound.
                primary.advanced(by: primaryStart).update(
                    repeating: entry, count: primaryRepetitions
                )
            }
        }
    }

    @inline(__always)
    func decode(from bits: inout RAR5RawBitReader) -> Int? {
        guard bits.bitPosition < bits.bitLimit else { return nil }
        let prefix = bits.peekPadded(Self.lookupBits)
        var entry = primary[prefix >> (Self.lookupBits - Self.primaryBits)]
        if entry == 0 { entry = lookup[prefix] }
        let length = Int(entry >> 16)
        guard length > 0, length <= bits.bitLimit - bits.bitPosition else { return nil }
        bits.bitPosition += length
        return Int(entry & 0xffff)
    }
}
