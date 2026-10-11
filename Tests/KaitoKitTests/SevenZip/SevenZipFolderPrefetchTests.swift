import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

/// 非 solid 7z（folder ごとに一つの substream）の先行復号。手組みの多 folder header と raw LZMA2 chunk
/// だけで作るので外部 tool は要らない。出力・順序・エラー時の部分出力を直列経路と比べる。
final class SevenZipFolderPrefetchTests: XCTestCase {
    private struct Fixture {
        var payloads: [Data]
        var packed: [Data]
        var folderCRCs: [UInt32?]
        var entryCRCs: [UInt32?]

        static func make(sizes: [Int], folderCRC: Bool = false, seed: UInt8 = 1) -> Fixture {
            let payloads = sizes.enumerated().map { id, size in
                Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ (id &+ Int(seed))) })
            }
            let packed = payloads.map { SevenZipParallelTestSupport.rawUnit($0) + Data([0]) }
            return Fixture(payloads: payloads, packed: packed,
                           folderCRCs: payloads.map { folderCRC ? CRC32.checksum($0) : nil },
                           entryCRCs: payloads.map { folderCRC ? nil : CRC32.checksum($0) })
        }

        var output: Data { payloads.reduce(into: Data()) { $0.append($1) } }

        /// packed stream の先頭を 7z の packed 領域内 offset で返す（破損を仕込む位置の計算用）。
        func packedOffset(ofFolder index: Int) -> Int {
            32 + packed.prefix(index).reduce(0) { $0 + $1.count }
        }

        func archive() -> Data {
            let count = payloads.count
            var header: [UInt8] = [0x01, 0x04, 0x06] + number(0) + number(UInt64(count)) + [0x09]
            for stream in packed { header += number(UInt64(stream.count)) }
            header += [0, 0x07, 0x0B] + number(UInt64(count)) + [0]
            for _ in 0..<count { header += number(1) + [0x21, 0x21] + number(1) + [8] }
            header += [0x0C]
            for payload in payloads { header += number(UInt64(payload.count)) }
            if folderCRCs.allSatisfy({ $0 != nil }) {
                header += [0x0A, 1]
                for crc in folderCRCs { header += SevenZipEditTestBytes.little(crc!) }
            }
            header += [0, 0x08]
            if folderCRCs.contains(where: { $0 == nil }) {
                header += [0x0A, 1]
                for (index, crc) in entryCRCs.enumerated() where folderCRCs[index] == nil {
                    header += SevenZipEditTestBytes.little(crc!)
                }
            }
            header += [0, 0, 0x05] + number(UInt64(count))
            var names: [UInt8] = [0]
            for index in 0..<count {
                for unit in "entry-\(index).bin".utf16 { names += SevenZipEditTestBytes.little(unit) }
                names += [0, 0]
            }
            header += [0x11] + number(UInt64(names.count)) + names + [0, 0]
            let packedBytes = packed.reduce(into: [UInt8]()) { $0 += $1 }
            return SevenZipEditTestBytes.archive(header: header, packed: packedBytes)
        }

        private func number(_ value: UInt64) -> [UInt8] {
            for count in 0..<8 where value < (UInt64(1) << (7 + count * 7)) {
                let prefix = UInt8(truncatingIfNeeded: 0xFF << (8 - count))
                return [prefix | UInt8(value >> (count * 8))]
                    + (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
            }
            return [0xFF] + (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    private final class CapturedInput: Sendable {}

    private struct Outcome: Equatable {
        let bytes: Data
        let error: KaitoError?
    }

    private func outcome(_ reader: SevenZipReader, entry: ArchiveEntry, chunk: Int) -> Outcome {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        do {
            let stream = try reader.stream(for: entry, limits: ReadLimits())
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return Outcome(bytes: bytes, error: nil)
        } catch {
            XCTAssertTrue(error is KaitoError, "\(error)")
            return Outcome(bytes: bytes, error: error as? KaitoError)
        }
    }

    private static let smallSizes: [Int] = (0..<300).map { 700 + ($0 * 37) % 1_900 } + [70_003, 131_077]

    func testSequentialReadMatchesSerialAndUsesPrefetch() throws {
        for folderCRC in [false, true] {
            let fixture = Fixture.make(sizes: Self.smallSizes, folderCRC: folderCRC), archive = fixture.archive()
            for threads: Int? in [1, nil, 16] {
                let reader = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: threads))
                XCTAssertEqual(reader.entries.count, fixture.payloads.count)
                XCTAssertTrue(reader.entries.allSatisfy { $0.solidGroup < 0 })
                for (index, entry) in reader.entries.enumerated() {
                    XCTAssertEqual(try reader.stream(for: entry, limits: ReadLimits()).readAll(), fixture.payloads[index])
                }
                if threads == 1 {
                    XCTAssertNil(reader.prefetchStatistics, "one thread must not create a prefetcher")
                } else if LeafDecodePool.shared.capacity > 1 {
                    let statistics = try XCTUnwrap(reader.prefetchStatistics)
                    XCTAssertGreaterThan(statistics.servedFolders, fixture.payloads.count / 2)
                    XCTAssertGreaterThan(statistics.batches, 1, "small folders must be batched, not one job each")
                    XCTAssertLessThan(statistics.batches, fixture.payloads.count / 4)
                    XCTAssertEqual(statistics.heldBytes, 0, "every batch must be released after its folders are taken")
                }
            }
        }
    }

    func testReverseRandomAndRepeatedAccessMatchPayloads() throws {
        let fixture = Fixture.make(sizes: Self.smallSizes), archive = fixture.archive()
        let reader = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 16))
        let entries = reader.entries
        for index in entries.indices.reversed() {
            XCTAssertEqual(try reader.stream(for: entries[index], limits: ReadLimits()).readAll(), fixture.payloads[index])
        }
        var generator = SystemRandomNumberGenerator()
        var order = Array(entries.indices)
        order.shuffle(using: &generator)
        for index in order + [5, 5, 5, 300, 7, 301, 0] {
            XCTAssertEqual(try reader.stream(for: entries[index], limits: ReadLimits()).readAll(), fixture.payloads[index])
        }
        // 順方向に飛び飛びに読む: 飛ばした folder の先行復号は捨てられ、読んだものは一致する。
        for index in stride(from: 0, to: entries.count, by: 7) {
            XCTAssertEqual(try reader.stream(for: entries[index], limits: ReadLimits()).readAll(), fixture.payloads[index])
        }
        for index in entries.indices {
            XCTAssertEqual(try reader.stream(for: entries[index], limits: ReadLimits()).readAll(), fixture.payloads[index])
        }
        XCTAssertEqual(try XCTUnwrap(reader.prefetchStatistics).heldBytes, 0)
    }

    func testStreamsInterleavedAcrossEntriesStayIndependent() throws {
        let fixture = Fixture.make(sizes: Self.smallSizes), archive = fixture.archive()
        let reader = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 16))
        var streams: [EntryStream] = []
        for entry in reader.entries.prefix(40) { streams.append(try reader.stream(for: entry, limits: ReadLimits())) }
        for (index, stream) in streams.enumerated() { XCTAssertEqual(try stream.readAll(), fixture.payloads[index]) }
    }

    func testCorruptAndMismatchedFoldersMatchSerialPartialOutputAtEveryBufferSize() throws {
        var fixture = Fixture.make(sizes: Self.smallSizes)
        // folder 150 の二つ目の raw chunk header を壊す（無効な control byte）。
        var corrupt = fixture.packed[150]
        XCTAssertGreaterThan(corrupt.count, 3)
        corrupt[0] = 3
        fixture.packed[150] = corrupt
        // folder 301（二 chunk の大きな folder）は末尾を切り詰める。
        fixture.packed[301] = fixture.packed[301].dropLast(5)
        // folder 20 は entry CRC だけを壊す。folder 21 は payload を壊して CRC 不一致にする。
        fixture.entryCRCs[20] = fixture.entryCRCs[20]! ^ 1
        var swapped = fixture.packed[21]
        swapped[3] ^= 0xFF
        fixture.packed[21] = swapped
        let archive = fixture.archive()
        let serial = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 1))
        for chunk in [1, 4_099, 65_536, 1 << 20] {
            let parallel = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 16))
            var failures = 0
            for (index, entry) in serial.entries.enumerated() {
                let expected = outcome(serial, entry: entry, chunk: chunk)
                if expected.error != nil { failures += 1 } else { XCTAssertEqual(expected.bytes, fixture.payloads[index]) }
                XCTAssertEqual(outcome(parallel, entry: parallel.entries[index], chunk: chunk), expected,
                               "entry \(index) chunk \(chunk)")
            }
            XCTAssertEqual(failures, 4)
            if LeafDecodePool.shared.capacity > 1 {
                let statistics = try XCTUnwrap(parallel.prefetchStatistics)
                XCTAssertGreaterThan(statistics.servedFolders, fixture.payloads.count / 2)
                XCTAssertEqual(statistics.heldBytes, 0)
            }
        }
    }

    func testMemoryBudgetAndSingleThreadKeepSerialPath() throws {
        let fixture = Fixture.make(sizes: Self.smallSizes), archive = fixture.archive()
        let tiny = try SevenZipReader(source: DataByteSource(archive),
                                      options: ReaderOptions(limits: ReadLimits(parallelDecodeMemory: 4_096), decodeThreads: 16))
        for (index, entry) in tiny.entries.enumerated() {
            XCTAssertEqual(try tiny.stream(for: entry, limits: ReadLimits()).readAll(), fixture.payloads[index])
        }
        if let statistics = tiny.prefetchStatistics {
            XCTAssertEqual(statistics.batches, 0)
            XCTAssertEqual(statistics.servedFolders, 0)
        }
        // 予算が batch 一つ分なら、投入は一度に一つで出力は変わらない。
        let bounded = try SevenZipReader(source: DataByteSource(archive),
                                         options: ReaderOptions(limits: ReadLimits(parallelDecodeMemory: 2 << 20), decodeThreads: 16))
        for (index, entry) in bounded.entries.enumerated() {
            XCTAssertEqual(try bounded.stream(for: entry, limits: ReadLimits()).readAll(), fixture.payloads[index])
            if let statistics = bounded.prefetchStatistics { XCTAssertLessThanOrEqual(statistics.heldBytes, 2 << 20) }
        }
    }

    func testBudgetThatFitsOnlyThreeFoldersStillMakesPrefetchProgress() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity < 2, "needs two workers")
        let budget = (1 << 19) + 4 * 1_024 + 3 // LZMA2 scratch + three outputs and their end bytes.
        for corrupt in [false, true] {
            var fixture = Fixture.make(sizes: Array(repeating: 1_024, count: 40))
            if corrupt {
                fixture.entryCRCs[5]! ^= 1
                fixture.packed[17][0] = 3
            }
            let archive = fixture.archive()
            for threads in [2, 8] {
                for chunk in [1, 4_099, 65_536] {
                    let serial = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 1))
                    let reader = try SevenZipReader(
                        source: DataByteSource(archive),
                        options: ReaderOptions(limits: ReadLimits(parallelDecodeMemory: UInt64(budget)), decodeThreads: threads)
                    )
                    for (index, entry) in reader.entries.enumerated() {
                        let expected = outcome(serial, entry: serial.entries[index], chunk: chunk)
                        if !corrupt { XCTAssertEqual(expected.bytes, fixture.payloads[index]); XCTAssertNil(expected.error) }
                        XCTAssertEqual(outcome(reader, entry: entry, chunk: chunk), expected,
                                       "entry \(index), threads \(threads), chunk \(chunk), corrupt \(corrupt)")
                        if let statistics = reader.prefetchStatistics { XCTAssertLessThanOrEqual(statistics.heldBytes, budget) }
                    }
                    let statistics = try XCTUnwrap(reader.prefetchStatistics)
                    XCTAssertGreaterThan(statistics.servedFolders, fixture.payloads.count / 2,
                                         "individually eligible folders must still be prefetched with a small budget")
                    XCTAssertGreaterThan(statistics.batches, 1)
                    XCTAssertEqual(statistics.heldBytes, 0)
                }
            }
        }
    }

    /// 先行復号は folder の出力を丸ごと保持するので、大きな folder（prefetchMaxUnitBytes 超）と
    /// maxInMemorySize を超える folder は投入せず、従来の経路に任せる。境界は「以下」。
    func testLargeFoldersAndMaxInMemorySizeStayOnSerialPath() throws {
        try XCTSkipIf(LeafDecodePool.shared.capacity <= 1, "needs a pool with more than one worker")
        let cap = Int(SevenZipReader.prefetchMaxUnitBytes)
        XCTAssertEqual(cap, 1 << 20)

        func read(_ reader: SevenZipReader, _ fixture: Fixture) throws {
            for (index, entry) in reader.entries.enumerated() {
                XCTAssertEqual(try reader.stream(for: entry, limits: ReadLimits()).readAll(), fixture.payloads[index])
            }
        }
        func servedFolders(_ reader: SevenZipReader) -> Int { reader.prefetchStatistics?.servedFolders ?? 0 }

        // 上限を 1 byte 超える folder だけの書庫: 何も投入されない（batch 0、保持 0）。
        let over = Fixture.make(sizes: Array(repeating: cap + 1, count: 4), seed: 3)
        let overReader = try SevenZipReader(source: DataByteSource(over.archive()), options: ReaderOptions(decodeThreads: 16))
        try read(overReader, over)
        if let statistics = overReader.prefetchStatistics {
            XCTAssertEqual(statistics.batches, 0)
            XCTAssertEqual(statistics.servedFolders, 0)
            XCTAssertEqual(statistics.heldBytes, 0)
        }

        // ちょうど上限の folder は投入される。
        let exact = Fixture.make(sizes: Array(repeating: cap, count: 4), seed: 5)
        let exactReader = try SevenZipReader(source: DataByteSource(exact.archive()), options: ReaderOptions(decodeThreads: 16))
        try read(exactReader, exact)
        XCTAssertGreaterThan(servedFolders(exactReader), 0)
        XCTAssertEqual(try XCTUnwrap(exactReader.prefetchStatistics).heldBytes, 0)

        // 大小の混在: 小さな folder は先行復号され、大きな folder は数に入らない。
        let mixedSizes = [900, cap + 7, 1_300, 2_100, cap + 70_001, 1_700, 800, 2_900, cap + 1, 1_100, 1_900, 1_500]
        let mixed = Fixture.make(sizes: mixedSizes, folderCRC: true, seed: 7)
        let mixedReader = try SevenZipReader(source: DataByteSource(mixed.archive()), options: ReaderOptions(decodeThreads: 16))
        try read(mixedReader, mixed)
        let small = mixedSizes.filter { $0 <= cap }.count
        let mixedStatistics = try XCTUnwrap(mixedReader.prefetchStatistics)
        // 先頭の 2 entry は順方向の読みを観測する前なので直列。
        XCTAssertLessThanOrEqual(mixedStatistics.servedFolders, small)
        XCTAssertGreaterThanOrEqual(mixedStatistics.servedFolders, small - 2)
        XCTAssertEqual(mixedStatistics.heldBytes, 0)

        // maxInMemorySize は reader の options.limits で見る（stream(for:limits:) の引数ではない）。
        let uniform = Fixture.make(sizes: Array(repeating: 3_000, count: 64), seed: 9)
        let archive = uniform.archive()
        let tooSmall = try SevenZipReader(
            source: DataByteSource(archive),
            options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 2_999), decodeThreads: 16)
        )
        try read(tooSmall, uniform)
        XCTAssertEqual(tooSmall.prefetchStatistics?.batches ?? 0, 0)
        XCTAssertEqual(servedFolders(tooSmall), 0)
        let fits = try SevenZipReader(
            source: DataByteSource(archive),
            options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 3_000), decodeThreads: 16)
        )
        try read(fits, uniform)
        XCTAssertGreaterThan(servedFolders(fits), 0)
    }

    func testReopenedReaderStartsWithoutPrefetchStateAndReleasesOnDeinit() throws {
        let fixture = Fixture.make(sizes: Self.smallSizes), archive = fixture.archive()
        var reader: SevenZipReader? = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 16))
        for entry in reader!.entries.prefix(3) { _ = try reader!.stream(for: entry, limits: ReadLimits()).readAll() }
        let reopened = try XCTUnwrap(reader!.reopened(options: ReaderOptions(decodeThreads: 16)) as? SevenZipReader)
        XCTAssertNil(reopened.prefetchStatistics)
        XCTAssertEqual(try reopened.stream(for: reopened.entries[10], limits: ReadLimits()).readAll(), fixture.payloads[10])
        let before = LeafDecodePool.shared.runningJobs
        reader = nil
        let deadline = Date(timeIntervalSinceNow: 3)
        while LeafDecodePool.shared.runningJobs > before, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertLessThanOrEqual(LeafDecodePool.shared.runningJobs, before)
    }

    func testCancelledTaskStopsWaitingForPrefetchedFolder() async throws {
        let fixture = Fixture.make(sizes: Self.smallSizes), archive = fixture.archive()
        let holder = Mutex<Task<Void, any Error>?>(nil)
        let task = Task.detached {
            try await LeafDecodePool.$testingSubmission.withValue({ holder.withLock { $0?.cancel() } }) {
                let reader = try SevenZipReader(source: DataByteSource(archive), options: ReaderOptions(decodeThreads: 16))
                for entry in reader.entries { _ = try reader.stream(for: entry, limits: ReadLimits()).readAll() }
            }
        }
        holder.withLock { $0 = task }
        do {
            try await task.value
            XCTFail("reading after the first submission must observe the cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testDiscardReleasesUnstartedTicket() {
        let blocks = Mutex<[@Sendable () -> Void]>([])
        let pool = LeafDecodePool(capacity: 1, executor: { block in blocks.withLock { $0.append(block) } })
        let ran = Mutex(0)
        let first = pool.submit(group: LeafDecodePool.Group()) { ran.withLock { $0 += 1 } }
        var capture: CapturedInput? = CapturedInput()
        weak let queuedCapture = capture
        let second = pool.submit(group: LeafDecodePool.Group()) { [capture] in
            withExtendedLifetime(capture) {}; ran.withLock { $0 += 1 }
        }
        capture = nil
        XCTAssertNotNil(queuedCapture)
        XCTAssertTrue(pool.discard(second))
        XCTAssertNil(queuedCapture, "a discarded pending ticket must release its captures")
        XCTAssertFalse(pool.runInline(second))
        XCTAssertTrue(pool.discard(first))
        blocks.withLock { $0 }.forEach { $0() }
        XCTAssertEqual(ran.withLock { $0 }, 0)
        XCTAssertEqual(pool.runningJobs, 0)
    }
}
