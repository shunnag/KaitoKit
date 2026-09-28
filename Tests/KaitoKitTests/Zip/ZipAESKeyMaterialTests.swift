import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipAESKeyMaterialTests: XCTestCase {
    func testDerivationMatchesExistingKeysForEveryStrengthAndUTF8Bytes() throws {
        for strength in WinZipAESStrength.allCases {
            let salt = Data((0..<strength.saltLength).map(UInt8.init))
            for password in [Data(), Data("日本語".utf8), Data("é".utf8), Data("e\u{301}".utf8), Data([0, 0xff, 0x80])] {
                let key = WinZipAESKeyCacheKey(passwordBytes: password, salt: salt, strength: strength)
                let existing = try WinZipAESDerivedKeys.derive(for: key)
                let material = try ZipAESKeyMaterial.derive(passwordBytes: password, salt: salt, strength: strength.rawValue)
                XCTAssertEqual(material.bytes, existing.encryptionKey + existing.authenticationKey + existing.passwordVerifier)
                XCTAssertEqual(material.salt, salt)
                XCTAssertEqual(material.strength, strength.rawValue)
                XCTAssertEqual(try WinZipAESDerivedKeys(salt: salt, strength: strength, material: material.bytes), existing)
                let sliced = (Data([0xff]) + material.bytes).dropFirst()
                XCTAssertEqual(try WinZipAESDerivedKeys(salt: salt, strength: strength, material: sliced), existing)
            }
            XCTAssertNotEqual(try ZipAESKeyMaterial.derive(passwordBytes: Data("é".utf8), salt: salt, strength: strength.rawValue),
                              try ZipAESKeyMaterial.derive(passwordBytes: Data("e\u{301}".utf8), salt: salt, strength: strength.rawValue))
        }
    }

    func testSuppliedMaterialDoesNotPopulateOrChangePasswordKeyCache() throws {
        let bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/aes128-ae1.zip")
        let reader = try ZipReader(source: DataByteSource(bytes), options: ReaderOptions(password: "raw-password"))
        let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0, limits: ReadLimits()))
        let offset = Int(layout.payloadRange.lowerBound)
        let material = try ZipAESKeyMaterial.derive(passwordBytes: Data("raw-password".utf8),
                                                  salt: bytes.subdata(in: offset..<(offset + 8)), strength: 1)
        XCTAssertEqual(try cache(reader).count, 0)
        for storedOnly in [true, false] {
            _ = try XCTUnwrap(reader.zipStream(at: 0, limits: ReadLimits(), aesKey: material, storedOnly: storedOnly)).readAll()
            XCTAssertEqual(try cache(reader).count, 0)
        }
        _ = try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll()
        let cached = try cache(reader)
        XCTAssertEqual(cached.count, 1)
        for storedOnly in [true, false] {
            _ = try XCTUnwrap(reader.zipStream(at: 0, limits: ReadLimits(), aesKey: material, storedOnly: storedOnly)).readAll()
            XCTAssertEqual(try cache(reader), cached)
        }
    }

    private func cache(_ reader: ZipReader) throws -> [WinZipAESKeyCacheKey: WinZipAESDerivedKeys] {
        try XCTUnwrap(Mirror(reflecting: reader).children.first { $0.label == "aesDerivedKeyCache" }?.value
            as? [WinZipAESKeyCacheKey: WinZipAESDerivedKeys])
    }
}
