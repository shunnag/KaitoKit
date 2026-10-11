import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// match copy の fast path（chunk 直接 copy、group 単位の適用、ring 終端・短距離・
/// 辞書長付近の距離の slow path）を、辞書 4 KiB の raw stream と copy primitive 単体で検証する。
final class LZMAMatchCopyTests: XCTestCase {
    // xz 5.8.4: `xz --format=raw --lzma1=dict=4KiB,lc=3,lp=0,pb=2` / `--lzma2=dict=4KiB,...`。
    // 入力は makeEdgeInput() が再生成する 8192 byte（SHA-256
    // 659c793e91adedd32d78c585be8c75565902a263849773037918b0a3f4f4c5a3）。
    // distance 1 の run、2 / 3 / 8 / 15 の短距離重複、16 以上の重複（17、40）、
    // 辞書長 - 5 の距離での 120 byte 反復（ring 末尾の source と先頭の destination が
    // memory 上で後方から重なる）、600 byte の長い match、4096 の倍数で終わる出力を含む。
    private static let lzma1Stream =
        "0020effbb7c17e7e5453fdfc08dedb6da6fb53eb0b009a1d6d167137371098fa" +
        "22638c0bb0ca30002e31ab2379f257091f2acd54bd574c069184f9625e56b79e" +
        "0ed31f1cd174e3e142e83b0735603f4136ca80b04f8a1142a7e78034668df56a" +
        "6ac6e6ab2774354fbce20cec7fd89dc3443fb73bcc42540aa64ebfbfa7e0783b" +
        "ec3cc8504326783f8aac4686ee31a5500af49f5b34cd601cf6761bb798b2341a" +
        "7bac3318dd0891550119fc74e048ee05dac7b056994afb1fcdf2b47581617d1a" +
        "1bf7c7b8a6d5ea77ef264ea01391b0fdc55ebb26f7f03dbbf5abc9913751923c" +
        "af47363baaae552d8126c8a82cde64b86da19fe2eb309e4d2ad404f5d86d251f" +
        "bdd6806cab51db5943486b70a4fe2d2942cf327cb9b779b906dd6f30fa47cec6" +
        "9a14c2b4ebba173fa8c7e33730ebde270dcf90932784cead2cd2a5c2d4537e4e" +
        "463796eafe30fc62fa85ffaa26e03ed7df937f9bf370c0c64c661302c5762f5e" +
        "ac87c57ec387be2232e9d7019507b6a7ddeda47ec4438b0107a36279fb04269e" +
        "fed8daf4e9339b8938a8baecd1b7bbb67b17c725f21be05ff28aae854bc37580" +
        "2e6541a3c881345b4e68a996bc4c60d5948a258c48785518b676be870a8f64e7" +
        "d186199bc26b4d23932b0c2afc6cd7f8aaf9c744d6c50aa3b01eef880ccf53c6" +
        "30b28fe9fdb70dd971931998f2c7267b3b274f487e02b6f41c64172f6ccd685f" +
        "407f8e24ef5e46e554c1acea5af43bf197013e8bc8a62c5105146a5f83ccacee" +
        "258cac4aa4190b1e2ba0fb43c38812eda2e2e86fe947625c23b4d84c1c44919c" +
        "0659be4c5a5f82424ef4f93f58294a6cc7005e8271dfee26d042eefd7c70112e" +
        "de3967f10f851e6996657d2594e9e067fc53777a74bb839a652ce38fe1ebc988" +
        "6a997961c593a65ca4db89e7ffffcf18c700"

