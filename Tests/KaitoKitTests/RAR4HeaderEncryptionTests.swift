import Foundation
@testable import KaitoKit
import XCTest

final class RAR4HeaderEncryptionTests: XCTestCase {
    private static let corpus = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/rar4-corpus",
        isDirectory: true
    )

    func testEncryptedHeadersRequirePasswordAndRejectWrongPassword() throws {
        let archive = Self.corpus.appendingPathComponent(
            "test_read_format_rar_encryption_header.rar"
        )
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("RAR4 encrypted-header corpus is absent")
        }

        XCTAssertThrowsError(try ArchiveReader.open(url: archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "incorrect")
        )) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testEncryptedHeadersAreListedAndReopenRetainsResolvedPassword() throws {
        let archive = Self.corpus.appendingPathComponent(
            "test_read_format_rar_encryption_header.rar"
        )
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("RAR4 encrypted-header corpus is absent")
        }

        let provider = FixedRARPasswordProvider(value: "12345678")
        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(passwordProvider: provider)
        )
        XCTAssertEqual(reader.password, "12345678")
        XCTAssertEqual(reader.entries.map(\.name), ["foo.txt", "bar.txt"])
        XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))

        let reopened = try reader.reopen()
        XCTAssertEqual(reopened.password, "12345678")
        XCTAssertEqual(reopened.entries, reader.entries)
    }
}

private struct FixedRARPasswordProvider: PasswordProvider {
    let value: String?

    func password(for format: ArchiveFormat) throws -> String? {
        XCTAssertEqual(format, .rar)
        return value
    }
}
