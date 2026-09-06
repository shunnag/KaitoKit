import Foundation
import Synchronization
private import CommonCrypto

// 参照仕様: WinZip AES Encryption Specification AE-1 and AE-2, version 1.04.

enum WinZipAESVendorVersion: UInt16, Sendable {
    case ae1 = 1
    case ae2 = 2

    var shouldVerifyCRC: Bool {
        self == .ae1
    }
}

enum WinZipAESStrength: UInt8, Sendable, CaseIterable {
    case aes128 = 1
    case aes192 = 2
    case aes256 = 3

    var keyLength: Int {
        switch self {
        case .aes128: 16
        case .aes192: 24
        case .aes256: 32
        }
    }

    var saltLength: Int {
        keyLength / 2
    }
}

// 0x9901 追加フィールドの 7 バイト仕様部分。
struct WinZipAESMetadata: Sendable, Equatable {
    static let extraFieldID: UInt16 = 0x9901

    let vendorVersion: WinZipAESVendorVersion
    let strength: WinZipAESStrength
    let compressionMethod: UInt16

    var shouldVerifyCRC: Bool {
        vendorVersion.shouldVerifyCRC
    }

    init(
        vendorVersion: WinZipAESVendorVersion,
        strength: WinZipAESStrength,
        compressionMethod: UInt16
    ) {
        self.vendorVersion = vendorVersion
        self.strength = strength
        self.compressionMethod = compressionMethod
    }

    // 呼び出し側が ID と長さを除いた追加フィールド本体を渡す。
    init(extraFieldPayload payload: Data) throws {
        guard payload.count >= 7 else {
            throw KaitoError.malformed("WinZip AES extra field is shorter than 7 bytes")
        }

        let bytes = [UInt8](payload.prefix(7))
        guard bytes[2] == 0x41, bytes[3] == 0x45 else {
            throw KaitoError.malformed("WinZip AES extra field has an invalid vendor ID")
        }

        let rawVersion = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard let vendorVersion = WinZipAESVendorVersion(rawValue: rawVersion) else {
            throw KaitoError.unsupportedMethod("WinZip AES vendor version \(rawVersion)")
        }
        guard let strength = WinZipAESStrength(rawValue: bytes[4]) else {
            throw KaitoError.unsupportedMethod("WinZip AES strength \(bytes[4])")
        }

        self.vendorVersion = vendorVersion
        self.strength = strength
        self.compressionMethod = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
    }
}

// 圧縮サイズに含まれる salt / verifier / ciphertext / auth を分離する。
struct WinZipAESPayload: Sendable, Equatable {
    static let passwordVerifierSize = 2
    static let authenticationCodeSize = 10

    let salt: Data
    let passwordVerifier: Data
    let ciphertext: Data
    let authenticationCode: Data

    init(data: Data, strength: WinZipAESStrength) throws {
        let overhead = strength.saltLength
            + Self.passwordVerifierSize
            + Self.authenticationCodeSize
        guard data.count >= overhead else {
            throw KaitoError.truncated
        }

        let bytes = [UInt8](data)
        let verifierStart = strength.saltLength
        let ciphertextStart = verifierStart + Self.passwordVerifierSize
        let authenticationStart = bytes.count - Self.authenticationCodeSize

        salt = Data(bytes[..<verifierStart])
        passwordVerifier = Data(bytes[verifierStart..<ciphertextStart])
        ciphertext = Data(bytes[ciphertextStart..<authenticationStart])
        authenticationCode = Data(bytes[authenticationStart...])
    }
}

// 派生鍵キャッシュの識別子。String は正規化せず UTF-8 バイト列にする。
struct WinZipAESKeyCacheKey: Hashable, Sendable {
    let passwordBytes: Data
    let salt: Data
    let strength: WinZipAESStrength

    init(password: String, salt: Data, strength: WinZipAESStrength) {
        self.init(passwordBytes: Data(password.utf8), salt: salt, strength: strength)
    }

