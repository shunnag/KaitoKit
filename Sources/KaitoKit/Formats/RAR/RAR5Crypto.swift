import CryptoKit
import Foundation
private import CommonCrypto

// Provenance / behavioral references:
// - RARLab, "RAR 5.0 archive format" technote (PBKDF2-HMAC-SHA256, salts,
//   count field, password-check and HashMAC fields).
// - RFC 8018 (PBKDF2 definition).
// Final RAR5 continuation/folding behavior was verified against archives
// generated locally by rar 7.23 as a black-box oracle. No unrar, 7-Zip Rar29,
// XADMaster, or The Unarchiver source was consulted.

struct RAR5DerivedKeys: Sendable, Equatable {
    let encryptionKey: Data
    let hashKey: Data
    let passwordCheckValue: Data

    /// Returns `false` when the stored check field is internally corrupt.
    /// RAR's final four bytes authenticate the first eight bytes of this
    /// advisory verifier; an invalid field must be ignored so callers can
    /// fall back to encrypted-header or payload-integrity verification.
    @discardableResult
    func verify(passwordCheckValue storedValue: [UInt8]) throws -> Bool {
        guard storedValue.count == 12 else {
            throw KaitoError.malformed("RAR5 password check is not 12 bytes")
        }
        let recordedChecksum = Data(storedValue[8..<12])
        let calculatedChecksum = Data(
            SHA256.hash(data: Data(storedValue[0..<8])).prefix(4)
        )
        guard ConstantTime.equals(recordedChecksum, calculatedChecksum) else {
            return false
        }
        guard ConstantTime.equals(passwordCheckValue, Data(storedValue)) else {
            throw KaitoError.wrongPassword
        }
        return true
    }
}

enum RAR5KeyDerivation {
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

        passwordStorage.withUnsafeBytes { passwordBytes in
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

struct RAR5KeyCacheKey: Hashable, Sendable {
    let passwordUTF8: Data
    let salt: Data
    let count: UInt8
}

/// RAR 6.24 / 7.23 black-box vectors establish a 127 Unicode-scalar cap.
/// Retain the full UTF-8 candidate for writers that do not impose that cap.
final class RAR5PasswordSelection {
    var selectedUTF8: Data?

    static func candidates(_ password: String) -> [Data] {
        let full = Data(password.utf8)
        guard password.unicodeScalars.prefix(128).count == 128 else { return [full] }
        let prefix = String(String.UnicodeScalarView(password.unicodeScalars.prefix(127)))
        return [Data(prefix.utf8), full]
    }
}

final class RAR5KeyCache {
    let passwordSelection: RAR5PasswordSelection
    private let capacity: Int
    private var values: [RAR5KeyCacheKey: RAR5DerivedKeys] = [:]
    private var insertionOrder: [RAR5KeyCacheKey] = []

    init(capacity: Int = 16, passwordSelection: RAR5PasswordSelection = RAR5PasswordSelection()) {
        self.capacity = max(1, capacity)
        self.passwordSelection = passwordSelection
    }

    func checkedKey(
        password: String,
        salt: [UInt8],
        count: UInt8,
        checkValue: [UInt8]?,
        charge: (Data) throws -> Void = { _ in }
    ) throws -> (keys: RAR5DerivedKeys, verified: Bool) {
        let candidates = passwordSelection.selectedUTF8.map { [$0] }
            ?? RAR5PasswordSelection.candidates(password)
        for candidate in candidates {
            try charge(candidate)
            let keys = try key(passwordUTF8: candidate, salt: salt, count: count)
            do {
                let verified = try checkValue.map { try keys.verify(passwordCheckValue: $0) } ?? false
                // Missing or internally damaged advisory checks cannot select a
                // candidate. Use the first candidate and retain existing CRC /
                // decoder error handling; a later valid check can still resolve it.
                if verified { passwordSelection.selectedUTF8 = candidate }
                return (keys, verified)
            } catch KaitoError.wrongPassword {
                continue
            }
        }
        throw KaitoError.wrongPassword
    }

    // テスト専用の鍵取得。読取経路は checkedKey を使う。
    func key(
        password: String,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        try key(passwordUTF8: Data(password.utf8), salt: salt, count: count)
    }

    private func key(
        passwordUTF8: Data,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        let cacheKey = RAR5KeyCacheKey(
            passwordUTF8: passwordUTF8,
            salt: Data(salt),
            count: count
        )
        if let cached = values[cacheKey] { return cached }
        let derived = try RAR5KeyDerivation.derive(
            passwordUTF8: cacheKey.passwordUTF8,
            salt: salt,
            count: count
        )
        insert(derived, for: cacheKey)
        return derived
    }

    func removeAll() {
        passwordSelection.selectedUTF8 = nil
        values.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    private func insert(_ value: RAR5DerivedKeys, for key: RAR5KeyCacheKey) {
        if values.count == capacity, let oldest = insertionOrder.first {
            values.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        values[key] = value
        insertionOrder.append(key)
    }
}

/// RAR5's password-dependent representation of otherwise public checksums.
enum RAR5ChecksumMAC {
    static func crc32(_ checksum: UInt32, hashKey: Data) -> UInt32 {
        let raw = [
            UInt8(truncatingIfNeeded: checksum),
            UInt8(truncatingIfNeeded: checksum >> 8),
            UInt8(truncatingIfNeeded: checksum >> 16),
            UInt8(truncatingIfNeeded: checksum >> 24),
        ]
        let digest = CommonCryptoPrimitives.hmacSHA256(data: raw, key: hashKey)
        var result: UInt32 = 0
        for index in digest.indices {
            result ^= UInt32(digest[index]) << UInt32((index & 3) * 8)
        }
        return result
    }

    static func blake2sp(_ digest: Data, hashKey: Data) throws -> Data {
        guard digest.count == 32 else {
            throw KaitoError.malformed("RAR5 BLAKE2sp digest is not 32 bytes")
        }
        return Data(CommonCryptoPrimitives.hmacSHA256(data: [UInt8](digest), key: hashKey))
    }
}
