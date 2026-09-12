// window 全指数、距離 alphabet の端、物理 bit 順と終端を独立に組み立てて検証する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXDeflateTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer
    private func word(_ value: Int, _ width: Int, _ w: inout Writer) {
        for i in (0..<width).reversed() { w.bits(UInt64((value >> i) & 1),1) }
    }
    private func dynamic(_ exponent: UInt8 = 25) -> Writer {
        var w = Writer(data: Data([exponent]))
        w.bits(1,1); w.bits(2,2); w.bits(29,5); w.bits(49,6); w.bits(4,4)
        // 二次木の symbol 6 と 9 にそれぞれ code 0 と 1 を割り当てる。
        for length: UInt64 in [0,0,0,0,0,0,1,1] { w.bits(length,3) }
        for _ in 0..<286 { w.bits(1,1) }; for _ in 0..<50 { w.bits(0,1) }
        return w
    }
    private func seed(_ size: Int, _ w: inout Writer) {
        word(65,9,&w)
        var count = 1
        while size - count >= 258 { word(285,9,&w); word(0,6,&w); count += 258 }
        while count < size { word(65,9,&w); count += 1 }
    }
    private func distanceEdges(last: Int, history: Int, exponent: UInt8) throws {
        var w = dynamic(exponent); seed(history,&w)
        var tokens = 0
        for symbol in 0...last {
            let width = symbol < 4 ? 0 : symbol / 2 - 1
            for extra in [0, (1 << width) - 1] {
                word(257,9,&w); word(symbol,6,&w); w.bits(UInt64(extra),width); tokens += 1
            }
        }
        word(256,9,&w); w.align()
        let size = history + tokens * 3
        let decoder = try StuffItXCodec.make(method: 3, source: DataByteSource(w.data), size: UInt64(size), limits: ReadLimits())
        var actual = SHA256(), count = 0
        try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
            while true {
                let n = try decoder.read(into: buffer); if n == 0 { break }
                actual.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n])); count += n
            }
        }
        XCTAssertEqual(count,size)
        XCTAssertEqual(actual.finalize(), SHA256.hash(data: Data(repeating: 65, count: size)))
    }
    func testAllWindowParameters() throws {
        for e: UInt8 in 10...25 {
            XCTAssertEqual(try StuffItXCodecTests.decode(Data([e,1,0,0,255,255]),method:3,size:0),Data())
        }
        for e: UInt8 in [0,9,26,31,255] {
            XCTAssertThrowsError(try StuffItXCodecTests.decode(Data([e,1,0,0,255,255]),method:3,size:0))
        }
    }
    func testDistancesThrough64KiB() throws { try distanceEdges(last:31,history:65_536,exponent:16) }
    func testAllFiftyDistanceSymbolsThrough32MiB() throws {
        guard ProcessInfo.processInfo.environment["STUFFITX_LARGE_WINDOWS"] == "1" else { throw XCTSkip("32 MiB 距離検証は明示実行") }
        try distanceEdges(last:49,history:33_554_432,exponent:25)
    }
    func testDeclaredWindowAndAvailableHistory() throws {
        for history in [1,1025] {
            var w = dynamic(10); seed(history,&w)
            word(257,9,&w); word(20,6,&w); w.bits(0,9); word(256,9,&w); w.align()
            XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data,method:3,size:history+3)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
    }
    func testGrammarAndCompletionRejections() throws {
        for bytes: [UInt8] in [[15,7],[15,1,1,0,255,255,65],[15,1,0,0,255],[15,1,0,0,255,255,0]] {
            XCTAssertThrowsError(try StuffItXCodecTests.decode(Data(bytes),method:3,size:0))
        }
        for symbol in [286,287] {
            var w = Writer(data:Data([15])); w.bits(1,1); w.bits(1,2); word(symbol - 88,8,&w); w.align()
            XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data,method:3,size:1))
        }
        var w = dynamic(); word(65,9,&w); word(256,9,&w); w.align()
        XCTAssertEqual(try StuffItXCodecTests.decode(w.data,method:3,size:1),Data([65]))
        XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data.dropLast(),method:3,size:1))
        XCTAssertThrowsError(try StuffItXCodecTests.decode(w.data,method:3,size:1,limits:ReadLimits(maxDictionarySize:1024)))
    }
    func testNonfinalHuffmanHeaderContinuesAtCurrentBit() throws {
        var w = Writer(data:Data([10]))
        for final: UInt64 in [0,1] {
            w.bits(final,1); w.bits(1,2); word(48 + 65,8,&w); word(0,7,&w)
        }
        w.align()
        XCTAssertEqual(try StuffItXCodecTests.decode(w.data,method:3,size:2,chunk:1),Data([65,65]))
    }
}
