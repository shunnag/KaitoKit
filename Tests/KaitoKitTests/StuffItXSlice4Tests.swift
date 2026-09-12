// 指定資料の vector を保存し、モデルの枯渇を含めて差分検証する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXSlice4Tests: XCTestCase {
    struct Vector: Decodable {
        let name: String
        let method: Int
        let input_hex: String
        let output_hex: String
        let arguments: [String]?
        let model_events: [String: Int]?
    }
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/stuffit")
    static func vectors(_ method: Int) throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: fixtures.appendingPathComponent("slice4-vectors.json"))).filter { $0.method == method }
    }
    func testBrimstoneVectors() throws {
        let vectors = try Self.vectors(100)
        XCTAssertEqual(vectors.count, 9)
        for vector in vectors {
            let order = vector.arguments.flatMap { Int($0[0]) } ?? 4
            let memory = vector.arguments.flatMap { Int($0[1]) } ?? 1_048_576
            let input = Data([UInt8(memory.trailingZeroBitCount), UInt8(order)]) + StuffItCodecTests.hex(vector.input_hex)
            let expected = StuffItCodecTests.hex(vector.output_hex)
            for chunk in [1, 4096] {
                let decoder = try StuffItXBrimstoneDecoder(input: StuffItXBitReader(source: DataByteSource(input)), size: UInt64(expected.count), limits: ReadLimits())
                do {
                    let output = try StuffItXCodecTests.collect(decoder, chunk: chunk)
                    XCTAssertEqual(output, expected, "\(vector.name), first difference \(zip(output, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")
                    if let events = vector.model_events {
                        XCTAssertEqual(decoder.model.restartCount, events["restarts"], vector.name)
                        XCTAssertEqual(decoder.model.rescaleCount, events["rescales"], vector.name)
                        XCTAssertEqual(decoder.model.promotionCount, events["promotions"], vector.name)
                        XCTAssertEqual(decoder.model.insertionCount, events["new_states"], vector.name)
                        XCTAssertEqual(decoder.model.singleConversionCount, events["multi_to_single"], vector.name)
                        XCTAssertEqual(decoder.model.suffixHitCount, events["suffix_hits"], vector.name)
                        XCTAssertEqual(decoder.model.fastCount, events["fast"], vector.name)
                    }
                } catch { XCTFail("\(vector.name): \(error)") }
            }
        }
    }
    func testAllocatorGapSplitAndLIFO() throws {
        let arena = try StuffItXBrimstoneAllocator(exponent: 8, limits: ReadLimits())
        let whole = try XCTUnwrap(arena.allocate(units: 21))
        XCTAssertEqual(whole, 12); XCTAssertNil(arena.context())
        arena.free(whole, units: 21)
        XCTAssertEqual(arena.allocate(units: 9), 12)
        XCTAssertEqual(arena.context(), 252)
        XCTAssertEqual(arena.allocate(units: 10), 132)
        XCTAssertNil(arena.allocate(units: 1))
        arena.reset()
        let first = try XCTUnwrap(arena.allocate(units: 1))
        arena.free(first, units: 1)
        XCTAssertEqual(arena.context(), 252)
        XCTAssertEqual(arena.allocate(units: 1), first)
        let second = try XCTUnwrap(arena.allocate(units: 1))
        arena.free(first, units: 1); arena.free(second, units: 1)
        XCTAssertEqual(arena.allocate(units: 1), second)
        XCTAssertEqual(arena.allocate(units: 1), first)
    }
    func testAllocatorGrowthAndShrinkPreserveData() throws {
        let arena = try StuffItXBrimstoneAllocator(exponent: 8, limits: ReadLimits())
        let block = try XCTUnwrap(arena.allocate(units: 8))
        let spare = try XCTUnwrap(arena.allocate(units: 4))
        arena.bytes[block] = 73
        while arena.context() != nil {}
        XCTAssertNil(arena.grow(block, units: 8))
        XCTAssertEqual(arena.bytes[block], 73)
        arena.free(spare, units: 4)
        let small = arena.shrink(block, from: 8, to: 4)
        XCTAssertEqual(small, spare); XCTAssertEqual(arena.bytes[small], 73)
        XCTAssertEqual(arena.allocate(units: 8), block)
        XCTAssertEqual(arena.shrink(small, from: 4, to: 2), small)
        XCTAssertEqual(arena.allocate(units: 2), small + 24)
    }
    func testBrimstoneBoundsAndTermination() throws {
        for prefix in [[31,4], [12,0], [0,4]] {
            let data = Data(prefix.map(UInt8.init)) + Data(repeating: 0, count: 4)
            XCTAssertThrowsError(try StuffItXCodecTests.decode(data, method: 0, size: 1))
        }
        XCTAssertThrowsError(try StuffItXCodecTests.decode(Data([12,4,0,0,0,0]), method: 0, size: 1, limits: ReadLimits(maxDictionarySize: 4095)))
        let vector = try XCTUnwrap(Self.vectors(100).first { $0.name == "brimstone-zero-history-adaptation-root-escape" })
        let input = Data([20,4]) + StuffItCodecTests.hex(vector.input_hex)
        // order 1 の初期 root の escape 区間を独立に選ぶ。正規化用 octet も供給する。
        let code = (UInt32.max / 385) * 384
        let empty = Data([12,1]) + Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) }) + Data([0])
        let decoder = try StuffItXCodec.make(method: 0, source: DataByteSource(empty), size: nil, limits: ReadLimits())
        XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: 7), Data())
        XCTAssertThrowsError(try StuffItXCodecTests.decode(input, method: 0, size: vector.output_hex.count / 2 + 1))
    }
    func testIronNativeVectorsAndLegacyProfileDifference() throws {
        let legacy = try Self.vectors(106)
        XCTAssertEqual(legacy.count, 4)
        for vector in legacy {
            // 元の宣言上限 (16,32,64) の期待値は保存し、native と混同しない。
            XCTAssertThrowsError(try StuffItXCodecTests.decode(StuffItCodecTests.hex(vector.input_hex), method: 6, size: vector.output_hex.count / 2), vector.name)
        }
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("slice4-iron-native-vectors.json")))
        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            for chunk in [1, 7, 4096] {
                XCTAssertEqual(try StuffItXCodecTests.decode(StuffItCodecTests.hex(vector.input_hex), method: 6, size: vector.output_hex.count / 2, chunk: chunk), StuffItCodecTests.hex(vector.output_hex), vector.name)
            }
        }
    }
    static func copy(_ bytes: Data) throws -> any Decompressor {
        try CopyDecompressor(source: DataByteSource(bytes), offset: 0, compressedSize: UInt64(bytes.count))
    }
    func testEnglishVectors() throws {
        let vectors = try Self.vectors(200)
        XCTAssertEqual(vectors.count, 5)
        for vector in vectors {
            for chunk in [1, 7, 4096] {
                let expected = StuffItCodecTests.hex(vector.output_hex)
                let decoder = try StuffItXEnglish(decoder: Self.copy(StuffItCodecTests.hex(vector.input_hex)), size: UInt64(expected.count))
                XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: chunk), expected, vector.name)
            }
        }
    }
    func testX86NativeVectorsAndTail() throws {
        let vectors = try Self.vectors(202)
        XCTAssertEqual(vectors.count, 4)
        for (i, vector) in vectors.enumerated() {
            // Ch.38 の訂正に従い、旧五バイト末尾の期待値と native の期待値を区別する。
            let native = i == 0 ? "e806000000" : (i == 1 ? "616263e90700000058595ae8ffffffff" : vector.output_hex)
            for chunk in [1, 7, 4096] {
                let data = StuffItCodecTests.hex(vector.input_hex)
                let decoder = try StuffItXX86(decoder: Self.copy(data), size: UInt64(data.count))
                XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: chunk), StuffItCodecTests.hex(native), vector.name)
            }
        }
        for count in 0...5 {
            let data = Data([0xe8,6,0,0,0].prefix(count))
            let decoder = try StuffItXX86(decoder: Self.copy(data), size: UInt64(count))
            XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: 1), data)
        }
        let decoder = try StuffItXX86(decoder: Self.copy(Data([0xe8,6,0,0,0,0])), size: 6)
        XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: 1), Data([0xe8,0,0,0,0,0]))
    }
    func testDictionaryAndReproducibleGeneration() throws {
        let words = try StuffItXEnglishDictionary.words.get()
        XCTAssertEqual(words.count, 100_366)
        XCTAssertEqual(Array(words.prefix(8)), ["the","and","that","was","for","you","with","have"])
        let data = Data((words.joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(data.count, 881_863)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), StuffItXEnglishDictionary.sha256)
        let root = Self.fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = root.appendingPathComponent(".build/slice4-dictionary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let list = temporary.appendingPathComponent("words.txt")
        try data.write(to: list)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Scripts/fixtures/make-stuffit-english-dictionary.py").path, "--input", list.path, "--check"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
