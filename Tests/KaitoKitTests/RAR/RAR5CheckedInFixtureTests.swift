import Foundation
@testable import KaitoKit
import XCTest

final class RAR5CheckedInFixtureTests: XCTestCase {
    func testCheckedInHeaderEncryptedMethod3FixtureRoundTripsWithoutGenerator() throws {
        let fixtureURL = ZipTestSupport.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/rar5/header_encrypted_method3.rar.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
        let archive = try XCTUnwrap(
            Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        )

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(password: "wrong")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(reader.entries.map { $0.formatSpecific["method"] }, ["3", "3"])
        XCTAssertTrue(reader.entries[0].name.hasSuffix("/a.txt"))
        XCTAssertTrue(reader.entries[1].name.hasSuffix("/b.txt"))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("alpha\n".utf8))
        XCTAssertEqual(
            try reader.read(reader.entries[1]),
            Data("beta beta beta\n".utf8)
        )
        XCTAssertEqual(
            try reader.reopen().read(reader.entries[1]),
            Data("beta beta beta\n".utf8)
        )
    }
}
