import Foundation
@testable import KaitoKit
import XCTest

final class CRC16Tests: XCTestCase {
    func testARCCheckValue() {
        XCTAssertEqual(CRC16.checksum(Array("123456789".utf8)), 0xBB3D)
        XCTAssertEqual(CRC16.checksum([]), 0)
    }

    func testSlicesAlignmentsAndIncrementalUpdatesAgainstBitSerialReference() {
        var seed: UInt64 = 0xC16_A001
        var bytes = [UInt8](repeating: 0, count: 8192 + 16)
        for index in bytes.indices {
            seed = seed &* 6364136223846793005 &+ 1
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 32)
        }
        for alignment in 0..<16 {
            for count in Array(0...80) + [127, 255, 256, 257, 1023, 4096, 8192] {
                bytes.withUnsafeBytes { raw in
                    let input = UnsafeRawBufferPointer(rebasing: raw[alignment..<(alignment + count)])
                    let expected = reference(input)
                    var crc = CRC16()
                    crc.update(input)
                    XCTAssertEqual(crc.value, expected, "offset \(alignment), length \(count)")
                    for split in [0, count / 3, count / 2, count] {
                        var incremental = CRC16()
                        incremental.update(UnsafeRawBufferPointer(rebasing: input[..<split]))
                        incremental.update(UnsafeRawBufferPointer(rebasing: input[split...]))
                        XCTAssertEqual(incremental.value, expected)
                    }
                }
            }
        }
    }

    private func reference(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                let mask = UInt16(bitPattern: -Int16(crc & 1))
                crc = (crc >> 1) ^ (0xA001 & mask)
            }
        }
        return crc
    }
}
