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

    private let randomAccess: AESCBCRandomAccess

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
            guard try AESCBCRandomAccess.roundedToBlock(plaintextSize) <= ciphertextSize else {
                throw KaitoError.malformed("RAR AES ciphertext is too short")
            }
        }

        self.length = plaintextSize
        self.randomAccess = AESCBCRandomAccess(
            source: source,
            ciphertextOffset: ciphertextOffset,
            length: plaintextSize,
            key: key,
            iv: [UInt8](initializationVector),
            invalidRangeMessage: "RAR AES output range is invalid",
            decryptECB: RARBlockDecryption.decryptECB
        )
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        try randomAccess.read(into: buffer, at: offset)
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
