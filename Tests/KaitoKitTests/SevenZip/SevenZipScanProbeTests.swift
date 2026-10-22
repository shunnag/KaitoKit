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

    private func fixture(units: Int = 200) -> SevenZipParallelTestSupport.Fixture {
        SevenZipParallelTestSupport.raw(sizes: Array(repeating: 17, count: units))
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

    func testWarmProbeCompletesDespiteSingleStalledRead() throws {
        for stalledLatency: UInt64 in [10_000_000, 15_000_000] {
            let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
            let clock = Clock { $0 == 300 ? stalledLatency : 50_000 }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                scanClock: { clock.now() })
            XCTAssertEqual(try factory.parallelUnits()?.count, 200)
            XCTAssertEqual(clock.reads, 601)
            XCTAssertEqual(try factory.parallelUnits()?.count, 200)
            XCTAssertEqual(clock.reads, 601)
        }
    }

    func testWarmProbeCompletesDespiteTwoStalledReadsWithin16Reads() throws {
        for baseLatency: UInt64 in [40_000, 50_000] {
            for stalledLatency: UInt64 in [4_000_000, 20_000_000] {
                let fixture = fixture(units: 2_000)
                let source = RecordingSource(DataByteSource(fixture.packed))
                // 先頭の窓と走査途中の両方で、同じ窓に一時停止を二つ入れる。
                let clock = Clock { [0, 7, 300, 307].contains($0) ? stalledLatency : baseLatency }
                let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                    scanClock: { clock.now() })
                let coordinator = SevenZipFolderCoordinator(factory: factory)
                XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
                XCTAssertEqual(clock.reads, 0)
                XCTAssertEqual(try read(coordinator, index: 1), fixture.payloads[1])
                XCTAssertEqual(try factory.parallelUnits()?.count, 2_000,
                    "通常\(baseLatency)ns・一時停止\(stalledLatency)nsでも並列走査を完了する")
                XCTAssertEqual(clock.reads, 6_001)
            }
        }
    }

    func testProbeAbortsWithSparseNineMillisecondReads() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 % 16 == 0 ? 9_000_000 : 200_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            scanClock: { clock.now() })
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
        XCTAssertEqual(clock.reads, 0)
        XCTAssertEqual(try read(coordinator, index: 1), fixture.payloads[1])
        // 生の平均が約 0.75 ms の入力は、疎な遅延でも全体を走査しない。
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertLessThanOrEqual(clock.reads, 300)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsWithSparseSixMillisecondReads() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 % 12 == 0 ? 6_000_000 : 50_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertGreaterThan(clock.reads, 16)
        XCTAssertLessThanOrEqual(clock.reads, 300)
        XCTAssertEqual(source.reads.count, clock.reads)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsWithDenseNineMillisecondReadsAfterFastPrefix() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 >= 90 && $0 % 3 == 0 ? 9_000_000 : 50_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertGreaterThan(clock.reads, 90)
        XCTAssertLessThanOrEqual(clock.reads, 100)
        XCTAssertEqual(source.reads.count, clock.reads)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsForSparseColdReadsAfterFastPrefix() throws {
        let patterns: [(name: String, period: Int, latency: UInt64)] = [
            ("ad60-20", 20, 17_000_000),
            ("ad60-30", 30, 17_000_000),
            ("ad60-45", 45, 50_000_000),
            ("moon-10", 10, 15_000_000),
            ("moon-8", 8, 15_000_000)
        ]
        for pattern in patterns {
            let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
            let cache = SevenZipLZMA2ResetIndexCache()
            let clock = Clock { read in
                read >= 265 && (read - 265) % pattern.period == 0 ? pattern.latency : 50_000
            }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                resetIndexCache: cache, scanClock: { clock.now() })
            XCTAssertNil(try factory.parallelUnits(), pattern.name)
            XCTAssertGreaterThan(clock.reads, 265, pattern.name)
            XCTAssertLessThanOrEqual(clock.reads, 512, "\(pattern.name): 全 6,001 回まで走査しない")
            XCTAssertEqual(source.reads.count, clock.reads, pattern.name)
            XCTAssertGreaterThan(cache.observedCoverage, 17, pattern.name)
            let stoppedReads = clock.reads
            XCTAssertNil(try factory.parallelUnits(), pattern.name)
            XCTAssertEqual(clock.reads, stoppedReads, "\(pattern.name): 打ち切り後は再走査しない")
        }
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

    func testProbeDoesNotLetCachedFirstWindowHideColdReads() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache()
        let clock = Clock { $0 < 16 ? 100_000 : 1_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        // 先頭のキャッシュ済み 16 回を通過しても、冷えた領域では短い窓で止める。
        XCTAssertEqual(clock.reads, 25)
        XCTAssertEqual(source.reads.count, 25)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, 25)
    }

    func testProbeAbortsOnRollingWindowAfterFastPrefix() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache()
        let clock = Clock { $0 < 256 ? 100_000 : 1_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        // 最長の 2 回を除いても、遅い read が 9 回入れば残る平均が 0.5 ms を超える。
        XCTAssertEqual(clock.reads, 265)
        XCTAssertEqual(source.reads.count, 265)
        XCTAssertEqual(cache.observedPoints.count, 88)
        XCTAssertEqual(cache.observedCoverage, 88 * 17)
    }

    func testProbeAbortsAfterConsecutiveColdReadsAndCachesDecision() throws {
        for slowStart in [0, 16] {
            let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
            let cache = SevenZipLZMA2ResetIndexCache()
            let clock = Clock { $0 < slowStart ? 100_000 : 9_000_000 }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                resetIndexCache: cache, scanClock: { clock.now() })
            // 二つの一時停止は許容しても、三つ目の冷えた read で止める。
            let expectedReads = slowStart + 3
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.reads, expectedReads)
            XCTAssertEqual(source.reads.count, expectedReads)
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.reads, expectedReads)
        }
    }

    func testBackwardSeekUsesScanObservationsAfterAbort() throws {
        var fixture = fixture(); fixture.folderCRC = nil
        let source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 500_001 }
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
