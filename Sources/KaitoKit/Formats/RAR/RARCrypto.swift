import CryptoKit
import Foundation
private import CommonCrypto

// Provenance / behavioral references:
// - RARLab, "RAR 5.0 archive format" technote (PBKDF2-HMAC-SHA256,
//   AES-256-CBC, salts, IVs, count field, password-check and HashMAC fields).
// - RFC 8018 (PBKDF2 definition) and FIPS 197 / NIST SP 800-38A (AES-CBC).
// - The unofficial clean-room RAR 1.5-4.x notes maintained by
//   bitplane/rar-research (RAR3 SHA-1 KDF details).
// Final RAR5 continuation/folding behavior was verified against archives
// generated locally by rar 7.23 as a black-box oracle. No unrar, 7-Zip Rar29,
// XADMaster, or The Unarchiver source was consulted.

struct RAR3DerivedKey: Sendable, Equatable {
    let key: Data
    let initializationVector: Data
}

enum RAR3KeyDerivation {
    private static let rounds = 0x40_000
    private static let snapshotInterval = rounds / 16
    private static let maximumChunkBytes = 512 * 1_024

    static func derive(password: String, salt: [UInt8]) throws -> RAR3DerivedKey {
        try derive(passwordUTF16LE: passwordBytes(password), salt: salt)
    }

    static func derive(password: String, salt: Data) throws -> RAR3DerivedKey {
        try derive(password: password, salt: [UInt8](salt))
    }

    static func derive(
        passwordUTF16LE: Data,
        salt: [UInt8]
    ) throws -> RAR3DerivedKey {
        guard salt.count == 8 else {
            throw KaitoError.malformed("RAR3 AES salt is not 8 bytes")
        }

        var base = [UInt8](passwordUTF16LE)
        base.append(contentsOf: salt)
        let recordSize = try Checked.toInt(
            try Checked.add(UInt64(base.count), 3)
        )
        guard recordSize > 3 else {
            throw KaitoError.malformed("RAR3 KDF record is invalid")
        }

        var sha1 = Insecure.SHA1()
        var initializationVector = [UInt8](repeating: 0, count: 16)

        // A snapshot is required immediately after rounds 0, 0x4000, ... .
        // Work between snapshots is submitted in bounded batches so CryptoKit
        // sees 17 updates rather than 262,144 tiny Data values in the common case.
        for group in 0..<16 {
            let firstRound = group * snapshotInterval
            try update(
                sha1: &sha1,
                base: base,
                recordSize: recordSize,
                rounds: firstRound..<(firstRound + 1)
            )
            let snapshot = sha1
            let digest = Array(snapshot.finalize())
            initializationVector[group] = digest[19]

            let endRound = (group + 1) * snapshotInterval
            try update(
                sha1: &sha1,
                base: base,
                recordSize: recordSize,
                rounds: (firstRound + 1)..<endRound
            )
        }

        let digest = Array(sha1.finalize())
        var key = [UInt8](repeating: 0, count: 16)
        for word in 0..<4 {
            let start = word * 4
            key[start] = digest[start + 3]
            key[start + 1] = digest[start + 2]
            key[start + 2] = digest[start + 1]
            key[start + 3] = digest[start]
        }
        return RAR3DerivedKey(
            key: Data(key),
            initializationVector: Data(initializationVector)
        )
    }

    static func passwordBytes(_ password: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(password.utf16.count * 2)
        for unit in password.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Data(bytes)
    }

    private static func update(
        sha1: inout Insecure.SHA1,
        base: [UInt8],
        recordSize: Int,
        rounds: Range<Int>
    ) throws {
        guard !rounds.isEmpty else { return }
        let recordsPerChunk = max(1, min(
            rounds.count,
            maximumChunkBytes / recordSize
        ))
        let capacity = try Checked.toInt(
            try Checked.mul(UInt64(recordSize), UInt64(recordsPerChunk))
        )
        var chunk = [UInt8](repeating: 0, count: capacity)
        var round = rounds.lowerBound

        while round < rounds.upperBound {
            let count = min(recordsPerChunk, rounds.upperBound - round)
            base.withUnsafeBytes { baseBytes in
                chunk.withUnsafeMutableBytes { chunkBytes in
                    for record in 0..<count {
                        let destination = chunkBytes.baseAddress!.advanced(
                            by: record * recordSize
                        )
                        destination.copyMemory(
                            from: baseBytes.baseAddress!,
                            byteCount: base.count
                        )
                        let value = round + record
                        destination.storeBytes(
                            of: UInt8(truncatingIfNeeded: value),
                            toByteOffset: base.count,
                            as: UInt8.self
                        )
                        destination.storeBytes(
                            of: UInt8(truncatingIfNeeded: value >> 8),
                            toByteOffset: base.count + 1,
                            as: UInt8.self
                        )
                        destination.storeBytes(
                            of: UInt8(truncatingIfNeeded: value >> 16),
                            toByteOffset: base.count + 2,
                            as: UInt8.self
                        )
                    }
                }
            }
            sha1.update(data: Data(chunk.prefix(count * recordSize)))
            round += count
        }
    }
}