    init(passwordBytes: Data, salt: Data, strength: WinZipAESStrength) {
        self.passwordBytes = passwordBytes
        self.salt = salt
        self.strength = strength
    }
}

struct WinZipAESDerivedKeys: Sendable, Equatable {
    let salt: Data
    let strength: WinZipAESStrength
    let encryptionKey: Data
    let authenticationKey: Data
    let passwordVerifier: Data

    static func derive(for cacheKey: WinZipAESKeyCacheKey) throws -> Self {
        guard cacheKey.salt.count == cacheKey.strength.saltLength else {
            throw KaitoError.malformed(
                "WinZip AES salt length \(cacheKey.salt.count) does not match strength"
            )
        }

        let keyLength = cacheKey.strength.keyLength
        let derivedLength = keyLength * 2 + WinZipAESPayload.passwordVerifierSize
        let material = try ZipCommonCrypto.pbkdf2SHA1(
            password: cacheKey.passwordBytes,
            salt: cacheKey.salt,
            iterations: 1_000,
            outputLength: derivedLength
        )

        let authenticationStart = keyLength
        let verifierStart = keyLength * 2
        return Self(
            salt: cacheKey.salt,
            strength: cacheKey.strength,
            encryptionKey: Data(material[..<authenticationStart]),
            authenticationKey: Data(material[authenticationStart..<verifierStart]),
            passwordVerifier: Data(material[verifierStart..<derivedLength])
        )
    }
}

struct WinZipAESDecryptionResult: Sendable, Equatable {
    let data: Data
    let derivedKeys: WinZipAESDerivedKeys
    let authenticationCheck: WinZipAESAuthenticationCheck
}

struct WinZipAESStreamDecryptionResult: Sendable {
    let source: WinZipAESByteSource
    let derivedKeys: WinZipAESDerivedKeys
    let cacheKey: WinZipAESKeyCacheKey
    let shouldCacheDerivedKeys: Bool
}

struct WinZipAESAuthenticationCheck: Sendable, Equatable {
    private let computedCode: Data
    private let storedCode: Data

    init(computedCode: Data, storedCode: Data) {
        self.computedCode = computedCode
        self.storedCode = storedCode
    }

    func verify() throws {
        guard ZipConstantTime.equals(computedCode, storedCode) else {
            // verifier の 16 bit 衝突を含む誤パスワードもここで拒否する。
            throw KaitoError.wrongPassword
        }
    }
}

