import CryptoKit
import Foundation
private import CommonCrypto

// 参照仕様: 7z AES (method 06 F1 07 01) の公開 property/KDF 記述。
// AES primitive は CommonCrypto、SHA-256 は CryptoKit に限定する。

struct SevenZipAESProperties: Sendable, Equatable {
    let cyclesPower: UInt8
    let salt: Data
    let initializationVector: Data

    init(bytes: [UInt8], maximumCyclesPower: UInt8) throws {
        guard !bytes.isEmpty else {
            throw KaitoError.malformed("7zAES properties are empty")
        }
        let first = bytes[0]
        cyclesPower = first & 0x3F
        guard cyclesPower == 0x3F || cyclesPower <= maximumCyclesPower else {
            throw KaitoError.limitExceeded("7zAES cycle power \(cyclesPower)")
        }

        let second = bytes.count > 1 ? bytes[1] : 0
        let saltSize = Int(first >> 7) + Int(second >> 4)
        let ivSize = Int((first >> 6) & 1) + Int(second & 0x0F)
        guard saltSize <= 16, ivSize <= 16 else {
            throw KaitoError.malformed("invalid 7zAES salt or IV size")
        }
        let payloadSize = try Checked.toInt(
            try Checked.add(UInt64(saltSize), UInt64(ivSize))
        )
        let prefixSize = payloadSize == 0 ? 1 : 2
        guard bytes.count == prefixSize + payloadSize else {
            throw KaitoError.malformed("7zAES property length is inconsistent")
        }
        let saltStart = prefixSize
        let ivStart = saltStart + saltSize
        salt = Data(bytes[saltStart..<ivStart])
        initializationVector = Data(bytes[ivStart..<(ivStart + ivSize)])
    }
}

struct SevenZipAESKeyCacheKey: Hashable, Sendable {
    let passwordUTF16LE: Data
    let salt: Data
    let cyclesPower: UInt8
}

final class SevenZipAESKeyCache {
    private var values: [SevenZipAESKeyCacheKey: Data] = [:]

    func key(
        password: String,
        properties: SevenZipAESProperties
    ) throws -> Data {
        let passwordBytes = Self.passwordBytes(password)
        let cacheKey = SevenZipAESKeyCacheKey(
            passwordUTF16LE: passwordBytes,
            salt: properties.salt,
            cyclesPower: properties.cyclesPower
        )
        if let cached = values[cacheKey] { return cached }
        let derived = try Self.derive(cacheKey)
        values[cacheKey] = derived
        return derived
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
    }

    private static func passwordBytes(_ password: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(password.utf16.count * 2)
        for unit in password.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Data(bytes)
    }

    private static func derive(_ key: SevenZipAESKeyCacheKey) throws -> Data {
        if key.cyclesPower == 0x3F {
            var direct = Data()
            direct.reserveCapacity(32)
            direct.append(key.salt)
            direct.append(key.passwordUTF16LE)
            if direct.count < 32 {
                direct.append(contentsOf: repeatElement(0, count: 32 - direct.count))
            }
            return Data(direct.prefix(32))
        }

        let rounds = try Checked.shiftLeft(1, by: UInt64(key.cyclesPower))
        let recordSize64 = try Checked.add(
            try Checked.add(UInt64(key.salt.count), UInt64(key.passwordUTF16LE.count)),
            8
        )
        let recordSize = try Checked.toInt(recordSize64)
        guard recordSize > 0 else {
            throw KaitoError.malformed("invalid 7zAES KDF record size")
        }

        // CryptoKit 呼出し回数を減らすため、4096 counter 分を上限付きでまとめる。
        let recordsPerChunk = max(1, min(4_096, (512 * 1_024) / recordSize))
        let chunkSize = try Checked.toInt(
            try Checked.mul(UInt64(recordSize), UInt64(recordsPerChunk))
        )
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let salt = [UInt8](key.salt)
        let password = [UInt8](key.passwordUTF16LE)
        var sha = SHA256()
        var counter: UInt64 = 0

        while counter < rounds {
            let count = try Checked.toInt(min(UInt64(recordsPerChunk), rounds - counter))
            for record in 0..<count {
                let base = record * recordSize
                if !salt.isEmpty {
                    chunk.replaceSubrange(base..<(base + salt.count), with: salt)
                }
                let passwordStart = base + salt.count
                if !password.isEmpty {
                    chunk.replaceSubrange(
                        passwordStart..<(passwordStart + password.count),
                        with: password
                    )
                }
                var value = counter + UInt64(record)
                let counterStart = passwordStart + password.count
                for index in 0..<8 {
                    chunk[counterStart + index] = UInt8(truncatingIfNeeded: value)
                    value >>= 8
                }
            }
            sha.update(data: Data(chunk.prefix(count * recordSize)))
            counter = try Checked.add(counter, UInt64(count))
        }
        return Data(sha.finalize())
    }
}

