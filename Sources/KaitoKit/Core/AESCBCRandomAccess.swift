import Foundation
private import CommonCrypto

// 検証済みの暗号範囲を、対象 block と直前の暗号 block だけで復号する。
struct AESCBCRandomAccess: Sendable {
    private static let blockSize = 16
    private static let maximumReadSize = 256 * 1_024

    private let source: any ByteSource
    private let ciphertextOffset: UInt64
    private let length: UInt64
    private let key: Data
    private let iv: [UInt8]
    private let invalidRangeMessage: String
    private let decryptECB: @Sendable ([UInt8], Data) throws -> [UInt8]

    init(
        source: any ByteSource,
        ciphertextOffset: UInt64,
        length: UInt64,
        key: Data,
        iv: [UInt8],
        invalidRangeMessage: String,
        decryptECB: @escaping @Sendable ([UInt8], Data) throws -> [UInt8]
    ) {
        self.source = source
        self.ciphertextOffset = ciphertextOffset
        self.length = length
        self.key = key
        self.iv = iv
        self.invalidRangeMessage = invalidRangeMessage
        self.decryptECB = decryptECB
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
        let prefixCount = firstBlock == 0 ? 0 : Self.blockSize
        // A single source range contains the CBC IV and all requested blocks.
        let ciphertext = try readByteRange(
            source: source,
            offset: try Checked.sub(encryptedOffset, UInt64(prefixCount)),
            count: encryptedCount + prefixCount
        )
        var plaintext = [UInt8](repeating: 0, count: encryptedCount)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            ciphertext.withUnsafeBytes { input in
                iv.withUnsafeBytes { initialIV in
                    plaintext.withUnsafeMutableBytes { output in
                        // Per-call cryptor: ByteSource permits concurrent reads.
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            keyBytes.baseAddress, key.count,
                            prefixCount == 0 ? initialIV.baseAddress : input.baseAddress,
                            input.baseAddress!.advanced(by: prefixCount), encryptedCount,
                            output.baseAddress, output.count, &written)
                    }
                }
            }
        }
        if status != kCCSuccess || written != encryptedCount {
            // Preserve the format-specific ECB callback's error cases/text if
            // CommonCrypto rejects an input. Valid CBC input takes the path above.
            let blocks = Array(ciphertext.dropFirst(prefixCount))
            plaintext = try decryptECB(blocks, key)
            plaintext.withUnsafeMutableBytes { output in
                ciphertext.withUnsafeBytes { input in
                    iv.withUnsafeBytes { initialIV in
                        xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[..<Self.blockSize]),
                                 with: prefixCount == 0 ? initialIV : UnsafeRawBufferPointer(rebasing: input[..<Self.blockSize]))
                        if encryptedCount > Self.blockSize {
                            xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[Self.blockSize...]),
                                     with: UnsafeRawBufferPointer(rebasing: input[prefixCount..<(prefixCount + encryptedCount - Self.blockSize)]))
                        }
                    }
                }
            }
        }

        let intraBlock = try Checked.toInt(offset % UInt64(Self.blockSize))
        guard intraBlock <= plaintext.count,
              requested <= plaintext.count - intraBlock,
              let destination = buffer.baseAddress else {
            throw KaitoError.malformed(invalidRangeMessage)
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

    static func roundedToBlock(_ value: UInt64) throws -> UInt64 {
        guard value > 0 else { return 0 }
        let adjusted = try Checked.add(value, UInt64(blockSize - 1))
        return adjusted & ~UInt64(blockSize - 1)
    }
}