struct RAR3KeyCacheKey: Hashable, Sendable {
    let passwordUTF16LE: Data
    let salt: Data
}

/// Small reader-owned cache: solid and multi-file archives commonly repeat a salt.
final class RAR3KeyCache {
    private let capacity: Int
    private var values: [RAR3KeyCacheKey: RAR3DerivedKey] = [:]
    private var insertionOrder: [RAR3KeyCacheKey] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    func key(password: String, salt: [UInt8]) throws -> RAR3DerivedKey {
        let cacheKey = RAR3KeyCacheKey(
            passwordUTF16LE: RAR3KeyDerivation.passwordBytes(password),
            salt: Data(salt)
        )
        if let cached = values[cacheKey] { return cached }
        let derived = try RAR3KeyDerivation.derive(
            passwordUTF16LE: cacheKey.passwordUTF16LE,
            salt: salt
        )
        insert(derived, for: cacheKey)
        return derived
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    private func insert(_ value: RAR3DerivedKey, for key: RAR3KeyCacheKey) {
        if values.count == capacity, let oldest = insertionOrder.first {
            values.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        values[key] = value
        insertionOrder.append(key)
    }
}

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
        guard RARConstantTime.equals(recordedChecksum, calculatedChecksum) else {
            return false
        }
        guard RARConstantTime.equals(passwordCheckValue, Data(storedValue)) else {
            throw KaitoError.wrongPassword
        }
        return true
    }
}

enum RAR5KeyDerivation {
    static let maximumCount: UInt8 = 24
    private static let digestSize = Int(CC_SHA256_DIGEST_LENGTH)

    static func derive(
        password: String,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        try derive(passwordUTF8: Data(password.utf8), salt: salt, count: count)
    }