enum WinZipAES {
    static func prepareStreamingDecryption(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        password: String,
        metadata: WinZipAESMetadata,
        cachedKeysFor: (WinZipAESKeyCacheKey) -> WinZipAESDerivedKeys?
    ) throws -> WinZipAESStreamDecryptionResult {
        let overhead = try Checked.add(
            UInt64(metadata.strength.saltLength),
            UInt64(
                WinZipAESPayload.passwordVerifierSize
                    + WinZipAESPayload.authenticationCodeSize
            )
        )
        guard compressedSize >= overhead else { throw KaitoError.truncated }
        let payloadEnd = try Checked.add(offset, compressedSize)
        guard payloadEnd <= source.length else { throw KaitoError.truncated }

        let saltAndVerifierSize = metadata.strength.saltLength
            + WinZipAESPayload.passwordVerifierSize
        let prefix = try readByteRange(
            source: source,
            offset: offset,
            count: saltAndVerifierSize
        )
        let salt = Data(prefix[..<metadata.strength.saltLength])
        let passwordVerifier = Data(prefix[metadata.strength.saltLength...])
        let cacheKey = WinZipAESKeyCacheKey(
            password: password,
            salt: salt,
            strength: metadata.strength
        )
        let cachedKeys = cachedKeysFor(cacheKey)
        let keys = try cachedKeys ?? WinZipAESDerivedKeys.derive(for: cacheKey)
        try validate(
            keys: keys,
            salt: salt,
            strength: metadata.strength,
            passwordVerifier: passwordVerifier
        )

        let ciphertextOffset = try Checked.add(offset, UInt64(saltAndVerifierSize))
        let ciphertextSize = try Checked.sub(compressedSize, overhead)
        let authenticationOffset = try Checked.add(ciphertextOffset, ciphertextSize)
        let storedCode = Data(try readByteRange(
            source: source,
            offset: authenticationOffset,
            count: WinZipAESPayload.authenticationCodeSize
        ))
        let decryptedSource = try WinZipAESByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: ciphertextSize,
            encryptionKey: keys.encryptionKey,
            authenticationKey: keys.authenticationKey,
            storedAuthenticationCode: storedCode
        )
        return WinZipAESStreamDecryptionResult(
            source: decryptedSource,
            derivedKeys: keys,
            cacheKey: cacheKey,
            shouldCacheDerivedKeys: cachedKeys == nil
        )
    }

    static func decrypt(
        payload data: Data,
        password: String,
        metadata: WinZipAESMetadata,
        cachedKeys: WinZipAESDerivedKeys? = nil
    ) throws -> WinZipAESDecryptionResult {
        let result = try prepareDecryption(
            payload: data,
            passwordBytes: Data(password.utf8),
            metadata: metadata,
            cachedKeys: cachedKeys
        )
        try result.authenticationCheck.verify()
        return result
    }

    static func decrypt(
        payload data: Data,
        passwordBytes: Data,
        metadata: WinZipAESMetadata,
        cachedKeys: WinZipAESDerivedKeys? = nil
    ) throws -> WinZipAESDecryptionResult {
        let result = try prepareDecryption(
            payload: data,
            passwordBytes: passwordBytes,
            metadata: metadata,
            cachedKeys: cachedKeys
        )
        try result.authenticationCheck.verify()
        return result
    }

    // EntryStream 用: verifier を検証して復号するが、HMAC の照合は終端クロージャまで遅延する。
    static func prepareDecryption(
        payload data: Data,
        password: String,
        metadata: WinZipAESMetadata,
        cachedKeys: WinZipAESDerivedKeys? = nil
    ) throws -> WinZipAESDecryptionResult {
        try prepareDecryption(
            payload: data,
            passwordBytes: Data(password.utf8),
            metadata: metadata,
            cachedKeys: cachedKeys
        )
    }

    static func prepareDecryption(
        payload data: Data,
        passwordBytes: Data,
        metadata: WinZipAESMetadata,
        cachedKeys: WinZipAESDerivedKeys? = nil
    ) throws -> WinZipAESDecryptionResult {
        let payload = try WinZipAESPayload(data: data, strength: metadata.strength)
        let keys: WinZipAESDerivedKeys
        if let cachedKeys {
            keys = cachedKeys
        } else {
            let cacheKey = WinZipAESKeyCacheKey(
                passwordBytes: passwordBytes,
                salt: payload.salt,
                strength: metadata.strength
            )
            keys = try WinZipAESDerivedKeys.derive(for: cacheKey)
        }

        return try prepareDecryption(payload, using: keys)
    }

    private static func prepareDecryption(
        _ payload: WinZipAESPayload,
        using keys: WinZipAESDerivedKeys
    ) throws -> WinZipAESDecryptionResult {
        try validate(
            keys: keys,
            salt: payload.salt,
            strength: payloadStrength(forSaltLength: payload.salt.count),
            passwordVerifier: payload.passwordVerifier
        )

        var ctr = try WinZipAESCTR(encryptionKey: keys.encryptionKey)
        let plaintext = try ctr.transform(payload.ciphertext)

        // 認証対象は復号後ではなく保存された暗号文。照合は呼び出し側へ遅延できる。
        let digest = ZipCommonCrypto.hmacSHA1(
            data: payload.ciphertext,
            key: keys.authenticationKey
        )
        let expectedAuthenticationCode = Data(
            digest.prefix(WinZipAESPayload.authenticationCodeSize)
        )
        return WinZipAESDecryptionResult(
            data: plaintext,
            derivedKeys: keys,
            authenticationCheck: WinZipAESAuthenticationCheck(
                computedCode: expectedAuthenticationCode,
                storedCode: payload.authenticationCode
            )
        )
    }

    private static func payloadStrength(forSaltLength saltLength: Int) -> WinZipAESStrength? {
        WinZipAESStrength.allCases.first { $0.saltLength == saltLength }
    }

    private static func validate(
        keys: WinZipAESDerivedKeys,
        salt: Data,
        strength: WinZipAESStrength?,
        passwordVerifier: Data
    ) throws {
        guard let strength,
              keys.strength == strength,
              keys.salt == salt else {
            throw KaitoError.malformed("cached WinZip AES keys do not match the payload")
        }
        guard ZipConstantTime.equals(keys.passwordVerifier, passwordVerifier) else {
            throw KaitoError.wrongPassword
        }
    }
}