    private static let lzma2Stream =
        "e01fff028b5d0020effbb7c17e7e5453fdfc08dedb6da6fb53eb0b009a1d6d16" +
        "7137371098fa22638c0bb0ca30002e31ab2379f257091f2acd54bd574c069184" +
        "f9625e56b79e0ed31f1cd174e3e142e83b0735603f4136ca80b04f8a1142a7e7" +
        "8034668df56a6ac6e6ab2774354fbce20cec7fd89dc3443fb73bcc42540aa64e" +
        "bfbfa7e0783bec3cc8504326783f8aac4686ee31a5500af49f5b34cd601cf676" +
        "1bb798b2341a7bac3318dd0891550119fc74e048ee05dac7b056994afb1fcdf2" +
        "b47581617d1a1bf7c7b8a6d5ea77ef264ea01391b0fdc55ebb26f7f03dbbf5ab" +
        "c9913751923caf47363baaae552d8126c8a82cde64b86da19fe2eb309e4d2ad4" +
        "04f5d86d251fbdd6806cab51db5943486b70a4fe2d2942cf327cb9b779b906dd" +
        "6f30fa47cec69a14c2b4ebba173fa8c7e33730ebde270dcf90932784cead2cd2" +
        "a5c2d4537e4e463796eafe30fc62fa85ffaa26e03ed7df937f9bf370c0c64c66" +
        "1302c5762f5eac87c57ec387be2232e9d7019507b6a7ddeda47ec4438b0107a3" +
        "6279fb04269efed8daf4e9339b8938a8baecd1b7bbb67b17c725f21be05ff28a" +
        "ae854bc375802e6541a3c881345b4e68a996bc4c60d5948a258c48785518b676" +
        "be870a8f64e7d186199bc26b4d23932b0c2afc6cd7f8aaf9c744d6c50aa3b01e" +
        "ef880ccf53c630b28fe9fdb70dd971931998f2c7267b3b274f487e02b6f41c64" +
        "172f6ccd685f407f8e24ef5e46e554c1acea5af43bf197013e8bc8a62c510514" +
        "6a5f83ccacee258cac4aa4190b1e2ba0fb43c38812eda2e2e86fe947625c23b4" +
        "d84c1c44919c0659be4c5a5f82424ef4f93f58294a6cc7005e8271dfee26d042" +
        "eefd7c70112ede3967f10f851e6996657d2594e9e067fc53777a74bb839a652c" +
        "e38fe1ebc9886a997961c593a65ca104250000"

    private static func makeEdgeInput() -> [UInt8] {
        var data: [UInt8] = []
        data += [UInt8](repeating: UInt8(ascii: "A"), count: 300)
        for _ in 0..<150 { data += Array("ab".utf8) }
        for _ in 0..<100 { data += Array("xyz".utf8) }
        for _ in 0..<40 { data += Array("01234567".utf8) }
        for _ in 0..<20 { data += Array("abcdefghijklmno".utf8) }
        for _ in 0..<20 { data += Array("0123456789abcdefg".utf8) }
        for _ in 0..<10 { data += Array((String(repeating: "K", count: 39) + "|").utf8) }
        let block = (0..<120).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        data += block
        var filler: [UInt8] = []
        for index in 0..<1000 { filler += Array(String(format: "%04d ", index).utf8) }
        data += filler[..<(4096 - 120 - 5)]
        data += block
        data += Array("qqq".utf8)
        data += block
        data += data[300..<900]
        let pad = (4096 - data.count % 4096) % 4096
        let padding = Array(String(repeating: "padding ", count: 600).utf8)
        data += padding[..<pad]
        return data
    }

    func testEdgeInputRegeneratesExpectedBytes() {
        let input = Self.makeEdgeInput()
        XCTAssertEqual(input.count, 8_192)
        XCTAssertEqual(
            sha256Hex(Data(input)),
            "659c793e91adedd32d78c585be8c75565902a263849773037918b0a3f4f4c5a3"
        )
    }

    func testLZMA1EdgeMatchesDecodeAtEveryReadSize() throws {
        let expected = Data(Self.makeEdgeInput())
        let compressed = try Hex.data(Self.lzma1Stream)
        for bufferSize in [1, 7, 16, 100, 4_096, 8_192, 1 << 20] {
            for expectedSize in [nil, UInt64(expected.count)] {
                let decoder = try LZMADecoder(
                    source: DataByteSource(compressed),
                    offset: 0,
                    compressedSize: UInt64(compressed.count),
                    properties: [0x5D, 0x00, 0x10, 0x00, 0x00],
                    expectedSize: expectedSize,
                    dictionarySizeLimit: 1 << 20
                )
                XCTAssertEqual(
                    try drain(decoder, bufferSize: bufferSize),
                    expected,
                    "bufferSize \(bufferSize) expectedSize \(String(describing: expectedSize))"
                )
                XCTAssertTrue(decoder.isFinished)
            }
        }
    }

    func testLZMA2EdgeMatchesDecodeAtEveryReadSize() throws {
        let expected = Data(Self.makeEdgeInput())
        let compressed = try Hex.data(Self.lzma2Stream)
        for bufferSize in [1, 7, 16, 100, 4_096, 8_192, 1 << 20] {
            for expectedSize in [nil, UInt64(expected.count)] {
                let decoder = try LZMA2Decoder(
                    source: DataByteSource(compressed),
                    offset: 0,
                    compressedSize: UInt64(compressed.count),
                    properties: [0],
                    expectedSize: expectedSize,
                    dictionarySizeLimit: 1 << 20
                )
                XCTAssertEqual(
                    try drain(decoder, bufferSize: bufferSize),
                    expected,
                    "bufferSize \(bufferSize) expectedSize \(String(describing: expectedSize))"
                )
                XCTAssertTrue(decoder.isFinished)
            }
        }
    }