    static func derive(
        password: String,
        salt: Data,
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        try derive(password: password, salt: [UInt8](salt), count: count)
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

final class RAR5KeyCache {
    private let capacity: Int
    private var values: [RAR5KeyCacheKey: RAR5DerivedKeys] = [:]
    private var insertionOrder: [RAR5KeyCacheKey] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    func key(
        password: String,
        salt: [UInt8],
        count: UInt8
    ) throws -> RAR5DerivedKeys {
        let cacheKey = RAR5KeyCacheKey(
            passwordUTF8: Data(password.utf8),
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
        let digest = RARCommonCrypto.hmacSHA256(data: raw, key: hashKey)
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
        return Data(RARCommonCrypto.hmacSHA256(data: [UInt8](digest), key: hashKey))
    }
}

enum RARConstantTime {
    static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        lhs.withUnsafeBytes { leftBytes in
            rhs.withUnsafeBytes { rightBytes in
                let left = leftBytes.bindMemory(to: UInt8.self)
                let right = rightBytes.bindMemory(to: UInt8.self)
                for index in 0..<left.count {
                    difference |= left[index] ^ right[index]
                }
            }
        }
        return difference == 0
    }
}

/// Random-access AES-CBC plaintext view used for both RAR3 and RAR5 payloads.
///
/// CBC random access needs only the requested ciphertext blocks and the block
/// immediately before them. Ciphertext is decrypted with AES-ECB in one batch,
/// then XORed with the validated preceding blocks. This avoids buffering a
/// complete encrypted entry and keeps the hot copy loop over fixed raw storage.
final class RARAESCBCByteSource: ByteSource {
    private static let blockSize = 16
    private static let maximumReadSize = 256 * 1_024

    private let source: any ByteSource
    private let ciphertextOffset: UInt64
    private let ciphertextSize: UInt64
    private let key: Data
    private let initializationVector: [UInt8]

    let length: UInt64

    init(
        source: any ByteSource,
        ciphertextOffset: UInt64,
        ciphertextSize: UInt64,
        plaintextSize: UInt64,
        key: Data,
        initializationVector: Data
    ) throws {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw KaitoError.malformed("RAR AES key has an invalid length")
        }
        guard initializationVector.count == Self.blockSize else {
            throw KaitoError.malformed("RAR AES IV is not 16 bytes")
        }
        guard ciphertextSize.isMultiple(of: UInt64(Self.blockSize)) else {
            throw KaitoError.malformed("RAR AES ciphertext is not block aligned")
        }
        let ciphertextEnd = try Checked.add(ciphertextOffset, ciphertextSize)
        guard ciphertextEnd <= source.length else { throw KaitoError.truncated }
        guard plaintextSize <= ciphertextSize else {
            throw KaitoError.malformed("RAR AES plaintext exceeds ciphertext")
        }
        if plaintextSize > 0 {
            guard try Self.roundedToBlock(plaintextSize) <= ciphertextSize else {
                throw KaitoError.malformed("RAR AES ciphertext is too short")
            }
        }

        self.source = source
        self.ciphertextOffset = ciphertextOffset
        self.ciphertextSize = ciphertextSize
        self.length = plaintextSize
        self.key = key
        self.initializationVector = [UInt8](initializationVector)
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let requested = try Checked.toInt(min(
            UInt64(buffer.count),
            UInt64(Self.maximumReadSize),
            length - offset
        ))
        let firstBlock = offset / UInt64(Self.blockSize)
        let endOffset = try Checked.add(offset, UInt64(requested))
        let blockEnd = try Self.roundedToBlock(endOffset) / UInt64(Self.blockSize)
        let blockCount = try Checked.toInt(try Checked.sub(blockEnd, firstBlock))
        let encryptedCount = try Checked.toInt(
            try Checked.mul(UInt64(blockCount), UInt64(Self.blockSize))
        )
        let encryptedOffset = try Checked.add(
            ciphertextOffset,
            try Checked.mul(firstBlock, UInt64(Self.blockSize))
        )
        let ciphertext = try readByteRange(
            source: source,
            offset: encryptedOffset,
            count: encryptedCount
        )

        let firstPrevious: [UInt8]
        if firstBlock == 0 {
            firstPrevious = initializationVector
        } else {
            firstPrevious = try readByteRange(
                source: source,
                offset: try Checked.sub(encryptedOffset, UInt64(Self.blockSize)),
                count: Self.blockSize
            )
        }

        var plaintext = try RARCommonCrypto.decryptECB(blocks: ciphertext, key: key)
        for block in 0..<blockCount {
            let base = block * Self.blockSize
            for index in 0..<Self.blockSize {
                let previous = block == 0
                    ? firstPrevious[index]
                    : ciphertext[base - Self.blockSize + index]
                plaintext[base + index] ^= previous
            }
        }

        let intraBlock = try Checked.toInt(offset % UInt64(Self.blockSize))
        guard intraBlock <= plaintext.count,
              requested <= plaintext.count - intraBlock,
              let destination = buffer.baseAddress else {
            throw KaitoError.malformed("RAR AES output range is invalid")
        }
        plaintext.withUnsafeBytes { bytes in
            destination.copyMemory(
                from: bytes.baseAddress!.advanced(by: intraBlock),
                byteCount: requested
            )
        }
        return requested
    }

    private static func roundedToBlock(_ value: UInt64) throws -> UInt64 {
        guard value > 0 else { return 0 }
        return try Checked.add(value, UInt64(blockSize - 1))
            & ~UInt64(blockSize - 1)
    }
}

private enum RARCommonCrypto {
    static func decryptECB(blocks: [UInt8], key: Data) throws -> [UInt8] {
        guard !blocks.isEmpty,
              blocks.count.isMultiple(of: kCCBlockSizeAES128),
              key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw KaitoError.malformed("invalid RAR AES-ECB input")
        }
        var output = [UInt8](repeating: 0, count: blocks.count)
        var outputLength = 0
        let capacity = output.count
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            blocks.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        blocks.count,
                        outputBytes.baseAddress,
                        capacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == blocks.count else {
            throw KaitoError.malformed(
                "CommonCrypto RAR AES failure (\(status), \(outputLength) bytes)"
            )
        }
        return output
    }

    static func hmacSHA256(data: [UInt8], key: Data) -> [UInt8] {
        var keyStorage = [UInt8](key)
        if keyStorage.isEmpty { keyStorage.append(0) }
        var output = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyStorage.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBytes.baseAddress,
                        key.count,
                        dataBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress
                    )
                }
            }
        }
        return output
    }
}
