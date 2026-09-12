// 前処理の境界は容器の frame / fork と独立であり、checksum は最終出力に掛かる。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXPreprocessingTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer
    private func coordinator(_ intermediate: Data, final: Data, preprocessing: UInt64, compression: UInt64? = nil,
                             digest: Data? = nil) throws -> StuffItXStreamCoordinator {
        var w = Writer(data: Data("StuffIt!".utf8))
        var algorithms: [(UInt64, UInt64, UInt64?)] = [(3,preprocessing,nil),(2,0,nil)]
        if let compression { algorithms.append((1,compression,nil)) }
        w.element(1,[(1,10)],algorithms)
        w.frames(intermediate.map { Data([$0]) }); w.frames([digest ?? StuffItXReaderTests.checksum(final)]); w.element(0)
        let source = DataByteSource(w.data)
        let element = try XCTUnwrap(StuffItXElementParser(source: source, limits: ReadLimits()).parse().first)
        return StuffItXStreamCoordinator(source: source, element: element, size: UInt64(final.count), limits: ReadLimits())
    }
    private func checkBoundaries(_ intermediate: Data, _ final: Data, method: UInt64, compression: UInt64? = nil) throws {
        let coordinator = try coordinator(intermediate, final: final, preprocessing: method, compression: compression)
        for i in final.indices {
            let stream = try coordinator.stream(offset: UInt64(i), length: 1)
            XCTAssertEqual(try StuffItXCodecTests.collect(stream, chunk: 1), Data([final[i]]))
        }
        XCTAssertFalse(coordinator.hasRetainedDecoderState)
        XCTAssertEqual(try StuffItXCodecTests.collect(coordinator.stream(offset: 0, length: UInt64(final.count)), chunk: 7), final)
        let bad = try self.coordinator(intermediate, final: final, preprocessing: method, compression: compression,
                                       digest: StuffItXReaderTests.checksum(intermediate))
        XCTAssertThrowsError(try StuffItXCodecTests.collect(bad.stream(offset: 0, length: UInt64(final.count)), chunk: 1)) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1))
        }
    }
    func testEnglishAcrossEveryFrameAndFork() throws {
        for vector in try StuffItXSlice4Tests.vectors(200) {
            try checkBoundaries(StuffItCodecTests.hex(vector.input_hex), StuffItCodecTests.hex(vector.output_hex), method: 0)
        }
    }
    func testX86AcrossOperandsAndNativeTail() throws {
        try checkBoundaries(StuffItCodecTests.hex("e806000000e80b00000000"), StuffItCodecTests.hex("e800000000e80000000000"), method: 2)
    }
    func testEnglishCompressedIntermediateLengthBothDirections() throws {
        for vector in try StuffItXSlice4Tests.vectors(200) {
            let raw = StuffItCodecTests.hex(vector.input_hex), n = UInt16(raw.count), complement = ~n
            let deflate = Data([15,1,UInt8(truncatingIfNeeded: n),UInt8(n >> 8),UInt8(truncatingIfNeeded: complement),UInt8(complement >> 8)]) + raw
            try checkBoundaries(deflate, StuffItCodecTests.hex(vector.output_hex), method: 0, compression: 3)
        }
    }
    func testEnglishErrorsAndMarkerPriority() throws {
        for (hex, size) in [("",0),("010203",0),("0102030401",0),("010203040201",3),("01020304025a5a5a",10),
                            ("0102030402",2),("0102030402",4)] {
            XCTAssertThrowsError(try {
                let decoder = try StuffItXEnglish(decoder: StuffItXSlice4Tests.copy(StuffItCodecTests.hex(hex)), size: UInt64(size))
                _ = try StuffItXCodecTests.collect(decoder, chunk: 1)
            }())
        }
        let decoder = try StuffItXEnglish(decoder: StuffItXSlice4Tests.copy(Data([1,1,1,1,1,65])), size: 1)
        XCTAssertEqual(try StuffItXCodecTests.collect(decoder, chunk: 1), Data([65]))
        let capitals = try StuffItXEnglish(decoder: StuffItXSlice4Tests.copy(Data([1,2,3,3,3])), size: 3)
        XCTAssertEqual(try StuffItXCodecTests.collect(capitals, chunk: 1), Data("tHE".utf8))
        let empty = try StuffItXEnglish(decoder: StuffItXSlice4Tests.copy(Data([1,2,3,4])), size: 0)
        XCTAssertEqual(try StuffItXCodecTests.collect(empty, chunk: 1), Data())
    }
    func testX86HistoryClosure() {
        var states: Set<UInt32> = [0], before = Set<UInt32>(), accepted = Set<UInt32>()
        while true {
            let old = states
            for value in old {
                for distance in 1...6 {
                    var mask = value
                    if distance == 6 { mask = 0 }
                    else { for _ in 0..<distance { mask = (mask & 0x77) << 1 } }
                    before.insert(mask); states.insert(mask | 1)
                    let t = mask >> 1
                    if t <= 15, (0x17 >> (t & 7)) & 1 != 0 { accepted.insert(mask); states.insert(0) }
                    else { states.insert(mask | 0x11) }
                }
            }
            if old == states { break }
        }
        XCTAssertEqual(states.count, 51); XCTAssertEqual(before.count, 27); XCTAssertEqual(accepted, [0,2,4,8])
    }
}
