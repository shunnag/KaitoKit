import Foundation
private import CommonCrypto

/// CommonCrypto の一括呼出し（AES-ECB、HMAC、PBKDF2）と、その pointer の扱いをこの file に閉じる。
/// 鍵長や block 整列の検査と error の文言は呼出側（WinZip AES / 7zAES / RAR）が持ち、
/// ここは CommonCrypto の status をそのまま ``Failure`` で返す。AES の鍵は 16 / 24 / 32 byte。
enum CommonCryptoPrimitives {
    /// CommonCrypto が失敗した status と、その時点で書かれた出力 byte 数。
    struct Failure: Error {
        let status: Int32
        let outputLength: Int
    }

    static func aesECBEncrypt(blocks: [UInt8], key: Data) throws(Failure) -> [UInt8] {
        try aesECB(CCOperation(kCCEncrypt), blocks: blocks, key: key)
    }

    static func aesECBDecrypt(blocks: [UInt8], key: Data) throws(Failure) -> [UInt8] {
        try aesECB(CCOperation(kCCDecrypt), blocks: blocks, key: key)
    }

    static func hmacSHA1(data: Data, key: Data) -> [UInt8] {
        hmac(CCHmacAlgorithm(kCCHmacAlgSHA1), digestLength: Int(CC_SHA1_DIGEST_LENGTH),
             data: [UInt8](data), key: key)
    }

    static func hmacSHA256(data: [UInt8], key: Data) -> [UInt8] {
        hmac(CCHmacAlgorithm(kCCHmacAlgSHA256), digestLength: Int(CC_SHA256_DIGEST_LENGTH),
             data: data, key: key)
    }

    /// `iterations > 0`、`outputLength > 0` は呼出側が保証する。
    static func pbkdf2SHA1(
        password: Data,
        salt: Data,
        iterations: UInt32,
        outputLength: Int
    ) throws(Failure) -> [UInt8] {
        // 空の Data でも baseAddress が nil にならないよう 1 byte 足す。長さは元の値を渡す。
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
            throw Failure(status: status, outputLength: 0)
        }
        return output
    }

    private static func hmac(_ algorithm: CCHmacAlgorithm, digestLength: Int, data: [UInt8], key: Data) -> [UInt8] {
        // 空の入力でも baseAddress が nil にならないよう 1 byte 足す。長さは元の値を渡す。
        let dataLength = data.count
        var dataStorage = data
        if dataStorage.isEmpty {
            dataStorage.append(0)
        }
        var keyStorage = [UInt8](key)
        if keyStorage.isEmpty {
            keyStorage.append(0)
        }
        var digest = [UInt8](repeating: 0, count: digestLength)

        keyStorage.withUnsafeBytes { keyBuffer in
            dataStorage.withUnsafeBytes { dataBuffer in
                digest.withUnsafeMutableBytes { digestBuffer in
                    // CCHmac は同期的に完了し、ポインタはこのクロージャ外に逃げない。
                    CCHmac(
                        algorithm,
                        keyBuffer.baseAddress,
                        key.count,
                        dataBuffer.baseAddress,
                        dataLength,
                        digestBuffer.baseAddress
                    )
                }
            }
        }
        return digest
    }

    private static func aesECB(_ operation: CCOperation, blocks: [UInt8], key: Data) throws(Failure) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: blocks.count)
        var outputLength = 0
        let outputCapacity = output.count

        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuffer in
            blocks.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    // CCCrypt はこの呼び出し中だけ各領域を参照する。出力は blocks.count byte 確保済み。
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        inputBuffer.baseAddress,
                        blocks.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess, outputLength == blocks.count else {
            throw Failure(status: status, outputLength: outputLength)
        }
        return output
    }
}
