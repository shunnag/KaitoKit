import Foundation
import Darwin
@testable import KaitoKit
import XCTest

final class CRC16FoldingTests: XCTestCase {
    private func data(_ count: Int) -> [UInt8] {
        var random: UInt64 = 0x9E3779B9C16A001
        return (0..<count).map { _ in
            random = random &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: random >> 32)
        }
    }

    private func split(_ input: UnsafeRawBufferPointer, initial: UInt16,
                       chunks: [Int], folding: Bool = true) -> UInt16 {
        var state = initial
        var offset = 0
        var chunk = 0
        while offset < input.count {
            let end = offset + min(chunks[chunk % chunks.count], input.count - offset)
            state = CRC16.update(UnsafeRawBufferPointer(rebasing: input[offset..<end]),
                                 initial: state, folding: folding)
            offset = end
            chunk += 1
        }
        return state
    }

    func testEveryLengthSeedsAndPartitions() {
        let bytes = data(4096 + 64)
        bytes.withUnsafeBytes { raw in
            for length in 0...4096 {
                let offset = length % 64
                let input = UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + length)])
                for seed in [UInt16(0), 0xFFFF, UInt16(truncatingIfNeeded: length &* 40503 &+ 173)] {
                    let old = CRC16.update(input, initial: seed, folding: false)
                    XCTAssertEqual(CRC16.update(input, initial: seed, folding: true), old,
                                   "length=\(length) offset=\(offset) seed=\(seed)")
                    XCTAssertEqual(split(input, initial: seed, chunks: [1]), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [257]), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [63, 1, 65, 127, 128, 129, 15, 16, 17]), old)
                }
                // Exercise the actual incremental value-storing API as well.
                var crc = CRC16()
                let cut = min(length, 129)
                crc.update(UnsafeRawBufferPointer(rebasing: input[..<cut]))
                crc.update(UnsafeRawBufferPointer(rebasing: input[cut...]))
                XCTAssertEqual(crc.value, CRC16.update(input, initial: 0, folding: false))
            }
        }
    }

    func testLargeBuffersSeedsAndPartitions() {
        for length in [65536, 1048576, 16777216] {
            data(length).withUnsafeBytes { input in
                for seed: UInt16 in [0, 0xFFFF, 0x93D7] {
                    let old = CRC16.update(input, initial: seed, folding: false)
                    XCTAssertEqual(CRC16.update(input, initial: seed, folding: true), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [1]), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [4093]), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [127, 129, 65535, 65537]), old)
                    XCTAssertEqual(split(input, initial: seed, chunks: [65537], folding: false), old)
                }
            }
        }
    }

    func testAllAlignmentsAndGuardPageTails() throws {
        let page = Int(getpagesize())
        let mapping = try XCTUnwrap(mmap(nil, page * 3, PROT_READ | PROT_WRITE,
                                         MAP_ANON | MAP_PRIVATE, -1, 0))
        guard mapping != MAP_FAILED else { XCTFail("mmap failed"); return }
        defer { munmap(mapping, page * 3) }
        XCTAssertEqual(mprotect(mapping, page, PROT_NONE), 0)
        XCTAssertEqual(mprotect(mapping + 2 * page, page, PROT_NONE), 0)
        let start = mapping + page
        data(page).withUnsafeBytes { start.copyMemory(from: $0.baseAddress!, byteCount: page) }
        // Input ends exactly at an unreadable page, covering every alignment and
        // all 16/64/128-byte loop and dispatch boundaries without readable padding.
        for length in Array(0...320) + [511, 512, 513, 1023, 1024, 1025, page] {
            for base in [start, start + page - length] {
                let input = UnsafeRawBufferPointer(start: base, count: length)
                XCTAssertEqual(CRC16.update(input, initial: 0xFFFF, folding: true),
                               CRC16.update(input, initial: 0xFFFF, folding: false))
            }
        }
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        XCTAssertEqual(CRC16.update(empty, initial: 0x1234, folding: true), 0x1234)
    }
}
