import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class LeafDecodePoolTests: XCTestCase {
    func testInlinePendingJobDoesNotUseTheOccupiedSlot() {
        let executions = Mutex(0), queue = DispatchQueue(label: "KaitoKitTests.leafDecode")
        let pool = LeafDecodePool(capacity: 1, executor: { block in
            executions.withLock { $0 += 1 }; queue.async(execute: block)
        })
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        pool.submit(group: LeafDecodePool.Group()) {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        let calls = Mutex(0), thread = Mutex<ObjectIdentifier?>(nil)
        let caller = ObjectIdentifier(Thread.current)
        let ticket = pool.submit(group: LeafDecodePool.Group()) {
            calls.withLock { $0 += 1 }; thread.withLock { $0 = ObjectIdentifier(Thread.current) }
        }
        XCTAssertTrue(pool.runInline(ticket))
        XCTAssertEqual(thread.withLock { $0 }, caller)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(pool.runInline(ticket))
        XCTAssertEqual(pool.runningJobs, 1)
        XCTAssertEqual(pool.peakRunningJobs, 1)
        release.signal()
        let deadline = Date(timeIntervalSinceNow: 2)
        while pool.runningJobs > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(pool.runningJobs, 0)
        XCTAssertEqual(executions.withLock { $0 }, 1, "the inline job must be removed from pending")
        XCTAssertEqual(calls.withLock { $0 }, 1, "the gated worker must not pop the inline job again")
    }

    func testInlineDispatchedJobReleasesCapturesAndWorkerReturnsItsSlot() throws {
        let blocks = Mutex<[@Sendable () -> Void]>([])
        let pool = LeafDecodePool(capacity: 1, executor: { block in blocks.withLock { $0.append(block) } })
        let calls = Mutex(0), thread = Mutex<ObjectIdentifier?>(nil)
        let caller = ObjectIdentifier(Thread.current)
        var capture: CapturedInput? = CapturedInput()
        weak let queuedCapture = capture
        let ticket = pool.submit(group: LeafDecodePool.Group()) { [capture] in
            withExtendedLifetime(capture) {}
            calls.withLock { $0 += 1 }; thread.withLock { $0 = ObjectIdentifier(Thread.current) }
        }
        capture = nil
        XCTAssertNotNil(queuedCapture)
        XCTAssertEqual(blocks.withLock { $0.count }, 1)
        XCTAssertEqual(pool.runningJobs, 1)
        XCTAssertTrue(pool.runInline(ticket))
        XCTAssertNil(queuedCapture, "a retained ticket and Dispatch block must release executed input")
        XCTAssertEqual(thread.withLock { $0 }, caller)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(pool.runningJobs, 1, "only the Dispatch block returns its reserved slot")
        let block = try XCTUnwrap(blocks.withLock { $0.popLast() })
        block()
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(pool.runInline(ticket))
        XCTAssertEqual(pool.runningJobs, 0)
        XCTAssertEqual(pool.peakRunningJobs, 1)
        XCTAssertTrue(blocks.withLock { $0.isEmpty })
    }

    func testWorkerClaimPreventsInlineExecutionAndReleasesCaptures() throws {
        let blocks = Mutex<[@Sendable () -> Void]>([])
        let pool = LeafDecodePool(capacity: 1, executor: { block in blocks.withLock { $0.append(block) } })
        let calls = Mutex(0)
        var capture: CapturedInput? = CapturedInput()
        weak let queuedCapture = capture
        let ticket = pool.submit(group: LeafDecodePool.Group()) { [capture] in
            withExtendedLifetime(capture) {}; calls.withLock { $0 += 1 }
        }
        capture = nil
        let block = try XCTUnwrap(blocks.withLock { $0.popLast() })
        block()
        XCTAssertNil(queuedCapture)
        XCTAssertFalse(pool.runInline(ticket))
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(pool.runningJobs, 0)
    }

    private final class CapturedInput: Sendable {}
}
