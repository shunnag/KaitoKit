import Foundation
@testable import KaitoKit
import XCTest

final class LZMA2DecoderTests: XCTestCase {
    func testCompressedChunkWithTinyReads() throws {
        // xz 5.8.3: `xz --format=raw --lzma2=dict=64KiB` が
        // `abcabcabcabcabcabc` に生成した complete raw stream。
        let stream = try Hex.data("e0001100085d00309888aa0207d00000")
        let expected = Data("abcabcabcabcabcabc".utf8)
        let decoder = try makeDecoder(stream, expectedSize: UInt64(expected.count))

        XCTAssertEqual(try drain(decoder, bufferSize: 1), expected)
        XCTAssertTrue(decoder.isFinished)
    }

    func testPropertyResetsGrowAndShrinkTheActiveLiteralModels() throws {
        // 7zz 26.04 generated the lc=4 (0x5e) vector with
        // -m0=LZMA2:lc=4:lp=0:pb=2:d=64k -ms=off -mhc=off.
        let vectors = [
            try Hex.data("e00011000800003099abddc0cb070000"), // lc=0
            try Hex.data("e0001100085d00309888aa0207d00000"), // lc=3
            try Hex.data("e0001100085e00309888aa0207d00000"), // lc=4
        ]
        var stream = Data()
        var expected = Data()
        let payload = Data("abcabcabcabcabcabc".utf8)
        for index in [0, 2, 1, 0, 1, 2, 0] {
            // Dictionary resets make each independently generated range stream
            // valid. Models must also reset to the newly active property count.
            stream.append(vectors[index].dropLast())
            expected.append(payload)
        }
        stream.append(0)
        for size in [1, 7, 128] {
            XCTAssertEqual(
                try drain(makeDecoder(stream, expectedSize: UInt64(expected.count)), bufferSize: size),
                expected
            )
        }
    }

    func testUncompressedChunks() throws {
        let stream = try Hex.data(
            "010002616263" + // dictionary reset: abc
            "020002646566" + // dictionary retained: def
            "00"
        )
        let decoder = try makeDecoder(stream, expectedSize: 6)

        XCTAssertEqual(try drain(decoder, bufferSize: 2), Data("abcdef".utf8))
    }

    func testStateResetWithoutDictionaryReset() throws {
        var first = Array(try Hex.data("e00011000800003099abddc0cb070000"))
        first.removeLast() // end control

        var second = first
        second[0] = 0xA0 // state reset; properties are retained
        second.remove(at: 5) // a 0xA0 chunk has no property byte

        let stream = Data(first + second + [0])
        let expectedPart = Data("abcabcabcabcabcabc".utf8)
        var expected = expectedPart
        expected.append(expectedPart)
        let decoder = try makeDecoder(stream, expectedSize: UInt64(expected.count))

        XCTAssertEqual(try drain(decoder, bufferSize: 5), expected)
    }

