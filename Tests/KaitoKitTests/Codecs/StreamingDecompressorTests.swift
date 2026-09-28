import Foundation
import KaitoKit
import XCTest

/// Copy・raw Deflate・bzip2 の decoder を小さい buffer で読み切り、短い固定 vector と切り詰めた入力で検査する。
final class StreamingDecompressorTests: XCTestCase {
    // 旧名: CodecAndFormatTests（形式判定の 4 件は FormatDetectorTests へ移した）
    private enum FixtureError: Error {
        case decoderMadeNoProgress
    }

    func testCopyDecompressorStreamsBoundedRangeWithTinyBuffer() throws {
        let expected = Data("copy-range-日本語".utf8)
        var stored = Data([0xAA, 0xBB])
        stored.append(expected)
        stored.append(contentsOf: [0xCC, 0xDD])

        let decoder = try CopyDecompressor(
            source: DataByteSource(data: stored),
            offset: 2,
            compressedSize: UInt64(expected.count)
        )
        XCTAssertFalse(decoder.isFinished)
        XCTAssertEqual(try drain(decoder, bufferSize: 2), expected)
        XCTAssertTrue(decoder.isFinished)
    }

    func testCopyDecompressorRejectsTruncatedRange() {
        let source = DataByteSource(data: Data([0x01, 0x02, 0x03]))
        XCTAssertThrowsError(
            try CopyDecompressor(source: source, offset: 1, compressedSize: 3)
        ) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testRawDeflateDecompressorStreamsWithTinyBuffer() throws {
        let fixture = try codecFixture()
        let decoder = try DeflateDecompressor(
            source: DataByteSource(data: fixture.deflate),
            offset: 0,
            compressedSize: UInt64(fixture.deflate.count)
        )

        XCTAssertEqual(try drain(decoder, bufferSize: 3), fixture.plaintext)
        XCTAssertTrue(decoder.isFinished)
    }

    func testRawDeflateDecompressorRejectsTruncatedInput() throws {
        let fixture = try codecFixture()
        let truncated = Data(fixture.deflate.dropLast())
        let decoder = try DeflateDecompressor(
            source: DataByteSource(data: truncated),
            offset: 0,
            compressedSize: UInt64(truncated.count)
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testBzip2DecompressorStreamsWithTinyBuffer() throws {
        let fixture = try codecFixture()
        let decoder = try Bzip2Decompressor(
            source: DataByteSource(data: fixture.bzip2),
            offset: 0,
            compressedSize: UInt64(fixture.bzip2.count)
        )

        XCTAssertEqual(try drain(decoder, bufferSize: 2), fixture.plaintext)
        XCTAssertTrue(decoder.isFinished)
    }

    func testBzip2DecompressorRejectsTruncatedInput() throws {
        let fixture = try codecFixture()
        let truncated = Data(fixture.bzip2.dropLast(4))
        let decoder = try Bzip2Decompressor(
            source: DataByteSource(data: truncated),
            offset: 0,
            compressedSize: UInt64(truncated.count)
        )

        XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testCLibraryDecompressorsRejectInvalidByteSourceCountsAsTruncated() throws {
        let sourceLength: UInt64 = 1
        for reportedCount in [-1, 0, Int(sourceLength) + 1] {
            let source = InvalidCountByteSource(length: sourceLength, reportedCount: reportedCount)
            let decoders: [any Decompressor] = [
                try DeflateDecompressor(source: source, offset: 0, compressedSize: sourceLength),
                try Bzip2Decompressor(source: source, offset: 0, compressedSize: sourceLength),
            ]
            for decoder in decoders {
                XCTAssertThrowsError(try drain(decoder, bufferSize: 1)) { error in
                    XCTAssertEqual(error as? KaitoError, .truncated)
                }
            }
        }
    }

    private func codecFixture() throws -> (
        plaintext: Data,
        deflate: Data,
        bzip2: Data
    ) {
        let plaintext = try Hex.data(
            "68656c6c6f204b6169746f4b69740a" +
            "68656c6c6f204b6169746f4b69740a" +
            "68656c6c6f204b6169746f4b69740a"
        )
        let deflate = try Hex.data(
            "cb48cdc9c957f04ecc2cc9f7ce2ce1cac0cb0500"
        )
        let bzip2 = try Hex.data(
            "425a6839314159265359d3182df100000a5580001040000008226484002000310" +
            "03023f5501a7a911a61b5b8cbab4a7929f177245385090d3182df10"
        )
        return (plaintext, deflate, bzip2)
    }

    private func drain(
        _ decoder: any Decompressor,
        bufferSize: Int
    ) throws -> Data {
        XCTAssertGreaterThan(bufferSize, 0)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0

        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // 不変条件: storage は固定長 buffer の全領域で、decoder はその範囲内だけを書く。
                try decoder.read(into: storage)
            }
            guard count > 0 else {
                if decoder.isFinished {
                    break
                }
                throw FixtureError.decoderMadeNoProgress
            }
            XCTAssertLessThanOrEqual(count, bufferSize)
            result.append(contentsOf: buffer.prefix(count))

            iterations += 1
            guard iterations < 10_000 else {
                throw FixtureError.decoderMadeNoProgress
            }
        }

        let finalCount = try buffer.withUnsafeMutableBytes { storage in
            // 不変条件: 完了後も decoder に渡す領域は固定長 buffer 内に限定される。
            try decoder.read(into: storage)
        }
        XCTAssertEqual(finalCount, 0)
        return result
    }
}

private struct InvalidCountByteSource: ByteSource {
    let length: UInt64
    let reportedCount: Int

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        reportedCount
    }
}
