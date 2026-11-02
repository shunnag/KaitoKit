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

    func testEncryptedEntriesRequireCorrectPassword() throws {
        let data = try TestFixtures.base64("rar13/encrypted.rar")
        let missing = try ArchiveReader.open(data: data)
        for entry in missing.entries {
            XCTAssertThrowsError(try missing.read(entry)) { error in
                XCTAssertEqual(error as? KaitoError, .passwordRequired)
            }
        }
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(password: "wrong"))
        for entry in reader.entries {
            XCTAssertThrowsError(try reader.read(entry)) { error in
                XCTAssertEqual(error as? KaitoError, .wrongPassword)
            }
        }
        reader.password = "password"
        let phrase = Data("RAR15!\r\n".utf8)
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), entry.name == "compressed.txt" ? phrase + phrase : phrase)
        }
    }

    func testEncryptedSolidEntriesSupportBackwardReads() throws {
        let reader = try ArchiveReader.open(
            data: TestFixtures.base64("rar13/solid-encrypted.rar"),
            options: ReaderOptions(password: "password")
        )
        let expected = Data("RAR15!\r\n".utf8)
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), expected, "forward \(entry.index)")
        }
        for index in [1, 0, 1, 0] {
            XCTAssertEqual(try reader.read(reader.entries[index]), expected, "read \(index)")
        }
    }

    func testCommentsAreDecoded() throws {
        let reader = try ArchiveReader.open(data: TestFixtures.base64("rar13/comments.rar"))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.formatSpecific["archiveComment"], "RAR 1.3 comment.\r\n")
        XCTAssertEqual(entry.formatSpecific["comment"], "note\r\n")
        XCTAssertEqual(try reader.read(entry), Data("RAR15!\r\n".utf8))
    }

    func testSplitEntriesAreExplicitlyUnsupported() throws {
        for flag in [UInt8(0x01), 0x02] {
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

    func testRAR1402CommentsAreDecoded() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR13_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR13_FIXTURES")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let archiveComment = try ArchiveReader.open(url: root.appendingPathComponent("COMMENT.RAR"))
        let archiveEntry = try XCTUnwrap(archiveComment.entries.first)
        XCTAssertEqual(archiveEntry.formatSpecific["archiveComment"], "This is the archive comment.\r\n")
        XCTAssertEqual(try archiveComment.read(archiveEntry), try Data(contentsOf: root.appendingPathComponent("expected/HELLO.TXT")))

        let fileComment = try ArchiveReader.open(url: root.appendingPathComponent("FCOMM.RAR"))
        let fileEntry = try XCTUnwrap(fileComment.entries.first)
        XCTAssertEqual(fileEntry.formatSpecific["comment"], "FCOM\r\n")
        XCTAssertEqual(try fileComment.read(fileEntry), Data("Hello, file comment fixture.\r\n".utf8))
    }

    func testRAR1402EncryptedEntriesMatchUnrarOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR13_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR13_FIXTURES")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        for (archive, expectedName) in [("README_password=password.rar", "README"), ("STOREPWD.RAR", "SECRET.TXT")] {
            let reader = try ArchiveReader.open(
                url: root.appendingPathComponent(archive),
                options: ReaderOptions(password: "password")
            )
            let entry = try XCTUnwrap(reader.entries.first)
            let expected = try Data(contentsOf: root.appendingPathComponent("expected/\(expectedName)"))
            XCTAssertEqual(try reader.read(entry), expected, archive)
        }
    }

    func testSFXArchiveRequiresOptInAndReadsEntries() throws {
        let data = try makeSFX()
        XCTAssertThrowsError(try ArchiveReader.open(data: data))
        let options = ReaderOptions(scanForSFXInData: true)
        XCTAssertEqual(try FormatDetector.detect(data: data, options: options), .rar)
        let reader = try ArchiveReader.open(data: data, options: options)
        let phrase = Data("RAR15!\r\n".utf8)
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), entry.name == "compressed.txt" ? phrase + phrase : phrase)
        }
    }

    func testSFXFullFinalPageComputesCorrectOffset() throws {
        let reader = try ArchiveReader.open(data: try makeSFX(stubSize: 512), options: ReaderOptions(scanForSFXInData: true))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("RAR15!\r\n".utf8))
    }

    func testInvalidSFXStubsAreRejected() throws {
        var wrongMarker = try makeSFX()
        wrongMarker[28] = 0
        var zeroPages = try makeSFX()
        zeroPages[4] = 0
        zeroPages[5] = 0
        var badLastPage = try makeSFX()
        badLastPage[2] = 0
        badLastPage[3] = 2
        var badSize = try makeSFX()
        badSize[4] = 2
        var badSignature = try makeSFX()
        badSignature[64] = 0
        for data in [wrongMarker, zeroPages, badLastPage, badSize, badSignature] {
            XCTAssertNil(try RAR13Reader.sfxOffset(source: DataByteSource(data: data)))
            XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(scanForSFXInData: true)))
        }
    }

    func testRAR1402SFXMatchesUnrarOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR13_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR13_FIXTURES")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("SFXSRC.EXE")
        XCTAssertEqual(try FormatDetector.detect(url: url), .rar)
        let reader = try ArchiveReader.open(url: url)
        let entry = try XCTUnwrap(reader.entries.first)
        let expected = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("expected/\(entry.name)"))
        XCTAssertEqual(try reader.read(entry), expected)
    }

    private func makeSFX(stubSize: Int = 64) throws -> Data {
        precondition(stubSize >= 32 && stubSize <= 128 * 1_024)
        var stub = Data(repeating: 0, count: stubSize)
        stub[0] = 0x4d
        stub[1] = 0x5a
        let lastPage = stubSize % 512
        let pages = (stubSize + 511) / 512
        stub[2] = UInt8(truncatingIfNeeded: lastPage)
        stub[3] = UInt8(truncatingIfNeeded: lastPage >> 8)
        stub[4] = UInt8(truncatingIfNeeded: pages)
        stub[5] = UInt8(truncatingIfNeeded: pages >> 8)
        stub.replaceSubrange(28..<32, with: Data("RSFX".utf8))
        return try stub + TestFixtures.base64("rar13/normal.rar")
    }

    func testPasswordProviderIsResolvedOnceAndReused() throws {
        let provider = RAR13TestPasswordProvider()
        let reader = try ArchiveReader.open(
            data: TestFixtures.base64("rar13/encrypted.rar"),
            options: ReaderOptions(passwordProvider: provider)
        )
        let phrase = Data("RAR15!\r\n".utf8)
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), entry.name == "compressed.txt" ? phrase + phrase : phrase)
        }
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(reader.password, "password")
        let nonASCII = try ArchiveReader.open(
            data: TestFixtures.base64("rar13/encrypted.rar"),
            options: ReaderOptions(password: "パスワード")
        )
        XCTAssertThrowsError(try nonASCII.read(nonASCII.entries[0])) { error in
            guard case KaitoError.unsupportedMethod = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

private final class RAR13TestPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func password(for format: ArchiveFormat) throws -> String? {
        lock.lock()
        requests += 1
        lock.unlock()
        XCTAssertEqual(format, .rar)
        return "password"
    }
}
