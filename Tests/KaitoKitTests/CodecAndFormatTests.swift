import Foundation
import KaitoKit
import XCTest

final class CodecAndFormatTests: XCTestCase {
    private enum FixtureError: Error {
        case invalidHex
        case decoderMadeNoProgress
    }

    func testFormatDetectorRecognizesEverySignatureFamily() throws {
        try assertFormat(.zip, bytes: [0x50, 0x4B, 0x03, 0x04])
        try assertFormat(.zip, bytes: [0x50, 0x4B, 0x05, 0x06])
        try assertFormat(.zip, bytes: [0x50, 0x4B, 0x07, 0x08])
        try assertFormat(
            .rar,
            bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        )
        try assertFormat(
            .rar,
            bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        )
        try assertFormat(.sevenZip, bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])
        try assertFormat(.lha, data: makeLHAHeader(method: "-lh5-"))
        try assertFormat(.lha, data: makeLHAHeader(method: "-lz4-"))
        try assertFormat(.lha, data: makeLHAHeader(method: "-pm1-"))
        try assertFormat(.gzip, bytes: [0x1F, 0x8B])
        try assertFormat(.bzip2, data: Data("BZh9".utf8))
        try assertFormat(.xz, bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        try assertFormat(.compress, bytes: [0x1F, 0x9D])

        var ustar = Data(repeating: 0, count: 512)
        ustar.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        assertUnsupported(ustar)
        try assertFormat(.tar, data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "member"),
        ]))
    }

    func testFormatDetectorDoesNotTreatAnArbitraryPrefixAsZipSFX() throws {
        var archive = Data("executable-prefix-without-a-ZIP-signature".utf8)
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.append(Data(repeating: 0, count: 18))

        XCTAssertThrowsError(try FormatDetector.detect(data: archive))
        XCTAssertThrowsError(
            try FormatDetector.detect(
                data: archive,
                options: ReaderOptions(scanForSFXInData: true)
            )
        )
    }

    func testFormatDetectorAcceptsChecksumOnlyTarAndRejectsCorruption() throws {
        let valid = try makeChecksumOnlyTarHeader()
        XCTAssertEqual(try FormatDetector.detect(data: valid), .tar)

        var corrupt = valid
        corrupt[0] ^= 0x01
        assertUnsupported(corrupt)
        assertUnsupported(Data(repeating: 0, count: 512))

        let emptyTar = Data(repeating: 0, count: 1_024)
        assertUnsupported(emptyTar)
        XCTAssertThrowsError(try ArchiveReader.open(data: emptyTar))
    }

    func testFormatDetectorRejectsInvalidNearSignatures() {
        assertUnsupported(Data([0x50, 0x4B, 0x03]))
        assertUnsupported(Data("BZh0".utf8))

        var implausibleLHA = makeLHAHeader(method: "-lh5-")
        implausibleLHA[0] = 4
        assertUnsupported(implausibleLHA)
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

    private func assertFormat(
        _ expected: ArchiveFormat,
        bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertFormat(expected, data: Data(bytes), file: file, line: line)
    }

    private func assertFormat(
        _ expected: ArchiveFormat,
        data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try FormatDetector.detect(data: data),
            expected,
            file: file,
            line: line
        )
    }

    private func assertUnsupported(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FormatDetector.detect(data: data),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedFormat,
                file: file,
                line: line
            )
        }
    }

    private func makeLHAHeader(method: String) -> Data {
        var result = Data(repeating: 0, count: 24)
        result[0] = 22
        result.replaceSubrange(2..<7, with: Data(method.utf8))
        return result
    }

    private func makeChecksumOnlyTarHeader() throws -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<11, with: Array("payload.bin".utf8))
        header[156] = Character("0").asciiValue ?? 0x30
        for index in 148..<156 {
            header[index] = 0x20
        }

        let checksum = header.reduce(UInt64(0)) { partial, byte in
            partial + UInt64(byte)
        }
        let digits = Array(String(checksum, radix: 8).utf8)
        guard digits.count <= 6 else {
            throw FixtureError.invalidHex
        }
        let field = [UInt8](repeating: 0x30, count: 6 - digits.count)
            + digits + [0, 0x20]
        header.replaceSubrange(148..<156, with: field)
        return Data(header)
    }

    private func codecFixture() throws -> (
        plaintext: Data,
        deflate: Data,
        bzip2: Data
    ) {
        let plaintext = try decodeHex(
            "68656c6c6f204b6169746f4b69740a" +
            "68656c6c6f204b6169746f4b69740a" +
            "68656c6c6f204b6169746f4b69740a"
        )
        let deflate = try decodeHex(
            "cb48cdc9c957f04ecc2cc9f7ce2ce1cac0cb0500"
        )
        let bzip2 = try decodeHex(
            "425a6839314159265359d3182df100000a5580001040000008226484002000310" +
            "03023f5501a7a911a61b5b8cbab4a7929f177245385090d3182df10"
        )
        return (plaintext, deflate, bzip2)
    }

    private func decodeHex(_ text: String) throws -> Data {
        guard text.utf8.count.isMultiple(of: 2) else {
            throw FixtureError.invalidHex
        }

        var result = Data()
        result.reserveCapacity(text.utf8.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else {
                throw FixtureError.invalidHex
            }
            result.append(byte)
            index = next
        }
        return result
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