    func testStateResetPreservesLiteralAndPositionContextPosition() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "lzma2-position")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )

        var value: UInt32 = 0x1234_5678
        var payload = Data()
        payload.reserveCapacity(235_000)
        for _ in 0..<70_000 {
            value = value &* 1_664_525 &+ 1_013_904_223
            payload.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        let suffix = Array("context-position-test-0123456789\n".utf8)
        for _ in 0..<5_000 { payload.append(contentsOf: suffix) }
        _ = try SevenZipTestSupport.write(
            payload,
            relativePath: "position.bin",
            below: sourceDirectory
        )

        let archiveURL = temporary.appendingPathComponent("position.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: sourceDirectory,
            paths: ["position.bin"],
            archiveURL: archiveURL,
            options: [
                "-m0=LZMA2:d=64k:lc=2:lp=1:pb=2",
                "-ms=off",
                "-mhc=off",
            ]
        )

        let archiveBytes = [UInt8](try Data(contentsOf: archiveURL))
        XCTAssertGreaterThan(archiveBytes.count, 35)
        XCTAssertEqual(archiveBytes[32], 0x01)
        let rawSize = (Int(archiveBytes[33]) << 8) | Int(archiveBytes[34])
        let secondControl = 32 + 3 + rawSize + 1
        XCTAssertTrue(archiveBytes.indices.contains(secondControl))
        XCTAssertTrue((0xC0...0xDF).contains(archiveBytes[secondControl]))

        let reader = try ArchiveReader.open(url: archiveURL)
        let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testCompressedChunkRequiresTerminalRangeStateAndExactPackedUse() throws {
        let valid = Array(try Hex.data("e0001100085d00309888aa0207d00000"))

        var nonzeroTerminalCode = valid
        nonzeroTerminalCode[14] = 1
        XCTAssertThrowsError(
            try drain(
                makeDecoder(Data(nonzeroTerminalCode), expectedSize: 18),
                bufferSize: 7
            )
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var unusedPackedByte = valid
        unusedPackedByte[4] = 9 // packed size: 9 -> 10
        unusedPackedByte.insert(0xA5, at: 15)
        XCTAssertThrowsError(
            try drain(
                makeDecoder(Data(unusedPackedByte), expectedSize: 18),
                bufferSize: 7
            )
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPropertiesResetAfterUncompressedChunk() throws {
        var compressed = Array(try Hex.data("e00011000800003099abddc0cb070000"))
        compressed.removeLast()
        compressed[0] = 0xC0 // state/properties reset, dictionary retained

        let raw = Array(try Hex.data("01000278797a"))
        let stream = Data(raw + compressed + [0])
        let decoder = try makeDecoder(stream, expectedSize: 21)

        XCTAssertEqual(
            try drain(decoder, bufferSize: 4),
            Data("xyzabcabcabcabcabcabc".utf8)
        )
    }

    func testMultipleCompressedChunksRetainModelAndDictionary() throws {
        let encoded = """
        //9FAaFdACWYSSd39hmL+1Xsn5hwbtlGkCRo7yjc6v0a//JYp9YmDVjyy6lHjxcWR3I9+uixrPmsYzaKza/gu+DTF74o7C/WVv1RA8Ru5aY/NE1t+zmLWL7HX+SW+OhXsQf5oj9nF5HRfZJy6sVHO/wIHyygeDl1PE5fHD2ReCWDC/vT1iFtgN169eJ5615Z/MlXMTgolHEfPY8k4XCepyNf7CjLhdGVmIp+KpHyJ3X3GcAGmE2Y/div1ZAPxCVT+PWRNjEFpbDub8FwTUcM0ZERqq1gHbrOsScYXFmG6WZSWL7pdqxZ5OVbBQj5x9qt/PtSK3TNHlsgQvndUz34KWQJO4DLKmzftTvwxL0uX6oPPktmQpATDv8Qk/hxeFn4C83/lShGD6n8fN77mjAuVsCPhfODgcBlxCVT+PWRNjEFpbDub8FwTUcM0ZERqq1gHbrOsScYXFmG6WZSWL7pdqxZ5OVbBQj5x9qt/PtSK3TNHlsgQvndUz34KWQJO4DLKmzftTvwxL0uX6oPPktmQpATDv8Qk/hxeFn4C83/lShGD6n8d9izUp//EAErAOxzU6f9vq58MRqft40xbnCepyNf7CjLhdGVmIp+KpHyJ3X3GcAGmE2Y/div1ZAPxCVT+PWRNjEFpbDub8FwTUcM0ZERqq1gHbrOsScYXFmG6WZSWL7pdqxZ5OVbBQj5x9qt/PtSK3TNHlsgQvndUz34KWQJO4DLKmzftTvwxL0uX6oPPktmQpATDv8Qk/hxeFn4C83/lShGD6n8fN77mjAuVsCPhfODgcBlxCVT+PWRNjEFpbDub8FwTUcM0ZERqq1gHbrOsScYXFmG6WZSWL7pdqxZ5OVbBQj5x9qt/PtSK3TNHlsgQvndUz34KWQJO4DLKmzftTvwxL0uX6oPPktmQpATDv8Qk/hxeFn4C83/lShGD6n8fN77mjAuVsCPhfODgcBlxCVRDz+yjEzoAHcA7HNTp/2+rnwxGp+3jTFucJ6nI1/sKMuF0ZWYin4qkfIndfcZwAaYTZj92K/VkA/EJVP49ZE2MQWlsO5vwXBNRwzRkRGqrWAdus6xJxhcWYbpZlJYvul2rFnk5VsFCPnH2q38+1IrdM0eWyBC+d1TPfgklULDAAAA
        """
        let stream = try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
        let pattern = Array("KaitoKit-LZMA2-streaming-dictionary-state-0123456789\n".utf8)
        var expected = Data()
        expected.reserveCapacity(5_000_000)
        while expected.count < 5_000_000 {
            let amount = min(pattern.count, 5_000_000 - expected.count)
            expected.append(contentsOf: pattern.prefix(amount))
        }

        let decoder = try makeDecoder(
            stream,
            property: 8, // 64 KiB
            expectedSize: 5_000_000,
            dictionarySizeLimit: 64 * 1_024
        )
        XCTAssertEqual(try drain(decoder, bufferSize: 8_191), expected)
    }

    func testDictionaryResetIndexUsesAbsoluteCompressedOffsets() throws {
        var chunk = Array(try Hex.data("e0001100085d00309888aa0207d00000"))
        chunk.removeLast()
        let stream = Data(chunk + chunk + [0])
        let prefix = Data(repeating: 0xCC, count: 7)
        var wrapped = prefix
        wrapped.append(stream)
        let source = DataByteSource(wrapped)

        let points = try LZMA2Decoder.makeDictionaryResetIndex(
            source: source,
            offset: 7,
            compressedSize: UInt64(stream.count),
            expectedSize: 36
        )
        XCTAssertEqual(
            points,
            [
                LZMA2ResetPoint(
                    compressedOffset: 7,
                    uncompressedOffset: 0,
                    lzmaProperties: 0x5D
                ),
                LZMA2ResetPoint(
                    compressedOffset: 7 + UInt64(chunk.count),
                    uncompressedOffset: 18,
                    lzmaProperties: 0x5D
                ),
            ]
        )

        let restarted = try LZMA2Decoder(
            source: source,
            originalOffset: 7,
            originalCompressedSize: UInt64(stream.count),
            properties: [0],
            restartingAt: points[1],
            expectedSize: 18,
            dictionarySizeLimit: 4_096
        )
        XCTAssertEqual(
            try drain(restarted, bufferSize: 3),
            Data("abcabcabcabcabcabc".utf8)
        )
    }

    func testRestartAtRawDictionaryResetFollowedByPropertiesChunk() throws {
        var compressed = Array(try Hex.data("e00011000800003099abddc0cb070000"))
        compressed.removeLast()
        // 0x01 の後の LZMA chunk は property 付き（0xC0 以上）でなければならない。
        var continued = compressed
        continued[0] = 0xC0
        let rawReset = Array(try Hex.data("01000278797a"))
        let stream = Data(compressed + rawReset + continued + [0])
        let source = DataByteSource(stream)
        let points = try LZMA2Decoder.makeDictionaryResetIndex(
            source: source,
            offset: 0,
            compressedSize: UInt64(stream.count),
            expectedSize: 39
        )
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].lzmaProperties, 0)
        XCTAssertTrue(points[1].isRestartable)

        let whole = try makeDecoder(stream, expectedSize: 39)
        XCTAssertEqual(
            try drain(whole, bufferSize: 5),
            Data("abcabcabcabcabcabcxyzabcabcabcabcabcabc".utf8)
        )

        let restarted = try LZMA2Decoder(
            source: source,
            originalOffset: 0,
            originalCompressedSize: UInt64(stream.count),
            properties: [0],
            restartingAt: points[1],
            expectedSize: 21,
            dictionarySizeLimit: 4_096
        )
        XCTAssertEqual(
            try drain(restarted, bufferSize: 4),
            Data("xyzabcabcabcabcabcabc".utf8)
        )
    }

    func testDictionaryPropertyLimitIsCheckedBeforeAllocation() throws {
        let stream = Data([0])
        XCTAssertEqual(try LZMA2Decoder.dictionarySize(for: 0), 4_096)
        XCTAssertEqual(try LZMA2Decoder.dictionarySize(for: 1), 6_144)
        XCTAssertEqual(try LZMA2Decoder.dictionarySize(for: 40), UInt64(UInt32.max))

        XCTAssertThrowsError(
            try makeDecoder(
                stream,
                property: 40,
                expectedSize: 0,
                dictionarySizeLimit: 64 * 1_024 * 1_024
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try makeDecoder(stream, property: 41, expectedSize: 0)
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidControlStatePropertiesAndTrailingBytes() throws {
        let invalidStreams: [Data] = [
            Data([0x03, 0, 0, 0]),
            Data([0x02, 0, 0, 0]),
            Data([0x00, 0xFF]),
            // lc=4, lp=1 violates the LZMA2 lc+lp <= 4 rule.
            try Hex.data("e0000000040d000000000000"),
        ]
        for stream in invalidStreams {
            let decoder = try makeDecoder(stream, expectedSize: nil)
            XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
                guard case .malformed = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }

    }

    func testLZMAChunkWithoutPropertiesAfterRawDictionaryResetIsRejected() throws {
        // LZMA SDK / liblzma / 7-Zip と同じく、0x01 の後の 0x80...0xBF（property なし）は壊れた stream。
        // 0x01 が最初の chunk でも、間に 0x02 が挟まっても同じ。
        var first = Array(try Hex.data("e0001100085d00309888aa0207d00000"))
        first.removeLast()
        let rawReset = Array(try Hex.data("01000078"))
        let rawKeep = Array(try Hex.data("02000079"))
        var noProperties = first
        noProperties.remove(at: 5)
        var stateOnly = noProperties
        stateOnly[0] = 0xA0
        noProperties[0] = 0x80
        let invalidStreams: [(Data, UInt64)] = [
            (Data(first + rawReset + noProperties + [0]), 37),
            (Data(first + rawReset + stateOnly + [0]), 37),
            (Data(first + rawReset + rawKeep + noProperties + [0]), 38),
            (Data(rawReset + noProperties + [0]), 19),
            (Data(rawReset + stateOnly + [0]), 19),
        ]
        for (stream, expectedSize) in invalidStreams {
            let source = DataByteSource(stream)
            XCTAssertThrowsError(
                try LZMA2Decoder.makeDictionaryResetIndex(
                    source: source,
                    offset: 0,
                    compressedSize: UInt64(stream.count),
                    expectedSize: expectedSize
                ),
                stream.map { String($0, radix: 16) }.joined(separator: " ")
            ) { error in
                guard case let .malformed(reason) = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains("before properties"), reason)
            }
            XCTAssertThrowsError(
                try LZMA2Decoder.makeParallelDictionaryResetIndex(
                    source: source,
                    offset: 0,
                    compressedSize: UInt64(stream.count),
                    expectedSize: expectedSize,
                    maximumPointCount: 16,
                    singleResetOutputLimit: 1 << 20
                )
            ) { error in
                guard case .malformed = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            let decoder = try makeDecoder(stream, expectedSize: expectedSize)
            XCTAssertThrowsError(try drain(decoder, bufferSize: 8)) { error in
                guard case let .malformed(reason) = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains("before properties"), reason)
            }
        }
    }

    func testRawChunkWithoutDictionaryResetKeepsCodingStateAndProperties() throws {
        // 0x02 は何も初期化し直さないので、その後の 0x80 / 0xA0（property なし）は引き続き有効。
        // lc=0 の fixture を使い、直前 byte が literal の文脈に影響しないようにする。
        var first = Array(try Hex.data("e00011000800003099abddc0cb070000"))
        first.removeLast()
        let rawKeep = Array(try Hex.data("02000078"))
        var stateOnly = first
        stateOnly.remove(at: 5)
        stateOnly[0] = 0xA0
        var noReset = stateOnly
        noReset[0] = 0x80
        let stream = Data(first + rawKeep + stateOnly + [0])
        let points = try LZMA2Decoder.makeDictionaryResetIndex(
            source: DataByteSource(stream),
            offset: 0,
            compressedSize: UInt64(stream.count),
            expectedSize: 37
        )
        XCTAssertEqual(points.count, 1)
        let decoder = try makeDecoder(stream, expectedSize: 37)
        XCTAssertEqual(
            try drain(decoder, bufferSize: 8),
            Data("abcabcabcabcabcabcxabcabcabcabcabcabc".utf8)
        )
        // 0x80（state も引き継ぐ）も header としては有効で、index 走査は受け付ける。
        let continued = Data(first + rawKeep + noReset + [0])
        XCTAssertEqual(
            try LZMA2Decoder.makeDictionaryResetIndex(
                source: DataByteSource(continued),
                offset: 0,
                compressedSize: UInt64(continued.count),
                expectedSize: 37
            ).count,
            1
        )

        // 先頭の 0x01 の後に 0xC0 が続く stream は有効で、その点から再開できる。
        let rawReset = Array(try Hex.data("01000078"))
        var withProperties = first
        withProperties[0] = 0xC0
        let leading = Data(rawReset + withProperties + [0])
        let leadingPoints = try LZMA2Decoder.makeDictionaryResetIndex(
            source: DataByteSource(leading),
            offset: 0,
            compressedSize: UInt64(leading.count),
            expectedSize: 19
        )
        XCTAssertEqual(leadingPoints.count, 1)
        XCTAssertTrue(leadingPoints[0].isRestartable)
        XCTAssertNil(leadingPoints[0].lzmaProperties)
        let leadingDecoder = try makeDecoder(leading, expectedSize: 19)
        XCTAssertEqual(
            try drain(leadingDecoder, bufferSize: 8),
            Data("xabcabcabcabcabcabc".utf8)
        )
    }

    func testSevenZipRawChunksCanContinueWithoutStateReset() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "lzma2-raw-state")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )

        var state: UInt64 = 0x0123_4567_89AB_CDEF
        var payload = Data()
        payload.reserveCapacity(8 * 65_536)
        for _ in 0..<4 {
            var block = [UInt8]()
            block.reserveCapacity(65_536)
            for _ in 0..<65_536 {
                state = state &* 6_364_136_223_846_793_005
                    &+ 1_442_695_040_888_963_407
                block.append(UInt8(truncatingIfNeeded: state >> 32))
            }
            payload.append(contentsOf: block)
            payload.append(contentsOf: block)
        }
        _ = try SevenZipTestSupport.write(
            payload,
            relativePath: "payload.bin",
            below: sourceDirectory
        )
        let archive = temporary.appendingPathComponent("state.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: archive,
            options: ["-m0=LZMA2", "-mx=9", "-ms=off", "-mhc=off"]
        )

        let archiveBytes = [UInt8](try Data(contentsOf: archive))
        let packedSize = littleUInt64(archiveBytes, at: 12)
        let packedSizeInt = try Checked.toInt(packedSize)
        let controls = try lzma2Controls(
            archiveBytes,
            range: 32..<(32 + packedSizeInt)
        )
        XCTAssertTrue(
            zip(controls, controls.dropFirst()).contains {
                ($0.0 == 0x01 || $0.0 == 0x02) && (0x80..<0xA0).contains($0.1)
            },
            "fixture must contain raw -> LZMA without a state reset"
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "payload.bin" })
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testRejectsTruncationAndExpectedSizeMismatch() throws {
        let truncated = try Hex.data("e0001100085d00309888")
        let truncatedDecoder = try makeDecoder(truncated, expectedSize: 18)
        XCTAssertThrowsError(try drain(truncatedDecoder, bufferSize: 8)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let raw = try Hex.data("0100006100")
        let mismatchDecoder = try makeDecoder(raw, expectedSize: 2)
        XCTAssertThrowsError(try drain(mismatchDecoder, bufferSize: 8)) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testThreeHundredTwentyDeterministicMutantsDoNotHangOrCrash() throws {
        let seed = Array(try Hex.data("e0001100085d00309888aa0207d00000"))
        var completed = 0
        for mutation in 0..<320 {
            var bytes = seed
            let index = (mutation * 11 + 3) % bytes.count
            let bit = UInt8(1) << UInt8(mutation % 8)
            bytes[index] ^= bit
            do {
                let decoder = try makeDecoder(Data(bytes), expectedSize: 18)
                _ = try drain(decoder, bufferSize: 7)
            } catch {
                // 変異入力は正常終了または構造化 error のどちらでもよい。
            }
            completed += 1
        }
        XCTAssertEqual(completed, 320)
    }

    private func littleUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private func lzma2Controls(
        _ bytes: [UInt8],
        range: Range<Int>
    ) throws -> [UInt8] {
        guard range.lowerBound >= 0,
              range.upperBound <= bytes.count,
              !range.isEmpty else {
            throw KaitoError.truncated
        }
        var cursor = range.lowerBound
        var result: [UInt8] = []
        while cursor < range.upperBound {
            let control = bytes[cursor]
            cursor += 1
            result.append(control)
            if control == 0 {
                guard cursor == range.upperBound else {
                    throw KaitoError.malformed("test LZMA2 stream has trailing bytes")
                }
                return result
            }
            if control < 0x80 {
                guard control == 0x01 || control == 0x02,
                      cursor <= range.upperBound - 2 else {
                    throw KaitoError.truncated
                }
                let size = (Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])) + 1
                cursor += 2
                guard cursor <= range.upperBound - size else {
                    throw KaitoError.truncated
                }
                cursor += size
                continue
            }

            guard cursor <= range.upperBound - 4 else { throw KaitoError.truncated }
            let packedSize = (Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])) + 1
            cursor += 4
            if control >= 0xC0 {
                guard cursor < range.upperBound else { throw KaitoError.truncated }
                cursor += 1
            }
            guard cursor <= range.upperBound - packedSize else {
                throw KaitoError.truncated
            }
            cursor += packedSize
        }
        throw KaitoError.truncated
    }

    private func makeDecoder(
        _ stream: Data,
        property: UInt8 = 0,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64 = 1 << 20
    ) throws -> LZMA2Decoder {
        try LZMA2Decoder(
            source: DataByteSource(stream),
            offset: 0,
            compressedSize: UInt64(stream.count),
            properties: [property],
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
        )
    }

    /// 終わらない decoder で止まらないよう、読む回数に上限を置く。
    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        try KaitoKitTests.drain(decoder, bufferSize: bufferSize, maxReads: 1_000_000)
    }
}
