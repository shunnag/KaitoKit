import Foundation
private import CommonCrypto

// ECB has no chaining state: complete aligned updates can share a keyed cryptor.
// The lock also makes copies of a Sendable CTR value safe to use concurrently.
final class CommonCryptoECBEncryptor: @unchecked Sendable {
    private let key: Data
    private let lock = NSLock()
    private var cryptor: CCCryptorRef?

    init(key: Data) { self.key = key }
    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    func encryptInPlace(_ blocks: UnsafeMutableRawBufferPointer) throws(CommonCryptoPrimitives.Failure) {
        lock.lock()
        defer { lock.unlock() }
        if cryptor == nil {
            var created: CCCryptorRef?
            let status = key.withUnsafeBytes { bytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeECB),
                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), nil,
                    bytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &created)
            }
            guard status == kCCSuccess, let created else {
                if let created { CCCryptorRelease(created) }
                throw CommonCryptoPrimitives.Failure(status: status, outputLength: 0)
            }
            cryptor = created
        }
        var written = 0
        let status = CCCryptorUpdate(cryptor!, blocks.baseAddress, blocks.count,
                                     blocks.baseAddress, blocks.count, &written)
        guard status == kCCSuccess, written == blocks.count else {
            // A failed update must not leave a cryptor with buffered input.
            CCCryptorRelease(cryptor!)
            cryptor = nil
            throw CommonCryptoPrimitives.Failure(status: status, outputLength: written)
        }
    }
}

// Both ranges are validated by callers. Unaligned loads also cover partial CTR
// blocks; only the last seven bytes need scalar XOR.
@inline(__always)
func xorBytes(_ output: UnsafeMutableRawBufferPointer, with keyStream: UnsafeRawBufferPointer) {
    precondition(output.count <= keyStream.count)
    var offset = 0
    while output.count - offset >= 8 {
        output.storeBytes(of: output.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            ^ keyStream.loadUnaligned(fromByteOffset: offset, as: UInt64.self),
            toByteOffset: offset, as: UInt64.self)
        offset += 8
    }
    while offset < output.count {
        output[offset] ^= keyStream[offset]
        offset += 1
    }
}
