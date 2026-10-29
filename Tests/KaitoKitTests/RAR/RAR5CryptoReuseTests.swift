import CryptoKit
import Foundation
private import CommonCrypto
@testable import KaitoKit
import XCTest

// RARLab RAR 5.0 technote と KaitoKit の変更前 CCHmac loop を比較する。
final class RAR5CryptoReuseTests: XCTestCase {
    func testAllThreeOutputsMatchOriginalHMACLoop() throws {
        let passwords = [Data(), Data("password".utf8), Data("日é\0本".utf8),
                         Data(repeating: 0x61, count: 64), Data(repeating: 0x62, count: 65),
                         Data(String(repeating: "日é", count: 40).utf8), Data((0..<255).map(UInt8.init))]
        let salts = [Array(0..<16).map(UInt8.init), [UInt8](repeating: 0, count: 16),
                     (0..<16).map { UInt8(truncatingIfNeeded: $0 * 37 + 19) }]
        for password in passwords {
            for salt in salts {
                for count: UInt8 in [0, 1, 4, 8, 12] {
                    let actual = try RAR5KeyDerivation.derive(passwordUTF8: password, salt: salt, count: count)
                    let expected = try RAR5KDFReference.derive(passwordUTF8: password, salt: salt, count: count)
                    XCTAssertEqual(actual, expected, "password bytes=\(password.count), count=\(count)")
                }
            }
        }
    }
}

// 変更前の実装を保存する。2^n / 2^n+16 / 2^n+32 の継続・folding も独立に検査する。
private enum RAR5KDFReference {
    static let maximumCount: UInt8 = 24
    private static let digestSize = Int(CC_SHA256_DIGEST_LENGTH)

    // テスト専用の鍵導出。読取経路は derive(passwordUTF8:salt:count:) を使う。
    static func derive(
        password: String,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        try derive(passwordUTF8: Data(password.utf8), salt: salt, count: count)
    }

    static func derive(
        passwordUTF8: Data,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        guard salt.count == 16 else {
            throw KaitoError.malformed("RAR5 AES salt is not 16 bytes")
        }
        guard count <= maximumCount else {
            throw KaitoError.limitExceeded("RAR5 KDF count \(count) exceeds 24")
        }

        let baseIterations = 1 << Int(count)
        let finalIteration = baseIterations + 32
        var firstMessage = salt
        // PBKDF2 block number 1, big-endian.
        firstMessage.append(contentsOf: [0, 0, 0, 1])

        var passwordStorage = [UInt8](passwordUTF8)
        if passwordStorage.isEmpty { passwordStorage.append(0) }
        var current = [UInt8](repeating: 0, count: digestSize)
        var next = [UInt8](repeating: 0, count: digestSize)
        var accumulator = [UInt8](repeating: 0, count: digestSize)
        var encryptionKey: [UInt8]?
        var hashKey: [UInt8]?

        try passwordStorage.withUnsafeBytes { passwordBytes in
            try Task.checkCancellation()
            hmacSHA256(
                key: passwordBytes,
                keyCount: passwordUTF8.count,
                message: firstMessage,
                output: &current
            )
            accumulator = current
            if baseIterations == 1 {
                encryptionKey = accumulator
            }

            if finalIteration >= 2 {
                for iteration in 2...finalIteration {
                    if (iteration - 1).isMultiple(of: 4_096) { try Task.checkCancellation() }
                    hmacSHA256(
                        key: passwordBytes,
                        keyCount: passwordUTF8.count,
                        message: current,
                        output: &next
                    )
                    swap(&current, &next)
                    for index in 0..<digestSize {
                        accumulator[index] ^= current[index]
                    }
                    if iteration == baseIterations {
                        encryptionKey = accumulator
                    } else if iteration == baseIterations + 16 {
                        hashKey = accumulator
                    }
                }
            }
        }

        guard let encryptionKey, let hashKey else {
            throw KaitoError.malformed("RAR5 KDF did not produce all keys")
        }

        var foldedCheck = [UInt8](repeating: 0, count: 8)
        for index in accumulator.indices {
            foldedCheck[index & 7] ^= accumulator[index]
        }
        let checkDigest = SHA256.hash(data: Data(foldedCheck))
        foldedCheck.append(contentsOf: checkDigest.prefix(4))

        return RAR5DerivedKeys(
            encryptionKey: Data(encryptionKey),
            hashKey: Data(hashKey),
            passwordCheckValue: Data(foldedCheck)
        )
    }

    private static func hmacSHA256(
        key: UnsafeRawBufferPointer,
        keyCount: Int,
        message: [UInt8],
        output: inout [UInt8]
    ) {
        message.withUnsafeBytes { messageBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    key.baseAddress,
                    keyCount,
                    messageBytes.baseAddress,
                    message.count,
                    outputBytes.baseAddress
                )
            }
        }
    }
}