    func testLZMA1EdgeRejectsTruncationAndWrongSizeWithTypedErrors() throws {
        let compressed = try Hex.data(Self.lzma1Stream)
        let truncated = compressed.prefix(compressed.count - 40)
        let truncatedDecoder = try LZMADecoder(
            source: DataByteSource(truncated),
            offset: 0,
            compressedSize: UInt64(truncated.count),
            properties: [0x5D, 0x00, 0x10, 0x00, 0x00],
            expectedSize: nil,
            dictionarySizeLimit: 1 << 20
        )
        XCTAssertThrowsError(try drain(truncatedDecoder, bufferSize: 4_096)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        // 既知サイズが実際より小さいと、残る match が出力超過か early end marker として止まる。
        let shortDecoder = try LZMADecoder(
            source: DataByteSource(compressed),
            offset: 0,
            compressedSize: UInt64(compressed.count),
            properties: [0x5D, 0x00, 0x10, 0x00, 0x00],
            expectedSize: 8_000,
            dictionarySizeLimit: 1 << 20
        )
        XCTAssertThrowsError(try drain(shortDecoder, bufferSize: 4_096)) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBitFlipsInEdgeStreamNeverHangOrCrash() throws {
        let seed = Array(try Hex.data(Self.lzma1Stream))
        var completed = 0
        for mutation in 0..<400 {
            var bytes = seed
            let index = 5 + (mutation * 13 + 7) % (bytes.count - 5)
            bytes[index] ^= UInt8(1) << UInt8(mutation % 8)
            do {
                let decoder = try LZMADecoder(
                    source: DataByteSource(Data(bytes)),
                    offset: 0,
                    compressedSize: UInt64(bytes.count),
                    properties: [0x5D, 0x00, 0x10, 0x00, 0x00],
                    expectedSize: nil,
                    dictionarySizeLimit: 1 << 20
                )
                _ = try KaitoKitTests.drain(decoder, bufferSize: 33, maxReads: 100_000)
            } catch {
                // 変異入力は正常終了または構造化 error のどちらでもよい。
            }
            completed += 1
        }
        XCTAssertEqual(completed, 400)
    }

    /// copy primitive を byte loop と比較する。source が destination の前にある場合と、
    /// ring 末尾の source が memory 上で後ろにある（重ならない）場合の両方を網羅する。
    func testDirectCopyMatchesByteLoopForEveryLengthAndDistance() {
        var failures = 0
        for amount in 1...300 {
            for distance in 1...320 where distance >= amount || distance >= 16 {
                var reference = [UInt8](repeating: 0, count: 700)
                for index in 0..<reference.count {
                    reference[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
                }
                var candidate = reference
                let start = 340
                for index in 0..<amount {
                    reference[start + index] = reference[start + index - distance]
                }
                candidate.withUnsafeMutableBufferPointer { buffer in
                    copyLZMAMatchDirect(
                        destination: buffer.baseAddress! + start,
                        source: buffer.baseAddress! + start - distance,
                        amount: amount
                    )
                }
                if candidate != reference {
                    failures += 1
                }
            }
        }
        XCTAssertEqual(failures, 0, "forward layout")

        // source が後ろにあり、両区間が重ならない（gap >= amount）場合。
        var backwardFailures = 0
        for amount in 1...64 {
            for gap in amount...80 {
                var reference = [UInt8](repeating: 0, count: 400)
                for index in 0..<reference.count {
                    reference[index] = UInt8(truncatingIfNeeded: index &* 17 &+ 3)
                }
                var candidate = reference
                let destination = 100
                let source = destination + gap
                for index in 0..<amount {
                    reference[destination + index] = reference[source + index]
                }
                candidate.withUnsafeMutableBufferPointer { buffer in
                    copyLZMAMatchDirect(
                        destination: buffer.baseAddress! + destination,
                        source: buffer.baseAddress! + source,
                        amount: amount
                    )
                }
                if candidate != reference {
                    backwardFailures += 1
                }
            }
        }
        XCTAssertEqual(backwardFailures, 0, "backward non-overlapping layout")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
