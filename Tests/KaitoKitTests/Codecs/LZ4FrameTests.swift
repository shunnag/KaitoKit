import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LZ4FrameTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            let name: String
            let sha256: String
            let decoded_size: Int
            let decoded_sha256: String
        }
        struct Vector: Decodable { let length: Int; let xxh32: String }
        let fixtures: [Fixture]
        let xxh32_vectors: [Vector]
    }
    private var root: URL { TestFixtures.url("lz4-frame") }
    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }
    private func fixture(_ name: String) throws -> Data { try TestFixtures.base64("lz4-frame/" + name + ".lz4") }
    private func decode(_ bytes: Data, chunk: Int = 8191, limits: ReadLimits = ReadLimits(),
                        partialInput: Int = Int.max, workers: Int = 1) throws -> Data {
        let source = LZ4PartialSource(data: bytes, chunk: partialInput)
        let decoder: any Decompressor = workers > 1
            ? try LZ4FrameDecompressor.parallel(source: source, limits: limits, workers: workers)
            : try LZ4FrameDecompressor(source: source, limits: limits)
        var result = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        XCTAssertEqual(try decoder.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer[..<count])
        }
        XCTAssertTrue(decoder.isFinished)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }, 0)
        return result
    }

    func testParallelIndependentFramesMatchSerialAtEveryBufferBoundary() throws {
        for includeSize in [false, true] {
            for blockChecksum in [false, true] {
                for contentChecksum in [false, true] {
                    for storedSecond in [false, true] {
                        let (bytes, expected) = multiBlockFrame(
                            includeSize: includeSize, blockChecksum: blockChecksum,
                            contentChecksum: contentChecksum, storedSecond: storedSecond
                        )
                        let decoder = try LZ4FrameDecompressor.parallel(
                            source: LZ4PartialSource(data: bytes, chunk: 37), limits: ReadLimits(), workers: 4
                        )
                        XCTAssertTrue(decoder is ParallelLZ4FrameDecompressor)
                        for chunk in [1, 4_099, 65_536] {
                            XCTAssertEqual(try decode(bytes, chunk: chunk, partialInput: 37, workers: 4), expected)
                        }
                    }
                }
            }
        }
    }

    func testParallelFallbackPreservesSingleDependentLegacyAndConcatenatedFrames() throws {
        let (bytes, expected) = multiBlockFrame()
        let serial = try LZ4FrameDecompressor.parallel(
            source: DataByteSource(bytes), limits: ReadLimits(), workers: 1
        )
        XCTAssertFalse(serial is ParallelLZ4FrameDecompressor)
        for name in ["tiny", "linked-64k", "legacy-tiny"] {
            let encoded = try fixture(name)
            let decoder = try LZ4FrameDecompressor.parallel(
                source: DataByteSource(encoded), limits: ReadLimits(), workers: 4
            )
            XCTAssertFalse(decoder is ParallelLZ4FrameDecompressor, name)
            XCTAssertEqual(try decode(encoded, workers: 4), try decode(encoded), name)
        }
        XCTAssertEqual(try decode(bytes + bytes, workers: 4), expected + expected)
        let constrained = try LZ4FrameDecompressor.parallel(
            source: DataByteSource(bytes), limits: ReadLimits(parallelDecodeMemory: 1), workers: 4
        )
        XCTAssertFalse(constrained is ParallelLZ4FrameDecompressor)
        XCTAssertEqual(try decode(bytes, limits: ReadLimits(parallelDecodeMemory: 1), workers: 4), expected)
    }

    func testParallelMutationsPreservePartialOutputErrorsAndFailedBuffers() throws {
        for contentChecksum in [false, true] {
            let (bytes, _) = multiBlockFrame(blockChecksum: true, contentChecksum: contentChecksum)
            var badContent = bytes
            badContent[badContent.count - 1] ^= 1
            var badBlock = bytes
            badBlock[7 + 4 + 166] ^= 1
            var badGrammar = bytes
            badGrammar[11] = 0xf0
            let firstBlock = Data(badGrammar[11..<(11 + 166)])
            badGrammar.replaceSubrange((11 + 166)..<(15 + 166), with: word(XXH32.digest(Array(firstBlock))))
            var badSecondGrammar = bytes
            badSecondGrammar.replaceSubrange(185..<191, with: [0xF0])
            badSecondGrammar.replaceSubrange(181..<185, with: word(1))
            badSecondGrammar.replaceSubrange(186..<190, with: word(XXH32.digest([0xF0])))
            let variants = [bytes, badContent, badBlock, badGrammar, badSecondGrammar,
                            Data(bytes.dropLast()), Data(bytes.dropLast(32)), bytes + Data([1, 2, 3, 4])]
            for (index, variant) in variants.enumerated() {
                for chunk in [1, 4_099, 65_536] {
                    let expected = streamOutcome(variant, chunk: chunk, workers: 1)
                    let actual = streamOutcome(variant, chunk: chunk, workers: 4)
                    let difference = zip(expected.failedBuffer ?? Data(), actual.failedBuffer ?? Data())
                        .enumerated().first { $0.element.0 != $0.element.1 }
                    XCTAssertEqual(actual, expected,
                                   "checksum \(contentChecksum), variant \(index), chunk \(chunk), buffer difference \(String(describing: difference))")
                }
            }
        }
    }

    func testPublicReaderUsesParallelLZ4WithoutChangingEntryIdentity() throws {
        let (bytes, expected) = multiBlockFrame()
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(decodeThreads: 4))
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].uncompressedSize, nil)
        XCTAssertEqual(try reader.read(reader.entries[0]), expected)
        XCTAssertEqual(try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits()), nil)
    }

    func testBlockBatchFailureReplayMatchesSeparateUnits() throws {
        let first = try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 0) {
            InjectedLeaf(bytes: [65])
        }
        let second = try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 0) {
            InjectedLeaf(bytes: [66], failure: true)
        }
        let third = try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 0) {
            InjectedLeaf(bytes: [67])
        }
        let batch = try ParallelIndependentDecompressor.Unit(outputSize: 2, scratchBytes: 0) {
            LZ4FrameBlockBatch(units: [first, second])
        }
        for chunk in [1, 4_099, 65_536] {
            let separate = try XCTUnwrap(ParallelIndependentDecompressor(
                units: [first, second, third], limits: ReadLimits(), workers: 2
            ))
            let batched = try XCTUnwrap(ParallelIndependentDecompressor(
                units: [batch, third], limits: ReadLimits(), workers: 2
            ))
            XCTAssertEqual(streamOutcome(batched, chunk: chunk), streamOutcome(separate, chunk: chunk))
        }
    }

    private final class InjectedLeaf: Decompressor {
        private let bytes: [UInt8]
        private let failure: Bool
        private var offset = 0
        var isFinished: Bool { !failure && offset == bytes.count }

        init(bytes: [UInt8], failure: Bool = false) {
            self.bytes = bytes
            self.failure = failure
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            if failure { throw KaitoError.malformed("injected LZ4 block failure") }
            guard !buffer.isEmpty, !isFinished else { return 0 }
            let count = min(buffer.count, bytes.count - offset)
            bytes.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + count)]))
            }
            offset += count
            return count
        }
    }

    private func streamOutcome(_ current: any Decompressor, chunk: Int) -> StreamOutcome {
        var result = Data(), buffer = [UInt8](repeating: 0xa5, count: chunk)
        do {
            while true {
                let count = try buffer.withUnsafeMutableBytes { try current.read(into: $0) }
                if count == 0 { return StreamOutcome(bytes: result, error: nil, failedBuffer: nil, finished: current.isFinished) }
                result.append(contentsOf: buffer[..<count])
            }
        } catch {
            return StreamOutcome(bytes: result, error: String(reflecting: error),
                                 failedBuffer: Data(buffer), finished: current.isFinished)
        }
    }

    private struct StreamOutcome: Equatable {
        let bytes: Data
        let error: String?
        let failedBuffer: Data?
        let finished: Bool
    }

    private func streamOutcome(_ bytes: Data, chunk: Int, workers: Int) -> StreamOutcome {
        var result = Data(), buffer = [UInt8](repeating: 0xa5, count: chunk)
        var decoder: (any Decompressor)?
        do {
            let source = LZ4PartialSource(data: bytes, chunk: 37)
            let current: any Decompressor = workers > 1
                ? try LZ4FrameDecompressor.parallel(source: source, limits: ReadLimits(), workers: workers)
                : try LZ4FrameDecompressor(source: source, limits: ReadLimits())
            decoder = current
            while true {
                let count = try buffer.withUnsafeMutableBytes { try current.read(into: $0) }
                if count == 0 { return StreamOutcome(bytes: result, error: nil, failedBuffer: nil, finished: current.isFinished) }
                result.append(contentsOf: buffer[..<count])
            }
        } catch {
            return StreamOutcome(bytes: result, error: String(reflecting: error),
                                 failedBuffer: Data(buffer), finished: decoder?.isFinished ?? false)
        }
    }

    private func multiBlockFrame(includeSize: Bool = false, blockChecksum: Bool = false,
                                 contentChecksum: Bool = true, storedSecond: Bool = false,
                                 includeEmpty: Bool = false) -> (Data, Data) {
        let sequence: [UInt8] = [0x14, 65, 1, 0]
        let first: [UInt8] = Array(repeating: sequence, count: 40).flatMap { $0 } + [0x50, 66, 67, 68, 69, 70]
        let payload: [UInt8] = [71, 72, 73, 74, 75]
        let encodedSecond = storedSecond ? payload : [0x50] + payload
        let expected = Data(repeating: 65, count: 360) + Data([66, 67, 68, 69, 70] + payload)
        func encodedBlock(_ bytes: [UInt8], stored: Bool) -> Data {
            var result = word(UInt32(bytes.count) | (stored ? 0x8000_0000 : 0)) + Data(bytes)
            if blockChecksum { result += word(XXH32.digest(bytes)) }
            return result
        }
        var flags: UInt8 = 0x60
        if includeSize { flags |= 8 }
        if blockChecksum { flags |= 16 }
        if contentChecksum { flags |= 4 }
        let optional = includeSize
            ? Data((0..<8).map { UInt8(truncatingIfNeeded: UInt64(expected.count) >> (8 * $0)) }) : Data()
        let empty = includeEmpty ? encodedBlock([], stored: true) + encodedBlock([0], stored: false) : Data()
        var result = frame(flags: flags, blockDescriptor: 0x40, optional: optional,
                           blocks: empty + encodedBlock(first, stored: false) + encodedBlock(encodedSecond, stored: storedSecond))
        if contentChecksum { result += word(XXH32.digest(Array(expected))) }
        return (result, expected)
    }

    func testParallelEmptyCompressedAndStoredBlocksMakeProgress() throws {
        for blockChecksum in [false, true] {
            for contentChecksum in [false, true] {
                let (bytes, expected) = multiBlockFrame(
                    blockChecksum: blockChecksum, contentChecksum: contentChecksum, includeEmpty: true
                )
                for chunk in [1, 4_099, 65_536] {
                    XCTAssertEqual(try decode(bytes, chunk: chunk, workers: 4), expected)
                }
            }
        }
    }

    func testCancelledParallelDecodeRemainsSticky() async throws {
        let (bytes, _) = multiBlockFrame()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let decoder = try LZ4FrameDecompressor.parallel(
                source: DataByteSource(bytes), limits: ReadLimits(), workers: 4
            )
            var output = [UInt8](repeating: 0, count: 37)
            do {
                _ = try output.withUnsafeMutableBytes { try decoder.read(into: $0) }
                return false
            } catch is CancellationError {
                do {
                    _ = try output.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    return false
                } catch is CancellationError { return true }
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
    }

    func testStreamingXXH32MatchesIndependentCLIAtStripeAndInputBoundaries() throws {
        for vector in try manifest().xxh32_vectors {
            let input = (0..<vector.length).map { UInt8(($0 * 73 + 19) & 255) }
            let expected = try XCTUnwrap(UInt32(vector.xxh32, radix: 16))
            for chunk in [1, 3, 15, 16, 17, 31, 32, 4093, 65539] {
                var checksum = XXH32()
                for start in stride(from: 0, to: input.count, by: chunk) {
                    checksum.update(input[start..<min(start + chunk, input.count)])
                    let snapshot = checksum.value
                    checksum.update(input[0..<0])
                    XCTAssertEqual(checksum.value, snapshot)
                }
                XCTAssertEqual(checksum.value, expected, "\(vector.length) bytes, chunk \(chunk)")
            }
        }
    }

    func testAllIndependentFixturesMatchEveryDecodedByteAndDeclaredSizes() throws {
        for item in try manifest().fixtures {
            let bytes = try fixture(item.name)
            XCTAssertEqual(bytes.sha256Hex, item.sha256, item.name)
            let output = try decode(bytes, chunk: item.name == "tiny" ? 1 : 65537, partialInput: 37)
            XCTAssertEqual(output.count, item.decoded_size, item.name)
            XCTAssertEqual(output.sha256Hex, item.decoded_sha256, item.name)
            let size = try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits())
            // The CLI intentionally omits a content-size field for empty input.
            XCTAssertEqual(size, (["empty", "no-checksum"].contains(item.name) || item.name.hasPrefix("legacy-")) ? nil : UInt64(item.decoded_size), item.name)
        }
    }

    func testConcatenatedFramesResetHistoryAndSkipEverySkippableMagic() throws {
        let tiny = try fixture("tiny"), linked = try fixture("linked-64k")
        let expected = try decode(tiny) + decode(linked)
        for magic: UInt32 in 0x184d2a50...0x184d2a5f {
            let skipped = word(magic) + word(7) + Data("ignored".utf8)
            let bytes = skipped + tiny + skipped + linked + skipped
            XCTAssertEqual(try decode(bytes, chunk: 257, partialInput: 3), expected)
            XCTAssertEqual(try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits()), UInt64(expected.count))
        }
        XCTAssertEqual(try decode(try fixture("empty") + tiny + fixture("empty")), try decode(tiny))
        XCTAssertThrowsError(try decode(tiny + Data([1, 2, 3, 4])))
        XCTAssertEqual(try decode(tiny + word(0x184c2102)), try decode(tiny), "An empty legacy frame has only its magic")
    }

    func testEveryTruncationAndChecksumCorruptionRejectsTypedWithoutRetryingInput() throws {
        let bytes = try fixture("tiny")
        for count in 0..<bytes.count {
            XCTAssertThrowsError(try decode(Data(bytes.prefix(count)))) { XCTAssertTrue($0 is KaitoError) }
        }
        for index in bytes.indices {
            var modified = bytes
            modified[index] ^= 1
            let decoder = try LZ4FrameDecompressor(source: DataByteSource(modified))
            var output = [UInt8](repeating: 0, count: 2048)
            var failure: KaitoError?
            do {
                while try output.withUnsafeMutableBytes({ try decoder.read(into: $0) }) > 0 {}
                XCTFail("Corrupted byte \(index) was accepted")
            } catch { failure = try XCTUnwrap(error as? KaitoError) }
            XCTAssertThrowsError(try output.withUnsafeMutableBytes { try decoder.read(into: $0) }) {
                XCTAssertEqual($0 as? KaitoError, failure)
            }
        }
    }

    func testFrameFlagsDictionaryAndGlobalOutputLimitsAreEnforcedInEveryFrame() throws {
        let tiny = try fixture("tiny"), empty = try fixture("empty")
        for flags: UInt8 in [0, 0x80, 0xc0, 0x62] {
            XCTAssertThrowsError(try decode(frame(flags: flags, blockDescriptor: 0x40)))
        }
        for descriptor: UInt8 in [0, 0x30, 0x41, 0xc0, 0x80] {
            XCTAssertThrowsError(try decode(frame(flags: 0x60, blockDescriptor: descriptor)))
        }
        for identifier: UInt32 in [0, 1, UInt32.max] {
            let dictionary = frame(flags: 0x61, blockDescriptor: 0x40, optional: word(identifier))
            for input in [dictionary, tiny + dictionary] {
                XCTAssertThrowsError(try decode(input)) {
                    XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("LZ4 external dictionary \(identifier)"))
                }
                XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source: DataByteSource(input), limits: ReadLimits()))
            }
        }
        for limits in [ReadLimits(maxEntrySize: 1032), ReadLimits(maxDictionarySize: 1032)] {
            XCTAssertThrowsError(try decode(tiny, limits: limits))
            XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source: DataByteSource(tiny), limits: limits))
        }
        XCTAssertThrowsError(try decode(tiny + tiny, limits: ReadLimits(maxEntrySize: 2065)))
        XCTAssertThrowsError(try decode(try fixture("no-checksum"), limits: ReadLimits(maxEntrySize: 65536)))
        XCTAssertThrowsError(try decode(empty + empty + empty, limits: ReadLimits(maxMetadataRecordCount: 2)))
        XCTAssertThrowsError(try decode(try fixture("linked-64k"), limits: ReadLimits(maxMetadataRecordCount: 2)))
        let huge = frame(flags: 0x68, blockDescriptor: 0x40, optional: Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try decode(huge))
        let oversizedBlock = frame(flags: 0x60, blockDescriptor: 0x40, blocks: word(0x80010001))
        XCTAssertThrowsError(try decode(oversizedBlock))
    }

    func testEmptyStoredBlockIsNotEndAndHasItsOwnChecksum() throws {
        let emptyBlock = word(0x80000000) + word(0x02cc5d05)
        let bytes = frame(flags: 0x70, blockDescriptor: 0x40, blocks: emptyBlock)
        XCTAssertEqual(try decode(bytes), Data())
        XCTAssertEqual(try decode(bytes + fixture("tiny")), try decode(fixture("tiny")))
        var bad = bytes
        bad[11] ^= 1
        XCTAssertThrowsError(try decode(bad)) { XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 0)) }
    }

    func testRawBlocksRejectInvalidDistancesLengthsAndEndConditions() throws {
        for invalid: [UInt8] in [[], [0xf0], [0x10], [0x10, 65, 0, 0], [0x00, 1, 0],
                                [0x10, 65, 1, 0], [0x1f, 65, 1, 0, 255, 255],
                                [0x10, 65, 1, 0, 0x10, 66]] {
            XCTAssertThrowsError(try LZ4BlockDecoder.decode(invalid, history: [], maximumSize: 64))
        }
        XCTAssertEqual(try LZ4BlockDecoder.decode([0], history: [], maximumSize: 0), [])
        // A one-byte-distance match overlaps itself, then ends with five literals.
        XCTAssertEqual(try LZ4BlockDecoder.decode([0x18, 65, 1, 0, 0x50, 66, 67, 68, 69, 70], history: [], maximumSize: 18),
                       [UInt8](repeating: 65, count: 13) + [66, 67, 68, 69, 70])
        // Starts in preceding block history, then crosses into current output.
        XCTAssertEqual(try LZ4BlockDecoder.decode([0x08, 2, 0, 0x50, 66, 67, 68, 69, 70], history: [65, 66], maximumSize: 17),
                       Array(repeating: [UInt8(65), 66], count: 6).flatMap { $0 } + [66, 67, 68, 69, 70])
    }

    func testPublicReaderDetectsSharedSkippableFramesAndPreservesFallbackNames() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tiny = try fixture("tiny")
        let skipped = word(0x184d2a5f) + word(3) + Data([7, 8, 9])
        for bytes in [tiny, skipped + tiny + skipped] {
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .lz4)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .lz4)
            XCTAssertEqual(reader.entries[0].name, "data")
            XCTAssertEqual(reader.entries[0].methodDescription, "LZ4")
            XCTAssertEqual(try reader.read(reader.entries[0]), try decode(tiny))
        }
        XCTAssertEqual(try FormatDetector.detect(data: skipped), .zstd, "Preserve the existing ambiguous-stream policy")
        XCTAssertThrowsError(try FormatDetector.detect(data: skipped + skipped + tiny,
            options: ReaderOptions(limits: ReadLimits(maxMetadataRecordCount: 1))))
        for name in ["payload.lz4", "payload.LZ4", "unrelated.zip"] {
            let url = temporary.appendingPathComponent(name)
            try tiny.write(to: url)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .lz4, "Content takes precedence over suffix")
            XCTAssertEqual(reader.entries[0].name, name == "unrelated.zip" ? name : "payload")
            try FileManager.default.removeItem(at: url)
            let reopened = try reader.reopen()
            XCTAssertEqual(try reopened.read(reopened.entries[0]), try decode(tiny))
        }
    }

    func testCompressedTarMemoryDiskSplitUnlinkAndReopenPreserveEveryMember() throws {
        for name in ["tar-linked", "legacy-tar"] { try assertCompressedTar(name) }
    }

    private func assertCompressedTar(_ name: String) throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoded = try fixture(name)
        let expected = try decode(encoded)
        let plain = try TarReader(source: DataByteSource(expected), options: ReaderOptions())
        let payloads = try Dictionary(uniqueKeysWithValues: plain.entries.map { entry in
            (entry.name, try plain.stream(for: entry, limits: ReadLimits()).readAll())
        })
        XCTAssertEqual(Set(payloads.keys), ["folder/first.bin", "note.txt", "empty"])
        XCTAssertEqual(payloads["note.txt"], Data("LZ4 frame fixture\n".utf8))
        for threshold: UInt64 in [UInt64.max, 0] {
            for split in [false, true] {
                let name = "archive-\(threshold)-\(split).tar.LZ4"
                let url = temporary.appendingPathComponent(name + (split ? ".001" : ""))
                let parts = split ? stride(from: 0, to: encoded.count, by: 128).enumerated().map { index, start in
                    (temporary.appendingPathComponent(name + String(format: ".%03d", index + 1)), Data(encoded[start..<min(start + 128, encoded.count)]))
                } : [(url, encoded)]
                for (file, data) in parts { try data.write(to: file) }
                // Aggregate limits apply to published member bytes, not tar
                // headers/padding in the temporary staging stream.
                let limits = ReadLimits(maxTotalUncompressedSize: UInt64(payloads.values.reduce(0) { $0 + $1.count }),
                                        inMemorySingleFileLimit: threshold)
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: limits))
                XCTAssertEqual(reader.format, .tar)
                for (file, _) in parts { try FileManager.default.removeItem(at: file) }
                let reopened = try reader.reopen()
                for source in [reader, reopened] {
                    for entry in source.entries.reversed() {
                        XCTAssertEqual(try source.read(entry), payloads[entry.name])
                    }
                }
            }
        }
    }

    func testPublicReaderAggregateAndMemoryLimitsIncludeUnknownAndConcatenatedSizes() throws {
        for name in ["tiny", "no-checksum", "legacy-tiny"] {
            let encoded = try fixture(name)
            let expected = try decode(encoded)
            for keyPath in [\ReadLimits.maxEntrySize, \ReadLimits.maxTotalUncompressedSize, \ReadLimits.maxInMemorySize] {
                var exact = ReadLimits()
                exact[keyPath: keyPath] = UInt64(expected.count)
                let reader = try ArchiveReader.open(data: encoded, options: ReaderOptions(limits: exact))
                XCTAssertEqual(try reader.read(reader.entries[0]), expected)
                var short = exact
                short[keyPath: keyPath] -= 1
                XCTAssertThrowsError(try {
                    let rejected = try ArchiveReader.open(data: encoded, options: ReaderOptions(limits: short))
                    _ = try rejected.read(rejected.entries[0])
                }()) { guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") } }
            }
        }
        let tiny = try fixture("tiny")
        XCTAssertThrowsError(try ArchiveReader.open(data: tiny + tiny,
            options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 2065))))
    }

    func testCancelledDecodeStopsBeforeReadingFramePayload() async throws {
        let bytes = try fixture("independent-4m")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let decoder = try LZ4FrameDecompressor(source: DataByteSource(bytes))
            var output = [UInt8](repeating: 0, count: 37)
            do {
                _ = try output.withUnsafeMutableBytes { try decoder.read(into: $0) }
                return false
            } catch is CancellationError {
                do {
                    _ = try output.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    return false
                } catch is CancellationError { return true }
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
    }

    private func word(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func frame(flags: UInt8, blockDescriptor: UInt8, optional: Data = Data(), blocks: Data = Data()) -> Data {
        let descriptor = [flags, blockDescriptor] + Array(optional)
        let check = UInt8(truncatingIfNeeded: XXH32.digest(descriptor) >> 8)
        return word(0x184d2204) + Data(descriptor) + Data([check]) + blocks + word(0)
    }
}

private struct LZ4PartialSource: ByteSource {
    let data: Data
    let chunk: Int
    var length: UInt64 { UInt64(data.count) }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try DataByteSource(data).read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(min(chunk, buffer.count))), at: offset)
    }
}
