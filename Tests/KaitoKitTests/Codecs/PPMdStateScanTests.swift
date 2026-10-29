@testable import KaitoKit
import XCTest

final class PPMdStateScanTests: XCTestCase {
    func testMaskedFrequencyExtremesAndSparseMasks() {
        for count in [1, 2, 3, 4, 5, 255, 256] {
            let capacity = count * 6 + 1
            let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            allocation.initialize(repeating: 255, count: capacity)
            defer {
                allocation.deinitialize(count: capacity)
                allocation.deallocate()
            }
            let states = allocation + 1
            for index in 0..<count { states[index * 6] = UInt8(index) }
            var mask = [UInt8](repeating: 0, count: 256)
            mask.withUnsafeMutableBufferPointer { mask in
                let maskBytes = mask.baseAddress!
                func check(_ expectedCount: Int, escapeCount: UInt8 = 1) {
                    let scan = PPMdStateScan.unmasked(in: states, count: count,
                        mask: maskBytes, escapeCount: escapeCount)
                    XCTAssertEqual(scan.count, expectedCount)
                    XCTAssertEqual(scan.frequency, expectedCount * 255)
                }
                check(count) // Includes the maximum sum, 256 * 255 = 65,280.
                maskBytes.update(repeating: 1, count: 256)
                check(0)
                mask[0] = 0
                mask[count - 1] = 0
                check(min(2, count))
                maskBytes.update(repeating: 1, count: 256)
                for index in stride(from: 0, to: count, by: 2) { mask[index] = 0 }
                check((count + 1) / 2)
                check(count / 2, escapeCount: 0)
                check(count, escapeCount: 255)
            }
        }
    }

    func testEveryStateCountAndSymbolInAnExactUnalignedSpan() {
        for count in 1...256 {
            let capacity = count * 6 + 1
            let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            allocation.initialize(repeating: 0xA5, count: capacity)
            defer {
                allocation.deinitialize(count: capacity)
                allocation.deallocate()
            }
            // Leave no readable tail beyond the last packed state: ASan also
            // checks the four-state groups and all three possible tail sizes.
            let states = allocation + 1
            for index in 0..<count { states[index * 6] = UInt8(index) }
            for symbol in 0...255 {
                XCTAssertEqual(PPMdStateScan.index(of: UInt8(symbol), in: states, count: count),
                               symbol < count ? symbol : nil, "count \(count), symbol \(symbol)")
            }
            if count > 1 {
                states[6] = states[0]
                XCTAssertEqual(PPMdStateScan.index(of: states[0], in: states, count: count), 0)
            }
        }
    }
}
