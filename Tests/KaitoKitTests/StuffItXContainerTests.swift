// 指定資料 Ch.03 の表と文法を固定した検査。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXContainerTests: XCTestCase {
    struct Writer {
        var data = Data()
        var pending: UInt8 = 0
        var count = 0
        mutating func bits(_ value: UInt64, _ width: Int) {
            for i in 0..<width {
                pending |= UInt8((value >> i) & 1) << count; count += 1
                if count == 8 { align() }
            }
        }
        mutating func align() {
            if count > 0 { data.append(pending) }; count = 0; pending = 0
        }
        mutating func p2(_ value: UInt64) {
            let x = value + 1, population = x.nonzeroBitCount
            for _ in 1..<population { bits(1, 1) }
            bits(0, 1); bits(x, 64 - x.leadingZeroBitCount)
        }
        mutating func string(_ bytes: Data) { p2(UInt64(bytes.count)); align(); data += bytes }
        mutating func element(_ type: UInt64, _ attributes: [(UInt64, UInt64)] = [],
                              _ algorithms: [(UInt64, UInt64, UInt64?)] = [], extra: UInt64? = nil) {
            align(); bits(0, 1); p2(type)
            for (k, v) in attributes { p2(k); p2(v) }; p2(0)
            for (k, v, e) in algorithms { p2(k); p2(v); if let e { p2(e) } }; p2(0)
            if let extra { p2(extra) }; align()
        }
        mutating func frames(_ blocks: [Data]) {
            for block in blocks { p2(UInt64(block.count)); align(); data += block }
            p2(0); align()
        }
    }
    func testP2PublishedExamples() throws {
        let examples: [(UInt64, String)] = [(0,"01"),(1,"001"),(2,"1011"),(3,"0001"),(4,"10101"),
            (5,"10011"),(6,"110111"),(7,"00001"),(14,"11101111"),(15,"000001"),(16,"1010001")]
        for (value, bits) in examples {
            var writer = Writer()
            for bit in bits { writer.bits(bit == "1" ? 1 : 0, 1) }; writer.align()
            let input = try StuffItXBitReader(source: DataByteSource(writer.data))
            XCTAssertEqual(try input.p2(), value)
        }
        for value in [UInt64.max - 1, UInt64.max / 2, 1 << 63] {
            var w = Writer(); w.p2(value); w.align()
            XCTAssertEqual(try StuffItXBitReader(source: DataByteSource(w.data)).p2(), value)
        }
    }
    func testP2RejectsOverflowAndEOF() throws {
        for bytes in [Data(repeating: 255, count: 9), Data(repeating: 0, count: 10)] {
            XCTAssertThrowsError(try StuffItXBitReader(source: DataByteSource(bytes)).p2()) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
        for bytes in [Data(), Data([255]), Data([0])] {
            XCTAssertThrowsError(try StuffItXBitReader(source: DataByteSource(bytes)).p2()) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }
    func testOrderedAlgorithmsAndTwoFrameSequences() throws {
        var w = Writer(data: Data("StuffIt!".utf8))
        w.element(1, [(1, 3)], [(4, 0, 32), (2, 1, nil), (4, 3, 64), (2, 0, nil)])
        w.frames([Data([65]), Data([66, 67])]); w.frames([Data([1, 2, 3, 4])])
        w.element(13); w.frames([]); w.frames([]); w.element(0)
        let source = DataByteSource(w.data)
        let elements = try StuffItXElementParser(source: source, limits: ReadLimits()).parse()
        XCTAssertEqual(elements.map(\.type), [1, 13, 0])
        XCTAssertEqual(elements[0].algorithms.map(\.key), [4, 2, 4, 2])
        XCTAssertEqual(elements[0].algorithms[2].keyLength, 64)
        let framed = try StuffItXFramedInput(source: source, ranges: elements[0].data)
        XCTAssertEqual(try readByteRange(source: framed, offset: 0, count: 3), [65,66,67])
        XCTAssertThrowsError(try StuffItXElementParser(source: DataByteSource(w.data.dropLast()), limits: ReadLimits()).parse())
    }
}
