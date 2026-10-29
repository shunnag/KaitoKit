import Foundation
private import CommonCrypto
@testable import KaitoKit
import XCTest

// KaitoKit の暗号経路を同じ入力で比較する opt-in release probe。
// 合成 CFB 入力は CommonCrypto だけで作る。第三者実装 source は参照しない。
final class CryptoPerformanceTests: XCTestCase {
    func testReleaseCryptoPerformance() throws {
        guard ProcessInfo.processInfo.environment["KAITO_CRYPTO_BENCH"] == "1" else {
            throw XCTSkip("KAITO_CRYPTO_BENCH=1 で release 計測を有効にする")
        }
        let plain = [UInt8]((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 * 29 + 7) })
        var output = [UInt8](repeating: 0, count: plain.count)
        for (cipher, keySize, name): (UInt64, UInt64, String) in [(0, 32, "AES"), (2, 8, "DES"), (1, 5, "Blowfish")] {
            let crypto = try StuffItXCrypto(password: "password", algorithms: StuffItXCryptoTests.records([(cipher, keySize)]))
            let layer = try XCTUnwrap(crypto.layers.first)
            let iv = [UInt8](repeating: 0x37, count: layer.prefixSize)
            let encrypted = try Self.cfbEncrypt(plain, layer: layer, iv: iv)
            let input = DataByteSource(Data(crypto.verifier + iv + encrypted))
            let seconds = try median(repetitions: 1) {
                let source = try crypto.decrypt(input)
                try output.withUnsafeMutableBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let end = min(offset + 65_536, bytes.count)
                        let n = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[offset..<end]), at: UInt64(offset))
                        guard n > 0 else { throw KaitoError.truncated }
                        offset += n
                    }
                }
            }
            XCTAssertEqual(output, plain)
            print(String(format: "CRYPTO_BENCH StuffItX %@ %.3f MB/s", name, Double(plain.count) / seconds / 1_000_000))
        }
        for power: UInt8 in [15, 18] {
            var keys: RAR5DerivedKeys?
            let seconds = try median(repetitions: 3) {
                keys = try RAR5KeyDerivation.derive(password: "password", salt: Array(0..<16), count: power)
            }
            XCTAssertEqual(keys?.encryptionKey.count, 32)
            print(String(format: "CRYPTO_BENCH RAR5 2^%d %.3f ms/derivation", power, seconds * 1_000))
        }
        let properties = try SevenZipAESProperties(bytes: [0x92, 0xF0] + Array(0..<16), maximumCyclesPower: 24)
        var key = Data()
        let sevenZip = try median(repetitions: 3) {
            key = try SevenZipAESKeyCache().key(password: "password", properties: properties)
        }
        XCTAssertEqual(key.count, 32)
        print(String(format: "CRYPTO_BENCH 7z 2^18 %.3f ms/derivation", sevenZip * 1_000))

        let cacheKey = WinZipAESKeyCacheKey(password: "password", salt: Data(0..<16), strength: .aes256)
        let keys = try WinZipAESDerivedKeys.derive(for: cacheKey)
        let smallPlain = Data(plain.prefix(127))
        var ctr = try WinZipAESCTR(encryptionKey: keys.encryptionKey)
        let ciphertext = try ctr.transform(smallPlain)
        let tag = Data(CommonCryptoPrimitives.hmacSHA1(data: ciphertext, key: keys.authenticationKey).prefix(10))
        let input = DataByteSource(ciphertext)
        var smallOutput = [UInt8](repeating: 0, count: smallPlain.count)
        func readEntry(_ keys: WinZipAESDerivedKeys) throws {
            let source = try WinZipAESByteSource(source: input, ciphertextOffset: 0, ciphertextSize: input.length,
                encryptionKey: keys.encryptionKey, authenticationKey: keys.authenticationKey, storedAuthenticationCode: tag)
            let n = try smallOutput.withUnsafeMutableBytes { try source.read(into: $0, at: 0) }
            guard n == smallPlain.count else { throw KaitoError.truncated }
            try source.finishAndVerify()
        }
        let stream = try median(repetitions: 5_000) { try readEntry(keys) }
        XCTAssertEqual(Data(smallOutput), smallPlain)
        let kdf = try median(repetitions: 500) { _ = try WinZipAESDerivedKeys.derive(for: cacheKey) }
        let full = try median(repetitions: 500) { try readEntry(WinZipAESDerivedKeys.derive(for: cacheKey)) }
        print(String(format: "CRYPTO_BENCH ZIP AES256 127B stream %.3f us/entry; PBKDF2 %.3f us/entry; combined %.3f us/entry",
                     stream * 1_000_000, kdf * 1_000_000, full * 1_000_000))
    }

    private func median(repetitions: Int, _ body: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<repetitions { try body() }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 / Double(repetitions))
        }
        return samples.sorted()[2]
    }

    static func cfbEncrypt(_ plain: [UInt8], layer: StuffItXCrypto.Layer, iv: [UInt8]) throws -> [UInt8] {
        let algorithm = layer.cipher == 0 ? kCCAlgorithmAES : (layer.cipher == 1 ? kCCAlgorithmBlowfish : kCCAlgorithmDES)
        let key = layer.cipher == 1 && layer.key.count < kCCKeySizeMinBlowfish ? layer.key + layer.key : layer.key
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCFB), CCAlgorithm(algorithm),
                CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &cryptor)
        } }
        guard status == kCCSuccess, let cryptor else { throw KaitoError.malformed("test CFB create \(status)") }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: plain.count), written = 0
        let updated = plain.withUnsafeBytes { input in output.withUnsafeMutableBytes { destination in
            CCCryptorUpdate(cryptor, input.baseAddress, input.count, destination.baseAddress, destination.count, &written)
        } }
        guard updated == kCCSuccess, written == plain.count else { throw KaitoError.malformed("test CFB update \(updated)") }
        return output
    }
}
