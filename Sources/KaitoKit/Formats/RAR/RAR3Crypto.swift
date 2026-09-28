import CryptoKit
import Foundation
private import CommonCrypto

// Provenance / behavioral references:
// - The unofficial clean-room RAR 1.5-4.x notes maintained by
//   bitplane/rar-research (RAR3 SHA-1 KDF details).
// - The long-password input mutation was derived from supplied compatibility
//   findings and verified against RAR 6.24 -p/-hp archives as a black box.
// No unrar, 7-Zip Rar29, XADMaster, or The Unarchiver source was consulted.

struct RAR3DerivedKey: Sendable, Equatable {
    let key: Data
    let initializationVector: Data
}

enum RAR3KeyDerivation {
    private static let rounds = 0x40_000
    private static let snapshotInterval = rounds / 16
    private static let maximumChunkBytes = 512 * 1_024

    // テスト専用の鍵導出。読取経路は derive(passwordUTF16LE:salt:) を使う。
    static func derive(password: String, salt: [UInt8]) throws -> RAR3DerivedKey {
        try derive(passwordUTF16LE: passwordBytes(password), salt: salt)
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

        guard UInt64(base.count) <= UInt64(CC_LONG.max) else {
            throw KaitoError.limitExceeded("RAR3 password exceeds SHA-1 update capacity")
        }
        if base.count > 64 {
            return deriveLegacyLongPassword(base: &base)
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

    // A long RAR3 password does not follow the plain SHA-1 KDF: for every input
    // block SHA-1 processes directly, the last 16 message-schedule words are
    // written back into the password buffer and become the next round's input.
    private static func deriveLegacyLongPassword(base: inout [UInt8]) -> RAR3DerivedKey {
        var context = CC_SHA1_CTX()
        CC_SHA1_Init(&context)
        var iv = [UInt8](repeating: 0, count: 16)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        var words = [UInt32](repeating: 0, count: 16)
        var pending = 0
        base.withUnsafeMutableBytes { bytes in
            words.withUnsafeMutableBufferPointer { schedule in
                for round in 0..<rounds {
                    CC_SHA1_Update(&context, bytes.baseAddress, CC_LONG(bytes.count))
                    // A leading partial block is copied into SHA-1's internal
                    // buffer; only directly processed blocks are rewritten.
                    var start = 64 - pending
                    while start <= bytes.count - 64 {
                        for index in 0..<16 {
                            schedule[index] = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: start + index * 4, as: UInt32.self))
                        }
                        for index in 16..<80 {
                            let value = schedule[(index - 3) & 15] ^ schedule[(index - 8) & 15]
                                ^ schedule[(index - 14) & 15] ^ schedule[index & 15]
                            schedule[index & 15] = (value << 1) | (value >> 31)
                        }
                        for index in 0..<16 {
                            bytes.storeBytes(of: schedule[index].littleEndian, toByteOffset: start + index * 4, as: UInt32.self)
                        }
                        start += 64
                    }
                    var counter = UInt32(round).littleEndian
                    CC_SHA1_Update(&context, &counter, 3)
                    pending = (pending + bytes.count + 3) & 63
                    if round.isMultiple(of: snapshotInterval) {
                        var snapshot = context
                        CC_SHA1_Final(&digest, &snapshot)
                        iv[round / snapshotInterval] = digest[19]
                    }
                }
            }
        }
        CC_SHA1_Final(&digest, &context)
        var key = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { key[index] = digest[(index & ~3) + 3 - (index & 3)] }
        return RAR3DerivedKey(key: Data(key), initializationVector: Data(iv))
    }

    static func passwordBytes(_ password: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(password.utf16.count, 127) * 2)
        // RAR3 writers retain at most 127 wide characters. Match that boundary
        // before applying the legacy SHA-1 input mutation.
        for unit in password.utf16.prefix(127) {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Data(bytes)
    }

    static func unixPasswordBytes(_ password: String) -> Data {
        // Unix RAR truncates its 32-bit wchar_t to the low 16 bits for the RAR3
        // KDF. Windows writers use UTF-16 surrogate pairs (`passwordBytes`); the
        // reader selects whichever matches the writer.
        var bytes = [UInt8]()
        bytes.reserveCapacity(min(password.utf16.count, 127) * 2)
        for scalar in password.unicodeScalars.prefix(127) {
            bytes.append(UInt8(truncatingIfNeeded: scalar.value))
            bytes.append(UInt8(truncatingIfNeeded: scalar.value >> 8))
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

    func key(password: String, salt: [UInt8], unixScalars: Bool = false) throws -> RAR3DerivedKey {
        let cacheKey = RAR3KeyCacheKey(
            passwordUTF16LE: unixScalars
                ? RAR3KeyDerivation.unixPasswordBytes(password)
                : RAR3KeyDerivation.passwordBytes(password),
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