// CBC の任意位置は、対象 block と直前の暗号 block だけで復号できる。
// そのため巨大な暗号 stream を保持せず ByteSource の random-access 契約を満たす。
final class SevenZipAESByteSource: ByteSource {
    private static let blockSize = 16
    private static let maximumReadSize = 256 * 1_024

    private let source: any ByteSource
    private let ciphertextOffset: UInt64
    private let ciphertextSize: UInt64
    private let key: Data
    private let iv: [UInt8]

    let length: UInt64

    init(
        source: any ByteSource,
        ciphertextOffset: UInt64,
        ciphertextSize: UInt64,
        plaintextSize: UInt64,
        key: Data,
        initializationVector: Data
    ) throws {
        guard key.count == 32 else {
            throw KaitoError.malformed("7zAES key is not 256 bits")
        }
        guard initializationVector.count <= Self.blockSize else {
            throw KaitoError.malformed("7zAES IV is longer than one block")
        }
        let end = try Checked.add(ciphertextOffset, ciphertextSize)
        guard end <= source.length else { throw KaitoError.truncated }
        guard ciphertextSize.isMultiple(of: UInt64(Self.blockSize)) else {
            throw KaitoError.malformed("7zAES ciphertext is not block aligned")
        }
        let paddedPlaintext = try Self.roundedToBlock(plaintextSize)
        guard paddedPlaintext == ciphertextSize else {
            throw KaitoError.malformed("7zAES padded size is inconsistent")
        }

        var iv = [UInt8](repeating: 0, count: Self.blockSize)
        for (index, byte) in initializationVector.enumerated() { iv[index] = byte }
        self.source = source
        self.ciphertextOffset = ciphertextOffset
        self.ciphertextSize = ciphertextSize
        self.length = plaintextSize
        self.key = key
        self.iv = iv
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
            firstPrevious = iv
        } else {
            let previousOffset = try Checked.sub(encryptedOffset, UInt64(Self.blockSize))
            firstPrevious = try readByteRange(
                source: source,
                offset: previousOffset,
                count: Self.blockSize
            )
        }

        var plaintext = try SevenZipCommonCrypto.decryptECB(blocks: ciphertext, key: key)
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
            throw KaitoError.malformed("7zAES output range is invalid")
        }
        plaintext.withUnsafeBytes { bytes in
            // requested は caller buffer と plaintext の検証済み範囲内。
            destination.copyMemory(
                from: bytes.baseAddress!.advanced(by: intraBlock),
                byteCount: requested
            )
        }
        return requested
    }

    private static func roundedToBlock(_ value: UInt64) throws -> UInt64 {
        guard value > 0 else { return 0 }
        let adjusted = try Checked.add(value, UInt64(blockSize - 1))
        return adjusted & ~UInt64(blockSize - 1)
    }
}

private enum SevenZipCommonCrypto {
    static func decryptECB(blocks: [UInt8], key: Data) throws -> [UInt8] {
        guard !blocks.isEmpty,
              blocks.count.isMultiple(of: kCCBlockSizeAES128),
              key.count == kCCKeySizeAES256 else {
            throw KaitoError.malformed("invalid 7zAES ECB input")
        }
        var output = [UInt8](repeating: 0, count: blocks.count)
        let outputCount = output.count
        var moved = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            blocks.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    // 3 領域はクロージャ中有効で、出力は blocks.count byte 確保済み。
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
                        outputCount,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == blocks.count else {
            throw KaitoError.malformed("CommonCrypto 7zAES failure (\(status))")
        }
        return output
    }
}
