import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class DecodeParallelTests: XCTestCase {
    private static let counts = [1, 2, 4, 8, 16, 36, 64]
    private struct Fixture: Sendable {
        let body: Data
        let packed: Data
    }
    // 既定の XZ job 目標 16 MiB を越え、standalone stream でも三つの job を作る。
    private static let xz = Result<Fixture, any Error> {
        var body = Data()
        let part = ParallelXZTestSupport.random(65_536)
        for _ in 0..<528 { body.append(part) }
        return Fixture(body: body, packed: try CompressedTarFramingTestSupport.xz(body, chunkSize: 1_048_576).data)
    }
    // level 1 の単一 stream に 20 個以上の block を置き、複数 run にする。
    private static let bzip2 = Result<Fixture, any Error> {
        let body = ParallelXZTestSupport.random(2_100_003)
        return Fixture(body: body, packed: try CompressedTarFramingTestSupport.bzip2(body, level: 1, chunkSize: body.count).data)
    }

    func testByteIdentitySweepForMultiBlockDecodersAndStandaloneStreams() throws {
        let xz = try Self.xz.get(), bzip2 = try Self.bzip2.get()
        XCTAssertEqual(try drain(XZDecompressor(source: DataByteSource(xz.packed), limits: ReadLimits()), bufferSize: 65_536), xz.body)
        XCTAssertEqual(try drain(Bzip2Decompressor(source: DataByteSource(bzip2.packed), offset: 0,
            compressedSize: UInt64(bzip2.packed.count), concatenatedStreams: true), bufferSize: 65_536), bzip2.body)
        for threads in Self.counts {
            let options = ReaderOptions(decodeThreads: threads)
            XCTAssertEqual(try drain(ParallelXZDecompressor(source: DataByteSource(xz.packed), limits: options.limits,
                workers: options.resolvedDecodeThreads), bufferSize: 131_071), xz.body)
            XCTAssertEqual(try drain(ParallelBzip2Decompressor(source: DataByteSource(bzip2.packed), limits: options.limits,
                workers: options.resolvedDecodeThreads), bufferSize: 131_071), bzip2.body)
            for fixture in [xz, bzip2] {
                let submitted = Mutex(0)
                try LeafDecodePool.$testingSubmission.withValue({ submitted.withLock { $0 += 1 } }) {
                    let reader = try ArchiveReader.open(data: fixture.packed, options: options)
                    XCTAssertEqual(try reader.stream(reader.entries[0]).readAll(), fixture.body)
                }
                XCTAssertEqual(submitted.withLock { $0 > 0 }, threads > 1, "standalone stream must use parallel leaf jobs")
            }
        }
    }

    func testTwelveConcurrentReadersWithSixteenThreadsShareHardwarePool() async throws {
        let xz = try Self.xz.get(), bzip2 = try Self.bzip2.get()
        for fixture in [xz, bzip2] {
            try await withThrowingTaskGroup(of: Data.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        let reader = try ArchiveReader.open(data: fixture.packed,
                            options: ReaderOptions(decodeThreads: 16, decodePowerPolicy: index.isMultiple(of: 2)
                                ? .alwaysUseAllCores : .reduceInLowPowerMode))
                        let independent = try reader.reopen()
                        return try independent.stream(independent.entries[0]).readAll()
                    }
                }
                var completed = 0
                for try await bytes in group {
                    XCTAssertEqual(bytes, fixture.body)
                    completed += 1
                }
                XCTAssertEqual(completed, 12)
            }
        }
        XCTAssertGreaterThan(LeafDecodePool.shared.peakRunningJobs, 1)
        XCTAssertLessThanOrEqual(LeafDecodePool.shared.peakRunningJobs, LeafDecodePool.shared.capacity)
        print("DecodeParallel pool: peak=\(LeafDecodePool.shared.peakRunningJobs), cap=\(LeafDecodePool.shared.capacity), readers=12, requested=16")
    }

    func testPoolCancellationReleasesQueuedCapturesAndKeepsOtherReadersRunning() {
        let pool = LeafDecodePool(capacity: 1)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        // Test hook の gate で実行枠を占有し、他 reader の queued job を確実に作る。
        pool.submit(group: LeafDecodePool.Group()) {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        let cancelled = LeafDecodePool.Group()
        var capture: CapturedInput? = CapturedInput()
        weak var queuedCapture = capture
        pool.submit(group: cancelled) { [capture] in
            withExtendedLifetime(capture) {}
            XCTFail("cancelled queued leaf must not run")
        }
        capture = nil
        XCTAssertNotNil(queuedCapture)
        pool.cancel(group: cancelled)
        XCTAssertNil(queuedCapture, "abandon must release queued input without waiting for a slot")
        pool.submit(group: LeafDecodePool.Group()) { completed.signal() }
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(pool.peakRunningJobs, 1)
    }

    private final class CapturedInput: Sendable {}

    func testBzip2MemoryBudgetLimitsInFlightJobsAndFallsBackWhenTooSmall() throws {
        let fixture = try Self.bzip2.get()
        let compressedLimit = 512 * 1_024, outputLimit = 1_048_576
        let scannerBytes = 4 * compressedLimit + Bzip2BlockScanner.readSize + Bzip2StreamLayout.headerLength
        let perJob = compressedLimit + outputLimit
        for (budget, fallback) in [(scannerBytes + 2 * perJob, false), (scannerBytes + perJob, true), (0, true)] {
            let diagnostics = ParallelBzip2Decompressor.Diagnostics()
            let decoder = try ParallelBzip2Decompressor(source: DataByteSource(fixture.packed),
                limits: ReadLimits(parallelDecodeMemory: UInt64(budget)), workers: 64,
                maximumCompressedSize: compressedLimit, maximumOutputSize: outputLimit, diagnostics: diagnostics)
            XCTAssertEqual(try drain(decoder, bufferSize: 65_536), fixture.body)
            XCTAssertEqual(diagnostics.fallbackCount > 0, fallback)
            XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, budget)
            XCTAssertLessThanOrEqual(diagnostics.peakWorkers, fallback ? 0 : 2)
            if !fallback { XCTAssertGreaterThan(diagnostics.decodedRunCount, 2) }
            print("DecodeParallel bzip2 memory: budget=\(budget), peak=\(diagnostics.peakHeldBytes), serial=\(fallback)")
        }
    }

    func testCLIDecodeThreadsForEverySupportedCommandAndRejectsInvalidValues() throws {
        let fixture = try Self.bzip2.get()
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try TarTestSupport.write(fixture.packed, relativePath: "payload.bz2", below: directory)
        let serial = try KaitoCLI.run(["sha", "--threads", "1", archive.path])
        XCTAssertEqual(try KaitoCLI.run(["sha", archive.path, "--threads", "16"]), serial)
        XCTAssertEqual(try KaitoCLI.run(["sha", "--threads", "auto", archive.path]), serial)
        XCTAssertTrue(try KaitoCLI.run(["list", "--threads", "4", archive.path]).contains("payload"))
        XCTAssertTrue(try KaitoCLI.run(["bench", "--data", archive.path, "1", "--threads", "36"]).contains("bytes\t\(fixture.body.count)"))
        let output = directory.appendingPathComponent("unpacked")
        _ = try KaitoCLI.run(["extract", archive.path, "-o", output.path, "--threads", "2"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("payload")), fixture.body)
        for command in ["list", "sha", "extract", "bench"] {
            let base = command == "extract" ? [command, archive.path, "-o", output.path] : [command, archive.path]
            for tail in [["--threads", "0"], ["--threads", "1025"], ["--threads", "-1"], ["--threads", "bad"],
                         ["--threads"], ["--threads", "auto", "--threads", "2"]] {
                let result = try ZipTestSupport.run(KaitoCLI.executableURL().path, arguments: base + tail)
                XCTAssertEqual(result.terminationStatus, 2, "\(command) \(tail)")
            }
        }
    }

    func testXZReportsEarliestStreamFailureEvenWhenLaterJobFailsFirst() throws {
        let body = ParallelXZTestSupport.random(600_003)
        let packed = try CompressedTarFramingTestSupport.xz(body, chunkSize: 131_072).data
        let blocks = try XCTUnwrap(ParallelXZTestSupport.layout(packed).streams.first).blocks
        let faults = [(blocks[0].compressedRange, "earlier XZ payload"), (blocks[1].compressedRange, "later XZ payload")]
        let serialSource = FailureSource(packed, faults: faults)
        let serial = try XZDecompressor(source: serialSource, limits: ReadLimits())
        serialSource.arm()
        let expected = Self.decodeFailure(serial) as? KaitoError
        XCTAssertEqual(expected, .malformed("earlier XZ payload"))
        for threads in Self.counts {
            let source = FailureSource(packed, faults: faults, delaysFirst: threads > 1)
            let decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), workers: threads,
                targetJobOutput: 131_072)
            source.arm()
            let actual = Self.decodeFailure(decoder)
            XCTAssertTrue(actual is KaitoError)
            XCTAssertEqual(actual as? KaitoError, expected)
            if threads > 1, LeafDecodePool.shared.capacity > 1 {
                XCTAssertEqual(source.observed.first, "later XZ payload")
            }
        }
    }

    func testBzip2EarlierCorruptRunWinsOverLaterScannerReadFailure() throws {
        var packed = try Self.bzip2.get().packed
        packed[150] ^= 4
        let source = FailureSource(packed, faults: [(1_048_576..<UInt64(packed.count), "later bzip2 source read")])
        let serial = try Bzip2Decompressor(source: source, offset: 0, compressedSize: UInt64(packed.count), concatenatedStreams: true)
        source.arm()
        let expected = Self.decodeFailure(serial) as? KaitoError
        XCTAssertNotNil(expected)
        XCTAssertNotEqual(expected, .malformed("later bzip2 source read"))
        for threads in [2, 16, 64] {
            let source = FailureSource(packed, faults: [(1_048_576..<UInt64(packed.count), "later bzip2 source read")])
            let diagnostics = ParallelBzip2Decompressor.Diagnostics()
            let decoder = try ParallelBzip2Decompressor(source: source, workers: threads, diagnostics: diagnostics)
            source.arm()
            let actual = Self.decodeFailure(decoder)
            XCTAssertTrue(actual is KaitoError)
            XCTAssertEqual(actual as? KaitoError, expected)
            XCTAssertTrue(source.observed.contains("later bzip2 source read"))
            XCTAssertEqual(diagnostics.fallbackCount, 1)
        }
    }

    private static func decodeFailure(_ decoder: any Decompressor) -> (any Error)? {
        do { _ = try drain(decoder, bufferSize: 65_536); return nil }
        catch { return error }
    }

    private final class FailureSource: ByteSource, @unchecked Sendable {
        let source: DataByteSource
        let faults: [(Range<UInt64>, String)]
        let delaysFirst: Bool
        private let lock = NSLock()
        private var armed = false
        private var errors: [String] = []
        init(_ bytes: Data, faults: [(Range<UInt64>, String)], delaysFirst: Bool = false) {
            source = DataByteSource(bytes); self.faults = faults; self.delaysFirst = delaysFirst
        }
        var length: UInt64 { source.length }
        var observed: [String] { lock.withLock { errors } }
        func arm() { lock.withLock { armed = true } }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            if lock.withLock({ armed }), let fault = faults.first(where: {
                offset < $0.0.upperBound && offset + UInt64(buffer.count) > $0.0.lowerBound
            }) {
                if delaysFirst, fault.1 == faults.first?.1 { Thread.sleep(forTimeInterval: 0.05) }
                lock.withLock { errors.append(fault.1) }
                throw KaitoError.malformed(fault.1)
            }
            return try source.read(into: buffer, at: offset)
        }
    }
}
