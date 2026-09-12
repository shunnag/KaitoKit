// 指定レポートの独立 vector と Ch.04・12 の境界条件を検証する。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItSlice2CodecTests: XCTestCase {
    struct Vector: Decodable { let name: String; let method: Int; let input_hex: String; let expected_hex: String }
    private func vector(_ name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/stuffit/slice2-vectors.json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: data)
        XCTAssertEqual(vectors.count, 6)
        let v = try XCTUnwrap(vectors.first { $0.name == name })
        let expected = StuffItCodecTests.hex(v.expected_hex)
        for chunk in [1, 7, 4096] {
            XCTAssertEqual(try StuffItCodecTests.decode(StuffItCodecTests.hex(v.input_hex), method: v.method,
                                                       size: expected.count, chunk: chunk), expected, name)
        }
    }
    func testLZAHInitialLiteral() throws { try vector("lzah_initial_literal") }
    func testLZAHInitialWindowAndOverlap() throws { try vector("lzah_initial_window_and_overlap") }
    func testLZAHAdaptationAndRescale() throws { try vector("lzah_adaptation_and_rescale") }
    func testMWPairsAndReset() throws { try vector("mw_pairs_and_reset") }
    func testInstallerTwoBlocksKeepWindow() throws { try vector("installer_two_blocks_keep_window") }
    func testInstallerMetaTreeTiedLengths() throws { try vector("installer_meta_tree_tied_lengths") }

    static func pack(_ codes: [(Int, Int)], lsb: Bool = true) -> Data {
        var bytes = Data(), byte = 0, count = 0
        for (value, width) in codes {
            for i in 0..<width {
                let bit = (value >> (lsb ? i : width - 1 - i)) & 1
                byte |= bit << (lsb ? count : 7 - count); count += 1
                if count == 8 { bytes.append(UInt8(byte)); byte = 0; count = 0 }
            }
        }
        if count > 0 { bytes.append(UInt8(byte)) }
        return bytes
    }
    func testMWWidthCapacityAndTerminalRules() throws {
        var codes: [(Int, Int)] = [(256, 9), (65, 9)]
        var width = 9
        for q in 256..<16_385 {
            codes.append((66, width))
            if q + 1 == 1 << width { width += 1 }
        }
        XCTAssertEqual(width, 15)
        let expected = Data([65] + Array(repeating: 66, count: 16_129))
        let reset = Self.pack(codes + [(16_385, 15), (67, 9)])
        XCTAssertEqual(try StuffItCodecTests.decode(reset, method: 8, size: expected.count + 1), expected + [67])
        XCTAssertThrowsError(try StuffItCodecTests.decode(Self.pack(codes + [(66, 15)]), method: 8, size: expected.count + 1)) {
            guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
        }
        for tail in [[(16_386, 15)], [(16_385, 15), (257, 9)]] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(Self.pack(codes + tail), method: 8, size: expected.count + 1)) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
        XCTAssertThrowsError(try StuffItCodecTests.decode(Self.pack([(65, 9), (66, 9), (256, 9)]), method: 8, size: 3))
    }
    func testInstallerPartitionAndMalformedTrees() throws {
        XCTAssertEqual(StuffItInstaller.orderedSymbols([2, 2, 2, 2]), [3, 2, 0, 1])
        let header = Data([1, 0, 0, 0, 0, 0, 1, 0, 0, 0])
        for body in [Data([0, 3]), Data(repeating: 64, count: StuffItInstaller.maximumTreeDepth + 1)] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(header + body, method: 14, size: 1)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
    }
    private func positive(_ translation: [UInt8], bits: String, intermediate: Int) -> Data {
        let packed = Self.pack(bits.map { ($0 == "1" ? 1 : 0, 1) }, lsb: false)
        var header = [UInt8](repeating: 0, count: 10)
        StuffItContainerTests.put(UInt64(10 + translation.count + packed.count), 4, 0, &header)
        StuffItContainerTests.put(UInt64(intermediate), 4, 4, &header)
        StuffItContainerTests.put(UInt64(translation.count), 2, 8, &header)
        return Data(header + translation) + packed
    }
    private func negative(_ packed: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 4)
        StuffItContainerTests.put(UInt64(UInt32(bitPattern: -Int32(packed.count + 4))), 4, 0, &header)
        return Data(header + packed)
    }
    func testMethod6TranslationPersistsAcrossBothBlockTypes() throws {
        let first = positive([0, 65], bits: "0000010", intermediate: 2)
        let second = negative([128, 254, 66])
        let third = positive([0], bits: "0000010", intermediate: 2)
        for chunk in [1, 2, 4096] {
            XCTAssertEqual(try StuffItCodecTests.decode(first + second + third, method: 6, size: 5, chunk: chunk), Data("ABBBA".utf8))
        }
        XCTAssertEqual(try StuffItCodecTests.decode(positive([], bits: "0000010", intermediate: 2), method: 6, size: 1), Data([0]))
    }
    func testMethod6RejectsExtentOperandAndEarlyStop() throws {
        for data in [Data([128, 0, 0, 0]), Data([0, 0, 0, 0]), negative([0]), negative([255]),
                     positive([0], bits: "000", intermediate: 1),
                     positive([0], bits: "111111111111", intermediate: 1)] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(data, method: 6, size: 1))
        }
    }
    func testMethod6NonmonotonicCodeAssignments() throws {
        let words = [(114, "111010000"), (115, "1110100010"), (116, "1110100011"),
                     (117, "111010010"), (118, "111010011"), (119, "1110101000"),
                     (253, "11111111110"), (254, "1111111111100"), (255, "1111111111101")]
        for (symbol, word) in words {
            let block = positive(Array(0...255), bits: "000" + word, intermediate: 2)
            XCTAssertEqual(try StuffItCodecTests.decode(block, method: 6, size: 1), Data([UInt8(symbol)]))
        }
    }
    func testNewCodecLimitsAndTruncation() throws {
        for method in [5, 6, 8, 14] {
            XCTAssertThrowsError(try StuffItCodecTests.decode(Data(), method: method, size: 1))
            XCTAssertThrowsError(try StuffItCodecTests.decode(Data(repeating: 0, count: 20), method: method,
                                                             size: 1, limits: ReadLimits(maxDictionarySize: 1))) {
                guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
            }
        }
    }
}
