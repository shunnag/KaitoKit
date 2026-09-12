// 研究ハーネスの routing 値を容器の圧縮番号へ変換して固定 vector を検証する。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXCodecTests: XCTestCase {
    struct Vector: Decodable { let name: String; let method: Int; let input_hex: String; let output_hex: String }
    static func vectors() throws -> [Vector] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/stuffit/slice3-vectors.json")))
    }
    static func decode(_ data: Data, method: UInt64?, size: Int, chunk: Int = 4096, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try StuffItXCodec.make(method: method, source: DataByteSource(data), size: UInt64(size), limits: limits)
        return try collect(decoder, chunk: chunk)
    }
    static func collect(_ decoder: any Decompressor, chunk: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: chunk), output = Data()
        while true {
            let n = try bytes.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if n == 0 { break }; output.append(contentsOf: bytes[..<n])
        }
        XCTAssertTrue(decoder.isFinished)
        return output
    }
    func testPublishedVectors() throws {
        let vectors = try Self.vectors()
        XCTAssertEqual(vectors.count, 10)
        for vector in vectors where vector.method != 104 {
            var data = StuffItCodecTests.hex(vector.input_hex)
            if vector.method == 102 { data.insert(20, at: 0) }
            if vector.method == 103 { data.insert(15, at: 0) }
            let expected = StuffItCodecTests.hex(vector.output_hex)
            for chunk in [1, 7, 4096] {
                XCTAssertEqual(try Self.decode(data, method: UInt64(vector.method - 100), size: expected.count, chunk: chunk), expected, vector.name)
            }
        }
    }
    func testBlendSupportedPrefix() throws {
        let vector = try XCTUnwrap(Self.vectors().first { $0.method == 104 })
        let expected = StuffItCodecTests.hex(vector.output_hex), source = DataByteSource(StuffItCodecTests.hex(vector.input_hex))
        for chunk in [1, 7, 4096] {
            let decoder = StuffItXBlend(input: try StuffItXBitReader(source: source), size: UInt64(expected.count), limits: ReadLimits())
            var bytes = [UInt8](repeating: 0, count: chunk), output = Data()
            XCTAssertThrowsError(try {
                while true {
                    let n = try bytes.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    if n == 0 { break }; output.append(contentsOf: bytes[..<n])
                }
            }()) { guard case KaitoError.unsupportedMethod = $0 else { return XCTFail("\($0)") } }
            XCTAssertEqual(output, expected.prefix(output.count))
            XCTAssertEqual(output.count, 31)
        }
    }
    func testCyanideAcceptsAllTailCounts() throws {
        // 初期 ternary model の rank 0 区間から一文字だけ復号する独立標本。
        for n in UInt8.min...UInt8.max {
            var data = StuffItCodecTests.hex("0077000000010000000000c0000000ff"); data[10] = n
            XCTAssertEqual(try Self.decode(data, method: 1, size: 1, chunk: 1), Data([0]), "n=\(n)")
        }
    }
    func testCyanideRankBoundary() throws {
        // Ch.07 の初期等頻度区間の中点を使用。n=254/255 の最終群は 128/129 個。
        // rank 255 は list の最終 byte、256/257 は list を拡張せず拒否する。
        for hex in ["00770000000100000000fe001fffff00ff", "00770000000100000000ff0034eb7d00ff"] {
            XCTAssertEqual(try Self.decode(StuffItCodecTests.hex(hex), method: 1, size: 1, chunk: 1), Data([255]))
        }
        for hex in ["00770000000100000000fe000aaaaa00ff", "00770000000100000000ff001fc07e00ff",
                    "00770000000100000000ff000a957f00ff"] {
            XCTAssertThrowsError(try Self.decode(StuffItCodecTests.hex(hex), method: 1, size: 1, chunk: 1)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("StuffIt X Cyanide rank"))
            }
        }
    }
    func testCyanideMemoryLimit() throws {
        let vector = try XCTUnwrap(Self.vectors().first { $0.name == "cyanide-small-alphabet" })
        XCTAssertThrowsError(try Self.decode(StuffItCodecTests.hex(vector.input_hex), method: 1, size: 400,
                                              limits: ReadLimits(maxDictionarySize: 2399))) {
            guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
        }
    }
    func testRangeCountAndTruncationInBothModes() throws {
        for explicit in [false,true] {
            let input = try StuffItXBitReader(source: DataByteSource(Data(repeating: 255, count: 4)))
            let range = try StuffItXRangeDecoder(input: input, explicitLower: explicit)
            XCTAssertThrowsError(try range.count(total: 2)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertThrowsError(try StuffItXRangeDecoder(input: StuffItXBitReader(source: DataByteSource(Data([0,0,0]))), explicitLower: explicit)) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }
    func testBlendAmbiguityAndShortInput() throws {
        XCTAssertTrue(StuffItXBlend.acceptsHeader([0x77,0,0,0,0,3]))
        XCTAssertFalse(StuffItXBlend.acceptsHeader([0x77,0,0x77,1,0,3]))
        XCTAssertTrue(StuffItXBlend.acceptsHeader([0x77,0,0x77,1,0x20,0]))
        for data in [Data([0x77]), Data(repeating: 0, count: 6)] {
            XCTAssertThrowsError(try Self.decode(data, method: 4, size: 1)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        }
    }
    func testDictionaryBoundsAndStoredAbsence() throws {
        XCTAssertEqual(try Self.decode(Data([65]), method: nil, size: 1), Data([65]))
        XCTAssertThrowsError(try Self.decode(Data([65]), method: 0, size: 1)) {
            guard case KaitoError.unsupportedMethod = $0 else { return XCTFail("\($0)") }
        }
        for e: UInt8 in [31,255] {
            XCTAssertThrowsError(try Self.decode(Data([e,0,0,0,0,0]), method: 2, size: 1)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try Self.decode(Data([0,0,0,0,0,0]), method: 2, size: 1, limits: ReadLimits(maxDictionarySize: 1))) {
            guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
        }
    }
    func testCodecStateAcrossSingleByteFramesAndShortSourceReads() throws {
        final class OneByteSource: ByteSource {
            let base: DataByteSource
            init(_ data: Data) { base = DataByteSource(data) }
            var length: UInt64 { base.length }
            func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
                try base.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(1)), at: offset)
            }
        }
        for vector in try Self.vectors() where vector.method != 104 {
            var data = StuffItCodecTests.hex(vector.input_hex)
            if vector.method == 102 { data.insert(20,at:0) }
            if vector.method == 103 { data.insert(15,at:0) }
            let source = OneByteSource(data)
            let framed = try StuffItXFramedInput(source: source, ranges: (0..<source.length).map { $0..<($0 + 1) })
            let expected = StuffItCodecTests.hex(vector.output_hex)
            let decoder = try StuffItXCodec.make(method: UInt64(vector.method - 100), source: framed,
                                                 size: UInt64(expected.count), limits: ReadLimits())
            XCTAssertEqual(try Self.collect(decoder, chunk: 3), expected, vector.name)
        }
    }
}
