import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class TarSpliceDifferentialFuzzTests: XCTestCase {
    func testFixedSeedMutationsAreNeverLooserThanFullOpen() throws {
        typealias S = TarSpliceTestSupport
        var state: UInt64 = 0x51a4_7319_dbee_2083
        func random(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(max(1, bound)))
        }
        var total = 0, accepted = 0
        for codec in S.Codec.allCases {
            let initial = try XCTUnwrap(S.full(S.encode(S.corpus(), codec).data, codec).tarEditingSnapshot())
            var seeds = try S.cases(initial, codec).map { (initial, $0) }
            let fixture = codec == .tgz ? "strgz.tgz" : codec == .tbz ? "strbz.tbz" : "strxz.txz"
            let straddle = try XCTUnwrap(S.full(TarEditTestSupport.fixture(fixture), codec).tarEditingSnapshot())
            let append = try S.edit("straddle-append", straddle, codec, a: Int(XCTUnwrap(straddle.layout).endOfArchiveOffset),
                b: Int(straddle.image.length), replacement: S.member("fuzz", Data([1])) + Data(count: 1024))
            seeds.append((straddle, append))
            var base = initial
            for i in 0..<3 {
                let output = try S.prefix(base, codec, bytes: S.member("chain-\(i)", Data([UInt8(i)])))
                seeds.append((base, output))
                base = try XCTUnwrap(S.open(output, codec, base: base).tarEditingSnapshot())
            }
            for (base, seed) in seeds {
                for iteration in 0..<200 {
                    var bytes = seed.bytes, segments = seed.splice.segments
                    switch iteration % 5 {
                    case 0: bytes[random(bytes.count)] ^= UInt8(1 << random(8))
                    case 1:
                        let start = random(bytes.count), count = min(1 + random(16), bytes.count - start)
                        for i in start..<(start + count) { bytes[i] = UInt8(random(256)) }
                    case 2: bytes = Data(bytes.prefix(random(bytes.count)))
                    case 3:
                        let index = random(segments.count), delta = [-512, -1, 1, 512][random(4)]
                        let original = segments[index].outputRange
                        let lower = random(2) == 0
                        let value = max(0, Int(lower ? original.lowerBound : original.upperBound) + delta)
                        let start = lower ? UInt64(value) : original.lowerBound
                        let end = lower ? original.upperBound : UInt64(value)
                        let range = min(start, end)..<max(start, end)
                        switch segments[index] {
                        case .encoded: segments[index] = .encoded(output: range)
                        case .reused(_, let base): segments[index] = .reused(output: range, base: base)
                        }
                    default:
                        let index = random(segments.count), range = segments[index].outputRange
                        switch segments[index] {
                        case .encoded: segments[index] = .reused(output: range, base: range)
                        case .reused: segments[index] = .encoded(output: range)
                        }
                    }
                    let result = S.Output(name: seed.name, bytes: bytes, splice: .init(segments: segments), image: Data())
                    let actual = Result { try S.open(result, codec, base: base) }
                    let full = Result { try S.full(bytes, codec) }
                    let label = "\(codec) / \(seed.name) / \(iteration)"
                    switch (actual, full) {
                    case (.success(let a), .success(let b)):
                        accepted += 1; try S.equal(a, b)
                    case (.success, .failure(let error)): XCTFail("K5 accepted invalid output: \(label): \(error)")
                    case (.failure(let error), .failure(let expected)):
                        if let error = error as? KaitoError { XCTAssertEqual(error, expected as? KaitoError, label) }
                        else { XCTAssertTrue(error is TarSpliceVerificationError, "\(label): \(error)") }
                    case (.failure, .success): break
                    }
                    total += 1
                }
            }
        }
        XCTAssertEqual(total, 7_000)
        print("KAITOKIT-SPLICE-FUZZ mutations=\(total) accepted=\(accepted) seed=51a47319dbee2083")
    }
}
