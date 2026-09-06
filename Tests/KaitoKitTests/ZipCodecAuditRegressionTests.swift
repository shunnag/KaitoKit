import Foundation
import KaitoKit
import XCTest

final class ZipCodecAuditRegressionTests: XCTestCase {
    func testLZMAEOSFlagRejectsMarkerlessStream() throws {
        let expected = Data("abcabcabcabcabcabc".utf8)
        let compressed = zipLZMAData(raw: [
            0x00, 0x30, 0x98, 0x88, 0xAA, 0x02, 0xA6,
            0x43, 0xEB, 0xFF, 0xFF, 0xB5, 0x80,
        ])

        let knownSizeArchive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "known-size.txt",
                uncompressedData: expected,
                compressedData: compressed,
                method: 14,
                flags: 0x0800
            ),
        ])
        let knownSizeReader = try ArchiveReader.open(data: knownSizeArchive)
        XCTAssertEqual(try knownSizeReader.read(knownSizeReader.entries[0]), expected)

        let endMarkedArchive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "missing-eos.txt",
                uncompressedData: expected,
                compressedData: compressed,
                method: 14,
                flags: 0x0802
            ),
        ])
        let endMarkedReader = try ArchiveReader.open(data: endMarkedArchive)
        XCTAssertThrowsError(try endMarkedReader.read(endMarkedReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testLZMAEOSFlagAcceptsEndMarkedStream() throws {
        let compressed = zipLZMAData(raw: [
            0x00, 0x83, 0xFF, 0xFB, 0xFF,
            0xFF, 0xC0, 0x00, 0x00, 0x00,
        ])
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "empty.txt",
                compressedData: compressed,
                method: 14,
                flags: 0x0802
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        XCTAssertEqual(try reader.read(reader.entries[0]), Data())
    }

    private func zipLZMAData(raw: [UInt8]) -> Data {
        var result = Data([
            0x09, 0x14, // LZMA SDK バージョン 9.20
            0x05, 0x00, // 5 バイトのプロパティ
            0x5D, 0x00, 0x00, 0x01, 0x00, // lc/lp/pb と 64 KiB 辞書
        ])
        result.append(contentsOf: raw)
        return result
    }
}
