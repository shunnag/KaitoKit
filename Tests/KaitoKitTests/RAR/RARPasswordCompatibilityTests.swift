import Foundation
@testable import KaitoKit
import XCTest

final class RARPasswordCompatibilityTests: XCTestCase {
    func testAscii28P() throws {
        try verify("ascii28-p", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }
    func testAscii28Hp() throws {
        try verify("ascii28-hp", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }
    func testAscii29P() throws {
        try verify("ascii29-p", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }
    func testAscii29Hp() throws {
        try verify("ascii29-hp", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }
    func testAscii64P() throws {
        try verify("ascii64-p", password: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }
    func testAscii64Hp() throws {
        try verify("ascii64-hp", password: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }
    func testAscii100P() throws {
        try verify("ascii100-p", password: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
    }
    func testAscii100Hp() throws {
        try verify("ascii100-hp", password: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
    }
    func testJapanese29P() throws {
        try verify("japanese29-p", password: "海海海海海海海海海海海海海海海海海海海海海海海海海海海海海")
    }
    func testJapanese29Hp() throws {
        try verify("japanese29-hp", password: "海海海海海海海海海海海海海海海海海海海海海海海海海海海海海")
    }
    func testNonbmpP() throws {
        try verify("nonbmp-p", password: "key🔑")
    }
    func testNonbmpHp() throws {
        try verify("nonbmp-hp", password: "key🔑")
    }
    func testNonbmpLongP() throws {
        try verify("nonbmp-long-p", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaa🔑")
    }
    func testNonbmpLongHp() throws {
        try verify("nonbmp-long-hp", password: "aaaaaaaaaaaaaaaaaaaaaaaaaaa🔑")
    }
    func testNonbmpUtf16P() throws {
        try verify("nonbmp-utf16-p", password: "key🔑")
    }
    func testNonbmpUtf16Hp() throws {
        try verify("nonbmp-utf16-hp", password: "key🔑")
    }
    func testCanonicalUTF16OnUnixHost() throws {
        try verify("nonbmp-utf16-unix-p", password: "key🔑")
    }
    func testUnixScalarEncodingOnWindowsHost() throws {
        try verify("nonbmp-unix-windows-p", password: "key🔑")
    }
    func testNonBMPCompressedSolidRandomAccessAndPasswordReset() throws {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/kaito-password-nonbmp-solid.rar.b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(password: "key🔑"))
        for index in [0, 1, 2, 0, 2, 1] {
            let expected = Data(String(repeating: "KaitoKit solid password \(index)\n", count: 128).utf8)
            XCTAssertEqual(try reader.read(reader.entries[index]), expected)
        }
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[2]), Data(String(repeating: "KaitoKit solid password 2\n", count: 128).utf8))
        reader.password = "wrong🔑"
        XCTAssertThrowsError(try reader.read(reader.entries[2]))
        reader.password = "key🔑"
        XCTAssertEqual(try reader.read(reader.entries[2]), Data(String(repeating: "KaitoKit solid password 2\n", count: 128).utf8))
    }

    func testNonBMPCandidateRetriesAfterDictionaryLimitError() throws {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/kaito-password-nonbmp-retry-limit.rar.b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        var limits = ReadLimits()
        limits.maxDictionarySize = 8 * 1_024 * 1_024
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits, password: "key🔑"))
        // The UTF-16 candidate's garbage PPMd header requests 109 MiB. Its
        // limitExceeded must not prevent the correct Unix candidate's LZ decode.
        XCTAssertEqual(try reader.read(reader.entries[0]), Data(String(repeating: "KaitoKit RAR3 candidate retry\n", count: 128).utf8))
    }

    func testEmptyEncryptedMemberDoesNotSelectPasswordEncoding() throws {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/kaito-password-nonbmp-p.rar.b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let bytes = Array(try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)))
        var offset = 7
        while bytes[offset + 2] != 0x74 {
            offset += Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        }
        let size = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        var emptyHeader = Array(bytes[offset..<(offset + size)])
        emptyHeader.replaceSubrange(7..<15, with: repeatElement(UInt8(0), count: 8))
        emptyHeader.replaceSubrange(16..<20, with: repeatElement(UInt8(0), count: 4))
        emptyHeader[25] = 0x30 // Stored, zero ciphertext and plaintext, but still encrypted.
        let crc = CRC32.checksum(Array(emptyHeader.dropFirst(2)))
        emptyHeader[0] = UInt8(truncatingIfNeeded: crc)
        emptyHeader[1] = UInt8(truncatingIfNeeded: crc >> 8)
        let archive = Data(bytes[..<offset] + emptyHeader + bytes[offset...])
        let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(password: "key🔑"))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data())
        let reopened = try reader.reopen()
        let expected = Data(String(repeating: "KaitoKit RAR3 password compatibility\n", count: 4).utf8)
        XCTAssertEqual(try reader.read(reader.entries[1]), expected)
        XCTAssertEqual(try reopened.read(reopened.entries[1]), expected)
    }

    func testAscii128PWriterLengthLimit() throws {
        try verify("ascii128-p", password: String(repeating: "d", count: 128))
    }
    func testAscii128HpWriterLengthLimit() throws {
        try verify("ascii128-hp", password: String(repeating: "d", count: 128))
    }
    func testAscii200PWriterLengthLimit() throws {
        try verify("ascii200-p", password: String(repeating: "d", count: 200))
    }
    func testAscii200HpWriterLengthLimit() throws {
        try verify("ascii200-hp", password: String(repeating: "d", count: 200))
    }
    private func verify(_ name: String, password: String) throws {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/kaito-password-\(name).rar.b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name), ["payload.txt"])
        let expected = Data(String(repeating: "KaitoKit RAR3 password compatibility\n", count: 4).utf8)
        XCTAssertEqual(try reader.read(reader.entries[0]), expected)
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[0]), expected)
        if !name.hasSuffix("hp") {
            reader.password = "incorrect"
            XCTAssertThrowsError(try reader.read(reader.entries[0]))
        }
    }
}
