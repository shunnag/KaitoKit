import Foundation
@testable import KaitoKit
import XCTest

final class PPMd7DecoderTests: XCTestCase {
    func testKnownPPMd7StreamsWithSingleByteReads() throws {
        // 7zz 26.03: each payload was archived with
        // `-t7z -m0=PPMd:o=6:mem=1m -mhc=off`; these are the exact packed ranges.
        let vectors: [(packed: String, output: Data)] = [
            ("00609f609f00", Data("a".utf8)),
            ("00610308bba400", Data("ab".utf8)),
            ("0061036db96c2d00", Data("abc".utf8)),
            ("0061036e0fa7194000", Data("abcabcabcabcabcabc".utf8)),
            (
                "00620279778de882efeeaedc2f74e42e003a0d19919ed570d672bc71e6c3ce82ee",
                Data(String(repeating: "banana bandana banana bandana\n", count: 20).utf8)
            ),
        ]

        for vector in vectors {
            let packed = try XCTUnwrap(Data(hexadecimal: vector.packed))
            let decoder = try PPMd7Decoder(
                source: DataByteSource(packed),
                offset: 0,
                compressedSize: UInt64(packed.count),
                properties: [6, 0, 0, 0x10, 0],
                expectedSize: UInt64(vector.output.count),
                memorySizeLimit: 1 << 20
            )
            XCTAssertEqual(try drainOneByteAtATime(decoder), vector.output)
            XCTAssertTrue(decoder.isFinished)
        }

        // 現行 7zz encoder は order 64 を拒否するが、最初の symbol は order に
        // 依存しないため、実際の PPMd7z range stream で decoder 上限も通す。
        let order64Packed = try XCTUnwrap(Data(hexadecimal: "00609f609f00"))
        let order64Decoder = try PPMd7Decoder(
            source: DataByteSource(order64Packed),
            offset: 0,
            compressedSize: UInt64(order64Packed.count),
            properties: [64, 0, 0, 0x10, 0],
            expectedSize: 1,
            memorySizeLimit: 1 << 20
        )
        XCTAssertEqual(try drainOneByteAtATime(order64Decoder), Data("a".utf8))
        XCTAssertTrue(order64Decoder.isFinished)
    }

    func testPropertiesAreValidatedBeforeModelAllocation() throws {
        let source = DataByteSource(Data(repeating: 0, count: 5))
        for order in [0, 1, 65, 255] {
            XCTAssertThrowsError(try PPMd7Decoder(
                source: source,
                offset: 0,
                compressedSize: 5,
                properties: [UInt8(order), 0, 0, 0x10, 0],
                expectedSize: 1,
                memorySizeLimit: 1 << 20
            ))
        }
        XCTAssertThrowsError(try PPMd7Decoder(
            source: source,
            offset: 0,
            compressedSize: 5,
            properties: [6, 0, 0, 0x10, 0],
            expectedSize: 1,
            memorySizeLimit: (1 << 20) - 1
        )) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let order64 = try PPMd7Decoder(
            source: source,
            offset: 0,
            compressedSize: 5,
            properties: [64, 0, 0, 0x10, 0],
            expectedSize: 0,
            memorySizeLimit: 1 << 20
        )
        XCTAssertTrue(order64.isFinished)
    }

    func testCorruptPPMdStreamsThrowOrRemainOutputBounded() throws {
        let seed = try XCTUnwrap(Data(hexadecimal:
            "00620279778de882efeeaedc2f74e42e003a0d19919ed570d672bc71e6c3ce82ee"
        ))
        var completed = 0
        for mutation in 0..<64 {
            var bytes = seed
            let index = 1 + (mutation * 13 + 5) % (bytes.count - 1)
            bytes[index] ^= UInt8(1) << UInt8(mutation & 7)
            do {
                let decoder = try PPMd7Decoder(
                    source: DataByteSource(bytes),
                    offset: 0,
                    compressedSize: UInt64(bytes.count),
                    properties: [6, 0, 0, 0x10, 0],
                    expectedSize: 620,
                    memorySizeLimit: 1 << 20
                )
                let output = try drain(decoder, chunkSize: 257)
                XCTAssertEqual(output.count, 620)
            } catch is KaitoError {
                // 構造不正・入力枯渇・model invariant 違反はいずれも正常な拒否経路。
            } catch {
                XCTFail("PPMd mutant raised a non-Kaito error: \(error)")
            }
            completed += 1
        }
        XCTAssertEqual(completed, 64)
    }

