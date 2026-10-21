import Foundation
import XCTest
@testable import KaitoKit

final class SevenZipScanProbeTests: XCTestCase {
    typealias RecordingSource = SevenZipLZMA2ResetIndexTests.RecordingSource

    // 実際には待たず、pread ごとの遅延を単調時計へ注入する。
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private let latency: @Sendable (Int) -> UInt64
        private var ticks: UInt64 = 0
        private var calls = 0
        var reads: Int { lock.withLock { calls / 2 } }
        init(latency: @escaping @Sendable (Int) -> UInt64) { self.latency = latency }
        func now() -> UInt64 {
            lock.withLock {
                if calls % 2 == 1 { ticks += latency(calls / 2) }
                calls += 1
                return ticks
            }
        }
    }

    private func fixture() -> SevenZipParallelTestSupport.Fixture {
        SevenZipParallelTestSupport.raw(sizes: Array(repeating: 17, count: 200))
    }

    private func read(_ coordinator: SevenZipFolderCoordinator, index: Int) throws -> Data {
        try EntryStream(decompressor: coordinator.stream(offset: UInt64(index * 17), length: 17),
                        length: 17, expectedCRC32: nil, entryIndex: index, limits: ReadLimits()).readAll()
    }

    func testProbePassesAndParallelDecodeStartsAfterFirstSerialPage() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 500_000 }
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let factory = try fixture.factory(workers: 4, diagnostics: diagnostics, source: source,
            avoidsHeaderScans: true, resetIndexCache: cache, scanClock: { clock.now() })
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
        XCTAssertEqual(clock.reads, 0)
        XCTAssertFalse(source.reads.contains { $0.offset == 1 && $0.count == 1 })
        for index in [1, 100, 99] {
            XCTAssertEqual(try read(coordinator, index: index), fixture.payloads[index])
        }
        XCTAssertEqual(clock.reads, 601)
        XCTAssertEqual(try factory.parallelUnits()?.count, 200)
        XCTAssertGreaterThan(diagnostics.peakHeldBytes, 0)
        XCTAssertEqual(coordinator.lastBackwardRestart, .head)
    }

    func testProbeAbortsAfterFirst16ReadsAndCachesDecision() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 500_001 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, 16)
        XCTAssertEqual(source.reads.count, 16)
        XCTAssertEqual(cache.observedPoints.map(\.uncompressedOffset), [0, 17, 34, 51, 68])
        XCTAssertEqual(cache.observedCoverage, 85)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 68)?.uncompressedOffset, 68)
        XCTAssertEqual(factory.lastBackwardRestartKind, .observed)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, 16)
    }

    func testProbeAbortsOnRollingWindowAfterFastPrefix() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache()
        let clock = Clock { $0 < 256 ? 100_000 : 1_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        // 最後の 256 回に遅い read が 114 回入ると、平均が 0.5 ms を超える。
        XCTAssertEqual(clock.reads, 370)
        XCTAssertEqual(source.reads.count, 370)
        XCTAssertEqual(cache.observedPoints.count, 123)
        XCTAssertEqual(cache.observedCoverage, 123 * 17)
    }

    func testProbeAbortsAsSoonAsRollingBudgetIsExceeded() throws {
        for slowRead in [0, 16] {
            let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
            let cache = SevenZipLZMA2ResetIndexCache()
            let clock = Clock { $0 == slowRead ? 256 * 500_000 + 1 : 100_000 }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                resetIndexCache: cache, scanClock: { clock.now() })
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.reads, slowRead + 1)
            XCTAssertEqual(source.reads.count, slowRead + 1)
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.reads, slowRead + 1)
        }
    }

    func testBackwardSeekUsesScanObservationsAfterAbort() throws {
        var fixture = fixture(); fixture.folderCRC = nil
        let source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 1_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
        XCTAssertEqual(cache.observedCoverage, 17)
        XCTAssertNil(try factory.parallelUnits())
        // 直列復号が届いていない位置を先に確かめ、走査の観測がない実装を通さない。
        XCTAssertEqual(cache.observedCoverage, 85)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 51)?.uncompressedOffset, 51)
        XCTAssertEqual(factory.lastBackwardRestartKind, .observed)
        XCTAssertEqual(try read(coordinator, index: 100), fixture.payloads[100])
        XCTAssertEqual(clock.reads, 16)
        XCTAssertEqual(try read(coordinator, index: 3), fixture.payloads[3])
        XCTAssertEqual(coordinator.lastBackwardRestart, .observed)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 51)?.uncompressedOffset, 51)
        XCTAssertEqual(clock.reads, 16)
    }

    func testLowLatencyDoesNotConsultProbeClock() throws {
        let fixture = fixture(), clock = Clock { _ in 100_000_000 }
        let factory = try fixture.factory(workers: 4, scanClock: { clock.now() })
        XCTAssertEqual(try factory.parallelUnits()?.count, 200)
        XCTAssertEqual(clock.reads, 0)
    }
}