// 通常の codec 読みは暗号文を HMAC へ加えてから同じ buffer を CTR 復号する。
// ByteSource の任意 offset 契約を満たすため、巻戻し・穴あき読みだけは暗号文全体を
// 固定バッファで再認証し、その同じ scan から取得した範囲だけを復号する。
// これにより、上流 ByteSource が実際には変更され得る場合も HMAC と復号の間で
// 対象 byte を再読みせず、キャッシュ量をエントリサイズに比例させない。
// Mutex は ByteSource の Sendable 境界でも一つの認証状態を直列化する。
final class WinZipAESByteSource: ByteSource {
    private static let completionChunkSize = 256 * 1_024

    private struct StreamState {
        var offset: UInt64
        var ctr: WinZipAESCTR
        var hmac: WinZipAESStreamingHMAC
        var computedAuthenticationCode: Data?
    }

    private let source: any ByteSource
    private let ciphertextOffset: UInt64
    private let encryptionKey: Data
    private let authenticationKey: Data
    private let storedAuthenticationCode: Data
    private let state: Mutex<StreamState>

    let length: UInt64

    init(
        source: any ByteSource,
        ciphertextOffset: UInt64,
        ciphertextSize: UInt64,
        encryptionKey: Data,
        authenticationKey: Data,
        storedAuthenticationCode: Data
    ) throws {
        let end = try Checked.add(ciphertextOffset, ciphertextSize)
        guard end <= source.length else { throw KaitoError.truncated }
        guard [16, 24, 32].contains(encryptionKey.count) else {
            throw KaitoError.malformed("invalid AES key length \(encryptionKey.count)")
        }
        guard storedAuthenticationCode.count
                == WinZipAESPayload.authenticationCodeSize else {
            throw KaitoError.malformed("invalid WinZip AES authentication-code length")
        }
        self.source = source
        self.ciphertextOffset = ciphertextOffset
        self.length = ciphertextSize
        self.encryptionKey = encryptionKey
        self.authenticationKey = authenticationKey
        self.storedAuthenticationCode = storedAuthenticationCode
        self.state = Mutex(StreamState(
            offset: 0,
            ctr: try WinZipAESCTR(encryptionKey: encryptionKey),
            hmac: WinZipAESStreamingHMAC(key: authenticationKey),
            computedAuthenticationCode: nil
        ))
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let remaining = try Checked.sub(length, offset)
        let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))
        return try state.withLock { state in
            guard state.computedAuthenticationCode == nil,
                  offset == state.offset else {
                return try readAuthenticatedRange(
                    into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested]),
                    at: offset
                )
            }
            let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested])
            let absoluteOffset = try Checked.add(ciphertextOffset, offset)
            let actual = try source.read(into: destination, at: absoluteOffset)
            guard actual >= 0, actual <= requested else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard actual > 0 else { return 0 }

            let actualBytes = UnsafeMutableRawBufferPointer(
                rebasing: destination[..<actual]
            )
            state.hmac.update(UnsafeRawBufferPointer(actualBytes))
            try state.ctr.transformInPlace(actualBytes)
            state.offset = try Checked.add(state.offset, UInt64(actual))
            return actual
        }
    }

    // 任意 offset の結果を返す前に、宣言された暗号文全体の tag を照合する。
    // 対象範囲はこの scan で読んだ byte からコピーし、照合後に初めて復号する。
    // 従って上流を読み直す TOCTOU 窓はなく、作業メモリは固定上限に留まる。
    private func readAuthenticatedRange(
        into destination: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !destination.isEmpty else { return 0 }
        let rangeEnd = try Checked.add(offset, UInt64(destination.count))
        guard rangeEnd <= length else {
            throw KaitoError.malformed("WinZip AES range exceeds ciphertext")
        }

        var hmac = WinZipAESStreamingHMAC(key: authenticationKey)
        var scratch = [UInt8](repeating: 0, count: Self.completionChunkSize)
        var scanOffset: UInt64 = 0
        var copied = 0

        while scanOffset < length {
            let remaining = try Checked.sub(length, scanOffset)
            let requested = try Checked.toInt(
                min(UInt64(Self.completionChunkSize), remaining)
            )
            let absoluteOffset = try Checked.add(ciphertextOffset, scanOffset)
            let actual = try scratch.withUnsafeMutableBytes { storage in
                try source.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                    at: absoluteOffset
                )
            }
            guard actual >= 0, actual <= requested else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard actual > 0 else { throw KaitoError.truncated }

            let scanEnd = try Checked.add(scanOffset, UInt64(actual))
            try scratch.withUnsafeBytes { storage in
                let authenticatedBytes = UnsafeRawBufferPointer(
                    rebasing: storage[..<actual]
                )
                hmac.update(authenticatedBytes)

                let overlapStart = max(scanOffset, offset)
                let overlapEnd = min(scanEnd, rangeEnd)
                guard overlapStart < overlapEnd else { return }
                let sourceIndex = try Checked.toInt(
                    try Checked.sub(overlapStart, scanOffset)
                )
                let destinationIndex = try Checked.toInt(
                    try Checked.sub(overlapStart, offset)
                )
                let overlapCount = try Checked.toInt(
                    try Checked.sub(overlapEnd, overlapStart)
                )
                guard let sourceBase = authenticatedBytes.baseAddress,
                      let destinationBase = destination.baseAddress else {
                    throw KaitoError.malformed("WinZip AES range buffer has no storage")
                }
                destinationBase.advanced(by: destinationIndex).copyMemory(
                    from: sourceBase.advanced(by: sourceIndex),
                    byteCount: overlapCount
                )
                copied += overlapCount
            }
            scanOffset = scanEnd
        }

        let computed = Data(
            hmac.finalize().prefix(WinZipAESPayload.authenticationCodeSize)
        )
        guard ZipConstantTime.equals(computed, storedAuthenticationCode) else {
            throw KaitoError.wrongPassword
        }
        guard copied == destination.count else { throw KaitoError.truncated }

        var ctr = try WinZipAESCTR(
            encryptionKey: encryptionKey,
            streamOffset: offset
        )
        try ctr.transformInPlace(destination)
        return destination.count
    }

    func finishAndVerify() throws {
        try state.withLock { state in
            if let computed = state.computedAuthenticationCode {
                guard ZipConstantTime.equals(computed, storedAuthenticationCode) else {
                    throw KaitoError.wrongPassword
                }
                return
            }

            // Decoder が入力を先読みしなかった残りも、宣言された暗号文範囲として認証する。
            var scratch = [UInt8](repeating: 0, count: Self.completionChunkSize)
            while state.offset < length {
                let remaining = try Checked.sub(length, state.offset)
                let requested = try Checked.toInt(
                    min(UInt64(Self.completionChunkSize), remaining)
                )
                let absoluteOffset = try Checked.add(ciphertextOffset, state.offset)
                let actual = try scratch.withUnsafeMutableBytes { storage in
                    try source.read(
                        into: UnsafeMutableRawBufferPointer(
                            rebasing: storage[..<requested]
                        ),
                        at: absoluteOffset
                    )
                }
                guard actual >= 0, actual <= requested else {
                    throw KaitoError.malformed("ByteSource returned an invalid byte count")
                }
                guard actual > 0 else { throw KaitoError.truncated }
                scratch.withUnsafeBytes { storage in
                    state.hmac.update(
                        UnsafeRawBufferPointer(rebasing: storage[..<actual])
                    )
                }
                state.offset = try Checked.add(state.offset, UInt64(actual))
            }

            let digest = state.hmac.finalize()
            let computed = Data(
                digest.prefix(WinZipAESPayload.authenticationCodeSize)
            )
            state.computedAuthenticationCode = computed
            guard ZipConstantTime.equals(computed, storedAuthenticationCode) else {
                throw KaitoError.wrongPassword
            }
        }
    }
}