    func testSuballocatorUsesOnlyItsFixedArenaAndRecyclesUnits() throws {
        let allocator = try PPMd7Suballocator(memorySize: 2_048)
        XCTAssertEqual(allocator.textOffset, 0)
        XCTAssertEqual(allocator.unitsStartOffset, 284)
        XCTAssertEqual(allocator.lowUnitOffset, 284)
        XCTAssertEqual(allocator.highUnitOffset, 2_048)

        let root = try XCTUnwrap(allocator.allocateContext())
        XCTAssertEqual(root, 2_036)
        let states = try XCTUnwrap(allocator.allocateUnits(128))
        XCTAssertEqual(states, 284)
        XCTAssertEqual(allocator.lowUnitOffset, 1_820)

        var contexts = [PPMd7Suballocator.Offset]()
        while allocator.highUnitOffset != allocator.lowUnitOffset {
            contexts.append(try XCTUnwrap(allocator.allocateContext()))
        }
        XCTAssertFalse(contexts.isEmpty)
        let borrowed = try XCTUnwrap(allocator.allocateContext())
        XCTAssertLessThan(borrowed, states)
        XCTAssertEqual(Int(borrowed), allocator.unitsStartOffset)

        var textCount = 0
        while try allocator.appendText(UInt8(truncatingIfNeeded: textCount)) != nil {
            textCount += 1
        }
        XCTAssertEqual(textCount, allocator.unitsStartOffset)

        allocator.restart()
        let block = try XCTUnwrap(allocator.allocateUnits(12))
        for index in 0..<(12 * PPMd7Suballocator.unitSize) {
            try allocator.storeByte(
                UInt8(truncatingIfNeeded: index),
                at: block + UInt32(index)
            )
        }
        let expanded = try XCTUnwrap(allocator.expandUnits(at: block, oldUnits: 12))
        for index in 0..<(12 * PPMd7Suballocator.unitSize) {
            XCTAssertEqual(
                try allocator.byte(at: expanded + UInt32(index)),
                UInt8(truncatingIfNeeded: index)
            )
        }
        let shrunk = try allocator.shrinkUnits(
            at: expanded,
            oldUnits: 13,
            newUnits: 3
        )
        for index in 0..<(3 * PPMd7Suballocator.unitSize) {
            XCTAssertEqual(
                try allocator.byte(at: shrunk + UInt32(index)),
                UInt8(truncatingIfNeeded: index)
            )
        }
        try allocator.freeUnits(at: shrunk, units: 3)
        XCTAssertNotNil(try allocator.allocateUnits(3))
    }

    private func drainOneByteAtATime(_ decoder: PPMd7Decoder) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while !decoder.isFinished {
            do {
                let count = try withUnsafeMutableBytes(of: &byte) { storage in
                    try decoder.read(into: storage)
                }
                guard count == 1 else {
                    throw KaitoError.malformed("PPMd7 decoder made no progress")
                }
                result.append(byte)
            } catch {
                XCTFail(
                    "PPMd7 failed after \(result.count) decoded bytes "
                        + "(\(result.map { String(format: "%02x", $0) }.joined())): \(error)"
                )
                throw error
            }
        }
        return result
    }

    private func drain(_ decoder: PPMd7Decoder, chunkSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try decoder.read(into: storage)
            }
            guard count > 0 else {
                throw KaitoError.malformed("PPMd7 decoder made no progress")
            }
            result.append(contentsOf: buffer[..<count])
        }
        return result
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        self.init()
        reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
            append(byte)
            index = end
        }
    }
}
