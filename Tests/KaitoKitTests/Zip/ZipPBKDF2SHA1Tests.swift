import Foundation
private import CommonCrypto
@testable import KaitoKit
import XCTest

// Independent oracle: Apple's CCKeyDerivationPBKDF; inputs are raw octets.
final class ZipPBKDF2SHA1Tests: XCTestCase {
    func testRequiredMatrixMatchesCommonCrypto() throws {
        var random = ZipDeterministicRandom(state: 0x8018_2104_1804)
        for passwordLength in [0, 1, 63, 64, 65, 200] {
            let password = bytes(passwordLength, random: &random)
            for saltLength in [8, 12, 16] {
                let salt = bytes(saltLength, random: &random)
                for iterations: UInt32 in [1, 2, 1000] {
                    for length in [34, 50, 66] {
                        try compare(password, salt, iterations, length)
                    }
                }
            }
        }
    }

    func testTenThousandDeterministicRandomCasesMatchCommonCrypto() throws {
        var random = ZipDeterministicRandom(state: 0xc001_8018_2104)
        for _ in 0..<10_000 {
            let password = bytes(random.next(257), random: &random)
            // Also exercise U1 padding at 51/52 and 59/60, multi-block salts,
            // empty salt, output block boundaries, and block numbers > 255.
            let salt = bytes(random.next(161), random: &random)
            let iterations = UInt32([1, 2, 3, 17, 1000][random.next(5)])
            let length = 1 + random.next(101)
            try compare(password, salt, iterations, length)
        }
        try compare(Data([0, 0xff, 0x80]), Data(), 2, 5_141)
        try compare(Data(repeating: 0x37, count: 4097), Data(repeating: 0xa5, count: 1024), 2, 66)
    }

    private func bytes(_ count: Int, random: inout ZipDeterministicRandom) -> Data {
        Data((0..<count).map { _ in UInt8(random.next(256)) })
    }

    private func compare(_ password: Data, _ salt: Data, _ iterations: UInt32, _ length: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try CommonCryptoPrimitives.pbkdf2SHA1(password: password, salt: salt,
                                                         iterations: iterations, outputLength: length)
        var expected = [UInt8](repeating: 0, count: length)
        // Non-null storage with the original length preserves empty inputs.
        let p = Array(password) + [0], s = Array(salt) + [0]
        let status = p.withUnsafeBytes { p in s.withUnsafeBytes { s in
            expected.withUnsafeMutableBufferPointer { out in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    p.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations, out.baseAddress, length)
            }
        } }
        XCTAssertEqual(status, Int32(kCCSuccess), file: file, line: line)
        XCTAssertEqual(actual, expected,
            "password=\(password.count), salt=\(salt.count), iterations=\(iterations), dkLen=\(length)",
            file: file, line: line)
    }
}
