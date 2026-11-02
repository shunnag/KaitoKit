import Foundation
@testable import KaitoKit
import XCTest

final class RAR13ReaderTests: XCTestCase {
    func testStoredAndCompressedEntriesMatchUnrarOutput() throws {
        let data = try TestFixtures.base64("rar13/normal.rar")
        XCTAssertEqual(try FormatDetector.detect(data: data), .rar)
        let reader = try ArchiveReader.open(data: data)
        let phrase = Data("RAR15!\r\n".utf8)
        XCTAssertEqual(reader.entries.map(\.name), ["stored.txt", "compressed.txt"])
        for entry in reader.entries {
            XCTAssertEqual(entry.formatSpecific["container"], "RAR1.3")
            XCTAssertNil(entry.crc32)
            XCTAssertNotNil(entry.formatSpecific["crc16"])
            XCTAssertEqual(try reader.read(entry), entry.name == "compressed.txt" ? phrase + phrase : phrase)
        }
        let stream = try reader.stream(reader.entries[1])
        var output = Data(), buffer = [UInt8](repeating: 0, count: 1)
        while stream.remaining != 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { return XCTFail("RAR1.3 stream made no progress") }
            output.append(buffer, count: count)
        }
        XCTAssertEqual(output, phrase + phrase)
    }

    func testSolidEntriesSupportForwardAndBackwardReads() throws {
        for fixture in ["solid", "solid-main"] {
            let reader = try ArchiveReader.open(data: TestFixtures.base64("rar13/\(fixture).rar"))
            let expected = Data("RAR15!\r\n".utf8)
            XCTAssertEqual(reader.entries.count, 2)
            for entry in reader.entries {
                XCTAssertEqual(try reader.read(entry), expected, "\(fixture):forward \(entry.index)")
            }
            for index in [1, 0, 1, 0] {
                XCTAssertEqual(try reader.read(reader.entries[index]), expected, "\(fixture):read \(index)")
            }
        }
    }

    func testRollingChecksumMismatchIsRejected() throws {
        var data = try TestFixtures.base64("rar13/normal.rar")
        data[15] ^= 1
        let reader = try ArchiveReader.open(data: data)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testEncryptedSplitAndCommentEntriesAreExplicitlyUnsupported() throws {
        for flag in [UInt8(0x04), 0x02, 0x08] {
            var data = try TestFixtures.base64("rar13/normal.rar")
            data[7 + 17] |= flag
            let reader = try ArchiveReader.open(data: data)
            XCTAssertThrowsError(try reader.read(reader.entries[0]), "flag \(flag)") { error in
                guard case KaitoError.unsupportedMethod = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testTruncatedHeaderPayloadAndTrailingDataAreRejected() throws {
        let fixture = try TestFixtures.base64("rar13/normal.rar")
        for count in [0, 1, 6, 20, fixture.count - 1] {
            XCTAssertThrowsError(try ArchiveReader.open(data: fixture.prefix(count)), "length \(count)")
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: fixture + Data([0])))
    }

    func testInvalidVersionAndStoredSizesAreRejected() throws {
        var invalidVersion = try TestFixtures.base64("rar13/normal.rar")
        invalidVersion[7 + 18] = 0
        XCTAssertThrowsError(try ArchiveReader.open(data: invalidVersion))

        var unequalSizes = try TestFixtures.base64("rar13/normal.rar")
        unequalSizes[7 + 4] = 9
        let reader = try ArchiveReader.open(data: unequalSizes)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRAR1402ArchivesMatchUnrarOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR13_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR13_FIXTURES")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        for name in [
            "README.RAR", "README_store.rar", "BIG80K.RAR", "REPEATB.RAR",
            "SOLID.RAR", "WITHDIR.RAR", "COMMENT.RAR", "MULTIFIL.RAR", "EMPTY.RAR",
        ] {
            let reader = try ArchiveReader.open(url: root.appendingPathComponent(name))
            for entry in reader.entries {
                if entry.kind == .directory {
                    XCTAssertEqual(try reader.read(entry), Data(), "\(name):\(entry.name)")
                    continue
                }
                let expected = try Data(contentsOf: root.appendingPathComponent("expected/\(entry.name)"))
                XCTAssertEqual(try reader.read(entry), expected, "\(name):\(entry.name)")
            }
            if name == "SOLID.RAR" {
                for entry in reader.entries.reversed() {
                    let expected = try Data(contentsOf: root.appendingPathComponent("expected/\(entry.name)"))
                    XCTAssertEqual(try reader.read(entry), expected, "reverse:\(entry.name)")
                }
            }
        }
    }

    func testRAR1402FileCommentIsListedButNotRead() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR13_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR13_FIXTURES")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let reader = try ArchiveReader.open(url: root.appendingPathComponent("FCOMM.RAR"))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            guard case KaitoError.unsupportedMethod = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
