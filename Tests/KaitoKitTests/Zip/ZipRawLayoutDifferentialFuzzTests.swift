import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipRawLayoutDifferentialFuzzTests: XCTestCase {
    func testFiveSeedsWithThreeHundredMutationsEach() throws {
        let inputs = try ZipGoldenCorpus.inputs()
        let names = ["descriptor-true-3", "sfx-true", "aes128-ae2", "shuffled"]
        let small = try ZipTestSupport.makeArchive(entries: (0..<12).map {
            HandZipEntry(name: "d/f\($0)", uncompressedData: Data([0x78]))
        })
        let seeds = try [small] + names.map { name in
            try ZipGoldenCorpus.decoded(XCTUnwrap(inputs.first { $0.id == name }).files[0])
        }
        let start = ContinuousClock.now
        for (seedIndex, seed) in seeds.enumerated() {
            var random = ZipDeterministicRandom(state: 0x50314b_f022 &+ UInt64(seedIndex))
            for iteration in 0..<300 {
                let bytes = random.mutate(seed, operation: iteration % 4)
                for reverse in [false, true] {
                    let left = ZipDifferentialSnapshot(bytes, reverse: reverse, spiFirst: false)
                    let right = ZipDifferentialSnapshot(bytes, reverse: reverse, spiFirst: true)
                    XCTAssertEqual(left, right, "seed=\(seedIndex) iteration=\(iteration) reverse=\(reverse)")
                }
            }
        }
        let duration = start.duration(to: .now)
        XCTAssertLessThan(duration, .seconds(60))
        print("ZIP-DIFFERENTIAL seeds=0x50314bf022...0x50314bf026 mutations=1500 seconds=\(duration)")
    }
}
