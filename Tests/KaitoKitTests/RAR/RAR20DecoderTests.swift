import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RAR20DecoderTests: XCTestCase {
    func testRAR250PlainLZArchivesMatchUnrarOutput() throws {
        let fixtures = [
            ("autorej", "dfa78453a790fcfd9ccb70b8363b0a6f5376371082a78127d8281ec4fb6156db"),
            ("audio", "49fdf4ee5a26c05158ed6873c11a97eb5bbc7966b65d1b0b1b3e06f847bc5a77"),
            ("biglz", "b915c3b0b8335cdb7ee06bb9487ea26a1a338cae4f8fc3208363d99e3938f842"),
        ]
        for (name, expected) in fixtures {
            let reader = try ArchiveReader.open(data: TestFixtures.base64("rar20/\(name).rar"))
            let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
            XCTAssertEqual(try hash(reader.read(entry)), expected, name)
        }
    }

    func testRAR250SolidArchiveSupportsForwardAndBackwardReads() throws {
        let reader = try ArchiveReader.open(data: TestFixtures.base64("rar20/solid.rar"))
        let entries = reader.entries.filter { $0.kind == .file }
        XCTAssertEqual(entries.count, 2)
        let expected = [
            "7e7cba72629554cc5a2bdc021326670a145d60a1af36a48920c475ec735413e4",
            "3d17d01bfc2e51e8e6a1c7b64a62956f627758be7cdd793c916d93648cb5b226",
        ]
        for entry in entries {
            XCTAssertEqual(try hash(reader.read(entry)), expected[entry.index], "forward \(entry.index)")
        }
        XCTAssertEqual(try hash(reader.read(entries[1])), expected[1])
        XCTAssertEqual(try hash(reader.read(entries[0])), expected[0])
        XCTAssertEqual(try hash(reader.read(entries[1])), expected[1])
    }

    func testVersion26DeclarationUsesTheSameDecoder() throws {
        var data = try TestFixtures.base64("rar20/autorej.rar")
        let start = 20, versionOffset = start + 24
        let headerSize = Int(data[start + 5]) | Int(data[start + 6]) << 8
        let headerEnd = start + headerSize
        data[versionOffset] = 26
        let checksum = CRC32.checksum(data[(start + 2)..<headerEnd])
        data[start] = UInt8(truncatingIfNeeded: checksum)
        data[start + 1] = UInt8(truncatingIfNeeded: checksum >> 8)
        let reader = try ArchiveReader.open(data: data)
        let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
        XCTAssertEqual(try hash(reader.read(entry)), "dfa78453a790fcfd9ccb70b8363b0a6f5376371082a78127d8281ec4fb6156db")
    }

    func testLongLZStreamResumesMatchesAcrossSmallBuffers() throws {
        let reader = try ArchiveReader.open(data: TestFixtures.base64("rar20/biglz.rar"))
        let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
        let stream = try reader.stream(entry)
        var output = Data(), buffer = [UInt8](repeating: 0, count: 97)
        while stream.remaining != 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { return XCTFail("RAR20 stream made no progress") }
            output.append(buffer, count: count)
        }
        XCTAssertEqual(try hash(output), "b915c3b0b8335cdb7ee06bb9487ea26a1a338cae4f8fc3208363d99e3938f842")
    }

    func testHuffmanLookupRetainsLongCodesAndTruncation() throws {
        let table = RAR20HuffmanTable()
        try table.build([1, 10, 10])
        var inputBits = [UInt8]()
        for (code, count) in [(0, 1), (512, 10), (513, 10), (512, 10)] {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                inputBits.append(UInt8((code >> shift) & 1))
            }
        }
        inputBits.append(contentsOf: repeatElement(0, count: (8 - inputBits.count % 8) % 8))
        var packed = [UInt8](repeating: 0, count: inputBits.count / 8)
        for (index, bit) in inputBits.enumerated() {
            packed[index / 8] |= bit << UInt8(7 - index % 8)
        }
        var bits = MSBFirstBitReader(bytes: packed)
        for expected in [0, 1, 2, 1] {
            XCTAssertEqual(try table.decode(&bits), expected)
        }
        XCTAssertFalse(bits.overrun)

        var truncated = MSBFirstBitReader(bytes: Array(packed.prefix(3)))
        for expected in [0, 1, 2, 1] {
            XCTAssertEqual(try table.decode(&truncated), expected)
        }
        XCTAssertTrue(truncated.overrun)

        var empty = MSBFirstBitReader(bytes: [])
        XCTAssertEqual(try table.decode(&empty), 0)
        XCTAssertTrue(empty.overrun)
    }

    func testTruncatedPackedInputIsRejected() throws {
        let data = try TestFixtures.base64("rar20/autorej.rar")
        for packedSize in [UInt64(1), 8, 20] {
            XCTAssertThrowsError(try RAR20Decoder(
                source: DataByteSource(data: data), offset: 61, compressedSize: packedSize,
                expectedSize: 2_300, unpackVersion: 20, method: 0x35,
                dictionarySize: 65_536, isSolid: false, limits: ReadLimits()
            )) { error in
                XCTAssertTrue(error is KaitoError)
            }
        }
    }

    private func hash(_ data: Data) throws -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
