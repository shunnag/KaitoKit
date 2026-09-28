import Foundation
@testable import KaitoKit
import XCTest

final class PPMdVarIMemoryTests: XCTestCase {
    private let invalidReference = KaitoError.malformed("invalid PPMd var.I arena reference")

    func testSixByteStateBoundsIncludeUnalignedEnd() throws {
        let arena = try PPMdVarISuballocator(memorySize: 1 << 20)
        let end = UInt32(arena.end)
        for offset in [UInt32(12), arena.unitsStart, arena.unitsStart + 2, end - 6] {
            XCTAssertEqual(try arena.checkedInt(offset, count: 6), Int(offset))
            try arena.put8(0xAB, offset)
            try arena.put8(0xCD, offset + 1)
            try arena.put32(0x12345678, offset + 2)
            XCTAssertEqual(try arena.get8(offset), 0xAB)
            XCTAssertEqual(try arena.get8(offset + 1), 0xCD)
            XCTAssertEqual(try arena.get32(offset + 2), 0x12345678)
        }
        for offset in [UInt32(0), 11, end - 5, end - 1, end, end + 1, UInt32.max] {
            XCTAssertThrowsError(try arena.checkedInt(offset, count: 6)) {
                XCTAssertEqual($0 as? KaitoError, self.invalidReference)
            }
        }
    }

    func testStatsBoundsAndUnitAlignmentForEveryStateCount() throws {
        let arena = try PPMdVarISuballocator(memorySize: 1 << 20)
        for n in 0...255 {
            let count = 6 * (n + 1)
            let base = UInt32(arena.end - 12 * ((count + 11) / 12))
            XCTAssertNoThrow(try arena.requireUnit(base, count: count))
            for offset in [base + 1, base + 12, arena.unitsStart - 12] {
                XCTAssertThrowsError(try arena.requireUnit(offset, count: count)) {
                    XCTAssertEqual($0 as? KaitoError, self.invalidReference)
                }
            }
        }
    }

    func testReleasedArenaRejectsStateAndStatsChecks() throws {
        let arena = try PPMdVarISuballocator(memorySize: 1 << 20)
        let base = try arena.allocateUnits(128)
        XCTAssertNoThrow(try arena.requireUnit(base, count: 6 * 256))
        arena.release()
        arena.release()
        XCTAssertTrue(arena.isReleased)
        for count in [1, 6, 12, 6 * 256] {
            XCTAssertThrowsError(try arena.checkedInt(base, count: count)) {
                XCTAssertEqual($0 as? KaitoError, self.invalidReference)
            }
            XCTAssertThrowsError(try arena.requireUnit(base, count: count)) {
                XCTAssertEqual($0 as? KaitoError, self.invalidReference)
            }
        }
        let model = try PPMdVarIModel(maximumOrder: 8, memorySize: 1 << 20, restoreMethod: 0)
        let decoder = try PPMdVarIRangeDecoder(source: DataByteSource(Data(repeating: 0, count: 4)),
                                              offset: 0, endOffset: 4)
        model.releaseArena()
        XCTAssertThrowsError(try model.decodeByte(using: decoder)) {
            XCTAssertEqual($0 as? KaitoError, self.invalidReference)
        }
    }

    func testRepeatedModelInitializationAndRelease() throws {
        for order in [2, 8, 16] {
            for restore in 0...2 {
                for iteration in 0..<8 {
                    weak var released: PPMdVarIModel?
                    do {
                        let model = try PPMdVarIModel(maximumOrder: order, memorySize: 1 << 20,
                                                     restoreMethod: restore)
                        released = model
                        XCTAssertFalse(model.isArenaReleased)
                        if iteration.isMultiple(of: 2) {
                            model.releaseArena()
                            XCTAssertTrue(model.isArenaReleased)
                        }
                    }
                    XCTAssertNil(released)
                }
            }
        }
        let invalidSizes: [UInt64] = [0, (1 << 20) - 1, (256 << 20) + 1, .max]
        for memory in invalidSizes {
            XCTAssertThrowsError(try PPMdVarIModel(maximumOrder: 8, memorySize: memory, restoreMethod: 0)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("invalid PPMd var.I arena size"))
            }
        }
        for (order, restore) in [(1, 0), (17, 0), (8, -1), (8, 3)] {
            XCTAssertThrowsError(try PPMdVarIModel(maximumOrder: order, memorySize: 1 << 20,
                                                 restoreMethod: restore)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("PPMd var.I: invalid model parameters"))
            }
        }
    }
}
