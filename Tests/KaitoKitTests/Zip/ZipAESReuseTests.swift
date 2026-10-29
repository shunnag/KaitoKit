import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

// WinZip AES spec の LE counter / 暗号文 HMAC と project-owned ZIP writer で合成する。
final class ZipAESReuseTests: XCTestCase {
    func testManySmallAESEntriesWithDistinctSalts() throws {
        let password = "small-entry-password"
        var entries: [HandZipEntry] = []
        for index in 0..<2_048 {
            let strength = WinZipAESStrength.allCases[index % 3]
            let salt = Data((0..<strength.saltLength).map { UInt8(truncatingIfNeeded: (index >> (($0 & 3) * 8)) + $0 * 31) })
            let keys = try WinZipAESDerivedKeys.derive(for: WinZipAESKeyCacheKey(password: password, salt: salt, strength: strength))
            let plain = plaintext(index)
            let ciphertext = try referenceCTR(plain, key: keys.encryptionKey)
            let tag = Data(HMAC<Insecure.SHA1>.authenticationCode(for: ciphertext,
                using: SymmetricKey(data: keys.authenticationKey)).prefix(10))
            let version: UInt8 = index.isMultiple(of: 2) ? 1 : 2
            let extra = try ZipTestSupport.extraField(identifier: 0x9901,
                payload: Data([version, 0, 65, 69, strength.rawValue, 0, 0]))
            entries.append(HandZipEntry(name: "entry-\(index)", uncompressedData: plain,
                compressedData: salt + keys.passwordVerifier + ciphertext + tag,
                method: 99, flags: 0x0801, localExtra: extra, centralExtra: extra,
                centralCRC32: version == 2 ? 0 : nil, localCRC32: version == 2 ? 0 : nil))
        }
        let reader = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: entries),
                                            options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.count, 2_048)
        for (index, entry) in reader.entries.enumerated() {
            XCTAssertEqual(try reader.read(entry), plaintext(index), "entry=\(index)")
        }
    }

    func testCTRRetainedScratchAcrossLargeAndSmallUpdatesAndCopies() throws {
        let plain = Data((0..<(512 * 1_024 + 47)).map { UInt8(truncatingIfNeeded: $0 * 37) })
        for size in [16, 24, 32] {
            let key = Data(repeating: 0x37, count: size)
            let expected = try referenceCTR(plain, key: key)
            var ctr = try WinZipAESCTR(encryptionKey: key)
            var offset = 0
            for requested in [262_143, 1, 7, 16, 131_071, 1, 8, 262_144] {
                let end = min(offset + requested, plain.count)
                var copy = ctr
                let input = plain.subdata(in: offset..<end)
                XCTAssertEqual(try ctr.transform(input), expected.subdata(in: offset..<end))
                XCTAssertEqual(try copy.transform(input), expected.subdata(in: offset..<end))
                offset = end
            }
            XCTAssertEqual(offset, plain.count)
        }
    }

    func testFinishAuthenticatesUnreadSmallTail() throws {
        let key = Data(repeating: 0x5A, count: 16)
        let plain = plaintext(127)
        let ciphertext = try referenceCTR(plain, key: key)
        let tag = Data(HMAC<Insecure.SHA1>.authenticationCode(for: ciphertext, using: SymmetricKey(data: key)).prefix(10))
        for damaged in [false, true] {
            var storedTag = tag
            if damaged { storedTag[0] ^= 1 }
            let source = try WinZipAESByteSource(source: DataByteSource(ciphertext), ciphertextOffset: 0,
                ciphertextSize: UInt64(ciphertext.count), encryptionKey: key, authenticationKey: key,
                storedAuthenticationCode: storedTag)
            var prefix = [UInt8](repeating: 0, count: 3)
            XCTAssertEqual(try prefix.withUnsafeMutableBytes { try source.read(into: $0, at: 0) }, 3)
            if damaged {
                XCTAssertThrowsError(try source.finishAndVerify()) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
            } else { try source.finishAndVerify() }
        }
    }

    private func plaintext(_ index: Int) -> Data {
        Data((0..<(index % 129)).map { UInt8(truncatingIfNeeded: $0 * 29 + index) })
    }

    private func referenceCTR(_ input: Data, key: Data) throws -> Data {
        var counters: [UInt8] = []
        for block in 0..<((input.count + 15) / 16) {
            let counter = UInt64(block + 1)
            counters += (0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * $0)) }
            counters += repeatElement(0, count: 8)
        }
        let stream = try CommonCryptoPrimitives.aesECBEncrypt(blocks: counters, key: key)
        return Data(zip(input, stream).map { $0 ^ $1 })
    }
}
