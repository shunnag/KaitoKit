// native profile のヘッダ境界と、空 raw block の継続を検証する。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXIronTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer
    private func header(st4: Bool = false, exponent: UInt64 = 6, shift: UInt64 = 2) -> Writer {
        var w = Writer()
        w.bits(st4 ? 1 : 0, 1); w.bits(0, 1)
        for n in [exponent,6,8,shift,3,4,2,3,4] { w.p2(n) }; w.align()
        return w
    }
    func testRawEmptyBlocksContinueAndDeclaredExponentIsIgnored() throws {
        for exponent: UInt64 in [0,1,30,0x7fffffff] {
            var w = header(exponent: exponent)
            for _ in 0..<4096 { w.bits(0,1); w.p2(0); w.bits(1,1); w.align() }
            w.bits(0,1); w.p2(3); w.bits(1,1); w.align(); w.data += Data("raw".utf8)
            w.bits(1,1); w.align()
            XCTAssertEqual(try StuffItXCodecTests.decode(w.data, method: 6, size: 3, chunk: 1), Data("raw".utf8))
            let unknown = try StuffItXCodec.make(method: 6, source: DataByteSource(w.data), size: nil, limits: ReadLimits())
            XCTAssertEqual(try StuffItXCodecTests.collect(unknown, chunk: 1), Data("raw".utf8))
        }
    }
    func testHeaderRunAndSortBounds() throws {
        for w in [header(exponent: 0x80000000), header(shift: 0), header(shift: 32)] {
            XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data, method: 6, size: 0))
        }
        for (st4, n, primary, dictionary) in [(false,UInt64(1 << 31),0,UInt64.max),(true,1 << 23,0,UInt64.max),
                                               (false,0,0,UInt64.max),(false,5,5,UInt64.max),(false,5,0,29)] {
            var w = header(st4: st4)
            w.bits(0,1); w.p2(n); w.bits(0,1); w.p2(UInt64(primary)); w.align()
            XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data, method: 6, size: Int(n), limits: ReadLimits(maxDictionarySize: dictionary)))
        }
        var w = header(); w.bits(1,1); w.align()
        XCTAssertEqual(try StuffItXCodecTests.decode(w.data, method: 6, size: 0), Data())
        XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data + [0], method: 6, size: 0))
        XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data, method: 6, size: 1))
        XCTAssertThrowsError(try StuffItXCodecTests.decode(Data(w.data.dropLast()), method: 6, size: 0))
    }
}
