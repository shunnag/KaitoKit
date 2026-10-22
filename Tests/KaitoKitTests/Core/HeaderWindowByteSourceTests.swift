import Foundation
import XCTest
@testable import KaitoKit

final class HeaderWindowByteSourceTests: XCTestCase {
    func testRandomReadsMatchBaseBytes() throws {
        let data = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 71) })
        let base = DataByteSource(data: data)
        let window = HeaderWindowByteSource(base: base, planner: HeaderReadPlanner(.adaptive))
        var seed: UInt64 = 943
        for _ in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1
            let offset = Int(seed % UInt64(data.count + 1024))
            seed = seed &* 6364136223846793005 &+ 1
            let requested = Int(seed % 4096)
            let count = min(requested, max(0, data.count - offset))
            var bytes = [UInt8](repeating: 0, count: requested)
            let actual = try bytes.withUnsafeMutableBytes { try window.read(into: $0, at: UInt64(offset)) }
            XCTAssertLessThanOrEqual(actual, count)
            XCTAssertEqual(Array(bytes.prefix(actual)), Array(data.dropFirst(offset).prefix(actual)))
            if actual < count {
                XCTAssertEqual(try readByteRange(source: window, offset: UInt64(offset + actual), count: count - actual), Array(data[(offset + actual)..<(offset + count)]))
            }
        }
    }

    func testShortBaseReadsAndEOFMatchBase() throws {
        let base = ShortSource()
        let window = HeaderWindowByteSource(base: base, planner: HeaderReadPlanner(.adaptive))
        XCTAssertEqual(try readByteRange(source: window, offset: 0, count: 27), Array(0..<27))
        var bytes = [UInt8](repeating: 0, count: 50)
        XCTAssertEqual(try bytes.withUnsafeMutableBytes { try window.read(into: $0, at: 25) }, 2)
        XCTAssertEqual(try bytes.withUnsafeMutableBytes { try window.read(into: $0, at: 27) }, 0)
        let truncated = HeaderWindowByteSource(base: ShortSource(length: 40), planner: HeaderReadPlanner(.adaptive))
        XCTAssertThrowsError(try readByteRange(source: truncated, offset: 0, count: 28)) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
    }

    func testBaseErrorsPropagateUnchanged() {
        let window = HeaderWindowByteSource(base: ShortSource(fails: true), planner: HeaderReadPlanner(.adaptive))
        XCTAssertThrowsError(try readByteRange(source: window, offset: 0, count: 1)) { XCTAssertEqual($0 as? KaitoError, .io(5)) }
    }

    func testSeededRegionsServeWithoutBaseReads() throws {
        let base = CallCountingByteSource(DataByteSource(data: Data(0..<100)))
        let window = HeaderWindowByteSource(base: base, planner: HeaderReadPlanner(.fixed(16 << 10)))
        window.seed(offset: 10, bytes: Array(10..<20))
        window.seed(offset: 70, bytes: Array(70..<80))
        XCTAssertEqual(try readByteRange(source: window, offset: 12, count: 8), Array(12..<20))
        XCTAssertEqual(try readByteRange(source: window, offset: 70, count: 10), Array(70..<80))
        XCTAssertEqual(base.readCount, 0)
    }

    func testWindowNeverExceedsOneMebibyte() throws {
        let base = CallCountingByteSource(DataByteSource(data: Data(repeating: 9, count: 4 << 20)))
        let window = HeaderWindowByteSource(base: base, planner: HeaderReadPlanner(.adaptive))
        _ = try readByteRange(source: window, offset: 0, count: 1)
        window.noteBlock(offset: 0, nextOffset: 32 << 10)
        base.reset()
        _ = try readByteRange(source: window, offset: 1 << 20, count: 1)
        XCTAssertEqual(base.readBytes, 1 << 20)
    }
}

private struct ShortSource: ByteSource {
    let fails: Bool
    let length: UInt64
    init(fails: Bool = false, length: UInt64 = 27) { self.fails = fails; self.length = length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        if fails { throw KaitoError.io(5) }
        guard offset < min(length, 27) else { return 0 }
        let count = min(3, buffer.count, Int(min(length, 27) - offset))
        for index in 0..<count { buffer[index] = UInt8(offset) + UInt8(index) }
        return count
    }
}
