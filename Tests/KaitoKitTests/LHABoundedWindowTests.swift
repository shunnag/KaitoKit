import Foundation
@testable import KaitoKit
import XCTest

final class LHABoundedWindowTests: XCTestCase {
    func testEveryRingPositionDistanceAndChunkAgainstForwardCopy() {
        let size = 32
        let window = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 100)
        defer { window.deallocate(); output.deallocate() }
        let initial = (0..<size).map { UInt8($0 * 7) }
        for start in 0..<size {
            for distance in 1...size {
                for length in [1, 2, 3, 7, 8, 9, 31, 32, 33, 97] {
                    for chunk in [1, 3, 8, 17, 100] {
                        var reference = initial
                        var expected: [UInt8] = []
                        var position = start
                        for _ in 0..<length {
                            let byte = reference[(position - distance) & (size - 1)]
                            reference[position] = byte
                            position = (position + 1) & (size - 1)
                            expected.append(byte)
                        }
                        initial.withUnsafeBufferPointer {
                            window.update(from: $0.baseAddress!, count: size)
                        }
                        var actualPosition = start
                        var remaining = length
                        var count = 0
                        while remaining > 0 {
                            lhaCopyMatch(
                                window: window, windowMask: size - 1,
                                windowPosition: &actualPosition, distance: distance,
                                remaining: &remaining, output: output,
                                outputPosition: &count, outputLimit: min(length, count + chunk)
                            )
                        }
                        XCTAssertEqual(Array(UnsafeBufferPointer(start: output, count: count)), expected)
                        XCTAssertEqual(Array(UnsafeBufferPointer(start: window, count: size)), reference)
                        XCTAssertEqual(actualPosition, position)
                    }
                }
            }
        }
    }
}
