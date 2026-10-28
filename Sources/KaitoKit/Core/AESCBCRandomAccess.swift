import Foundation
private import CommonCrypto

// 検証済みの暗号範囲を、対象 block と直前の暗号 block だけで復号する。
struct AESCBCRandomAccess: Sendable {
    private static let blockSize = 16
    private static let maximumReadSize = 256 * 1_024
    private static let ciphertextCapacity = maximumReadSize + blockSize * 2
    static let scratchBytes = ciphertextCapacity + maximumReadSize + blockSize

    // Checkout owns both buffers until read returns. Only one idle pair is
    // retained; concurrent reads allocate independently and never hold the lock
    // during source I/O or CommonCrypto. malloc avoids per-read zero filling.
    private final class Scratch {
        let storage: UnsafeMutableRawPointer
        init() throws {
            guard let storage = malloc(AESCBCRandomAccess.scratchBytes) else {
                throw KaitoError.limitExceeded("unable to allocate AES input buffer")
            }
            self.storage = storage
        }
        deinit { free(storage) }
    }
    private final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var spare: Scratch?
        func take() throws -> Scratch {
            if let scratch = lock.withLock({ let value = spare; spare = nil; return value }) { return scratch }
            return try Scratch()
        }
        func put(_ scratch: Scratch) { lock.withLock { if spare == nil { spare = scratch } } }
    }
    private let buffers = Buffers()

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

    func independent() -> Self {
        Self(source: source, ciphertextOffset: ciphertextOffset, length: length, key: key, iv: iv,
             invalidRangeMessage: invalidRangeMessage, decryptECB: decryptECB)
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
        let scratch = try buffers.take()
        defer { buffers.put(scratch) }
        let ciphertext = scratch.storage
        let plaintext = ciphertext.advanced(by: Self.ciphertextCapacity)
        let inputOffset = try Checked.sub(encryptedOffset, UInt64(prefixCount))
        let inputCount = encryptedCount + prefixCount
        guard inputCount <= Self.ciphertextCapacity, encryptedCount <= Self.maximumReadSize + Self.blockSize,
              inputOffset <= source.length, UInt64(inputCount) <= source.length - inputOffset else {
            throw KaitoError.truncated
        }
        // A single source range contains the CBC IV and all requested blocks.
        var filled = 0
        while filled < inputCount {
            let requested = inputCount - filled
            let count = try source.read(into: UnsafeMutableRawBufferPointer(
                start: ciphertext.advanced(by: filled), count: requested), at: inputOffset + UInt64(filled))
            guard count > 0, count <= requested else { throw KaitoError.truncated }
            filled += count
        }
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { initialIV in
                // Per-call cryptor: ByteSource permits concurrent reads.
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    keyBytes.baseAddress, key.count,
                    prefixCount == 0 ? initialIV.baseAddress : UnsafeRawPointer(ciphertext),
                    ciphertext.advanced(by: prefixCount), encryptedCount,
                    plaintext, encryptedCount, &written)
            }
        }
        if status != kCCSuccess || written != encryptedCount {
            // Preserve the format-specific ECB callback's error cases/text if
            // CommonCrypto rejects an input. Valid CBC input takes the path above.
            let input = UnsafeRawBufferPointer(start: ciphertext, count: inputCount)
            var blocks = try decryptECB(Array(input.dropFirst(prefixCount)), key)
            guard blocks.count == encryptedCount else { throw KaitoError.malformed(invalidRangeMessage) }
            blocks.withUnsafeMutableBytes { output in
                iv.withUnsafeBytes { initialIV in
                    xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[..<Self.blockSize]),
                             with: prefixCount == 0 ? initialIV : UnsafeRawBufferPointer(rebasing: input[..<Self.blockSize]))
                    if encryptedCount > Self.blockSize {
                        xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[Self.blockSize...]),
                                 with: UnsafeRawBufferPointer(rebasing: input[prefixCount..<(prefixCount + encryptedCount - Self.blockSize)]))
                    }
                }
                plaintext.copyMemory(from: output.baseAddress!, byteCount: encryptedCount)
            }
        }

        let intraBlock = try Checked.toInt(offset % UInt64(Self.blockSize))
        guard intraBlock <= encryptedCount,
              requested <= encryptedCount - intraBlock,
              let destination = buffer.baseAddress else {
            throw KaitoError.malformed(invalidRangeMessage)
        }
        // requested は caller buffer と plaintext の検証済み範囲内。
        destination.copyMemory(from: plaintext.advanced(by: intraBlock), byteCount: requested)
        return requested
    }

    static func roundedToBlock(_ value: UInt64) throws -> UInt64 {
        guard value > 0 else { return 0 }
        let adjusted = try Checked.add(value, UInt64(blockSize - 1))
        return adjusted & ~UInt64(blockSize - 1)
    }
}
