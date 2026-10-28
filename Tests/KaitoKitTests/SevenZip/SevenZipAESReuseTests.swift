import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

// KaitoKit の salt || UTF-16LE password || LE64 counter を一 record ずつ hash する参照。
final class SevenZipAESReuseTests: XCTestCase {
    func testKeysMatchRecordReferenceAcrossChunkBoundaries() throws {
        for password in ["", "password", "日é\0本", String(repeating: "p", count: 131)] {
            for salt in [[], [UInt8](0..<16)] {
                for power: UInt8 in [0, 1, 8, 12, 13, 63] {
                    let bytes = salt.isEmpty ? [power] : [0x80 | power, 0xF0] + salt
                    let properties = try SevenZipAESProperties(bytes: bytes, maximumCyclesPower: 24)
                    let actual = try SevenZipAESKeyCache().key(password: password, properties: properties)
                    XCTAssertEqual(actual, reference(password: password, salt: salt, power: power))
                }
            }
        }
        // 一 record だけで chunk の通常上限を超える password も同じ列を hash する。
        let password = String(repeating: "p", count: 270_000)
        let properties = try SevenZipAESProperties(bytes: [1], maximumCyclesPower: 24)
        XCTAssertEqual(try SevenZipAESKeyCache().key(password: password, properties: properties),
                       reference(password: password, salt: [], power: 1))
    }

    func testEmptyPasswordCounterZeroKnownAnswer() throws {
        let properties = try SevenZipAESProperties(bytes: [0], maximumCyclesPower: 24)
        // SHA-256 of eight zero counter bytes, with no salt or password.
        XCTAssertEqual(try SevenZipAESKeyCache().key(password: "", properties: properties),
                       try Hex.data("af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc"))
    }

    private func reference(password: String, salt: [UInt8], power: UInt8) -> Data {
        let passwordBytes = password.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        if power == 63 { return Data((salt + passwordBytes + [UInt8](repeating: 0, count: 32)).prefix(32)) }
        var sha = SHA256()
        for counter in UInt64(0)..<(UInt64(1) << power) {
            let bytes = (0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * $0)) }
            sha.update(data: salt + passwordBytes + bytes)
        }
        return Data(sha.finalize())
    }
}
