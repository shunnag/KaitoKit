import Foundation
private import CommonCrypto

// Provenance / behavioral references:
// - FIPS 197 / NIST SP 800-38A (AES-CBC).
// - RARLab, "RAR 5.0 archive format" technote (AES-256-CBC and IVs) and the
//   unofficial clean-room RAR 1.5-4.x notes maintained by bitplane/rar-research
//   (RAR3 AES-128 data and header encryption).
// No unrar, 7-Zip Rar29, XADMaster, or The Unarchiver source was consulted.

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

        var plaintext = try RARBlockDecryption.decryptECB(blocks: ciphertext, key: key)
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

// The CommonCrypto call is in Core/CommonCryptoPrimitives; this adds RAR's AES
// input checks and error text.
private enum RARBlockDecryption {
    static func decryptECB(blocks: [UInt8], key: Data) throws -> [UInt8] {
        guard !blocks.isEmpty,
              blocks.count.isMultiple(of: kCCBlockSizeAES128),
              key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw KaitoError.malformed("invalid RAR AES-ECB input")
        }
        do {
            return try CommonCryptoPrimitives.aesECBDecrypt(blocks: blocks, key: key)
        } catch {
            throw KaitoError.malformed(
                "CommonCrypto RAR AES failure (\(error.status), \(error.outputLength) bytes)"
            )
        }
    }
}
