import Foundation
import XCTest
@testable import KaitoKit

final class SevenZipScanProbeTests: XCTestCase {
    typealias RecordingSource = SevenZipLZMA2ResetIndexTests.RecordingSource

    // header 先頭の cold read にだけ遅延を注入し、後続 read は warm（零）にする。
    // physical read 数は batching 前後で異なっても、同じ header の遅延列を使う。
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private let latency: @Sendable (Int) -> UInt64
        private let warmLatency: UInt64
        private let readsPerHeader: [Int]
        private var ticks: UInt64 = 0
        private var calls = 0, header = 0, withinHeader = 0
        var reads: Int { lock.withLock { calls / 2 } }
        var headers: Int { lock.withLock { header + (withinHeader > 0 ? 1 : 0) } }
        init(readsPerHeader: [Int] = [], warmLatency: UInt64 = 0,
             latency: @escaping @Sendable (Int) -> UInt64) {
            self.readsPerHeader = readsPerHeader; self.latency = latency; self.warmLatency = warmLatency
        }
        func now() -> UInt64 {
            lock.withLock {
                if calls % 2 == 1 {
                    ticks += withinHeader == 0 ? latency(header) : warmLatency
                    withinHeader += 1
                    let count = header < readsPerHeader.count ? readsPerHeader[header] : 2
                    if withinHeader == count { header += 1; withinHeader = 0 }
                }
                calls += 1
                return ticks
            }
        }
    }

    // batching 前の read ごとの方針を独立に評価する。窓を slice して集計し、
    // production の ring 更新や header weighting を再利用しない。入力も 1 byte ずつ読む。
    private final class LegacyTimedSource: ByteSource, @unchecked Sendable {
        private let source: DataByteSource
        private let clock: Clock
        private var samples: [UInt64] = []
        var length: UInt64 { source.length }
        init(_ packed: Data, clock: Clock) { source = DataByteSource(packed); self.clock = clock }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let start = clock.now()
            // prefix(1) は元 buffer の範囲内で、高々一つの書き込み可能 byte だけを渡す。
            let actual = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(1)), at: offset)
            samples.append(clock.now() &- start)
            if samples.count > 256 { samples.removeFirst() }
            let short = samples.suffix(16).map { min($0, 7_000_001) }.sorted(by: >)
            let trimmed = short.dropFirst(2).reduce(UInt64(0), +)
            let stall = samples.reduce(UInt64(0)) {
                $0 + min($1 > 4_000_000 ? $1 - 4_000_000 : 0, 96_000_001)
            }
            let raw = samples.reduce(UInt64(0)) { $0 + min($1, 128_000_001) }
            if trimmed > 7_000_000 || stall > 96_000_000 || raw > 128_000_000 {
                throw LZMA2TimedScanSource.TooSlow()
            }
            return actual
        }
    }

    private enum HeaderKind: CaseIterable {
        case raw, compressed, properties
        var legacyReads: Int {
            switch self { case .raw: 3; case .compressed: 5; case .properties: 6 }
        }
        var shortThreshold: UInt64 {
            switch self { case .raw: 1_750_000; case .compressed: 3_500_000; case .properties: 7_000_000 }
        }
    }
    private struct Headers {
        let packed: Data
        let outputSize: UInt64
        let legacyReads: [Int]
        let batchedReads: [Int]
    }
    private enum Decision: Equatable { case complete, aborted(header: Int) }

    private func headers(_ kind: HeaderKind, count: Int) throws -> Headers {
        if kind == .raw {
            let fixture = fixture(units: count)
            return Headers(packed: fixture.packed, outputSize: UInt64(count * 17),
                legacyReads: Array(repeating: 3, count: count) + [1],
                batchedReads: Array(repeating: 2, count: count) + [1])
        }
        let first = Data(try Hex.data("e00011000800003099abddc0cb070000").dropLast())
        var continued = first
        if kind == .compressed { continued[0] = 0xA0; continued.remove(at: 5) }
        var packed = first
        for _ in 1..<count { packed.append(continued) }
        packed.append(0)
        return Headers(packed: packed, outputSize: UInt64(count * 18),
            legacyReads: [6] + Array(repeating: kind.legacyReads, count: count - 1) + [1],
            batchedReads: [3] + Array(repeating: kind == .compressed ? 2 : 3, count: count - 1) + [1])
    }

    private func decision(_ headers: Headers, latency: UInt64, legacy: Bool) throws -> Decision {
        let count = headers.legacyReads.count - 1
        let clock = Clock(readsPerHeader: legacy ? headers.legacyReads : headers.batchedReads) {
            $0 < count ? latency : 0
        }
        let source: any ByteSource = legacy ? LegacyTimedSource(headers.packed, clock: clock)
            : LZMA2TimedScanSource(source: DataByteSource(headers.packed), clock: { clock.now() })
        do {
            let index = try LZMA2Decoder.makeParallelDictionaryResetIndex(source: source, offset: 0,
                compressedSize: UInt64(headers.packed.count), expectedSize: headers.outputSize,
                maximumPointCount: 10_000, singleResetOutputLimit: UInt64.max)
            XCTAssertNotNil(index)
            XCTAssertEqual(clock.reads, (legacy ? headers.legacyReads : headers.batchedReads).reduce(0, +))
            return .complete
        } catch is LZMA2TimedScanSource.TooSlow {
            return .aborted(header: clock.headers)
        }
    }

    func testColdHeaderShortThresholdMatchesOldOneByteCadence() throws {
        // 短い burst なので raw / stall 窓は予算内。旧 16 read 窓には raw 6 / LZMA 4 /
        // property 付き 3 個の cold read が入り、最大 2 個を除く閾値を直接確かめる。
        for kind in HeaderKind.allCases {
            let input = try headers(kind, count: 12), threshold = kind.shortThreshold
            for latency in [threshold - 100_000, threshold - 1, threshold, threshold + 1, threshold + 100_000] {
                let old = try decision(input, latency: latency, legacy: true)
                let new = try decision(input, latency: latency, legacy: false)
                XCTAssertEqual(new, old, "\(kind) cold=\(latency)ns")
                XCTAssertEqual(new == .complete, latency <= threshold, "\(kind) cold=\(latency)ns")
            }
        }
    }

    func testColdHeaderRawThresholdMatchesOldOneByteCadence() throws {
        // 長い定常列の 256 read 窓には ceil(256 / 旧 header read 数) 個の cold read。
        // この境界では short 閾値より小さく、4 ms 超過の stall 標本は零。
        for kind in HeaderKind.allCases {
            let input = try headers(kind, count: 300)
            let coldCount = (256 + kind.legacyReads - 1) / kind.legacyReads
            let threshold = UInt64(128_000_000 / coldCount)
            for latency in [threshold - 100_000, threshold - 1, threshold, threshold + 1, threshold + 100_000] {
                let old = try decision(input, latency: latency, legacy: true)
                let new = try decision(input, latency: latency, legacy: false)
                XCTAssertEqual(new, old, "\(kind) cold=\(latency)ns")
                XCTAssertEqual(new == .complete, latency <= threshold, "\(kind) cold=\(latency)ns")
            }
        }
    }

    func testNASColdHeaderLatenciesMatchOldOneByteCadence() throws {
        for kind in HeaderKind.allCases {
            let input = try headers(kind, count: 300)
            for latency: UInt64 in [1_000_000, 1_400_000, 2_000_000, 2_400_000, 2_500_000,
                                    2_900_000, 3_000_000, 3_400_000, 3_500_000] {
                XCTAssertEqual(try decision(input, latency: latency, legacy: false),
                               try decision(input, latency: latency, legacy: true), "\(kind) cold=\(latency)ns")
            }
        }
    }

    func testHeaderSampleIncludesWarmFollowupTime() throws {
        let input = try headers(.compressed, count: 12)
        XCTAssertEqual(try decision(input, latency: 3_450_001, legacy: false), .complete)
        let clock = Clock(readsPerHeader: input.batchedReads, warmLatency: 50_000) { _ in 3_450_001 }
        let source = LZMA2TimedScanSource(source: DataByteSource(input.packed), clock: { clock.now() })
        // cold だけなら short 予算内だが、後続の 50 us を足すと 3.5 ms/header を超える。
        XCTAssertThrowsError(try LZMA2Decoder.makeParallelDictionaryResetIndex(source: source,
            offset: 0, compressedSize: UInt64(input.packed.count), expectedSize: input.outputSize,
            maximumPointCount: 10_000, singleResetOutputLimit: UInt64.max)) {
            XCTAssertTrue($0 is LZMA2TimedScanSource.TooSlow)
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
        XCTAssertFalse(source.reads.contains { $0.offset == 1 && $0.count == 2 })
        for index in [1, 100, 99] { XCTAssertEqual(try read(coordinator, index: index), fixture.payloads[index]) }
        XCTAssertEqual(clock.reads, 401)
        XCTAssertEqual(try factory.parallelUnits()?.count, 200)
        XCTAssertGreaterThan(diagnostics.peakHeldBytes, 0)
        XCTAssertEqual(coordinator.lastBackwardRestart, .head)
    }

    func testWarmProbeCompletesDespiteSingleStalledHeader() throws {
        for stalledLatency: UInt64 in [10_000_000, 15_000_000] {
            let fixture = fixture(), clock = Clock { $0 == 100 ? stalledLatency : 50_000 }
            let factory = try fixture.factory(workers: 4, avoidsHeaderScans: true, scanClock: { clock.now() })
            XCTAssertEqual(try factory.parallelUnits()?.count, 200)
            XCTAssertEqual(clock.reads, 401)
            XCTAssertEqual(try factory.parallelUnits()?.count, 200)
            XCTAssertEqual(clock.reads, 401)
        }
    }

    func testWarmProbeCompletesDespiteTwoStalledHeadersWithinShortWindow() throws {
        for baseLatency: UInt64 in [40_000, 50_000] {
            for stalledLatency: UInt64 in [4_000_000, 20_000_000] {
                let fixture = fixture(units: 2_000)
                let clock = Clock { [0, 2, 100, 102].contains($0) ? stalledLatency : baseLatency }
                let factory = try fixture.factory(workers: 4, avoidsHeaderScans: true, scanClock: { clock.now() })
                let coordinator = SevenZipFolderCoordinator(factory: factory)
                XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
                XCTAssertEqual(clock.reads, 0)
                XCTAssertEqual(try read(coordinator, index: 1), fixture.payloads[1])
                XCTAssertEqual(try factory.parallelUnits()?.count, 2_000)
                XCTAssertEqual(clock.reads, 4_001)
            }
        }
    }

    func testProbeAbortsWithSparseNineMillisecondHeaders() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 % 5 == 0 ? 9_000_000 : 200_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true, scanClock: { clock.now() })
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
        XCTAssertEqual(clock.reads, 0)
        XCTAssertEqual(try read(coordinator, index: 1), fixture.payloads[1])
        // 旧 read 重みで平均約 0.65 ms の媒体は、疎な遅延でも全体を走査しない。
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertLessThanOrEqual(clock.headers, 100)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsWithSparseSixMillisecondHeaders() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 % 4 == 0 ? 6_000_000 : 50_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertGreaterThan(clock.headers, 16)
        XCTAssertLessThanOrEqual(clock.headers, 100)
        XCTAssertEqual(source.reads.count, clock.reads)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsWithDenseNineMillisecondHeadersAfterFastPrefix() throws {
        let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
        let clock = Clock { $0 >= 30 ? 9_000_000 : 50_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 33)
        XCTAssertEqual(source.reads.count, clock.reads)
        let stoppedReads = clock.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.reads, stoppedReads)
    }

    func testProbeAbortsForSparseColdHeadersAfterFastPrefix() throws {
        let patterns: [(period: Int, latency: UInt64)] = [(7, 17_000_000), (10, 17_000_000),
            (15, 50_000_000), (3, 15_000_000), (4, 15_000_000)]
        for pattern in patterns {
            let fixture = fixture(units: 2_000), source = RecordingSource(DataByteSource(fixture.packed))
            let cache = SevenZipLZMA2ResetIndexCache()
            let clock = Clock { header in
                header >= 90 && (header - 90) % pattern.period == 0 ? pattern.latency : 50_000
            }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                resetIndexCache: cache, scanClock: { clock.now() })
            XCTAssertNil(try factory.parallelUnits(), "\(pattern)")
            XCTAssertGreaterThan(clock.headers, 90)
            XCTAssertLessThanOrEqual(clock.headers, 180, "\(pattern): 全 2,000 header まで走査しない")
            XCTAssertEqual(source.reads.count, clock.reads)
            XCTAssertGreaterThan(cache.observedCoverage, 17)
            let stoppedReads = clock.reads
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.reads, stoppedReads)
        }
    }

    func testProbeAbortsAtCalibratedHeaderBudgetAndCachesDecision() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 2_000_001 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 6)
        XCTAssertEqual(source.reads.count, 12)
        XCTAssertEqual(cache.observedPoints.map(\.uncompressedOffset), [0, 17, 34, 51, 68])
        XCTAssertEqual(cache.observedCoverage, 85)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 68)?.uncompressedOffset, 68)
        XCTAssertEqual(factory.lastBackwardRestartKind, .observed)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 6)
    }

    func testProbeDoesNotLetCachedFirstHeadersHideColdHeaders() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache()
        let clock = Clock { $0 < 6 ? 100_000 : 2_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 12)
        XCTAssertEqual(source.reads.count, clock.reads)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 12)
    }

    func testProbeAbortsOnRollingWindowAfterFastPrefix() throws {
        let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { $0 < 90 ? 100_000 : 2_000_000 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(clock.headers, 96)
        XCTAssertEqual(source.reads.count, clock.reads)
        XCTAssertEqual(cache.observedPoints.count, 95)
        XCTAssertEqual(cache.observedCoverage, 95 * 17)
    }

    func testProbeAbortsAfterConsecutiveColdHeadersAndCachesDecision() throws {
        for slowStart in [0, 6] {
            let fixture = fixture(), source = RecordingSource(DataByteSource(fixture.packed))
            let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { $0 < slowStart ? 100_000 : 9_000_000 }
            let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
                resetIndexCache: cache, scanClock: { clock.now() })
            // 最長の二つの header は許容しても、三つ目の cold header で止める。
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.headers, slowStart + 3)
            XCTAssertEqual(source.reads.count, clock.reads)
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertEqual(clock.headers, slowStart + 3)
        }
    }

    func testBackwardSeekUsesScanObservationsAfterAbort() throws {
        var fixture = fixture(); fixture.folderCRC = nil
        let source = RecordingSource(DataByteSource(fixture.packed))
        let cache = SevenZipLZMA2ResetIndexCache(), clock = Clock { _ in 2_000_001 }
        let factory = try fixture.factory(workers: 4, source: source, avoidsHeaderScans: true,
            resetIndexCache: cache, scanClock: { clock.now() })
        let coordinator = SevenZipFolderCoordinator(factory: factory)
        XCTAssertEqual(try read(coordinator, index: 0), fixture.payloads[0])
        XCTAssertEqual(cache.observedCoverage, 17)
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(cache.observedCoverage, 85)
        XCTAssertEqual(try factory.backwardRestartPoint(atOrBefore: 51)?.uncompressedOffset, 51)
        XCTAssertEqual(factory.lastBackwardRestartKind, .observed)
        XCTAssertEqual(try read(coordinator, index: 100), fixture.payloads[100])
        XCTAssertEqual(clock.headers, 6)
        XCTAssertEqual(try read(coordinator, index: 3), fixture.payloads[3])
        XCTAssertEqual(coordinator.lastBackwardRestart, .observed)
    }

    func testLowLatencyDoesNotConsultProbeClock() throws {
        let fixture = fixture(), clock = Clock { _ in 100_000_000 }
        let factory = try fixture.factory(workers: 4, scanClock: { clock.now() })
        XCTAssertEqual(try factory.parallelUnits()?.count, 200)
        XCTAssertEqual(clock.reads, 0)
    }
}
