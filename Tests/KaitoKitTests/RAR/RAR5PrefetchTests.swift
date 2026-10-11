import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// Independent-member prefetching (RAR5EntryPrefetcher), the recycled decoder
/// state pool and the in-window match copy: every thread count and buffer size
/// must deliver the serial path's bytes, errors and partial output exactly.
final class RAR5PrefetchTests: XCTestCase {
    // MARK: - Generated archives through the public reader

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
        try RAR5TestSupport.requireRAR()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rar5-prefetch-\(UUID().uuidString)", isDirectory: true)
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
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: input,
            paths: files.map(\.name),
            archiveURL: archive,
            options: options
        )
        return Generated(url: archive, files: files)
    }

    /// One read pass over every entry: the bytes delivered before any error and
    /// the error itself, in entry order. This is exactly what a caller observes.
    private struct Observation: Equatable {
        var deliveredCounts: [Int] = []
        var digests: [Data] = []
        var errors: [String] = []
    }

    private func observe(
        _ reader: ArchiveReader,
        order: [Int],
        bufferSize: Int,
        requireSuccess: Bool = false
    ) throws -> Observation {
        var observation = Observation()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for index in order {
            let entry = reader.entries[index]
            guard entry.kind == .file else { continue }
            var total = 0
            var hash = SHA256Digest()
            do {
                let stream = try reader.stream(entry)
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    hash.update(buffer[..<count])
                    total += count
                }
                observation.errors.append("")
            } catch {
                XCTAssertFalse(requireSuccess, "entry \(index) failed: \(error)")
                observation.errors.append(String(describing: error))
            }
            observation.deliveredCounts.append(total)
            observation.digests.append(hash.finalize())
        }
        return observation
    }

    func testPrefetchedMembersMatchSerialDecodingForEveryThreadCountAndOrder() throws {
        for options in [["-m3", "-md128k"], ["-m5", "-md1m"], ["-m3", "-htb"]] {
            let generated = try generate(options: options, suffix: options.joined())
            let serial = try ArchiveReader.open(
                url: generated.url, options: ReaderOptions(decodeThreads: 1)
            )
            XCTAssertNil((serial.formatReaderForTesting as? RAR5Reader)?.prefetcherForTesting)
            let forward = Array(serial.entries.indices)
            let expected = try observe(serial, order: forward, bufferSize: 65_536, requireSuccess: true)
            // Every byte must be the generator's input.
            let byName = Dictionary(uniqueKeysWithValues: generated.files.map { ($0.name, $0.contents) })
            for entry in serial.entries where entry.kind == .file {
                XCTAssertEqual(try serial.read(entry), byName[entry.name], "\(entry.name)")
            }

            // The full matrix runs on the first option set; later sets check
            // a representative thread count and buffer size.
            let full = options == [["-m3", "-md128k"], ["-m5", "-md1m"], ["-m3", "-htb"]][0]
            for threads in full ? [2, 3, 8] : [3] {
                for bufferSize in full ? [1, 4_099, 65_536, 1_048_576] : [4_099, 65_536] {
                    let reader = try ArchiveReader.open(
                        url: generated.url, options: ReaderOptions(decodeThreads: threads)
                    )
                    let rar5 = try XCTUnwrap(reader.formatReaderForTesting as? RAR5Reader)
                    let observed = try observe(reader, order: forward, bufferSize: bufferSize, requireSuccess: true)
                    XCTAssertEqual(observed, expected, "threads \(threads) buffer \(bufferSize) \(options)")
                    if bufferSize == 65_536 {
                        // The forward pass actually went through the prefetcher.
                        XCTAssertNotNil(rar5.prefetcherForTesting)
                        XCTAssertEqual(rar5.prefetcherForTesting?.liveBatchCount, 0)
                        XCTAssertEqual(rar5.prefetcherForTesting?.heldByteCount, 0)
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
                        reordered.digests.append(expected.digests[position])
                        reordered.errors.append(expected.errors[position])
                    }
                    XCTAssertEqual(observed, reordered, "threads \(threads) order \(order.prefix(5))")
                }
            }
        }
    }

    func testCorruptMembersFallBackToSerialDecodingWithIdenticalPartialOutputAndErrors() throws {
        let generated = try generate(options: ["-m3", "-md128k"], suffix: "corrupt")
        var bytes = [UInt8](try Data(contentsOf: generated.url))
        let layouts = try RAR5TestSupport.blockLayouts(in: bytes)
        let dataBlocks = layouts.filter { $0.data.count > 64 }
        XCTAssertGreaterThan(dataBlocks.count, 100)
        // Flip a byte deep inside every ninth member's compressed body, zero a
        // run in another, and truncate the archive inside a late member.
        for (position, layout) in dataBlocks.enumerated() {
            let middle = layout.data.lowerBound + layout.data.count / 2
            switch position % 9 {
            case 0: bytes[middle] ^= 0x5a
            case 4: bytes[layout.data.lowerBound + 8] ^= 0x01
            case 7: for offset in 0..<8 { bytes[middle + offset] = 0 }
            default: break
            }
        }
        let flipped = generated.url.deletingLastPathComponent().appendingPathComponent("flipped.rar")
        try Data(bytes).write(to: flipped)
        let cut = dataBlocks[dataBlocks.count * 9 / 10]
        bytes.removeSubrange((cut.data.lowerBound + cut.data.count / 3)...)
        let truncated = generated.url.deletingLastPathComponent().appendingPathComponent("truncated.rar")
        try Data(bytes).write(to: truncated)
        for threads in [1, 8] {
            XCTAssertThrowsError(try ArchiveReader.open(
                url: truncated, options: ReaderOptions(decodeThreads: threads)
            )) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        }

        for (corrupt, recover) in [(flipped, false), (flipped, true), (truncated, true)] {
            let serial = try ArchiveReader.open(url: corrupt, options: ReaderOptions(
                recoverDamagedArchives: recover, decodeThreads: 1
            ))
            let forward = Array(serial.entries.indices)
            // Single-byte reads expose partial output before an error; they are
            // slow, so one thread count takes them.
            var expectedByBuffer: [Int: Observation] = [:]
            for bufferSize in [1, 4_099, 65_536] {
                expectedByBuffer[bufferSize] = try observe(serial, order: forward, bufferSize: bufferSize)
            }
            let failures = expectedByBuffer[4_099]!.errors.filter { !$0.isEmpty }.count
            XCTAssertGreaterThan(failures, 10, "the mutation must hit members")
            XCTAssertLessThan(failures, expectedByBuffer[4_099]!.errors.count, "and leave members intact")

            for threads in [2, 3, 8] {
                for bufferSize in threads == 8 ? [1, 4_099, 65_536] : [4_099, 65_536] {
                    let reader = try ArchiveReader.open(url: corrupt, options: ReaderOptions(
                        recoverDamagedArchives: recover, decodeThreads: threads
                    ))
                    let observed = try observe(reader, order: forward, bufferSize: bufferSize)
                    XCTAssertEqual(
                        observed, expectedByBuffer[bufferSize]!,
                        "threads \(threads) buffer \(bufferSize) recover \(recover)"
                    )
                }
            }
        }
    }

    func testPrefetchHonoursThreadCountAndMemoryBudget() throws {
        var files: [Data] = []
        var expected: [Data] = []
        for index in 0..<40 {
            let size = 1 + (index * 7_919) % 16_384
            let payload = Data(repeating: UInt8(index), count: size)
            expected.append(payload)
            files.append(RAR5TestSupport.storedFile(
                name: "entry-\(index).bin", contents: RAR5DecoderTests.literalBlock(byte: UInt8(index), count: size),
                unpackedSize: UInt64(size), dataCRC32: CRC32.checksum(payload),
                compressionInfo: (3 << 7) | (5 << 10) // method 3, 4 MiB
            ))
        }
        let archive = RAR5TestSupport.archive(blocks: files)

        // Serial: no prefetcher at all.
        let serial = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: 1))
        _ = try serial.read(serial.entries[0])
        XCTAssertNil((serial.formatReaderForTesting as? RAR5Reader)?.prefetcherForTesting)

        // A budget below one member keeps the prefetcher idle but correct.
        let starved = try ArchiveReader.open(data: archive, options: ReaderOptions(
            limits: ReadLimits(parallelDecodeMemory: 1_024), decodeThreads: 8
        ))
        for index in expected.indices {
            XCTAssertEqual(try starved.read(starved.entries[index]), expected[index])
        }
        let starvedPrefetcher = try XCTUnwrap((starved.formatReaderForTesting as? RAR5Reader)?.prefetcherForTesting)
        XCTAssertEqual(starvedPrefetcher.liveBatchCount, 0)
        XCTAssertEqual(starvedPrefetcher.heldByteCount, 0)
        XCTAssertEqual((starved.formatReaderForTesting as? RAR5Reader)?.pooledScratchByteCount, 0)

        // A normal budget decodes ahead and releases everything when consumed.
        let parallel = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: 4))
        for index in expected.indices {
            XCTAssertEqual(try parallel.read(parallel.entries[index]), expected[index])
        }
        let prefetcher = try XCTUnwrap((parallel.formatReaderForTesting as? RAR5Reader)?.prefetcherForTesting)
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
        XCTAssertEqual(prefetcher.heldByteCount, 0)
    }

    // MARK: - Prefetcher scheduling with synthetic batches

    func testAbandonDoesNotDecrementRunningCountAfterAnInFlightBatchFinishes() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let entered = expectation(description: "batch entered decoder")
        let gate = PrefetchGate()
        defer { gate.open() }
        let prefetcher = try XCTUnwrap(RAR5EntryPrefetcher(
            workers: 2, memoryBudget: 4_096, memberCount: 4,
            candidate: { RAR5EntryPrefetcher.Candidate(index: $0, outputSize: 64, scratchBytes: 128) },
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

    func testRepeatedEntryStreamKeepsUntakenBatchOutputs() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let payloads = (0..<3).map { Data(repeating: UInt8($0), count: 64) }
        let files = payloads.enumerated().map { index, payload in
            RAR5TestSupport.storedFile(
                name: "entry-\(index)", contents: RAR5DecoderTests.literalBlock(byte: UInt8(index), count: payload.count),
                unpackedSize: UInt64(payload.count), dataCRC32: CRC32.checksum(payload),
                compressionInfo: (3 << 7) | (5 << 10)
            )
        }
        let reader = try ArchiveReader.open(data: RAR5TestSupport.archive(blocks: files),
                                            options: ReaderOptions(decodeThreads: 2))
        XCTAssertEqual(try reader.stream(reader.entries[0]).readAll(), payloads[0])
        let prefetcher = try XCTUnwrap((reader.formatReaderForTesting as? RAR5Reader)?.prefetcherForTesting)
        XCTAssertEqual(try reader.stream(reader.entries[1]).readAll(), payloads[1])
        XCTAssertEqual(prefetcher.servedMemberCount, 1)
        XCTAssertEqual(try reader.stream(reader.entries[1]).readAll(), payloads[1])
        XCTAssertEqual(prefetcher.liveBatchCount, 1, "the other entry still owns its output")
        XCTAssertEqual(try reader.stream(reader.entries[2]).readAll(), payloads[2])
        XCTAssertEqual(prefetcher.servedMemberCount, 2, "the other entry came from the batch")
        XCTAssertEqual(prefetcher.liveBatchCount, 0)
    }

    func testFailedAndRepeatedTakesDoNotConsumeOtherOutputs() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let prefetcher = try XCTUnwrap(RAR5EntryPrefetcher(
            workers: 2, memoryBudget: 4_096, memberCount: 4,
            candidate: { RAR5EntryPrefetcher.Candidate(index: $0, outputSize: 64, scratchBytes: 128) },
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
        let prefetcher = try XCTUnwrap(RAR5EntryPrefetcher(
            workers: 2, memoryBudget: budget, memberCount: 4,
            candidate: { index in
                RAR5EntryPrefetcher.Candidate(
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
        let prefetcher = try XCTUnwrap(RAR5EntryPrefetcher(
            workers: 3,
            memoryBudget: 1 << 30,
            memberCount: 1_000,
            candidate: { index in
                // Every third member is ineligible; member 500 is "too large".
                guard index % 3 != 2 else { return nil }
                return RAR5EntryPrefetcher.Candidate(
                    index: index,
                    outputSize: index == 500 ? RAR5EntryPrefetcher.maximumMemberSize + 1 : 64,
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
        XCTAssertNil(RAR5EntryPrefetcher(
            workers: 1, memoryBudget: 1 << 30, memberCount: 10,
            candidate: { _ in nil }, decodeBatch: { _, _ in [] }
        ))
        let prefetcher = try XCTUnwrap(RAR5EntryPrefetcher(
            workers: 4, memoryBudget: 3 * 1_024 + 2 * 128 + 10, memberCount: 100,
            candidate: { RAR5EntryPrefetcher.Candidate(index: $0, outputSize: 1_024, scratchBytes: 128) },
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

    // MARK: - Recycled decoder states

    func testScratchPoolBudgetCountsWindowsInputBuffersAndTables() throws {
        let packed = RAR5DecoderTests.literalBlock(byte: 0x41, count: 512)
        func populatedState() throws -> RAR5Decoder.SolidState {
            let state = try RAR5Decoder.SolidState(dictionarySize: 128 * 1_024)
            _ = try RAR5Decoder(
                source: DataByteSource(packed), offset: 0, compressedSize: UInt64(packed.count),
                expectedSize: 512, dictionarySize: 128 * 1_024, limits: ReadLimits(), independentState: state
            )
            return state
        }
        let bytes = 128 * 1_024 + packed.count + 16 + RAR5Decoder.ScratchPool.stateOverheadBytes
        let pool = RAR5Decoder.ScratchPool(capacity: 8, memoryBudget: 2 * bytes - 1)
        let first = try populatedState(), second = try populatedState()
        pool.recycle(first)
        pool.recycle(second)
        XCTAssertEqual(pool.freeCount, 1, "input buffers make two states exceed this budget")
        XCTAssertEqual(pool.heldByteCount, bytes)
        XCTAssertTrue(pool.take(windowSize: 128 * 1_024) === first)
        XCTAssertEqual(pool.heldByteCount, 0)
        pool.recycle(second)
        XCTAssertEqual(pool.heldByteCount, bytes, "taking a state releases its pool allowance")
        let disabled = RAR5Decoder.ScratchPool(capacity: 8, memoryBudget: 0)
        disabled.recycle(first)
        XCTAssertEqual(disabled.freeCount, 0)
        XCTAssertEqual(disabled.heldByteCount, 0)
    }

    func testScratchPoolHandsOutSmallestFittingStateAndCapsRetention() throws {
        let pool = RAR5Decoder.ScratchPool(capacity: 2)
        XCTAssertNil(pool.take(windowSize: 128 * 1_024))
        let small = try RAR5Decoder.SolidState(dictionarySize: 128 * 1_024)
        let medium = try RAR5Decoder.SolidState(dictionarySize: 512 * 1_024)
        let large = try RAR5Decoder.SolidState(dictionarySize: 2 * 1_024 * 1_024)
        small.historySize = 5
        small.windowPosition = 5
        small.lastLength = 9
        pool.recycle(medium)
        pool.recycle(small)
        pool.recycle(large)
        XCTAssertEqual(pool.freeCount, 2, "capacity bounds the free list")
        XCTAssertTrue(pool.take(windowSize: 256 * 1_024) === medium, "smallest state that fits")
        let reused = try XCTUnwrap(pool.take(windowSize: 128 * 1_024))
        XCTAssertTrue(reused === small)
        XCTAssertEqual(reused.historySize, 0)
        XCTAssertEqual(reused.windowPosition, 0)
        XCTAssertEqual(reused.lastLength, 0)
        XCTAssertFalse(reused.tablesWereRead)
        XCTAssertNil(pool.take(windowSize: 128 * 1_024))
        // Oversized states are released instead of retained.
        let huge = try RAR5Decoder.SolidState(dictionarySize: UInt64(RAR5Decoder.ScratchPool.maximumRecycledBytes * 2))
        pool.recycle(huge)
        XCTAssertEqual(pool.freeCount, 0)
    }

    /// A recycled or batch state may carry a ring larger than the member's own
    /// dictionary. The match-distance bound must stay the member's window, so
    /// a corrupt far match is rejected at the same output offset with the same
    /// error whether the ring is fresh, pooled or caller-owned.
    func testOversizedRecycledRingKeepsTheMemberDictionaryBoundOnMatches() throws {
        let dictionarySize = 128 * 1_024
        let literals = 300_000
        // 300000 literals, then one length-4 match at distance 204801: beyond
        // the 128 KiB dictionary but inside a 256 KiB ring's history.
        let (stream, distance) = Self.literalsThenFarMatch(literals: literals, high: 512)
        XCTAssertEqual(distance, 204_801)
        let expectedSize = UInt64(literals + 4)

        struct Outcome: Equatable { let delivered: Int; let error: String? }
        func drain(_ decoder: RAR5Decoder, bufferSize: Int) -> Outcome {
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var total = 0
            do {
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    if count == 0 { break }
                    total += count
                }
                return Outcome(delivered: total, error: nil)
            } catch {
                return Outcome(delivered: total, error: "\(error)")
            }
        }
        func fresh() throws -> RAR5Decoder {
            try RAR5Decoder(
                source: DataByteSource(data: stream), offset: 0,
                compressedSize: UInt64(stream.count), expectedSize: expectedSize,
                dictionarySize: UInt64(dictionarySize), limits: ReadLimits()
            )
        }
        func pooled() throws -> RAR5Decoder {
            let pool = RAR5Decoder.ScratchPool(capacity: 4)
            pool.recycle(try RAR5Decoder.SolidState(dictionarySize: 2 * UInt64(dictionarySize)))
            return try RAR5Decoder(
                source: DataByteSource(data: stream), offset: 0,
                compressedSize: UInt64(stream.count), expectedSize: expectedSize,
                dictionarySize: UInt64(dictionarySize), limits: ReadLimits(), scratchPool: pool
            )
        }
        func batch() throws -> RAR5Decoder {
            let state = try RAR5Decoder.SolidState(dictionarySize: 4 * UInt64(dictionarySize))
            return try RAR5Decoder(
                source: DataByteSource(data: stream), offset: 0,
                compressedSize: UInt64(stream.count), expectedSize: expectedSize,
                dictionarySize: UInt64(dictionarySize), limits: ReadLimits(), independentState: state
            )
        }

        for bufferSize in [1, 4_099, 65_536, 1_048_576] {
            let reference = drain(try fresh(), bufferSize: bufferSize)
            let message = try XCTUnwrap(reference.error, "fresh ring rejects the far match (buffer \(bufferSize))")
            XCTAssertTrue(message.contains("RAR5 invalid LZ match at output 300000: distance 204801"), message)
            XCTAssertTrue(message.contains("window \(dictionarySize)"), message)
            XCTAssertLessThanOrEqual(reference.delivered, literals)
            XCTAssertEqual(drain(try pooled(), bufferSize: bufferSize), reference, "pooled 256 KiB ring, buffer \(bufferSize)")
            XCTAssertEqual(drain(try batch(), bufferSize: bufferSize), reference, "batch 512 KiB ring, buffer \(bufferSize)")
        }

        // The same bound must not reject a match the member may make: a
        // distance inside the dictionary decodes identically with every ring.
        let (valid, validDistance) = Self.literalsThenFarMatch(literals: literals, high: 0)
        XCTAssertEqual(validDistance, 196_609)
        for bufferSize in [1, 4_099, 65_536] {
            let makeDecoder: (RAR5Decoder.SolidState?) throws -> RAR5Decoder = { state in
                try RAR5Decoder(
                    source: DataByteSource(data: valid), offset: 0,
                    compressedSize: UInt64(valid.count), expectedSize: expectedSize,
                    dictionarySize: 256 * 1_024, limits: ReadLimits(), independentState: state
                )
            }
            let reference = drain(try makeDecoder(nil), bufferSize: bufferSize)
            XCTAssertEqual(reference, Outcome(delivered: literals + 4, error: nil))
            let large = try RAR5Decoder.SolidState(dictionarySize: 1_024 * 1_024)
            XCTAssertEqual(drain(try makeDecoder(large), bufferSize: bufferSize), reference)
        }
    }

    /// `literals` copies of 'A' (one-bit literal code), then one match of
    /// length 2 (+2 for distance > 0x4000) at `196608 + 16 * high + 1`
    /// (distance slot 35 with 16 extra bits, low-distance symbol 0).
    private static func literalsThenFarMatch(literals: Int, high: Int) -> (Data, Int) {
        precondition((0..<4_096).contains(high))
        var bits = RAR5PrefetchBitWriter()
        // Bit-length alphabet: symbols 0 and 1 are one-bit codes. Combined
        // tables: main 65 -> '0', main 262 -> '1'; distance slot 35 -> '0';
        // low distance symbol 0 -> '0'.
        for index in 0..<20 { bits.append(index < 2 ? 1 : 0, count: 4) }
        let ones: Set<Int> = [65, 262, 306 + 35, 370]
        for index in 0..<430 { bits.append(ones.contains(index) ? 1 : 0, count: 1) }
        for _ in 0..<literals { bits.append(0, count: 1) }
        bits.append(1, count: 1)       // main 262: length slot 0 -> length 2
        bits.append(0, count: 1)       // distance slot 35: 16 extra bits
        bits.append(high, count: 12)   // high bits
        bits.append(0, count: 1)       // low distance symbol 0
        let payload = bits.bytes
        let sizeByteCount = payload.count <= 0xff ? 1 : (payload.count <= 0xffff ? 2 : 3)
        var flags = UInt8(bits.validBitsInFinalByte - 1) | UInt8(sizeByteCount - 1) << 3
        flags |= 0x40 | 0x80
        var sizeBytes: [UInt8] = []
        for index in 0..<sizeByteCount {
            sizeBytes.append(UInt8(truncatingIfNeeded: payload.count >> (index * 8)))
        }
        var checksum = UInt8(0x5a) ^ flags
        for byte in sizeBytes { checksum ^= byte }
        return (Data([flags, checksum] + sizeBytes + payload), 196_608 + 16 * high + 1)
    }

    // MARK: - In-window match copy

    func testWindowMatchCopyMatchesBytewiseOracleAcrossWrapsAndShortPeriods() {
        for windowSize in [64, 1_024, 128 * 1_024] {
            let mask = windowSize - 1
            var oracle = (0..<windowSize).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 >> 3) }
            let window = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSize)
            defer { window.deallocate() }
            window.update(from: oracle, count: windowSize)
            var position = windowSize - 3
            var oraclePosition = position
            var seed: UInt64 = UInt64(windowSize)
            for step in 0..<2_000 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let distance: Int
                switch step % 5 {
                case 0: distance = 1 + Int(seed >> 60) % 7            // 1...7
                case 1: distance = 8 + Int(seed >> 56) % 24           // 8...31
                case 2: distance = windowSize                          // the whole ring
                case 3: distance = windowSize - 1 - Int(seed >> 59) % 5
                default: distance = 1 + Int(seed >> 40) % windowSize
                }
                let count = 1 + Int(seed >> 20) % (step % 7 == 0 ? windowSize : 40)
                copyMatchWithinWindow(
                    window: window, windowMask: mask, position: &position,
                    distance: distance, count: count
                )
                for _ in 0..<count {
                    oracle[oraclePosition] = oracle[(oraclePosition - distance) & mask]
                    oraclePosition = (oraclePosition + 1) & mask
                }
                XCTAssertEqual(position, oraclePosition)
                if step % 97 == 0 || step == 1_999 {
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: window, count: windowSize)), oracle, "window \(windowSize) step \(step)")
                }
            }
        }
    }
}

private struct RAR5PrefetchBitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    var validBitsInFinalByte: Int {
        precondition(bitCount > 0)
        return (bitCount - 1) % 8 + 1
    }

    mutating func append(_ value: Int, count: Int) {
        precondition((0...32).contains(count))
        precondition(value >= 0 && value < 1 << count)
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            if value & (1 << shift) != 0 {
                bytes[bytes.count - 1] |= 1 << (7 - bitCount % 8)
            }
            bitCount += 1
        }
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

private struct SHA256Digest {
    private var hasher = SHA256()
    mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        hasher.update(data: Data(bytes))
    }
    func finalize() -> Data { Data(hasher.finalize()) }
}
