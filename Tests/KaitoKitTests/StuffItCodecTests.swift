// Clean-room format inputs: Ch.04 と research/core-vectors.json の独立作成 vector を hex のまま固定する。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItCodecTests: XCTestCase {
    static func hex(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        func digit(_ x: UInt8) -> UInt8 { x <= 57 ? x - 48 : x - 87 }
        return Data(stride(from: 0, to: bytes.count, by: 2).map { digit(bytes[$0]) << 4 | digit(bytes[$0 + 1]) })
    }
    static func decode(_ input: Data, method: Int, size: Int, chunk: Int = 7, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try StuffItCodec.make(method: method, source: DataByteSource(data: input), offset: 0,
                                            stored: UInt64(input.count), size: UInt64(size), limits: limits)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            output.append(contentsOf: buffer[..<count])
            if output.count > size { XCTFail("出力長の超過"); break }
        }
        XCTAssertTrue(decoder.isFinished)
        return output
    }
    private func vector(method: Int, input: String, expected: String) throws {
        let packed = Self.hex(input), plain = Self.hex(expected)
        for chunk in [1, 7, 4096] {
            XCTAssertEqual(try Self.decode(packed, method: method, size: plain.count, chunk: chunk), plain)
        }
    }
    func test_rle90_literal_escape_and_run() throws {
        try vector(method: 1, input: "419004429000",
                   expected: "414141414290")
    }
    func test_lzw_next_code_special_case() throws {
        try vector(method: 2, input: "4184041c08",
                   expected: "41424142414241")
    }
    func test_huffman_two_leaf_tree() throws {
        try vector(method: 3, input: "50684c",
                   expected: "41424241")
    }
    func test_method13_preset_1_context_switch() throws {
        try vector(method: 13, input: "1009ad9cafce02",
                   expected: "414241424143")
    }
    func test_method13_preset_2_context_switch() throws {
        try vector(method: 13, input: "20cd7e7c69ef03",
                   expected: "414241424143")
    }
    func test_method13_preset_3_context_switch() throws {
        try vector(method: 13, input: "308949f89bfd3f",
                   expected: "414241424143")
    }
    func test_method13_preset_4_context_switch() throws {
        try vector(method: 13, input: "40fe0af5cd16",
                   expected: "414241424143")
    }
    func test_method13_preset_5_context_switch() throws {
        try vector(method: 13, input: "50ba56e467ec07",
                   expected: "414241424143")
    }
    func test_method13_dynamic_shared_table() throws {
        try vector(method: 13, input: "088410420821841042082184104208218410420821841042082184104208218410420821841042082104bb841042082184104208218410420821841042082184104208218410420821841042082184104208218410420821841042082184104208218410420821841042082184104208218410420821841042082184104208218410420821841042082184104208218410420821841042082184104208218410420816218410420821841042082184104208218410420821841042082184104208218410420821841042b0b08b5d420821841019",
                   expected: "41414141")
    }
    func test_arsenic_single_byte() throws {
        try vector(method: 15, input: "42c1c36f2985d5f7a9f1549484",
                   expected: "41")
    }
    func test_arsenic_blocks_rle_models_randomization() throws {
        try vector(method: 15, input: "42c1c660072d07ef9fc6a91b0770e7c4ffb6a0310eaf2ea3d60d257aaf83218f528a75d557b7a9a229d893a93b5d655cd621649cc1f68f89ded6b2141bc15bdcbfdf1f9feb677a3eac08f2d5696b9a2e92b47a271e1e8bbd21f583e303a0c55d5fd2268437096dde167d09921d3a4bfeb6da023a4c90f8f20e6045822b6174c7f58db2ecfa492c9db698627b07af979ad89e9afd525e1c4e39f1d1ac3e7706b5c0a1308d529842596bbaa0e2b64006092298c90d2eba1ef927eacb40b637eafe5e8b0fec9617b5e0cdd56b83cf2a08aedd47aff9ae8e9afab40fe5c291c529cea9f1a9170aa24b6b39b47a2ca38a52c6a2615e42216f124508119a6e7b3b484ac6aaf90c5b84dfaef802d9845bef3f3155545b3c84d3f0e6a3ec07145fb0f6c79c4e4d60f9625e0a5c2cc15d14fcbf3edb2764a8d6b0090ea901b4d274f426513020953130d5c8a455ef4ce126d3d69eef0d355da827e9186a7112edf24d258de0",
                   expected: "41414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414142434445000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfefffffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1d0cfcecdcccbcac9c8c7c6c5c4c3c2c1c0bfbebdbcbbbab9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4a3a2a1a09f9e9d9c9b9a999897969594939291908f8e8d8c8b8a898887868584838281807f7e7d7c7b7a797877767574737271706f6e6d6c6b6a696867666564636261605f5e5d5c5b5a595857565554535251504f4e4d4c4b4a494847464544434241403f3e3d3c3b3a393837363534333231302f2e2d2c2b2a292827262524232221201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100")
    }
}
