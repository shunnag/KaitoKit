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
    static let extraFieldID = ZipExtraFieldID.winZipAES

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

    // テスト専用。読取経路では中央ディレクトリの解析が 0x9901 を検証して memberwise init で作る。
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
// 読取経路は二つの長さの定数だけを使い、`init(data:)` はテスト専用の一括復号が使う。
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
        try Self(salt: cacheKey.salt, strength: cacheKey.strength, material: deriveMaterial(for: cacheKey))
    }

    static func deriveMaterial(for cacheKey: WinZipAESKeyCacheKey) throws -> Data {
        guard cacheKey.salt.count == cacheKey.strength.saltLength else {
            throw KaitoError.malformed(
                "WinZip AES salt length \(cacheKey.salt.count) does not match strength"
            )
        }

        let keyLength = cacheKey.strength.keyLength
        let derivedLength = keyLength * 2 + WinZipAESPayload.passwordVerifierSize
        return Data(try ZipCommonCrypto.pbkdf2SHA1(
            password: cacheKey.passwordBytes,
            salt: cacheKey.salt,
            iterations: 1_000,
            outputLength: derivedLength
        ))
    }

    init(salt: Data, strength: WinZipAESStrength, material: Data) throws {
        let keyLength = strength.keyLength
        guard material.count == keyLength * 2 + WinZipAESPayload.passwordVerifierSize else {
            throw KaitoError.malformed("invalid WinZip AES key material length")
        }
        self.salt = salt
        self.strength = strength
        encryptionKey = Data(material.prefix(keyLength))
        authenticationKey = Data(material.dropFirst(keyLength).prefix(keyLength))
        passwordVerifier = Data(material.suffix(WinZipAESPayload.passwordVerifierSize))
    }
}

// テスト専用の一括復号の結果。
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

// テスト専用の一括復号が返す、遅延した HMAC の照合。
struct WinZipAESAuthenticationCheck: Sendable, Equatable {
    private let computedCode: Data
    private let storedCode: Data

    init(computedCode: Data, storedCode: Data) {
        self.computedCode = computedCode
        self.storedCode = storedCode
    }

