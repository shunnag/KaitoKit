import Foundation
@testable import KaitoKit
import XCTest

// Provenance:
// - Public-reader, ordering, budget, packed-span and abandonment tests are
//   ported from KaitoKit's own RAR5PrefetchTests.
// - Literal streams and headers follow KaitoKit's RAR29R1Tests and RAR4TestSupport.
// - Pool saturation follows KaitoKit's LeafDecodePoolTests; rar6 is used only
//   as a black-box archive generator for the optional generated matrix.
// - PPMd rejection and LZ-to-PPMd transitions reuse KaitoKit's checked-in
//   RAR 3.00 PPMd fixture and this test's existing literal-block grammar.
// No unrar, 7-Zip, XADMaster, or The Unarchiver source was used.

final class RAR4PrefetchTests: RAR4BuilderTestCase {
    /// Files whose compressed streams exercise short-distance runs (1-7, which
    /// expand through the bytewise period path), word copies, long matches
    /// that wrap the 128 KiB retained ring, pure literals and sizes around the
    /// ring boundary.
    private static func corpus() -> [(name: String, contents: Data)] {
        var files: [(String, Data)] = []
        for distance in 1...9 {
            let period = (0..<distance).map { UInt8(97 + $0) }
            var data = Data()
            while data.count < 300_000 { data.append(contentsOf: period) }
            files.append(("run-\(distance).txt", data))
        }
        var text = Data()
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        let words = ["alpha ", "beta ", "gamma ", "delta ", "epsilon ", "zeta\n", "eta ", "theta "]
        while text.count < 400_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            text.append(contentsOf: Array(words[Int(seed >> 61)].utf8))
        }
        files.append(("text.txt", text))
        files.append(("random.bin", RAR5TestSupport.deterministicPayload(count: 70_000, seed: 11)))
        for size in [131_071, 131_072, 131_073, 131_080] {
            files.append(("boundary-\(size).txt", Data(repeating: 0x41, count: size)))
        }
        for index in 0..<200 {
            var small = Data("file \(index): ".utf8)
            small.append(RAR5TestSupport.deterministicPayload(count: 1 + (index * 7_919) % 3_000, seed: UInt64(index)))
            small.append(contentsOf: Array(repeating: UInt8(0x20 + index % 60), count: 100 + index % 900))
            files.append(("small/\(index).txt", small))
        }
        return files
    }

    private struct Generated {
        let url: URL
        let files: [(name: String, contents: Data)]
    }

    private func generate(options: [String], suffix: String) throws -> Generated {
        let candidates: [String?] = [ProcessInfo.processInfo.environment["RAR4_TOOL"],
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/rar6").path,
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/opt/rar-6.24/rar").path]
        guard let executable = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("RAR 6.x black-box fixture generator unavailable") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rar4-prefetch-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(
            at: input.appendingPathComponent("small"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = Self.corpus()
        for file in files {
            try file.contents.write(to: input.appendingPathComponent(file.name))
        }
        let archive = root.appendingPathComponent("corpus-\(suffix).rar")
        _ = try ZipTestSupport.checkedRun(
            executable, arguments: ["a", "-ma4", "-s-", "-idq", "-mt1"] + options
                + [archive.path] + files.map(\.name), currentDirectory: input
        )
        return Generated(url: archive, files: files)
    }

    /// One read pass over every entry: the bytes delivered before any error and
    /// the error itself, in entry order. This is exactly what a caller observes.
    private struct Observation: Equatable {
        var deliveredCounts: [Int] = []
        var outputs: [Data] = []
        var errors: [KaitoError?] = []
    }

    private func observe(
        _ reader: ArchiveReader, order: [Int], bufferSize: Int, requireSuccess: Bool = false
    ) throws -> Observation {
        var observation = Observation()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for index in order where reader.entries[index].kind == .file {
            var delivered = Data()
            do {
                let stream = try reader.stream(reader.entries[index])
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    delivered.append(contentsOf: buffer[..<count])
                }
                observation.errors.append(nil)
            } catch {
                XCTAssertFalse(requireSuccess, "entry \(index) failed: \(error)")
                observation.errors.append(try XCTUnwrap(error as? KaitoError))
            }
            observation.deliveredCounts.append(delivered.count)
            // Retain actual bytes, rather than just their digest, for the corruption differential.
            observation.outputs.append(delivered)
        }
        return observation
    }

    func testPrefetchedMembersMatchSerialDecodingForEveryThreadCountAndOrder() throws {
        for options in [["-m3", "-md128k"], ["-m5", "-md1m"]] {
            let generated = try generate(options: options, suffix: options.joined())
            let serial = try ArchiveReader.open(
                url: generated.url, options: ReaderOptions(decodeThreads: 1)
            )
            XCTAssertNil((serial.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
            let forward = Array(serial.entries.indices)
            let expected = try observe(serial, order: forward, bufferSize: 65_536, requireSuccess: true)
            // Every byte must be the generator's input.
            let byName = Dictionary(uniqueKeysWithValues: generated.files.map { ($0.name, $0.contents) })
            for entry in serial.entries where entry.kind == .file {
                XCTAssertEqual(try serial.read(entry), byName[entry.name], "\(entry.name)")
            }

            // The full matrix runs on the first option set; later sets check
            // a representative thread count and buffer size.
            let full = options == [["-m3", "-md128k"], ["-m5", "-md1m"]][0]
            for threads in full ? [2, 3, 8] : [3] {
                for bufferSize in full ? [1, 4_099, 65_536, 1_048_576] : [4_099, 65_536] {
                    let reader = try ArchiveReader.open(
                        url: generated.url, options: ReaderOptions(decodeThreads: threads)
                    )
                    let rar4 = try XCTUnwrap(reader.formatReaderForTesting as? RAR4Reader)
                    let observed = try observe(reader, order: forward, bufferSize: bufferSize, requireSuccess: true)
                    XCTAssertEqual(observed, expected, "threads \(threads) buffer \(bufferSize) \(options)")
                    if bufferSize == 65_536 {
                        // The forward pass actually went through the prefetcher.
                        XCTAssertNotNil(rar4.prefetcherForTesting)
                        XCTAssertEqual(rar4.prefetcherForTesting?.liveBatchCount, 0)
                        XCTAssertEqual(rar4.prefetcherForTesting?.heldByteCount, 0)
                    }
                }
                // Backwards and shuffled access never gets stale or misplaced output.
                let reader = try ArchiveReader.open(
                    url: generated.url, options: ReaderOptions(decodeThreads: threads)
                )
                var shuffled = forward
                var seed: UInt64 = 42
                for index in shuffled.indices.reversed() where index > 0 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    shuffled.swapAt(index, Int(seed >> 33) % (index + 1))
                }
                for order in [forward.reversed(), shuffled, forward] {
                    let observed = try observe(reader, order: order, bufferSize: 4_099, requireSuccess: true)
                    var reordered = Observation()
                    let files = forward.filter { reader.entries[$0].kind == .file }
                    let positions = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
                    for index in order where reader.entries[index].kind == .file {
                        let position = positions[index]!
                        reordered.deliveredCounts.append(expected.deliveredCounts[position])
                        reordered.outputs.append(expected.outputs[position])
                        reordered.errors.append(expected.errors[position])
                    }
                    XCTAssertEqual(observed, reordered, "threads \(threads) order \(order.prefix(5))")
                }
            }
        }
    }

    func testSlowConsumerKeepsCompletedBatchesWithinPrefetchWindow() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        for requestedWorkers in [2, 3, 8] {
            let workers = min(requestedWorkers, LeafDecodePool.shared.capacity)
            let window = 2 * workers
            let batchMembers = IndependentEntryPrefetcher.batchMemberLimit
            let outputSize = 64
            let scratchBytes = 128
            let batchBytes = batchMembers * (outputSize + 1) + scratchBytes
            let memberCount = 8 * window * batchMembers
            // A roomy budget must not let completed, untaken batches grow
            // beyond the window; a tight budget still serves every member.
            for budget in [window * batchBytes, 8 * window * batchBytes] {
                let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
                    workers: requestedWorkers, memoryBudget: budget, memberCount: memberCount,
                    candidate: { IndependentEntryPrefetcher.Candidate(
                        index: $0, outputSize: outputSize, scratchBytes: scratchBytes
                    ) },
                    decodeBatch: { members, _ in members.map {
                        Data(repeating: UInt8(truncatingIfNeeded: $0.index), count: $0.outputSize)
                    } }
                ))
                defer { prefetcher.abandon() }
                var reachedWindow = false
                for index in 0..<memberCount {
                    prefetcher.schedule(after: index - 1)
                    XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window, "scheduled member \(index)")
                    XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
                    // Finish all scheduled work before taking just one member:
                    // the slow-reader state is structural, independent of time.
                    prefetcher.waitForScheduledBatchesForTesting()
                    XCTAssertEqual(prefetcher.runningBatchCount, 0)
                    let heldBatches = prefetcher.liveBatchCount
                    XCTAssertLessThanOrEqual(heldBatches, window, "completed member \(index)")
                    XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
                    guard heldBatches <= window else { return }
                    reachedWindow = reachedWindow || heldBatches == window
                    XCTAssertEqual(try prefetcher.take(index),
                                   Data(repeating: UInt8(truncatingIfNeeded: index), count: outputSize),
                                   "member \(index), workers \(workers), budget \(budget)")
                    XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window, "taken member \(index)")
                    XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
                }
                XCTAssertTrue(reachedWindow, "exercise a full window and its resumption")
                XCTAssertEqual(prefetcher.servedMemberCount, memberCount)
                XCTAssertEqual(prefetcher.liveBatchCount, 0)
            }
        }
    }

    func testDroppingPassedBatchesReopensPrefetchWindow() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let workers = 2
        let window = 2 * workers
        let batchMembers = IndependentEntryPrefetcher.batchMemberLimit
        let budget = 1 << 20
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: workers, memoryBudget: budget, memberCount: 12 * batchMembers,
            candidate: { IndependentEntryPrefetcher.Candidate(index: $0, outputSize: 64, scratchBytes: 128) },
            decodeBatch: { members, _ in members.map {
                Data(repeating: UInt8(truncatingIfNeeded: $0.index), count: $0.outputSize)
            } }
        ))
        defer { prefetcher.abandon() }
        for _ in 0..<2 {
            prefetcher.schedule(after: -1)
            prefetcher.waitForScheduledBatchesForTesting()
            XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        }
        XCTAssertEqual(prefetcher.liveBatchCount, window)
        prefetcher.schedule(after: -1)
        XCTAssertEqual(prefetcher.liveBatchCount, window, "a full window schedules no more work")

        let index = (window - 1) * batchMembers
        XCTAssertEqual(try prefetcher.take(index), Data(repeating: UInt8(truncatingIfNeeded: index), count: 64))
        XCTAssertEqual(prefetcher.liveBatchCount, 1, "passed batches are discarded")
        XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        for _ in 0..<2 {
            prefetcher.schedule(after: index)
            prefetcher.waitForScheduledBatchesForTesting()
            XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        }
        XCTAssertEqual(prefetcher.liveBatchCount, window, "discarding reopens the window")
        XCTAssertNil(try prefetcher.take(0), "discarded members stay absent")
        for next in (index + 1)..<(12 * batchMembers) {
            prefetcher.schedule(after: next - 1)
            prefetcher.waitForScheduledBatchesForTesting()
            XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
            XCTAssertEqual(try prefetcher.take(next), Data(repeating: UInt8(truncatingIfNeeded: next), count: 64))
            XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, window)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        }
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
    }

    func testAbandonDoesNotDecrementRunningCountAfterAnInFlightBatchFinishes() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let entered = expectation(description: "batch entered decoder")
        let gate = PrefetchGate()
        defer { gate.open() }
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: 2, memoryBudget: 4_096, memberCount: 4,
            candidate: { IndependentEntryPrefetcher.Candidate(index: $0, outputSize: 64, scratchBytes: 128) },
            decodeBatch: { members, _ in
                entered.fulfill()
                gate.wait()
                return members.map { Data(repeating: UInt8($0.index), count: $0.outputSize) }
            }
        ))
        prefetcher.schedule(after: 0)
        wait(for: [entered], timeout: 5)
        XCTAssertEqual(prefetcher.runningBatchCount, 1)
        prefetcher.abandon()
        XCTAssertEqual(prefetcher.runningBatchCount, 0)
        gate.open()
        // The job releases its reservation only after publishing completion.
        let deadline = Date(timeIntervalSinceNow: 5)
        while prefetcher.heldByteCount != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(prefetcher.heldByteCount, 0)
        XCTAssertEqual(prefetcher.runningBatchCount, 0)
        XCTAssertNil(try prefetcher.take(1))
    }

    func testFailedAndRepeatedTakesDoNotConsumeOtherOutputs() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: 2, memoryBudget: 4_096, memberCount: 4,
            candidate: { IndependentEntryPrefetcher.Candidate(index: $0, outputSize: 64, scratchBytes: 128) },
            decodeBatch: { members, _ in members.map { $0.index == 1 ? nil : Data(repeating: 1, count: 64) } }
        ))
        prefetcher.schedule(after: 0)
        for _ in 0..<4 { XCTAssertNil(try prefetcher.take(1)) }
        XCTAssertEqual(try prefetcher.take(2)?.count, 64)
        XCTAssertNil(try prefetcher.take(2))
        XCTAssertEqual(try prefetcher.take(3)?.count, 64)
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
    }

    func testPackedSpanIncludingGapsIsReservedBeforeScheduling() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rar5-span-\(UUID().uuidString)")
        let contents = Data((0..<600).map { UInt8(truncatingIfNeeded: $0) })
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileByteSource(url: url)
        let decoded = Counter()
        let spanReads = Counter()
        // Two 100-byte segments separated by 28 bytes: output + scratch + 228-byte span.
        let budget = 2 * 17 + 128 + 228
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: 2, memoryBudget: budget, memberCount: 4,
            candidate: { index in
                IndependentEntryPrefetcher.Candidate(
                    index: index, outputSize: 16, scratchBytes: 128,
                    packedSegment: SourceSegment(source: file, offset: UInt64(32 + (index - 1) * 128), length: 100)
                )
            },
            decodeBatch: { members, _ in
                let span = PrefetchedPackedSpan.read(members: members)
                if span != nil { spanReads.add(1) }
                let source: any ByteSource
                if let span { source = span } else { source = file }
                return members.map { member in
                    decoded.add(1)
                    guard let segment = member.packedSegment else { return nil }
                    return try? Data(readByteRange(source: source, offset: segment.offset, count: member.outputSize))
                }
            }
        ))
        prefetcher.schedule(after: 0)
        XCTAssertEqual(prefetcher.liveBatchCount, 1)
        XCTAssertEqual(prefetcher.heldByteCount, budget, "packed input and gaps count against the reservation")
        for index in 1...3 {
            let start = 32 + (index - 1) * 128
            XCTAssertEqual(try prefetcher.take(index), contents.subdata(in: start..<(start + 16)))
            if index == 2 {
                let deadline = Date(timeIntervalSinceNow: 5)
                while prefetcher.heldByteCount != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                XCTAssertEqual(prefetcher.heldByteCount, 0)
            }
            prefetcher.schedule(after: index)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        }
        XCTAssertEqual(decoded.value, 3)
        XCTAssertEqual(spanReads.value, 1, "the fitting two-member batch keeps its shared packed read")
    }

    func testPrefetcherDeliversInOrderDropsPassedBatchesAndStopsWhenAbandoned() throws {
        let decoded = Counter()
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: 3,
            memoryBudget: 1 << 30,
            memberCount: 1_000,
            candidate: { index in
                // Every third member is ineligible; member 500 is "too large".
                guard index % 3 != 2 else { return nil }
                return IndependentEntryPrefetcher.Candidate(
                    index: index,
                    outputSize: index == 500 ? IndependentEntryPrefetcher.maximumMemberSize + 1 : 64,
                    scratchBytes: 128
                )
            },
            decodeBatch: { members, shouldStop in
                var outputs: [Data?] = []
                for member in members {
                    if shouldStop() { break }
                    decoded.add(1)
                    // Member 100 fails and must simply be absent.
                    outputs.append(member.index == 100 ? nil : Data(repeating: UInt8(truncatingIfNeeded: member.index), count: 64))
                }
                return outputs
            }
        ))
        XCTAssertNil(try prefetcher.take(0), "nothing scheduled yet")
        prefetcher.schedule(after: 0)
        XCTAssertLessThanOrEqual(prefetcher.liveBatchCount, 3)
        for index in 1..<400 {
            let output = try prefetcher.take(index)
            prefetcher.schedule(after: index)
            if index % 3 == 2 || index == 100 {
                XCTAssertNil(output, "member \(index)")
            } else {
                XCTAssertEqual(output, Data(repeating: UInt8(truncatingIfNeeded: index), count: 64), "member \(index)")
            }
        }
        // Member 500 is oversized: never prefetched, neighbours still are.
        XCTAssertNil(try prefetcher.take(500))
        prefetcher.schedule(after: 500)
        XCTAssertEqual(try prefetcher.take(501), Data(repeating: UInt8(truncatingIfNeeded: 501), count: 64))
        // Jumping far ahead drops the batches in between.
        prefetcher.schedule(after: 501)
        XCTAssertEqual(try prefetcher.take(900), Data(repeating: UInt8(truncatingIfNeeded: 900), count: 64))
        prefetcher.schedule(after: 900)
        XCTAssertNil(try prefetcher.take(502), "passed members are dropped")
        prefetcher.abandon()
        XCTAssertNil(try prefetcher.take(901))
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
        // Give cancelled or running batches a moment to let go of their reservations.
        let deadline = Date(timeIntervalSinceNow: 5)
        while prefetcher.heldByteCount != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(prefetcher.heldByteCount, 0)
        XCTAssertLessThan(decoded.value, 1_000, "abandoning stops the remaining work")
    }

    func testPrefetcherNeedsTwoWorkersAndRespectsTheBudgetWhenScheduling() throws {
        XCTAssertNil(IndependentEntryPrefetcher(
            workers: 1, memoryBudget: 1 << 30, memberCount: 10,
            candidate: { _ in nil }, decodeBatch: { _, _ in [] }
        ))
        let prefetcher = try XCTUnwrap(IndependentEntryPrefetcher(
            workers: 4, memoryBudget: 3 * 1_024 + 2 * 128 + 10, memberCount: 100,
            candidate: { IndependentEntryPrefetcher.Candidate(index: $0, outputSize: 1_024, scratchBytes: 128) },
            decodeBatch: { members, _ in members.map { Data(repeating: 1, count: $0.outputSize) } }
        ))
        prefetcher.schedule(after: 0)
        // 1 KiB members plus one scratch per batch: at most three fit the budget.
        XCTAssertEqual(prefetcher.liveBatchCount, 1)
        XCTAssertLessThanOrEqual(prefetcher.heldByteCount, 3 * 1_024 + 2 * 128 + 10)
        for index in 1...30 {
            XCTAssertEqual(try prefetcher.take(index)?.count, 1_024, "member \(index)")
            prefetcher.schedule(after: index)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, 3 * 1_024 + 2 * 128 + 10)
        }
    }


    // MARK: - RAR4 integration of the shared scheduler

    private func member(
        _ index: Int, payload: Data, packed: Data? = nil, flags: UInt16 = 0,
        version: UInt8 = 29, method: UInt8 = 0x31, unpackedSize: UInt32? = nil,
        crc32: UInt32? = nil
    ) -> Data {
        let body = packed ?? Self.literalBlock(byte: payload.first ?? 0, count: payload.count)
        let name = Array("entry-\(index).bin".utf8)
        var fields: [UInt8] = []
        fields.appendLittleEndian(UInt32(body.count))
        fields.appendLittleEndian(unpackedSize ?? UInt32(payload.count))
        fields.append(2)
        fields.appendLittleEndian(crc32 ?? CRC32.checksum(payload))
        fields.appendLittleEndian(UInt32(0))
        fields.append(version)
        fields.append(method)
        fields.appendLittleEndian(UInt16(name.count))
        fields.appendLittleEndian(UInt32(0x20))
        fields.append(contentsOf: name)
        return Data(makeHeader(type: 0x74, flags: flags | 0x8000, fields: fields)) + body
    }

    private func archive(_ members: [Data], mainFlags: UInt16 = 0) -> Data {
        var result = Data(RAR4Reader.signature) + Data(makeMainHeader(flags: mainFlags))
        for member in members { result.append(member) }
        result.append(contentsOf: makeHeader(type: 0x7b, flags: 0, fields: []))
        return result
    }

    private static func literalBlock(byte: UInt8, count: Int, ppmdSuffix: Data? = nil) -> Data {
        var bits = RAR4PrefetchBitWriter()
        bits.append(0, count: 2) // LZ, clear previous lengths.
        for symbol in 0..<20 { bits.append(symbol < 16 ? 4 : 0, count: 4) }
        for _ in 0..<299 { bits.append(9, count: 4) }
        for _ in 0..<105 { bits.append(0, count: 4) }
        for _ in 0..<count { bits.append(Int(byte), count: 9) }
        bits.append(256, count: 9)
        if let ppmdSuffix {
            bits.append(1, count: 1) // New block, byte-aligned by readTables.
            while !bits.bitCount.isMultiple(of: 8) { bits.append(0, count: 1) }
            for byte in ppmdSuffix { bits.append(Int(byte), count: 8) }
        } else {
            bits.append(0, count: 2)
        }
        return Data(bits.bytes)
    }

    private func smallArchive(count: Int = 40) -> (data: Data, payloads: [Data]) {
        let payloads = (0..<count).map { index in
            Data(repeating: UInt8(index), count: 1 + (index * 7_919) % 16_384)
        }
        return (archive(payloads.enumerated().map { member($0.offset, payload: $0.element) }), payloads)
    }

    func testCorruptMemberFallsBackWithByteIdenticalPartialOutputAndKaitoError() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let payloads = (0..<4).map { Data(repeating: UInt8(65 + $0), count: 20_000) }
        // The second stream is valid LZ but its literals are corrupted. CRC32
        // must reject it in the batch, before take can publish any of its bytes.
        for truncated in [false, true] {
            let data = archive(payloads.enumerated().map { index, payload in
                var packed = Self.literalBlock(byte: index == 1 ? 0x5a : payload[0], count: payload.count)
                if truncated, index == 1 { packed.removeLast(8) }
                return member(index, payload: payload, packed: packed)
            })
            for bufferSize in [1, 4_099, 65_536] {
                let serial = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: 1))
                let order = Array(serial.entries.indices)
                let expected = try observe(serial, order: order, bufferSize: bufferSize)
                XCTAssertEqual(expected.errors.compactMap { $0 }.count, 1)
                XCTAssertEqual(expected.errors[1], truncated ? .truncated : .checksumMismatch(entry: 1))
                if bufferSize == 4_099 { XCTAssertGreaterThan(expected.deliveredCounts[1], 0) }
                XCTAssertNil((serial.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
                for threads: Int? in [nil, 2, 3, 8] {
                    let reader = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: threads))
                    _ = try reader.read(reader.entries[0])
                    let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
                    prefetcher.waitForScheduledBatchesForTesting()
                    XCTAssertNil(try prefetcher.take(1), "a corrupt member is never published")
                    XCTAssertEqual(try observe(reader, order: order, bufferSize: bufferSize), expected,
                                   "threads \(String(describing: threads)), buffer \(bufferSize), truncated \(truncated)")
                    XCTAssertGreaterThan(prefetcher.servedMemberCount, 0, "intact neighbours still use the batch")
                }
            }
        }
    }

    func testPrefetchedStandardFiltersAndSerialPPMdMatchSerialBytes() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let lead = Data(repeating: 0x41, count: 64)
        var members = [member(0, payload: lead)]
        var expected = [lead]
        for name in ["r0-rgb.rar", "r0-delta.rar", "r0-e8.rar", "r0-audio.rar", "ppmd_lorem_rar300.rar"] {
            let data = try TestFixtures.base64("rar4/" + name)
            let reader = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: 1))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(reader.entries.count, 1)
            expected.append(try reader.read(entry))
            let header = try XCTUnwrap(entry.formatSpecific["headerOffset"].flatMap(Int.init))
            let size = Int(data[header + 5]) | Int(data[header + 6]) << 8
            let packed = try XCTUnwrap(entry.compressedSize.flatMap(Int.init(exactly:)))
            members.append(data.subdata(in: header..<(header + size + packed)))
        }
        let reader = try ArchiveReader.open(data: archive(members), options: ReaderOptions(decodeThreads: 4))
        for index in expected.indices { XCTAssertEqual(try reader.read(reader.entries[index]), expected[index]) }
        let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        XCTAssertEqual(prefetcher.servedMemberCount, expected.count - 2, "only the four filter members are prefetched")
    }

    private func ppmdFixture() throws -> (packed: Data, payload: Data) {
        let data = try TestFixtures.base64("rar4/ppmd_lorem_rar300.rar")
        let reader = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: 1))
        let entry = try XCTUnwrap(reader.entries.first)
        let header = try XCTUnwrap(entry.formatSpecific["headerOffset"].flatMap(Int.init))
        let headerSize = Int(data[header + 5]) | Int(data[header + 6]) << 8
        let packedSize = try XCTUnwrap(entry.compressedSize.flatMap(Int.init(exactly:)))
        let start = header + headerSize
        return (data.subdata(in: start..<(start + packedSize)), try reader.read(entry))
    }

    func testNonSolidPPMdMembersStaySerialWithoutConstructingWorkerModels() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = try ppmdFixture()
        let data = archive((0..<6).map {
            member($0, payload: fixture.payload, packed: fixture.packed, flags: 0x00c0)
        })
        let serial = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: 1))
        let order = Array(serial.entries.indices)
        XCTAssertTrue(serial.entries.allSatisfy { $0.solidGroup < 0 })
        let expected = try observe(serial, order: order, bufferSize: 4_099, requireSuccess: true)
        let models = Counter()
        try RAR29Decoder.$testingPPMdModelConstruction.withValue({ models.add(1) }) {
            let reader = try ArchiveReader.open(data: data)
            let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
            prefetcher.schedule(after: -1)
            prefetcher.waitForScheduledBatchesForTesting()
            XCTAssertEqual(models.value, 0, "no model construction attempt on any worker")
            for index in order { XCTAssertNil(try prefetcher.take(index)) }
            XCTAssertEqual(try observe(reader, order: order, bufferSize: 4_099, requireSuccess: true), expected)
            XCTAssertEqual(prefetcher.servedMemberCount, 0)
            XCTAssertEqual(models.value, order.count, "the serial fallback still constructs each model")
        }
    }

    func testLZMembersArePrefetchedAroundInitialAndSwitchedPPMdMembers() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = try ppmdFixture()
        let prefix = Data(repeating: 0x41, count: 64)
        let switched = Self.literalBlock(byte: 0x41, count: prefix.count, ppmdSuffix: fixture.packed)
        let payloads = [prefix, Data(repeating: 0x42, count: 128), fixture.payload,
                        Data(repeating: 0x43, count: 256), prefix + fixture.payload]
        let data = archive([
            member(0, payload: payloads[0]), member(1, payload: payloads[1]),
            member(2, payload: payloads[2], packed: fixture.packed, flags: 0x00c0),
            member(3, payload: payloads[3]), member(4, payload: payloads[4], packed: switched, flags: 0x00c0),
        ])
        let serial = try ArchiveReader.open(data: data, options: ReaderOptions(decodeThreads: 1))
        let order = Array(serial.entries.indices)
        let expected = try observe(serial, order: order, bufferSize: 1_024, requireSuccess: true)
        XCTAssertEqual(expected.outputs, payloads, "the LZ-to-PPMd member is a valid serial stream")
        let models = Counter()
        try RAR29Decoder.$testingPPMdModelConstruction.withValue({ models.add(1) }) {
            let reader = try ArchiveReader.open(data: data)
            XCTAssertEqual(try reader.read(reader.entries[0]), payloads[0])
            let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
            prefetcher.waitForScheduledBatchesForTesting()
            XCTAssertEqual(models.value, 0, "both initial and later PPMd blocks stop before allocation")
            XCTAssertNil(try prefetcher.take(2))
            XCTAssertNil(try prefetcher.take(4), "the earlier LZ bytes must not be published either")
            XCTAssertEqual(try observe(reader, order: order, bufferSize: 1_024, requireSuccess: true), expected)
            XCTAssertEqual(prefetcher.servedMemberCount, 2, "the two independent LZ neighbours were prefetched")
            XCTAssertEqual(models.value, 2, "only the two serial fallbacks construct models")
        }
    }

    func testDisallowedInitialAndLaterPPMdErrorsAreDedicatedAndLatched() throws {
        let fixture = try ppmdFixture()
        let models = Counter()
        try RAR29Decoder.$testingPPMdModelConstruction.withValue({ models.add(1) }) {
            for prefixSize in [0, 64] {
                let packed = prefixSize == 0 ? fixture.packed
                    : Self.literalBlock(byte: 0x41, count: prefixSize, ppmdSuffix: fixture.packed)
                let decoder = try RAR29Decoder(
                    source: DataByteSource(packed), offset: 0, compressedSize: UInt64(packed.count),
                    expectedSize: UInt64(prefixSize + fixture.payload.count), unpackVersion: 29, method: 0x31,
                    dictionarySize: 4 * 1_024 * 1_024, isSolid: false, limits: ReadLimits(), allowsPPMd: false
                )
                var output = [UInt8](repeating: 0, count: prefixSize + fixture.payload.count + 1)
                for _ in 0..<2 {
                    XCTAssertThrowsError(try output.withUnsafeMutableBytes { try decoder.read(into: $0) }) {
                        XCTAssertEqual($0 as? RAR29Decoder.PrefetchError, .ppmdNotAllowed)
                    }
                    XCTAssertFalse(decoder.isFinished)
                }
            }
            XCTAssertEqual(models.value, 0)
        }
    }

    func testPrefetchHonoursThreadCountAndMemoryBudgetIncludingBothFilterAreas() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = smallArchive()
        let serial = try ArchiveReader.open(data: fixture.data, options: ReaderOptions(decodeThreads: 1))
        _ = try serial.read(serial.entries[0])
        let rar4 = try XCTUnwrap(serial.formatReaderForTesting as? RAR4Reader)
        XCTAssertNil(rar4.prefetcherForTesting)
        let candidate = try XCTUnwrap(rar4.prefetchCandidateForTesting(1))
        let packed = Self.literalBlock(byte: 1, count: fixture.payloads[1].count)
        let window = RAR29Decoder.retainedWindowSize(expectedSize: UInt64(fixture.payloads[1].count), dictionarySize: 65_536)
        let tables = 5 * ((32_768 + 1_024) * MemoryLayout<UInt32>.stride + 32 * MemoryLayout<Int>.stride) + 404 + 20
        XCTAssertEqual(candidate.scratchBytes, packed.count + window + tables + 8 + 2 * RARStandardFilters.rar3WorkAreaSize)

        let starved = try ArchiveReader.open(data: fixture.data, options: ReaderOptions(
            limits: ReadLimits(parallelDecodeMemory: UInt64(2 * RARStandardFilters.rar3WorkAreaSize - 1)), decodeThreads: 8
        ))
        for (index, payload) in fixture.payloads.enumerated() {
            XCTAssertEqual(try starved.read(starved.entries[index]), payload)
        }
        let idle = try XCTUnwrap((starved.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        XCTAssertEqual(idle.liveBatchCount, 0)
        XCTAssertEqual(idle.heldByteCount, 0)
        XCTAssertEqual(idle.servedMemberCount, 0)

        let budget = candidate.scratchBytes + candidate.outputSize + 1
        let bounded = try ArchiveReader.open(data: fixture.data, options: ReaderOptions(
            limits: ReadLimits(parallelDecodeMemory: UInt64(budget)), decodeThreads: 4
        ))
        let prefetcher = try XCTUnwrap((bounded.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        for (index, payload) in fixture.payloads.enumerated() {
            XCTAssertEqual(try bounded.read(bounded.entries[index]), payload)
            XCTAssertLessThanOrEqual(prefetcher.heldByteCount, budget)
        }
        prefetcher.waitForScheduledBatchesForTesting()
        XCTAssertGreaterThan(prefetcher.servedMemberCount, 0)
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
        XCTAssertEqual(prefetcher.heldByteCount, 0)
    }

    func testEligibilityKeepsStoredEncryptedSplitDirectorySolidAndOtherVersionsSerial() throws {
        let payload = Data(repeating: 0x41, count: 64)
        let maximum = UInt32(IndependentEntryPrefetcher.maximumMemberSize)
        let members = [
            member(0, payload: payload),
            member(1, payload: payload, packed: payload, method: 0x30),
            member(2, payload: payload, flags: RAR4FileFlag.encrypted),
            member(3, payload: payload, flags: RAR4FileFlag.splitBefore),
            member(4, payload: payload, flags: RAR4FileFlag.splitAfter),
            member(5, payload: Data(), flags: RAR4FileFlag.dictionaryMask),
            member(6, payload: payload, version: 20),
            member(7, payload: payload, version: 50),
            member(8, payload: Data()),
            member(9, payload: payload, unpackedSize: maximum + 1),
            member(10, payload: payload, unpackedSize: maximum),
            member(11, payload: payload, method: 0x36),
            member(12, payload: payload),
            member(13, payload: payload, flags: RAR4FileFlag.solid),
        ]
        let reader = try RAR4Reader(source: DataByteSource(archive(members, mainFlags: RAR4MainFlag.solid)), options: ReaderOptions(decodeThreads: 2))
        XCTAssertNotNil(reader.prefetchCandidateForTesting(0))
        XCTAssertNotNil(reader.prefetchCandidateForTesting(10), "8 MiB is inclusive")
        for index in [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13] {
            XCTAssertNil(reader.prefetchCandidateForTesting(index), "entry \(index)")
        }
    }

    func testRepeatedEntryStreamKeepsUntakenBatchOutputsAndReopenOwnsItsScheduler() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = smallArchive(count: 3)
        let reader = try ArchiveReader.open(data: fixture.data, options: ReaderOptions(decodeThreads: 2))
        XCTAssertEqual(try reader.stream(reader.entries[0]).readAll(), fixture.payloads[0])
        let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        XCTAssertEqual(try reader.stream(reader.entries[1]).readAll(), fixture.payloads[1])
        XCTAssertEqual(prefetcher.servedMemberCount, 1)
        XCTAssertEqual(try reader.stream(reader.entries[1]).readAll(), fixture.payloads[1])
        XCTAssertEqual(prefetcher.liveBatchCount, 1)
        let reopened = try reader.reopen()
        let reopenedPrefetcher = try XCTUnwrap((reopened.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        XCTAssertFalse(prefetcher === reopenedPrefetcher)
        XCTAssertEqual(reopenedPrefetcher.servedMemberCount, 0)
        for index in [2, 0, 1, 2] { XCTAssertEqual(try reopened.read(reopened.entries[index]), fixture.payloads[index]) }
        XCTAssertEqual(try reader.stream(reader.entries[2]).readAll(), fixture.payloads[2])
        XCTAssertEqual(prefetcher.servedMemberCount, 2)
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
    }

    func testReaderDeinitStopsAnInFlightBatchBetweenMembers() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = smallArchive(count: 4)
        let source = RAR4GatedPackedSource(fixture.data)
        defer { source.release.signal() }
        var reader: RAR4Reader? = try RAR4Reader(source: source, options: ReaderOptions(decodeThreads: 2))
        weak let weakReader = reader
        let target = try XCTUnwrap(reader?.prefetchCandidateForTesting(1)?.packedSegment?.offset)
        let next = try XCTUnwrap(reader?.prefetchCandidateForTesting(2)?.packedSegment?.offset)
        source.arm(at: target)
        let first = try XCTUnwrap(reader?.entries.first)
        _ = try reader?.stream(for: first, limits: ReadLimits()).readAll()
        XCTAssertEqual(source.entered.wait(timeout: .now() + 5), .success)
        let prefetcher = try XCTUnwrap(reader?.prefetcherForTesting)
        XCTAssertEqual(prefetcher.runningBatchCount, 1)
        reader = nil
        XCTAssertNil(weakReader, "workers must not retain the reader")
        XCTAssertEqual(prefetcher.runningBatchCount, 0)
        XCTAssertNil(try prefetcher.take(1))
        source.release.signal()
        let deadline = Date(timeIntervalSinceNow: 5)
        while prefetcher.heldByteCount != 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(prefetcher.heldByteCount, 0)
        XCTAssertFalse(source.requested(next), "shouldStop ends the abandoned batch before another member")
    }

    func testWaitingReaderRunsItsBatchInlineWhenTheSharedPoolIsSaturated() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let pool = LeafDecodePool.shared
        let deadline = Date(timeIntervalSinceNow: 5)
        while pool.runningJobs > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(pool.runningJobs, 0)
        let entered = DispatchSemaphore(value: 0), gate = PrefetchGate()
        defer { gate.open() }
        for _ in 0..<pool.capacity {
            pool.submit(group: LeafDecodePool.Group()) { entered.signal(); gate.wait() }
        }
        for _ in 0..<pool.capacity { XCTAssertEqual(entered.wait(timeout: .now() + 5), .success) }
        let fixture = smallArchive(count: 3)
        let reader = try ArchiveReader.open(data: fixture.data, options: ReaderOptions(decodeThreads: 2))
        XCTAssertEqual(try reader.read(reader.entries[0]), fixture.payloads[0])
        let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR4Reader)?.prefetcherForTesting)
        XCTAssertEqual(try reader.read(reader.entries[1]), fixture.payloads[1])
        XCTAssertEqual(prefetcher.servedMemberCount, 1)
        XCTAssertEqual(pool.runningJobs, pool.capacity, "the consumer did not need another pool slot")
        XCTAssertEqual(try reader.read(reader.entries[2]), fixture.payloads[2])
        gate.open()
        let drained = Date(timeIntervalSinceNow: 5)
        while pool.runningJobs > 0, Date() < drained { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(pool.runningJobs, 0)
    }

    func testRAR4FileCandidatesShareABudgetedPackedSpan() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let fixture = smallArchive(count: 3)
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar4-prefetch-span")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("batch.rar")
        try fixture.data.write(to: url)
        let file = try FileByteSource(url: url)
        let reader = try RAR4Reader(source: file, options: ReaderOptions(decodeThreads: 2), sourceURL: url)
        let members = try (1...2).map { try XCTUnwrap(reader.prefetchCandidateForTesting($0)) }
        let span = try XCTUnwrap(PrefetchedPackedSpan.read(members: members))
        for member in members {
            let segment = try XCTUnwrap(member.packedSegment)
            XCTAssertTrue(span.covers(segment.offset, length: segment.length))
            XCTAssertEqual(try readByteRange(source: span, offset: segment.offset, count: Int(segment.length)),
                           try readByteRange(source: file, offset: segment.offset, count: Int(segment.length)))
        }
        var plan = PrefetchedPackedSpan.Plan()
        for member in members { plan.append(member) }
        _ = try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll()
        let prefetcher = try XCTUnwrap(reader.prefetcherForTesting)
        prefetcher.waitForScheduledBatchesForTesting()
        XCTAssertEqual(prefetcher.heldByteCount, members.reduce(0) { $0 + $1.outputSize + 1 }
                       + members.map(\.scratchBytes).max()! + plan.byteCount)
        for index in 1...2 { XCTAssertEqual(try reader.stream(for: reader.entries[index], limits: ReadLimits()).readAll(), fixture.payloads[index]) }
        XCTAssertEqual(prefetcher.servedMemberCount, 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ delta: Int) { lock.withLock { count += delta } }
}

private final class PrefetchGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    func wait() {
        condition.lock()
        while !opened { condition.wait() }
        condition.unlock()
    }
    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}


private struct RAR4PrefetchBitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    mutating func append(_ value: Int, count: Int) {
        precondition((0...32).contains(count))
        if count < Int.bitWidth {
            precondition(value >= 0 && value < 1 << count)
        }
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            if value & (1 << shift) != 0 {
                bytes[bytes.count - 1] |= 1 << (7 - bitCount % 8)
            }
            bitCount += 1
        }
    }
}

private final class RAR4GatedPackedSource: ByteSource, @unchecked Sendable {
    private let base: DataByteSource
    private let lock = NSLock()
    private var target: UInt64?
    private var requests: [UInt64] = []
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var length: UInt64 { base.length }

    init(_ data: Data) { base = DataByteSource(data) }
    func arm(at offset: UInt64) { lock.withLock { target = offset; requests.removeAll() } }
    func requested(_ offset: UInt64) -> Bool { lock.withLock { requests.contains(offset) } }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let gated = lock.withLock {
            requests.append(offset)
            return target == offset
        }
        if gated {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw KaitoError.truncated }
        }
        return try base.read(into: buffer, at: offset)
    }
}
