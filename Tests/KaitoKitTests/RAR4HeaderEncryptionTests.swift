import Foundation
@testable import KaitoKit
import XCTest

final class RAR4HeaderEncryptionTests: XCTestCase {
    func testEncryptedHeadersRequirePasswordAndRejectWrongPassword() throws {
        let archive = try Self.fixture()

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(password: "incorrect")
        )) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testEncryptedHeadersAreListedAndReopenRetainsResolvedPassword() throws {
        let archive = try Self.fixture()

        let provider = FixedRARPasswordProvider(value: "12345678")
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(passwordProvider: provider)
        )
        XCTAssertEqual(reader.password, "12345678")
        XCTAssertEqual(reader.entries.map(\.name), ["foo.txt", "bar.txt"])
        XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))

        let reopened = try reader.reopen()
        XCTAssertEqual(reopened.password, "12345678")
        XCTAssertEqual(reopened.entries, reader.entries)
    }

    func testEncryptedHeaderPhysicalTruncationIsReportedAsTruncated() throws {
        let archive = try Self.fixture()
        let mainOffset = RAR4Reader.signature.count
        let mainHeaderSize = Int(archive[mainOffset + 5])
            | Int(archive[mainOffset + 6]) << 8
        let firstEncryptedHeader = mainOffset + mainHeaderSize
        let truncatedArchives = [
            Data(archive.prefix(firstEncryptedHeader + 23)),
            Data(archive.dropLast()),
        ]
        for truncated in truncatedArchives {
            XCTAssertThrowsError(try ArchiveReader.open(
                data: truncated,
                options: ReaderOptions(password: "12345678")
            )) { error in
                XCTAssertEqual(error as? KaitoError, .truncated)
            }
        }
    }

    private static func fixture() throws -> Data {
        let url = ZipTestSupport.repositoryRoot
            .appendingPathComponent(
                "Tests/Fixtures/rar4/libarchive_encrypted_headers.rar.b64"
            )
        let encoded = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )
    }
}

private struct FixedRARPasswordProvider: PasswordProvider {
    let value: String?

    func password(for format: ArchiveFormat) throws -> String? {
        XCTAssertEqual(format, .rar)
        return value
    }
}
