import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipFilterTests: XCTestCase {
    func testDeltaAcrossSingleByteReads() throws {
        let expected = [UInt8]("delta-filter-delta-filter".utf8)
        let distance = 5
        // Packed bytes captured from 7zz 26.03 with
        // `-t7z -m0=Delta:5 -m1=Copy -mhc=off` for the expected text.
        let encoded = try hex(
            "64656c7461c901fdf813380cc4f8f1070234c901fdf813380c"
        )

        let decoder = try DeltaFilterDecompressor(
            input: TestChunkDecompressor(encoded, maximumRead: 1),
            distance: distance,
            expectedSize: UInt64(expected.count)
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
    }

    func testX86BCJMatches7ZipEncodedBytesAcrossEveryBoundary() throws {
        let original = try hex(
            "58e80000000059e9fbffffff5a0f853412000057e800000000"
        )
        let encoded = try hex(
            "58e80600000059e9070000005a0f853412000057e819000000"
        )

        for inputChunk in 1...8 {
            let decoder = try BCJFilterDecompressor(
                input: TestChunkDecompressor(encoded, maximumRead: inputChunk),
                filter: .x86,
                expectedSize: UInt64(original.count)
            )
            XCTAssertEqual(
                try drain(decoder, bufferSize: 3),
                original,
                "input chunk \(inputChunk)"
            )
        }
    }

    func testARMFilterMatches7ZipEncodedBytes() throws {
        let original = try hex(
            "000000eb010000ebffffffeb000000ea000000eb"
        )
        let encoded = try hex(
            "020000eb040000eb030000eb000000ea060000eb"
        )
        try assertBranchDecode(encoded: encoded, expected: original, filter: .arm)
    }

    func testARMThumbFilterMatches7ZipEncodedBytes() throws {
        let original = try hex(
            "00f000f801f001f8fff7ffff00e000bf00f000f8"
        )
        let encoded = try hex(
            "00f002f801f005f800f005f800e000bf00f00af8"
        )
        try assertBranchDecode(encoded: encoded, expected: original, filter: .armThumb)
    }

    func testARM64FilterDecodesBLAndADRP() throws {
        // The filtered words below were captured from 7zz 26.03 using
        // `-t7z -m0=ARM64 -m1=Copy -mhc=off`; the complete 8,224-byte packed
        // stream had SHA-256 bb4bd55bfecbe76615301e23daadca8709e9722f2c94a835b4e47051fa46c653.
        var original = [UInt8](repeating: 0, count: 0x2020)
        var encoded = original
        let words: [(Int, UInt32, UInt32)] = [
            (0x0000, 0x9000_0000, 0x9000_0000),
            (0x0004, 0x9000_0001, 0x9000_0001),
            (0x0FFC, 0x9000_0000, 0x9000_0000),
            (0x1000, 0x9000_0000, 0xB000_0000),
            (0x1004, 0x9000_0001, 0xB000_0001),
            (0x2000, 0x9000_0000, 0xD000_0000),
            (0x2004, 0x90FF_FFE0, 0xD0FF_FFE0),
            (0x2008, 0x9400_0000, 0x9400_0802),
        ]
        for (offset, decoded, filtered) in words {
            putUInt32LE(decoded, into: &original, at: offset)
            putUInt32LE(filtered, into: &encoded, at: offset)
        }
        try assertBranchDecode(encoded: encoded, expected: original, filter: .arm64)
    }

    func testPowerPCFilterMatches7ZipEncodedBytes() throws {
        let original = try hex(
            "48000001480000054bfffffd480000004800000348000001"
        )
        let encoded = try hex(
            "480000014800000948000005480000004800000348000015"
        )
        try assertBranchDecode(encoded: encoded, expected: original, filter: .powerPC)
    }

    func testBCJ2CallJumpAndConditionalJump() throws {
        try assertBCJ2(
            main: [0xE8],
            call: [0, 0, 0, 5],
            jump: [],
            expected: [0xE8, 0, 0, 0, 0]
        )
        try assertBCJ2(
            main: [0xE9],
            call: [],
            jump: [0, 0, 0, 5],
            expected: [0xE9, 0, 0, 0, 0]
        )
        try assertBCJ2(
            main: [0x0F, 0x85],
            call: [],
            jump: [0, 0, 0, 6],
            expected: [0x0F, 0x85, 0, 0, 0, 0]
        )
    }

    func testBCJ2ZeroDecisionLeavesMainBytesInPlace() throws {
        let expected: [UInt8] = [0x41, 0xE8, 1, 2, 3, 4, 0x42]
        let decoder = try BCJ2Decompressor(
            main: TestChunkDecompressor(expected, maximumRead: 1),
            call: TestChunkDecompressor([], maximumRead: 1),
            jump: TestChunkDecompressor([], maximumRead: 1),
            range: TestChunkDecompressor([0, 0, 0, 0, 0], maximumRead: 1),
            expectedSize: UInt64(expected.count)
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
    }

    func testBCJ2StreamsProducedBy7Zip() throws {
        // 7zz 26.03: `-m0=BCJ2 -m1=Copy -m2=Copy -m3=Copy` の 4 packed streams。
        // mainText は初期の手作業 fixture を履歴として残したもの。review 時に
        // 717..<857 の区間が 7zz の main stream に含まれないと判明したため除去し、
        // correctedMainText と call/jump/range の全 byte 列を 7zz 出力と照合した。
        let mainText = (
            "Qeic////QulDD4VB6J////9C6UMPhUHoov///0LpQw+FQeil////QulDD4VB6Kj///9C6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhUHoQulDD4VB6ELpQw+FQehC6UMPhf8BAABB6ELpQw+FBgIAAEHoQulDD4UNAgAAQehC6UMPhRQCAABB6ELpQw+FGwIAAEHoQulDD4UiAgAAQehC6UMPhSkCAABB6ELpQw+FMAIAAEHoQulDD4U3AgAAQehC6UMPhT4CAABB6ELpQw+FRQIAAEHoQulDD4VMAgAAQehC6UMPhVMCAABB6ELpQw+FWgIAAEHoQulDD4VhAgAAQehC6UMPhWgCAABB6ELpQw+FbwIAAEHoQulDD4V2AgAAQeitAAAAQulDD4V9AgAAQeiwAAAAQulDD4WEAgAAQeizAAAAQulDD4WLAgAAQei2AAAAQulqAAAAQw+FkgIAAEHouQAAAELpaQAAAEMPhZkCAABB6LwAAABC6WgAAABDD4WgAgAAQei/AAAAQulnAAAAQw+FpwIAAEHowgAAAELpZgAAAEMPha4CAABB6MUAAABC6WUAAABDD4W1AgAA"
        )
        let correctedMainText = String(mainText.prefix(717))
            + String(mainText.dropFirst(857))
        let main = try base64(correctedMainText)
        let call = try base64(
            "AAAAEAAAACYAAAA8AAAAUgAAAGgAAAB+AAAAlAAAAKoAAADAAAAA1gAAAOwAAAECAAABGAAAAS4AAAFEAAABWgAAAXAAAAGGAAABnAAAAbIAAAHIAAAB3gAAAfQAAAIKAAACIAAAAjYAAAJMAAACYgAAAngAAAKOAAACpAAAAroAAALQAAAC5gAAAvwAAAMSAAADKAAAAz4AAANUAAADagAAA4AAAAOWAAADrAAAA8IAAAPYAAAD7gAABAQAAAQaAAAEMAAABEYAAARcAAAEcgAABIgAAASeAAAEtAAABMoAAATgAAAE9gAABQwAAAUiAAAFOAAABU4AAAVkAAAFegAABZAAAAWmAAAFvAAABdIAAAXoAAAF/gAABhQAAAYqAAAGQAAABlYAAAZsAAAGggAABpgAAAauAAAGxAAABtoAAAbwAAAHBgAABxwAAAcyAAAHSAAAB14="
        )
        let jump = try base64(
            "AAAA1AAAABMAAADmAAAALQAAAPgAAABHAAABCgAAAGEAAAEcAAAAewAAAS4AAACVAAABQAAAAK8AAAFSAAAAyQAAAWQAAADjAAABdgAAAP0AAAGIAAABFwAAAZoAAAExAAABrAAAAUsAAAG+AAABZQAAAdAAAAF/AAAB4gAAAZkAAAH0AAABswAAAgYAAAHNAAACGAAAAecAAAIqAAACAQAAAjwAAAIbAAACTgAAAjUAAAJgAAACTwAAAnIAAAJpAAAChAAAAoMAAAKWAAACnQAAAqgAAAK3AAACugAAAtEAAALMAAAC6wAAAt4AAAMFAAAC8AAAAx8AAAMCAAADOQAAAxQAAANTAAADJgAAA20AAAM4AAADhwAAA0oAAAOhAAADXAAAA7sAAANuAAAD1QAAA4AAAAPvAAADkgAABAkAAAOkAAAEIwAAA7YAAAQ9AAADyAAABFcAAAPaAAAEcQAAA+wAAASLAAAD/gAABKUAAAQQAAAEvwAABCIAAATZAAAENAAABPMAAARGAAAFDQAABFgAAAUnAAAEagAABUEAAAR8AAAFWwAABI4AAAV1AAAEoAAABY8AAASyAAAFqQAABMQAAAXDAAAE1gAABd0AAAToAAAF9wAABPoAAAYRAAAFDAAABisAAAUeAAAGRQAABTAAAAZfAAAFQgAABnkAAAVUAAAGkwAABWYAAAatAAAFeAAABscAAAWKAAAG4QAABZwAAAb7AAAFrgAABxUAAAXAAAAHLwAABdIAAAdJAAAF5AAAB2MAAAX2AAAGCAAABhoAAAYsAAAGPgAABlAAAAZiAAAGdAAABoYAAAaYAAAGqgAABrwAAAbOAAAG4AAABvIAAAcEAAAHFgAABygAAAc6AAAHTAAAB14="
        )
        let range = try base64("AG4YrZWx///////zxbqHtieq//quXAAAAAAA")
        XCTAssertEqual([main.count, call.count, jump.count, range.count], [888, 344, 668, 27])

        var expected = [UInt8]()
        for index in 0..<100 {
            expected.append(0x41)
            expected.append(0xE8)
            appendUInt32LE(UInt32(bitPattern: Int32(index * 3 - 100)), to: &expected)
            expected.append(0x42)
            expected.append(0xE9)
            appendUInt32LE(UInt32(200 - index), to: &expected)
            expected.append(0x43)
            expected.append(contentsOf: [0x0F, 0x85])
            appendUInt32LE(UInt32(index * 7), to: &expected)
        }

        let decoder = try BCJ2Decompressor(
            main: TestChunkDecompressor(main, maximumRead: 7),
            call: TestChunkDecompressor(call, maximumRead: 5),
            jump: TestChunkDecompressor(jump, maximumRead: 3),
            range: TestChunkDecompressor(range, maximumRead: 1),
            expectedSize: UInt64(expected.count)
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 2), expected)
    }

    func testFiltersRejectBadPropertiesAndTruncation() throws {
        XCTAssertThrowsError(
            try DeltaFilterDecompressor(
                input: TestChunkDecompressor([], maximumRead: 1),
                distance: 0,
                expectedSize: 0
            )
        )

        let truncated = try BCJFilterDecompressor(
            input: TestChunkDecompressor([1, 2], maximumRead: 1),
            filter: .x86,
            expectedSize: 3
        )
        XCTAssertThrowsError(try drain(truncated, bufferSize: 8)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let badRange = try BCJ2Decompressor(
            main: TestChunkDecompressor([0x41], maximumRead: 1),
            call: TestChunkDecompressor([], maximumRead: 1),
            jump: TestChunkDecompressor([], maximumRead: 1),
            range: TestChunkDecompressor([1, 0, 0, 0, 0], maximumRead: 1),
            expectedSize: 1
        )
        XCTAssertThrowsError(try drain(badRange, bufferSize: 1))
    }

    func testSingleInputFiltersFinalizeTheirUpstreamDecoder() throws {
        let encoded: [UInt8] = [1, 2, 3, 4]
        let deltaInput = DeferredCompletionDecompressor(encoded)
        let delta = try DeltaFilterDecompressor(
            input: deltaInput,
            distance: 1,
            expectedSize: UInt64(encoded.count)
        )
        XCTAssertEqual(try drain(delta, bufferSize: 2), [1, 3, 6, 10])
        XCTAssertTrue(deltaInput.isFinished)

        let branchInput = DeferredCompletionDecompressor(encoded)
        let branch = try BCJFilterDecompressor(
            input: branchInput,
            filter: .x86,
            expectedSize: UInt64(encoded.count)
        )
        XCTAssertEqual(try drain(branch, bufferSize: 2), encoded)
        XCTAssertTrue(branchInput.isFinished)

        for makeFilter in [
            { try DeltaFilterDecompressor(
                input: DeferredCompletionDecompressor(encoded, trailing: [0xFF]),
                distance: 1,
                expectedSize: UInt64(encoded.count)
            ) as any Decompressor },
            { try BCJFilterDecompressor(
                input: DeferredCompletionDecompressor(encoded, trailing: [0xFF]),
                filter: .x86,
                expectedSize: UInt64(encoded.count)
            ) as any Decompressor },
        ] {
            XCTAssertThrowsError(try drain(makeFilter(), bufferSize: 2)) { error in
                guard case .malformed = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testBCJ2RejectsUnusedBytesInEveryInputStream() throws {
        let validRange: [UInt8] = [0, 0, 0, 0, 0]
        let variants: [([UInt8], [UInt8], [UInt8], [UInt8])] = [
            ([0x41, 0x42], [], [], validRange),
            ([0x41], [0x01], [], validRange),
            ([0x41], [], [0x01], validRange),
            ([0x41], [], [], validRange + [0x01]),
        ]
        for (main, call, jump, range) in variants {
            let decoder = try BCJ2Decompressor(
                main: TestChunkDecompressor(main, maximumRead: 64),
                call: TestChunkDecompressor(call, maximumRead: 64),
                jump: TestChunkDecompressor(jump, maximumRead: 64),
                range: TestChunkDecompressor(range, maximumRead: 64),
                expectedSize: 1
            )
            XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
                guard case .malformed = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    private func assertBranchDecode(
        encoded: [UInt8],
        expected: [UInt8],
        filter: SevenZipBranchFilter
    ) throws {
        for chunk in [1, 2, 3, 4, 5, 7, 31] {
            let decoder = try BCJFilterDecompressor(
                input: TestChunkDecompressor(encoded, maximumRead: chunk),
                filter: filter,
                expectedSize: UInt64(expected.count)
            )
            XCTAssertEqual(
                try drain(decoder, bufferSize: 3),
                expected,
                "input chunk \(chunk)"
            )
        }
    }

    private func assertBCJ2(
        main: [UInt8],
        call: [UInt8],
        jump: [UInt8],
        expected: [UInt8]
    ) throws {
        // 0x80000000 は初期確率 1/2 の最初の decision を converted(1) にする。
        let decoder = try BCJ2Decompressor(
            main: TestChunkDecompressor(main, maximumRead: 1),
            call: TestChunkDecompressor(call, maximumRead: 1),
            jump: TestChunkDecompressor(jump, maximumRead: 1),
            range: TestChunkDecompressor([0, 0x80, 0, 0, 0], maximumRead: 1),
            expectedSize: UInt64(expected.count)
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
    }

    private func drain(
        _ decoder: any Decompressor,
        bufferSize: Int
    ) throws -> [UInt8] {
        var result = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // storage は固定長配列で、decoder は返却 count より先へ書き込まない。
                try decoder.read(into: storage)
            }
            guard count > 0 else { throw KaitoError.malformed("test decoder stalled") }
            result.append(contentsOf: buffer[..<count])
            iterations += 1
            guard iterations < 1_000_000 else {
                throw KaitoError.malformed("test decoder did not terminate")
            }
        }
        return result
    }

    private func hex(_ string: String) throws -> [UInt8] {
        guard string.count.isMultiple(of: 2) else {
            throw KaitoError.malformed("odd test hex")
        }
        var result = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = end
        }
        return result
    }

    private func putUInt32LE(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func appendUInt32LE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func base64(_ string: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: string) else {
            throw KaitoError.malformed("invalid test base64")
        }
        return [UInt8](data)
    }
}

private final class TestChunkDecompressor: Decompressor {
    private let bytes: [UInt8]
    private let maximumRead: Int
    private var offset = 0

    init(_ bytes: [UInt8], maximumRead: Int) {
        self.bytes = bytes
        self.maximumRead = maximumRead
    }

    var isFinished: Bool { offset == bytes.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        let count = min(buffer.count, maximumRead, bytes.count - offset)
        buffer.copyBytes(from: bytes[offset..<(offset + count)])
        offset += count
        return count
    }
}

private final class DeferredCompletionDecompressor: Decompressor {
    private let bytes: [UInt8]
    private let trailing: [UInt8]
    private var offset = 0
    private var trailingOffset = 0
    private(set) var isFinished = false

    init(_ bytes: [UInt8], trailing: [UInt8] = []) {
        self.bytes = bytes
        self.trailing = trailing
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        if offset < bytes.count {
            let count = min(buffer.count, bytes.count - offset)
            buffer.copyBytes(from: bytes[offset..<(offset + count)])
            offset += count
            return count
        }
        if trailingOffset < trailing.count {
            let count = min(buffer.count, trailing.count - trailingOffset)
            buffer.copyBytes(from: trailing[trailingOffset..<(trailingOffset + count)])
            trailingOffset += count
            return count
        }
        isFinished = true
        return 0
    }
}
