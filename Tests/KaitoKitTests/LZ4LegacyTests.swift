import Foundation
@testable import KaitoKit
import XCTest

// Legacy framing comes from the public Frame Format v1.6.4 description.
// The independent LZ4 CLI is used only to encode/decode project-owned bytes.
final class LZ4LegacyTests: XCTestCase {
    private let blockSize = 8 * 1_024 * 1_024
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lz4-frame")
        return try XCTUnwrap(Data(base64Encoded: Data(contentsOf: root.appendingPathComponent(name + ".lz4.b64")),
                                  options: .ignoreUnknownCharacters))
    }
    private func word(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func decode(_ bytes: Data, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try LZ4FrameDecompressor(source: DataByteSource(bytes), limits: limits)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 8191)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertTrue(decoder.isFinished)
        return output
    }
    private func lz4() throws -> String {
        guard let path = ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/usr/bin/lz4"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("The independent LZ4 CLI is required for this comparison")
        }
        return path
    }

    func testLegacyAndModernConcatenationWithEverySkippableMagic() throws {
        let legacy = try fixture("legacy-tiny"), modern = try fixture("tiny")
        let expected = try decode(modern)
        let cli = try lz4()
        for magic: UInt32 in 0x184d2a50...0x184d2a5f {
            let skipped = word(magic) + word(3) + Data([4, 5, 6])
            let bytes = skipped + word(0x184c2102) + legacy + skipped + modern + legacy + skipped
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .lz4)
            XCTAssertNil(try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits()))
            XCTAssertEqual(try decode(bytes), expected + expected + expected)
            // lz4 1.10.0 stops with ERROR_frameType_unknown for modern ->
            // legacy. Compare its supported legacy -> modern direction;
            // KaitoKit intentionally handles both independent-frame orders.
            let oracleBytes = skipped + word(0x184c2102) + legacy + skipped + modern + skipped
            let reference = try ZipTestSupport.checkedRun(cli, arguments: ["-d", "-c", "-q"], standardInput: oracleBytes)
            XCTAssertEqual(reference.standardOutput, expected + expected)
        }
        // Real tools accept a short block before another independent block.
        let shortBlocks = legacy + legacy.dropFirst(4)
        XCTAssertEqual(try decode(shortBlocks), expected + expected)
        XCTAssertEqual(try ZipTestSupport.checkedRun(cli, arguments: ["-d", "-c", "-q"],
            standardInput: shortBlocks).standardOutput, expected + expected)
    }

    func testLinuxZeroEndMarkerAndFollowingFrames() throws {
        let legacy = try fixture("legacy-tiny"), modern = try fixture("tiny")
        let expected = try decode(modern)
        for suffix in [Data(), modern, legacy] {
            let bytes = legacy + word(0) + suffix
            XCTAssertEqual(try decode(bytes), suffix.isEmpty ? expected : expected + expected)
            XCTAssertNil(try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: ReadLimits()))
        }
        XCTAssertEqual(try decode(word(0x184c2102) + word(0)), Data())
        // The public format documents this Linux extension; lz4 1.10.0 CLI
        // rejects it. This acceptance is not claimed as CLI equivalence.
        XCTAssertThrowsError(try decode(legacy + word(0) + word(0)))
    }

    func testTruncatedLegacyBlocksRejectButCompleteBlockBoundaryCanEndStream() throws {
        let tiny = try fixture("legacy-tiny")
        for length in 0..<tiny.count where length != 4 {
            XCTAssertThrowsError(try decode(Data(tiny.prefix(length))), "prefix \(length)") {
                XCTAssertTrue($0 is KaitoError)
            }
        }
        XCTAssertEqual(try decode(Data(tiny.prefix(4))), Data())
        let twoBlocks = try fixture("legacy-8m-tail")
        let firstSize = twoBlocks[4..<8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let first = Data(twoBlocks.prefix(8 + firstSize))
        XCTAssertEqual(try decode(first), try decode(fixture("legacy-8m-exact")))
        // Legacy has no size/checksum/footer: removing an entire last block
        // is indistinguishable from a valid, shorter stream.
        XCTAssertThrowsError(try decode(Data(twoBlocks.dropLast())))
        for count in 1...3 { XCTAssertThrowsError(try decode(tiny + Data(repeating: 0, count: count))) }
    }

    func testLegacyBlockHistoryIsIndependentAndMalformedSizeFailureIsSticky() throws {
        let first = Data([0x20, 65, 66])
        let refersToPrevious = Data([0x08, 2, 0, 0x50, 66, 67, 68, 69, 70])
        let invalidBlock = word(UInt32(refersToPrevious.count)) + refersToPrevious
        let bytes = word(0x184c2102) + word(UInt32(first.count)) + first + invalidBlock
        XCTAssertThrowsError(try decode(bytes))
        XCTAssertThrowsError(try decode(try fixture("tiny") + word(0x184c2102) + invalidBlock))
        let maximum = blockSize + blockSize / 255 + 16
        for size in [UInt32(maximum + 1), 0x80000001, UInt32.max] {
            let malformed = word(0x184c2102) + word(size)
            XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source: DataByteSource(malformed), limits: ReadLimits()))
            let decoder = try LZ4FrameDecompressor(source: DataByteSource(malformed))
            var buffer = [UInt8](repeating: 0, count: 7)
            for _ in 0..<2 {
                XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }) {
                    XCTAssertEqual($0 as? KaitoError, .malformed("LZ4 legacy compressed block size"))
                }
            }
        }
    }

    func testLegacyOutputDictionaryFrameAndBlockLimits() throws {
        let legacy = try fixture("legacy-tiny"), modern = try fixture("tiny")
        XCTAssertEqual(try decode(legacy, limits: ReadLimits(maxEntrySize: 1033)).count, 1033)
        for bytes in [legacy + modern, modern + legacy, legacy + legacy] {
            XCTAssertEqual(try decode(bytes, limits: ReadLimits(maxEntrySize: 2066)).count, 2066)
            XCTAssertThrowsError(try decode(bytes, limits: ReadLimits(maxEntrySize: 2065)))
        }
        XCTAssertThrowsError(try decode(try fixture("legacy-8m-tail"),
            limits: ReadLimits(maxEntrySize: UInt64(blockSize + 52))))
        let dictionary = ReadLimits(maxDictionarySize: 65535)
        XCTAssertThrowsError(try decode(legacy, limits: dictionary))
        XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source: DataByteSource(legacy), limits: dictionary))
        for bytes in [legacy + legacy, legacy + legacy.dropFirst(4), word(0x184c2102) + legacy] {
            let limits = ReadLimits(maxMetadataRecordCount: 1)
            XCTAssertThrowsError(try decode(bytes, limits: limits))
            XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source: DataByteSource(bytes), limits: limits))
        }
    }

    func testLegacyMetadataScanSkipsEncodedBytesWithoutAllocatingDeclaredSize() throws {
        let encodedSize = blockSize + blockSize / 255 + 16
        let source = LZ4LegacyHeaderOnlySource(header: word(0x184c2102) + word(UInt32(encodedSize)),
                                             length: UInt64(8 + encodedSize))
        XCTAssertNil(try LZ4FrameDecompressor.contentSize(source: source, limits: ReadLimits()))
        XCTAssertThrowsError(try LZ4FrameDecompressor.contentSize(source:
            LZ4LegacyHeaderOnlySource(header: source.header, length: source.length - 1), limits: ReadLimits()))
    }

    func testIncompressibleEightMiBBlockCanBeLargerOnDiskAndMatchesIndependentCLI() throws {
        let cli = try lz4()
        var state: UInt32 = 0x12345678
        var input = Data(count: blockSize + 17)
        input.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                buffer[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let encoded = try ZipTestSupport.checkedRun(cli, arguments: ["-T1", "-l", "-c", "-q"], standardInput: input).standardOutput
        let firstSize = encoded[4..<8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertGreaterThan(firstSize, blockSize, "Legacy cannot store incompressible data as a raw block")
        XCTAssertLessThanOrEqual(firstSize, blockSize + blockSize / 255 + 16)
        XCTAssertEqual(try decode(encoded), input)
        XCTAssertEqual(try ZipTestSupport.checkedRun(cli, arguments: ["-d", "-c", "-q"], standardInput: encoded).standardOutput, input)
        XCTAssertNil(try LZ4FrameDecompressor.contentSize(source: DataByteSource(encoded), limits: ReadLimits()))
    }

    func testLegacyDetectionSingleFileNameAndUnlinkReopen() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = try fixture("legacy-tiny")
        let expected = try decode(fixture("tiny"))
        let skipped = word(0x184d2a50) + word(0)
        for bytes in [legacy, skipped + legacy] {
            let url = directory.appendingPathComponent("payload.LZ4")
            try bytes.write(to: url)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .lz4)
            XCTAssertEqual(reader.entries[0].name, "payload")
            XCTAssertEqual(reader.entries[0].methodDescription, "LZ4")
            try FileManager.default.removeItem(at: url)
            for source in [reader, try reader.reopen()] {
                XCTAssertEqual(try source.read(source.entries[0]), expected)
            }
        }
    }
}

private struct LZ4LegacyHeaderOnlySource: ByteSource {
    let header: Data
    let length: UInt64
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset <= UInt64(header.count), buffer.count <= header.count - Int(offset) else {
            XCTFail("Metadata scan must not read a legacy block payload")
            throw KaitoError.truncated
        }
        return try DataByteSource(header).read(into: buffer, at: offset)
    }
}