private struct WinZipAESStreamingHMAC {
    private var context: CCHmacContext
    private var isFinalized = false

    init(key: Data) {
        var context = CCHmacContext()
        var keyStorage = [UInt8](key)
        if keyStorage.isEmpty {
            keyStorage.append(0)
        }
        keyStorage.withUnsafeBytes { keyBuffer in
            CCHmacInit(
                &context,
                CCHmacAlgorithm(kCCHmacAlgSHA1),
                keyBuffer.baseAddress,
                key.count
            )
        }
        self.context = context
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        precondition(!isFinalized)
        guard !bytes.isEmpty else { return }
        CCHmacUpdate(&context, bytes.baseAddress, bytes.count)
    }

    mutating func finalize() -> Data {
        precondition(!isFinalized)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { buffer in
            CCHmacFinal(&context, buffer.baseAddress)
        }
        isFinalized = true
        return Data(digest)
    }
}

// WinZip 互換の 1 始まり little-endian CTR。分割入力の端数バイトも保持する。
struct WinZipAESCTR: Sendable {
    private static let blockSize = 16
    private static let maximumBlocksPerCall = (256 * 1_024) / blockSize

    private let encryptionKey: Data
    private var counter = [UInt8](repeating: 0, count: blockSize)
    private var pendingKeyStream: [UInt8] = []
    private var pendingOffset = 0

