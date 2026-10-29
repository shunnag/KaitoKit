import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class UDIFChunkCacheConcurrencyTests: XCTestCase {
    private static let size = 512
    private static var chunks: [UDIFChunk] {
        (0..<4).map {
            UDIFChunk(kind: .zlib, sector: UInt64($0), sectorCount: 1, dataOffset: 0, dataLength: 1)
        }
    }

    func testCancelledInlineOrSerialLeafCannotPoisonSharedWorkOrLRU() async throws {
        for threads in [1, 2] {
            // No executor runs the submitted closure. Only the waiting Task can
            // claim a ticket after its poll, so cancellation has a known owner.
            let pool = LeafDecodePool(capacity: 1, executor: { _ in })
            let diagnostics = UDIFChunkCache.Diagnostics()
            let cache = UDIFChunkCache(chunks: Self.chunks, budget: 4 * Self.size,
                                      decodeThreads: threads, pool: pool, diagnostics: diagnostics)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let first = Mutex(true)
            let decode: UDIFChunkCache.Decode = { chunk, _ in
                if chunk.sector == 1, first.withLock({ value in
                    if !value { return false }; value = false; return true
                }) {
                    entered.signal()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw KaitoError.malformed("cancellation test gate timed out")
                    }
                }
                try Task.checkCancellation()
                return [UInt8](repeating: UInt8(chunk.sector), count: Self.size)
            }
            defer { release.signal(); cache.abandon() }
            // Also keep an unrelated, valid LRU entry throughout the retry.
            _ = try cache.read(0, sequential: false, decode: decode)
            cache.prefetch(after: 0, decode: decode)
            let cancelled = Task.detached { try cache.read(1, sequential: false, decode: decode).bytes }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            cancelled.cancel()
            release.signal()
            do { _ = try await cancelled.value; XCTFail("cancelled owner succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }

            // The poisoned Work is still shared/pending in the old code. A
            // fresh uncancelled consumer must retire it and decode again.
            do {
                let expected = [UInt8](repeating: 1, count: Self.size)
                XCTAssertEqual(try cache.read(1, sequential: false, decode: decode).bytes, expected)
                XCTAssertEqual(try cache.read(1, sequential: false, decode: decode).bytes, expected)
                XCTAssertEqual(diagnostics.decodeCount(1), 2)
                _ = try cache.read(0, sequential: false, decode: decode)
                XCTAssertEqual(diagnostics.decodeCount(0), 1)
            } catch {
                XCTFail("uncancelled consumer received \(error), threads=\(threads)")
            }
            XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, 4 * Self.size)
        }
    }

    func testDemandDoesNotWaitForOrRunUnstartedSpeculation() async throws {
        try await demandProgress(pool: LeafDecodePool(capacity: 1, executor: { _ in }), running: false)
    }

    func testDemandDoesNotWaitForRunningSpeculation() async throws {
        try await demandProgress(pool: LeafDecodePool(capacity: 1), running: true)
    }

    private func demandProgress(pool: LeafDecodePool, running: Bool) async throws {
        let diagnostics = UDIFChunkCache.Diagnostics()
        let cache = UDIFChunkCache(chunks: Self.chunks, budget: 4 * Self.size,
                                  decodeThreads: 2, pool: pool, diagnostics: diagnostics)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let decode: UDIFChunkCache.Decode = { chunk, _ in
            if chunk.sector == 1 || chunk.sector == 2 {
                entered.signal()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw KaitoError.malformed("speculation test gate timed out")
                }
            }
            return [UInt8](repeating: UInt8(chunk.sector), count: Self.size)
        }
        defer { release.signal(); release.signal(); cache.abandon() }
        cache.prefetch(after: 0, decode: decode)
        if running { XCTAssertEqual(entered.wait(timeout: .now() + 5), .success) }
        let demanded = Task.detached {
            defer { finished.signal() }
            return try cache.read(3, sequential: false, decode: decode).bytes
        }
        // Both speculative candidates are gated if the old arbitrary wait loop
        // chooses one. The result is independent of Dictionary iteration order.
        let progress = Self.waitForDemand(finished)
        XCTAssertEqual(progress, .success, "a demand must finish before speculative gates open")
        if progress == .success {
            XCTAssertEqual(diagnostics.decodeCount(1), running ? 1 : 0)
            XCTAssertEqual(diagnostics.decodeCount(2), 0, "a demand must not run another leaf inline")
            XCTAssertEqual(diagnostics.decodeCount(3), 1)
        }
        // Release even on failure so the regression cannot strand its Task.
        release.signal(); release.signal()
        let bytes = try await demanded.value
        XCTAssertEqual(bytes, [UInt8](repeating: 3, count: Self.size))
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, 4 * Self.size)
    }

    private static func waitForDemand(_ finished: DispatchSemaphore) -> DispatchTimeoutResult {
        finished.wait(timeout: .now() + 2)
    }
}
