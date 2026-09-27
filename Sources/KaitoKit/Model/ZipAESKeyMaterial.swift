import Foundation

@_spi(ZipRawLayout)
public struct ZipAESKeyMaterial: Sendable, Equatable {
    public let salt: Data
    public let strength: UInt8
    /// 暗号鍵・認証鍵・2 byte の verifier を順に含む PBKDF2 出力。
    public let bytes: Data

    public init(salt: Data, strength: UInt8, bytes: Data) throws {
        guard let aesStrength = WinZipAESStrength(rawValue: strength),
              salt.count == aesStrength.saltLength,
              bytes.count == aesStrength.keyLength * 2 + WinZipAESPayload.passwordVerifierSize else {
            throw KaitoError.malformed("invalid WinZip AES key material")
        }
        self.salt = salt
        self.strength = strength
        self.bytes = bytes
    }

    /// 読取と同じ PBKDF2-HMAC-SHA1（1,000 回）。状態を持たず、並行して呼べる。
    public static func derive(passwordBytes: Data, salt: Data, strength: UInt8) throws -> ZipAESKeyMaterial {
        guard let aesStrength = WinZipAESStrength(rawValue: strength) else {
            throw KaitoError.malformed("invalid WinZip AES key material strength")
        }
        let key = WinZipAESKeyCacheKey(passwordBytes: passwordBytes, salt: salt, strength: aesStrength)
        return try ZipAESKeyMaterial(salt: salt, strength: strength,
                                     bytes: WinZipAESDerivedKeys.deriveMaterial(for: key))
    }
}
