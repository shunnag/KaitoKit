import Foundation
@testable import KaitoKit
import XCTest

final class RAR5PasswordCompatibilityTests: XCTestCase {
    func testCandidatesPreserveShortBytesAndUseScalarBoundary() {
        for password in ["", "secret", String(repeating: "😀", count: 127),
                         String(repeating: "e\u{301}", count: 63) + "e"] {
            XCTAssertEqual(RAR5PasswordSelection.candidates(password), [Data(password.utf8)])
        }
        for password in [String(repeating: "A", count: 128),
                         String(repeating: "か", count: 200),
                         String(repeating: "😀", count: 130),
                         String(repeating: "e\u{301}", count: 65)] {
            let prefix = String(String.UnicodeScalarView(password.unicodeScalars.prefix(127)))
            XCTAssertEqual(RAR5PasswordSelection.candidates(password), [Data(prefix.utf8), Data(password.utf8)])
        }
    }

    func testMeasuredWriterPasswordsReadReopenAndReset() throws {
        for (writer, label, password) in [
            ("rar6", "ascii127", String(repeating: "A", count: 127)),
            ("rar6", "ascii128", String(repeating: "A", count: 128)),
            ("rar6", "kana128", String(repeating: "か", count: 128)),
            ("rar7", "emoji130", String(repeating: "😀", count: 130)),
        ] {
            for mode in ["p", "hp"] {
                try verify("m5_\(writer)_\(mode)_\(label)", password: password,
                           payloads: [Data("hello world\n".utf8), Data("second file contents 12345\n".utf8)])
            }
        }
    }

    func testFullPasswordWriterFallbackForFilesAndHeaders() throws {
        for mode in ["p", "hp"] {
            try verify("password-full-\(mode)", password: String(repeating: "e\u{301}", count: 65),
                       payloads: Array(repeating: Data("KaitoKit full UTF-8 password compatibility\n".utf8), count: 2))
        }
    }

    func testSelectionReusedAcrossSaltsAndKDFCacheHits() throws {
        let password = String(repeating: "😀", count: 130)
        let cache = RAR5KeyCache()
        let firstSalt = [UInt8](repeating: 1, count: 16)
        let secondSalt = [UInt8](repeating: 2, count: 16)
        let fullKeys = try RAR5KeyDerivation.derive(password: password, salt: firstSalt, count: 0)
        var attempted: [Data] = []
        _ = try cache.checkedKey(password: password, salt: firstSalt, count: 0,
                                 checkValue: Array(fullKeys.passwordCheckValue)) { attempted.append($0) }
        XCTAssertEqual(attempted, RAR5PasswordSelection.candidates(password))
        let secondKeys = try RAR5KeyDerivation.derive(password: password, salt: secondSalt, count: 0)
        for salt in [secondSalt, firstSalt, secondSalt] {
            attempted.removeAll()
            let expected = salt == firstSalt ? fullKeys : secondKeys
            let result = try cache.checkedKey(password: password, salt: salt, count: 0,
                                             checkValue: Array(expected.passwordCheckValue)) { attempted.append($0) }
            XCTAssertEqual(attempted, [Data(password.utf8)])
            XCTAssertEqual(result.keys, expected)
        }
        cache.removeAll()
        XCTAssertNil(cache.passwordSelection.selectedUTF8)
    }

    func testMissingOrDamagedCheckUsesFirstCandidateWithoutSelecting() throws {
        let password = String(repeating: "😀", count: 130)
        let cache = RAR5KeyCache()
        let salt = [UInt8](repeating: 1, count: 16)
        let prefix = String(repeating: "😀", count: 127)
        let expected = try RAR5KeyDerivation.derive(password: prefix, salt: salt, count: 0)
        for check: [UInt8]? in [nil, [UInt8](repeating: 0, count: 12)] {
            let result = try cache.checkedKey(password: password, salt: salt, count: 0, checkValue: check)
            XCTAssertEqual(result.keys, expected)
            XCTAssertFalse(result.verified)
            XCTAssertNil(cache.passwordSelection.selectedUTF8)
        }
    }

    func testFallbackHeaderKDFWorkIsCharged() throws {
        var limits = ReadLimits()
        limits.maxRAR5HeaderKDFWork = 33 // One count=0 derivation; fallback needs two.
        XCTAssertThrowsError(try ArchiveReader.open(data: fixture("password-full-hp"),
            options: ReaderOptions(limits: limits, password: String(repeating: "e\u{301}", count: 65)))) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("RAR5 header encryption KDF work"))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar5/\(name).rar.b64")
        return try XCTUnwrap(Data(base64Encoded: String(contentsOf: url, encoding: .utf8), options: .ignoreUnknownCharacters))
    }

    private func verify(_ name: String, password: String, payloads: [Data]) throws {
        let data = try fixture(name)
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.count, payloads.count)
        for index in [1, 0, 1] {
            XCTAssertEqual(try reader.read(reader.entries[index]), payloads[index], name)
        }
        XCTAssertEqual(reader.password, password)
        let reopened = try reader.reopen()
        reader.password = String(repeating: "wrong", count: 30)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        XCTAssertEqual(try reopened.read(reopened.entries[0]), payloads[0])
        reader.password = password
        XCTAssertEqual(try reader.read(reader.entries[0]), payloads[0])
        XCTAssertThrowsError(try {
            let wrong = try ArchiveReader.open(data: data, options: ReaderOptions(password: "incorrect"))
            _ = try wrong.read(wrong.entries[0])
        }()) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
    }
}