    init(encryptionKey: Data, streamOffset: UInt64 = 0) throws {
        guard [16, 24, 32].contains(encryptionKey.count) else {
            throw KaitoError.malformed("invalid AES key length \(encryptionKey.count)")
        }
        self.encryptionKey = encryptionKey

        // counter は次の makeKeyStream で先に increment されるため、対象 block の
        // 0-based index を little-endian で初期値にする。
        var blockIndex = streamOffset / UInt64(Self.blockSize)
        for index in 0..<MemoryLayout<UInt64>.size {
            counter[index] = UInt8(truncatingIfNeeded: blockIndex)
            blockIndex >>= 8
        }
        let intraBlockOffset = Int(streamOffset % UInt64(Self.blockSize))
        if intraBlockOffset > 0 {
            pendingKeyStream = try makeKeyStream(blockCount: 1)
            pendingOffset = intraBlockOffset
        }
    }

    mutating func transform(_ input: Data) throws -> Data {
        guard !input.isEmpty else {
            return Data()
        }

        var output = [UInt8](input)
        try output.withUnsafeMutableBytes { buffer in
            try transformInPlace(buffer)
        }
        return Data(output)
    }

    mutating func transformInPlace(
        _ output: UnsafeMutableRawBufferPointer
    ) throws {
        guard !output.isEmpty else { return }
        var outputOffset = 0

        if pendingOffset < pendingKeyStream.count {
            let available = pendingKeyStream.count - pendingOffset
            let count = min(available, output.count)
            for index in 0..<count {
                output[index] ^= pendingKeyStream[pendingOffset + index]
            }
            pendingOffset += count
            outputOffset += count
            if pendingOffset == pendingKeyStream.count {
                pendingKeyStream.removeAll(keepingCapacity: true)
                pendingOffset = 0
            }
        }

        while outputOffset < output.count {
            let remaining = output.count - outputOffset
            let requestedBlocks = remaining / Self.blockSize
                + (remaining.isMultiple(of: Self.blockSize) ? 0 : 1)
            let blockCount = min(requestedBlocks, Self.maximumBlocksPerCall)
            let keyStream = try makeKeyStream(blockCount: blockCount)
            let count = min(remaining, keyStream.count)

            for index in 0..<count {
                output[outputOffset + index] ^= keyStream[index]
            }
            outputOffset += count

            if count < keyStream.count {
                pendingKeyStream = keyStream
                pendingOffset = count
            }
        }
    }