    func verify() throws {
        guard ConstantTime.equals(computedCode, storedCode) else {
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
        cachedKeysFor: (WinZipAESKeyCacheKey) throws -> WinZipAESDerivedKeys?,
        availableCompressedSize: UInt64? = nil,
        hasKnownCompressedSize: Bool = true
    ) throws -> WinZipAESStreamDecryptionResult {
        let overhead = try Checked.add(
            UInt64(metadata.strength.saltLength),
            UInt64(
                WinZipAESPayload.passwordVerifierSize
                    + WinZipAESPayload.authenticationCodeSize
            )
        )
        let saltAndVerifierSize = metadata.strength.saltLength
            + WinZipAESPayload.passwordVerifierSize
        let available = availableCompressedSize ?? compressedSize
        let isIncomplete = availableCompressedSize != nil
        if !isIncomplete || hasKnownCompressedSize {
            guard compressedSize >= overhead else { throw KaitoError.truncated }
        }
        guard available >= UInt64(saltAndVerifierSize) else { throw KaitoError.truncated }
        let payloadEnd = try Checked.add(offset, available)
        guard payloadEnd <= source.length else { throw KaitoError.truncated }

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
        let cachedKeys = try cachedKeysFor(cacheKey)
        let keys = try cachedKeys ?? WinZipAESDerivedKeys.derive(for: cacheKey)
        try validate(
            keys: keys,
            salt: salt,
            strength: metadata.strength,
            passwordVerifier: passwordVerifier
        )

        let ciphertextOffset = try Checked.add(offset, UInt64(saltAndVerifierSize))
        let availableCiphertext = try Checked.sub(available, UInt64(saltAndVerifierSize))
        let ciphertextSize = try hasKnownCompressedSize
            ? min(Checked.sub(compressedSize, overhead), availableCiphertext)
            : availableCiphertext
        let authenticationOffset = try Checked.add(ciphertextOffset, ciphertextSize)
        // 欠損した暗号文には末尾 HMAC がない。完全な範囲では認証が必須。
        let storedCode: Data? = try isIncomplete ? nil : Data(readByteRange(
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
            shouldCacheDerivedKeys: !isIncomplete && cachedKeys == nil
        )
    }

    // テスト専用の一括復号 API（decrypt と prepareDecryption）。読取経路は prepareStreamingDecryption を使う。
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

    // verifier を検証して復号し、HMAC の照合は返した authenticationCheck まで遅延する。
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
        guard ConstantTime.equals(keys.passwordVerifier, passwordVerifier) else {
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
    private let storedAuthenticationCode: Data?
    private let state: Mutex<StreamState>

    let length: UInt64

    init(
        source: any ByteSource,
        ciphertextOffset: UInt64,
        ciphertextSize: UInt64,
        encryptionKey: Data,
        authenticationKey: Data,
        storedAuthenticationCode: Data?
    ) throws {
        let end = try Checked.add(ciphertextOffset, ciphertextSize)
        guard end <= source.length else { throw KaitoError.truncated }
        guard [16, 24, 32].contains(encryptionKey.count) else {
            throw KaitoError.malformed("invalid AES key length \(encryptionKey.count)")
        }
        if let storedAuthenticationCode,
           storedAuthenticationCode.count != WinZipAESPayload.authenticationCodeSize {
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
        if let storedAuthenticationCode,
           !ConstantTime.equals(computed, storedAuthenticationCode) {
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
                if let storedAuthenticationCode,
                   !ConstantTime.equals(computed, storedAuthenticationCode) {
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
            if let storedAuthenticationCode,
               !ConstantTime.equals(computed, storedAuthenticationCode) {
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

    private let encryptor: CommonCryptoECBEncryptor
    private var counterLow: UInt64 = 0
    private var counterHigh: UInt64 = 0
    private var keyStream: [UInt8] = []
    private var pendingOffset = 0

    init(encryptionKey: Data, streamOffset: UInt64 = 0) throws {
        guard [16, 24, 32].contains(encryptionKey.count) else {
            throw KaitoError.malformed("invalid AES key length \(encryptionKey.count)")
        }
        encryptor = CommonCryptoECBEncryptor(key: encryptionKey)
        // Increment before emitting: the first encrypted counter is one.
        counterLow = streamOffset / UInt64(Self.blockSize)
        let intraBlockOffset = Int(streamOffset % UInt64(Self.blockSize))
        if intraBlockOffset > 0 {
            try makeKeyStream(blockCount: 1)
            pendingOffset = intraBlockOffset
        }
    }

    // Internal counter positioning also lets tests reach 128-bit carry/exhaustion
    // boundaries that a UInt64 byte offset cannot represent.
    init(encryptionKey: Data, counterLow: UInt64, counterHigh: UInt64) throws {
        try self.init(encryptionKey: encryptionKey)
        self.counterLow = counterLow
        self.counterHigh = counterHigh
    }

    // テスト専用の一括復号。読取経路は transformInPlace を使う。
    mutating func transform(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var output = [UInt8](input)
        try output.withUnsafeMutableBytes { try transformInPlace($0) }
        return Data(output)
    }

    mutating func transformInPlace(_ output: UnsafeMutableRawBufferPointer) throws {
        guard !output.isEmpty else { return }
        var outputOffset = 0
        if pendingOffset < keyStream.count {
            let count = min(keyStream.count - pendingOffset, output.count)
            keyStream.withUnsafeBytes {
                xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[..<count]),
                         with: UnsafeRawBufferPointer(rebasing: $0[pendingOffset..<(pendingOffset + count)]))
            }
            pendingOffset += count
            outputOffset += count
        }
        while outputOffset < output.count {
            let remaining = output.count - outputOffset
            let requestedBlocks = remaining / Self.blockSize
                + (remaining.isMultiple(of: Self.blockSize) ? 0 : 1)
            try makeKeyStream(blockCount: min(requestedBlocks, Self.maximumBlocksPerCall))
            let count = min(remaining, keyStream.count)
            keyStream.withUnsafeBytes {
                xorBytes(UnsafeMutableRawBufferPointer(rebasing: output[outputOffset..<(outputOffset + count)]), with: $0)
            }
            outputOffset += count
            pendingOffset = count
        }
    }

    private mutating func makeKeyStream(blockCount: Int) throws {
        guard blockCount > 0, blockCount <= Self.maximumBlocksPerCall else {
            throw KaitoError.malformed("invalid AES-CTR block count")
        }
        let count = blockCount * Self.blockSize
        if keyStream.count > count { keyStream.removeLast(keyStream.count - count) }
        if keyStream.count < count { keyStream.append(contentsOf: repeatElement(0, count: count - keyStream.count)) }
        try keyStream.withUnsafeMutableBytes { blocks in
            for block in 0..<blockCount {
                let (low, carry) = counterLow.addingReportingOverflow(1)
                counterLow = low
                if carry {
                    let (high, exhausted) = counterHigh.addingReportingOverflow(1)
                    counterHigh = high
                    guard !exhausted else { throw KaitoError.limitExceeded("WinZip AES-CTR counter exhausted") }
                }
                blocks.storeBytes(of: counterLow.littleEndian, toByteOffset: block * Self.blockSize, as: UInt64.self)
                blocks.storeBytes(of: counterHigh.littleEndian, toByteOffset: block * Self.blockSize + 8, as: UInt64.self)
            }
            do {
                try encryptor.encryptInPlace(blocks)
            } catch let error as CommonCryptoPrimitives.Failure {
                throw KaitoError.malformed("CommonCrypto AES-ECB failed (\(error.status), \(error.outputLength) bytes)")
            }
        }
        pendingOffset = 0
    }
}

// CommonCrypto の呼出しは Core/CommonCryptoPrimitives。ここは WinZip AES の入力検査と error 文言。
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
        do {
            return try CommonCryptoPrimitives.pbkdf2SHA1(
                password: password, salt: salt, iterations: iterations, outputLength: outputLength
            )
        } catch {
            throw KaitoError.malformed("CommonCrypto PBKDF2 failed (\(error.status))")
        }
    }

    static func hmacSHA1(data: Data, key: Data) -> Data {
        Data(CommonCryptoPrimitives.hmacSHA1(data: data, key: key))
    }

    /// ECB は CTR の鍵流生成にのみ使う。
    static func aesECBEncrypt(blocks: [UInt8], key: Data) throws -> [UInt8] {
        guard !blocks.isEmpty, blocks.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw KaitoError.malformed("AES-ECB input is not block aligned")
        }
        do {
            return try CommonCryptoPrimitives.aesECBEncrypt(blocks: blocks, key: key)
        } catch {
            throw KaitoError.malformed(
                "CommonCrypto AES-ECB failed (\(error.status), \(error.outputLength) bytes)"
            )
        }
    }
}
