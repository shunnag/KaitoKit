import XCTest
@testable import KaitoKit

final class HeaderReadPlannerTests: XCTestCase {
    func testLocalSourcesUseFixedSixteenKiB() {
        var planner = HeaderReadPlanner(.fixed(16 << 10))
        planner.noteBlock(offset: 0, nextOffset: 4096)
        XCTAssertEqual(planner.windowSize(offset: 0, request: 7, length: 2 << 20), 16 << 10)
    }
    func testHopUntilMedianSpacingAtMostSixtyFourKiB() {
        var planner = HeaderReadPlanner(.adaptive)
        XCTAssertEqual(planner.windowSize(offset: 0, request: 7, length: 4 << 20), 16 << 10)
        planner.noteBlock(offset: 0, nextOffset: 600 << 10)
        XCTAssertEqual(planner.windowSize(offset: 1 << 20, request: 7, length: 4 << 20), 16 << 10)
        for _ in 0..<3 { planner.noteBlock(offset: 0, nextOffset: 4096) }
        XCTAssertEqual(planner.windowSize(offset: 2 << 20, request: 7, length: 4 << 20), 256 << 10)
    }
    func testStreamWindowClampedBetween256KiBAnd1MiB() {
        for (spacing, expected) in [(1, 256 << 10), (64 << 10, 1 << 20)] {
            var planner = HeaderReadPlanner(.adaptive)
            _ = planner.windowSize(offset: 0, request: 7, length: 4 << 20)
            planner.noteBlock(offset: 0, nextOffset: UInt64(spacing))
            XCTAssertEqual(planner.windowSize(offset: 1 << 20, request: 7, length: 4 << 20), expected)
        }
    }
    func testSingleLargeSpacingDoesNotLeaveStreamMode() {
        var planner = HeaderReadPlanner(.adaptive)
        for spacing in [4096, 4096, 900_000, 4096] { planner.noteBlock(offset: 0, nextOffset: UInt64(spacing)) }
        _ = planner.windowSize(offset: 0, request: 1, length: 4 << 20)
        XCTAssertEqual(planner.windowSize(offset: 1 << 20, request: 1, length: 4 << 20), 256 << 10)
    }
    func testMaximumSpacingWaitsForFullHistoryAndKeepsLargeSkips() {
        var planner = HeaderReadPlanner(.adaptive, minimumWindowSize: 4096, spacingEstimate: .maximum)
        XCTAssertEqual(planner.windowSize(offset: 0, request: 4096, length: 16 << 20), 4096)
        for _ in 0..<7 {
            planner.noteBlock(offset: 0, nextOffset: 1024)
            XCTAssertEqual(planner.windowSize(offset: 1 << 20, request: 4096, length: 16 << 20), 4096)
        }
        planner.noteBlock(offset: 0, nextOffset: 1024)
        XCTAssertEqual(planner.windowSize(offset: 1 << 20, request: 4096, length: 16 << 20), 256 << 10)
        planner.noteBlock(offset: 0, nextOffset: 4 << 20)
        for _ in 0..<3 {
            planner.noteBlock(offset: 0, nextOffset: 1024)
            XCTAssertEqual(planner.windowSize(offset: 2 << 20, request: 4096, length: 16 << 20), 4096)
        }
        planner.noteBlock(offset: 0, nextOffset: 1024)
        XCTAssertEqual(planner.windowSize(offset: 2 << 20, request: 4096, length: 16 << 20), 256 << 10)
    }
    func testWholeFileWindowAtOrBelowOneMiB() {
        for length in [123, 1 << 20] {
            var planner = HeaderReadPlanner(.adaptive)
            XCTAssertEqual(planner.windowSize(offset: 0, request: 1, length: UInt64(length)), length)
        }
    }
    func testWindowCoversRequestAndStopsAtLength() {
        var planner = HeaderReadPlanner(.fixed(16 << 10))
        XCTAssertEqual(planner.windowSize(offset: 0, request: 2 << 20, length: 4 << 20), 2 << 20)
        XCTAssertEqual(planner.windowSize(offset: 90, request: 200, length: 100), 10)
        XCTAssertEqual(planner.windowSize(offset: 100, request: 200, length: 100), 0)
    }
}
