import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipSwapTests: XCTestCase {
    func testOracleVectorsAcrossEverySmallInputAndOutputBoundary() throws {
        // Raw packed bytes from 7zz 26.03, -m0=SwapN -m1=Copy -mhc=off.
        // Each row encodes 0..<row.count, including final incomplete units.
        let vectors: [(Int, [[UInt8]])] = [
            (2, [[], [0], [1, 0], [1, 0, 2], [1, 0, 3, 2], [1, 0, 3, 2, 4],
                 [1, 0, 3, 2, 5, 4], [1, 0, 3, 2, 5, 4, 6],
                 [1, 0, 3, 2, 5, 4, 7, 6], [1, 0, 3, 2, 5, 4, 7, 6, 8]]),
            (4, [[], [0], [0, 1], [0, 1, 2], [3, 2, 1, 0], [3, 2, 1, 0, 4],
                 [3, 2, 1, 0, 4, 5], [3, 2, 1, 0, 4, 5, 6],
                 [3, 2, 1, 0, 7, 6, 5, 4], [3, 2, 1, 0, 7, 6, 5, 4, 8]])
        ]
        for (width, rows) in vectors {
            for encoded in rows {
                for inputChunk in 1...9 {
                    for outputChunk in 1...7 {
                        let decoder = try SwapFilterDecompressor(
                            input: SwapTestInput(encoded, chunk: inputChunk), width: width,
                            expectedSize: UInt64(encoded.count))
                        XCTAssertEqual(try drain(decoder, chunk: outputChunk), Data(0..<UInt8(encoded.count)),
                                       "Swap\(width), length \(encoded.count), \(inputChunk)/\(outputChunk)")
                    }
                }
            }
        }
    }

    func testEmptyReadsAndDeferredCompletionDoNotLoseFinalBytes() throws {
        for width in [2, 4] {
            for bytes: [UInt8] in [[], [3, 2, 1, 0, 9]] {
                let input = SwapTestInput(bytes, chunk: 3)
                let decoder = try SwapFilterDecompressor(input: input, width: width, expectedSize: UInt64(bytes.count))
                XCTAssertEqual(try decoder.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0)
                XCTAssertEqual(input.reads, 0)
                let expected: [UInt8] = bytes.isEmpty ? [] : (width == 2 ? [2, 3, 0, 1, 9] : [0, 1, 2, 3, 9])
                XCTAssertEqual(try drain(decoder, chunk: 1), Data(expected))
                XCTAssertTrue(input.isFinished, "The upstream end check must run after a partial unit, too")
                XCTAssertTrue(decoder.isFinished)
            }
        }
    }

    func testTruncationTrailingBytesAndInvalidWidthsAreRejectedWithoutLargeAllocation() throws {
        for width in [2, 4] {
            for (bytes, declared): ([UInt8], UInt64) in [([0, 1], 3), ([0, 1, 2], 2), ([0], 0)] {
                let decoder = try SwapFilterDecompressor(input: SwapTestInput(bytes, chunk: 1),
                                                         width: width, expectedSize: declared)
                XCTAssertThrowsError(try drain(decoder, chunk: 1))
            }
            let input = SwapTestInput([], chunk: 1)
            let huge = try SwapFilterDecompressor(input: input, width: width, expectedSize: UInt64.max)
            XCTAssertThrowsError(try drain(huge, chunk: 1)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
            XCTAssertEqual(input.maximumRequested, 256 * 1_024)
        }
        for width in [0, 1, 3, 8, Int.max] {
            XCTAssertThrowsError(try SwapFilterDecompressor(input: SwapTestInput([], chunk: 1),
                                                          width: width, expectedSize: 0))
        }
    }

    func testCoderGraphValidatesPropertiesArityAndMatchingSizes() throws {
        for width in [2, 4] {
            let coder = SevenZipCoder(methodID: [2, 3, UInt8(width)], inputCount: 1, outputCount: 1,
                                      properties: [], firstInput: 0, firstOutput: 0)
            XCTAssertEqual(SevenZipMethod.description(for: coder), "Swap\(width)")
            let expected = width == 2 ? Data([1, 0, 3, 2, 4]) : Data([3, 2, 1, 0, 4])
            XCTAssertEqual(try factory(width: width).decodeAll(limit: 5), expected)
            XCTAssertThrowsError(try factory(width: width, properties: [0]).makeDecoder())
            XCTAssertThrowsError(try factory(width: width, inputs: 2).makeDecoder())
            for size: UInt64 in [0, 4, 6, UInt64.max] {
                XCTAssertThrowsError(try factory(width: width, size: size).makeDecoder())
            }
        }
    }

    func testIndependentSolidAndAESFixturesPreserveOddMemberBoundariesAndReverseReads() throws {
        for name in fixtureNames {
            let reader = try ArchiveReader.open(data: fixture(name), options: ReaderOptions(password: "KaitoFixture"))
            XCTAssertEqual(Set(reader.entries.map(\.name)), Set(payloads.keys))
            let nonempty = reader.entries.filter { $0.uncompressedSize != 0 }
            XCTAssertEqual(Set(nonempty.map(\.solidGroup)).count, 1)
            for entry in nonempty {
                XCTAssertTrue(entry.methodDescription.contains(name.hasPrefix("swap2") ? "Swap2" : "Swap4"))
                XCTAssertEqual(entry.isEncrypted, name.contains("aes"))
            }
            for entry in reader.entries.reversed() {
                XCTAssertEqual(try read(reader.stream(entry), chunk: 37), payloads[entry.name], name + entry.name)
            }
            let reopened = try reader.reopen()
            for entry in reopened.entries {
                XCTAssertEqual(try reopened.read(entry), payloads[entry.name], name + entry.name)
            }
        }
    }

    func testIndependentReadersInterleaveAndSharedReaderRejectsStaleStreams() throws {
        for name in fixtureNames {
            let reader = try ArchiveReader.open(data: fixture(name), options: ReaderOptions(password: "KaitoFixture"))
            let first = try reader.stream(XCTUnwrap(reader.entries.first { $0.name == "first.bin" }))
            let otherReader = try reader.reopen()
            let second = try otherReader.stream(XCTUnwrap(otherReader.entries.first { $0.name == "second.bin" }))
            var prefix = [UInt8](repeating: 0, count: 3)
            let count = try prefix.withUnsafeMutableBytes { try first.read(into: $0) }
            XCTAssertEqual(count, 3)
            XCTAssertEqual(try read(second, chunk: 3), payloads["second.bin"])
            XCTAssertEqual(Data(prefix) + (try read(first, chunk: 257)), payloads["first.bin"])

            // One solid coordinator deliberately invalidates an older stream.
            // Independent readers above are the supported concurrent path.
            let stale = try reader.stream(XCTUnwrap(reader.entries.first { $0.name == "first.bin" }))
            _ = try prefix.withUnsafeMutableBytes { try stale.read(into: $0) }
            let current = try reader.stream(XCTUnwrap(reader.entries.first { $0.name == "second.bin" }))
            XCTAssertThrowsError(try prefix.withUnsafeMutableBytes { try stale.read(into: $0) }) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertEqual(try read(current, chunk: 3), payloads["second.bin"])
        }
    }

    func testSplitAndUnlinkedArchiveCanBeReopened() throws {
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "swap-split")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in fixtureNames {
            let data = try fixture(name)
            let parts = stride(from: 0, to: data.count, by: 128).enumerated().map { index, offset in
                (directory.appendingPathComponent(String(format: "\(name).%03d", index + 1)),
                 Data(data[offset..<min(offset + 128, data.count)]))
            }
            for (url, bytes) in parts { try bytes.write(to: url) }
            let reader = try ArchiveReader.open(url: XCTUnwrap(parts.first?.0),
                                               options: ReaderOptions(password: "KaitoFixture"))
            for (url, _) in parts { try FileManager.default.removeItem(at: url) }
            let reopened = try reader.reopen()
            for entry in reopened.entries.reversed() {
                XCTAssertEqual(try reopened.read(entry), payloads[entry.name])
            }
        }
    }

    func testPasswordTruncationAndOutputLimitsRemainEnforced() throws {
        for name in fixtureNames {
            let data = try fixture(name)
            if name.contains("aes") {
                XCTAssertThrowsError(try ArchiveReader.open(data: data)) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
                XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(password: "wrong"))) {
                    XCTAssertEqual($0 as? KaitoError, .wrongPassword)
                }
            }
            for cutoff in [31, data.count / 2, data.count - 1] {
                XCTAssertThrowsError(try ArchiveReader.open(data: Data(data.prefix(cutoff)),
                                                            options: ReaderOptions(password: "KaitoFixture")))
            }
            if !name.contains("aes") {
                for limits in [ReadLimits(maxEntrySize: 1_026), ReadLimits(maxTotalUncompressedSize: 263_429)] {
                    XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits))) {
                        guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
                    }
                }
                let reader = try ArchiveReader.open(data: data, options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 16)))
                let entry = try XCTUnwrap(reader.entries.first { $0.name == "first.bin" })
                XCTAssertThrowsError(try reader.read(entry))
                XCTAssertEqual(try read(reader.stream(entry), chunk: 17), payloads["first.bin"])
            }
        }
    }

    private let fixtureNames = ["swap2-plain.7z", "swap2-aes.7z", "swap4-plain.7z", "swap4-aes.7z"]
    private var payloads: [String: Data] {
        ["first.bin": Data((0..<(256 * 1025)).map { UInt8(truncatingIfNeeded: $0) }) + Data([17, 31, 127]),
         "second.bin": Data((0..<1027).map { UInt8(truncatingIfNeeded: $0 * 73 + 41) }), "empty": Data()]
    }

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let encoded = try Data(contentsOf: root.appendingPathComponent("Fixtures/sevenzip-swap/" + name + ".b64"))
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func factory(width: Int, properties: [UInt8] = [], inputs: Int = 1,
                         size: UInt64 = 5) throws -> SevenZipFolderDecoderFactory {
        try SevenZipFolderDecoderFactory(source: DataByteSource(data: Data([0, 1, 2, 3, 4])),
            folder: SevenZipFolder(coders: [SevenZipCoder(methodID: [2, 3, UInt8(width)],
                inputCount: inputs, outputCount: 1, properties: properties, firstInput: 0, firstOutput: 0)],
                bindPairs: [], packedIndices: [0], inputCount: inputs, outputCount: 1,
                finalOutputIndex: 0, unpackSizes: [size], digest: SevenZipDigest(value: nil)),
            packedRanges: [0: SevenZipPackRange(offset: 0, size: 5, digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(), password: nil, keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24)
    }

    private func drain(_ decoder: any Decompressor, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 || decoder.isFinished else { throw KaitoError.malformed("Swap test stalled") }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    private func read(_ stream: EntryStream, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private final class SwapTestInput: Decompressor {
    private let bytes: [UInt8]
    private let chunk: Int
    private var offset = 0
    private(set) var isFinished = false
    private(set) var reads = 0
    private(set) var maximumRequested = 0
    init(_ bytes: [UInt8], chunk: Int) { self.bytes = bytes; self.chunk = chunk }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        reads += 1
        maximumRequested = max(maximumRequested, buffer.count)
        guard offset < bytes.count else { isFinished = true; return 0 }
        let count = min(chunk, buffer.count, bytes.count - offset)
        buffer.copyBytes(from: bytes[offset..<(offset + count)])
        offset += count
        return count
    }
}