    private mutating func makeKeyStream(blockCount: Int) throws -> [UInt8] {
        guard blockCount > 0, blockCount <= Self.maximumBlocksPerCall else {
            throw KaitoError.malformed("invalid AES-CTR block count")
        }

        var counterBlocks = [UInt8]()
        counterBlocks.reserveCapacity(blockCount * Self.blockSize)
        for _ in 0..<blockCount {
            try incrementCounter()
            counterBlocks.append(contentsOf: counter)
        }
        return try ZipCommonCrypto.aesECBEncrypt(
            blocks: counterBlocks,
            key: encryptionKey
        )
    }

    private mutating func incrementCounter() throws {
        for index in counter.indices {
            let (value, overflow) = counter[index].addingReportingOverflow(1)
            counter[index] = value
            if !overflow {
                return
            }
        }
        throw KaitoError.limitExceeded("WinZip AES-CTR counter exhausted")
    }
}

// CommonCrypto のポインタ境界をこの型だけに封じ込める。
private enum ZipCommonCrypto {
    static func pbkdf2SHA1(
        password: Data,
        salt: Data,
        iterations: UInt32,
        outputLength: Int
    ) throws -> [UInt8] {
        guard iterations > 0, outputLength > 0 else {
            throw KaitoError.malformed("invalid PBKDF2 parameters")
        }

        let passwordLength = password.count
        var passwordStorage = [UInt8](password)
        if passwordStorage.isEmpty {
            passwordStorage.append(0)
        }
        var saltStorage = [UInt8](salt)
        if saltStorage.isEmpty {
            saltStorage.append(0)
        }
        var output = [UInt8](repeating: 0, count: outputLength)

        let status = passwordStorage.withUnsafeBytes { passwordBuffer in
            saltStorage.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    // 各 storage はクロージャの間固定され、C 関数は呼び出し後にポインタを保持しない。
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordLength,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw KaitoError.malformed("CommonCrypto PBKDF2 failed (\(status))")
        }
        return output
    }

    static func hmacSHA1(data: Data, key: Data) -> Data {
        let dataLength = data.count
        var dataStorage = [UInt8](data)
        if dataStorage.isEmpty {
            dataStorage.append(0)
        }
        var keyStorage = [UInt8](key)
        if keyStorage.isEmpty {
            keyStorage.append(0)
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        keyStorage.withUnsafeBytes { keyBuffer in
            dataStorage.withUnsafeBytes { dataBuffer in
                digest.withUnsafeMutableBytes { digestBuffer in
                    // CCHmac は同期的に完了し、ポインタはこのクロージャ外に逃げない。
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyBuffer.baseAddress,
                        key.count,
                        dataBuffer.baseAddress,
                        dataLength,
                        digestBuffer.baseAddress
                    )
                }
            }
        }
        return Data(digest)
    }

    static func aesECBEncrypt(blocks: [UInt8], key: Data) throws -> [UInt8] {
        guard !blocks.isEmpty, blocks.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw KaitoError.malformed("AES-ECB input is not block aligned")
        }

        let input = blocks
        let keyStorage = [UInt8](key)
        var output = [UInt8](repeating: 0, count: blocks.count)
        var outputLength = 0
        let outputCapacity = output.count

        let status = keyStorage.withUnsafeBytes { keyBuffer in
            input.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    // CCCrypt はこの呼び出し中だけ各領域を参照する。ECB は CTR の鍵流生成にのみ使う。
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        inputBuffer.baseAddress,
                        input.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == blocks.count else {
            throw KaitoError.malformed(
                "CommonCrypto AES-ECB failed (\(status), \(outputLength) bytes)"
            )
        }
        return output
    }
}
