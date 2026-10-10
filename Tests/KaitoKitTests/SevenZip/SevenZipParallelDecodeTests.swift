import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipParallelDecodeTests: XCTestCase {
    private struct Outcome: Equatable {
        let bytes: Data
        let error: KaitoError?
    }

    private func outcome(_ decoder: any Decompressor, chunk: Int) -> Outcome {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        do {
            while true {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                if count == 0 { XCTAssertTrue(decoder.isFinished); break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return Outcome(bytes: bytes, error: nil)
        } catch {
            XCTAssertTrue(error is KaitoError, "\(error)")
            return Outcome(bytes: bytes, error: error as? KaitoError)
        }
    }

    func testSolidEntriesAndDecodeAllMatchSerialAtEveryThreadCount() throws {
        for fixture in [SevenZipParallelTestSupport.raw(), try SevenZipParallelTestSupport.compressed()] {
            for workers: Int? in [1, nil, 16] {
                let reader = try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(decodeThreads: workers))
                XCTAssertEqual(reader.entries.count, fixture.payloads.count)
                for (index, entry) in reader.entries.enumerated() {
                    XCTAssertEqual(try reader.stream(entry).readAll(), fixture.payloads[index])
                }
                // 完了後の backward seek と reopen も元の coordinator 契約を保つ。
                for index in reader.entries.indices.reversed() {
                    XCTAssertEqual(try reader.read(reader.entries[index]), fixture.payloads[index])
                }
                XCTAssertEqual(try reader.reopen().read(reader.entries[0]), fixture.payloads[0])
                XCTAssertEqual(try fixture.factory(workers: workers ?? ReaderOptions.automaticDecodeThreads())
                    .decodeAll(limit: ReadLimits().maxInMemorySize), fixture.output)
            }
            let factory = try fixture.factory(workers: 16)
            XCTAssertTrue(try factory.makeDecoder() is ParallelIndependentDecompressor)
            for chunk in [1, 7, 65_537, 262_144] {
                XCTAssertEqual(outcome(try factory.makeDecoder(), chunk: chunk),
                               outcome(try fixture.factory(workers: 1).makeDecoder(), chunk: chunk))
            }
        }
    }

    private final class Submissions: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }

    func testReaderUsesResolvedThreadsAndReopenSnapshot() throws {
        let fixture = SevenZipParallelTestSupport.raw(), archive = fixture.archive()
        for threads: Int? in [1, nil, 16] {
            let submissions = Submissions()
            try ReaderOptions.$testingAutomaticThreads.withValue({ _ in 1 }) {
                try LeafDecodePool.$testingSubmission.withValue({ submissions.record() }) {
                    let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: threads))
                    for entry in reader.entries { _ = try reader.read(entry) }
                }
            }
            XCTAssertEqual(submissions.count, threads == 16 ? fixture.payloads.count : 0)
        }
        let submissions = Submissions()
        try ReaderOptions.$testingAutomaticThreads.withValue({ _ in 2 }) {
            let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: nil))
            try ReaderOptions.$testingAutomaticThreads.withValue({ _ in 1 }) {
                try LeafDecodePool.$testingSubmission.withValue({ submissions.record() }) {
                    let reopened = try reader.reopen()
                    for entry in reopened.entries { _ = try reopened.read(entry) }
                }
            }
        }
        XCTAssertEqual(submissions.count, fixture.payloads.count)
    }

    func testSingleResetAndUnsupportedGraphsKeepSerialDecoder() throws {
        var fixture = SevenZipParallelTestSupport.raw(sizes: [65_539])
        XCTAssertTrue(try fixture.factory(workers: 16).makeDecoder() is LZMA2Decoder)
        fixture = SevenZipParallelTestSupport.raw()
        // LZMA2 → Copy は単純 filter 列ではない。
        fixture.filters = [([0], [])]
        XCTAssertNil(try fixture.factory(workers: 16).parallelUnits())
        XCTAssertTrue(try fixture.factory(workers: 16).makeDecoder() is LZMA2Decoder)
        XCTAssertEqual(try fixture.factory(workers: 16).decodeAll(limit: 1 << 20), fixture.output)
        fixture.filters = [([0x06, 0xF1, 0x07, 0x01], [])]
        XCTAssertNil(try fixture.factory(workers: 16).parallelUnits())
    }

    func testRawResetWithoutCodingStateResetIsNotSplit() throws {
        var first = Array(try Hex.data("e00011000800003099abddc0cb070000").dropLast())
        var continued = first
        continued[0] = 0x80
        continued.remove(at: 5)
        first += [1, 0, 0, 97] + continued + [0]
        let fixture = SevenZipParallelTestSupport.Fixture(packed: Data(first),
            payloads: [Data(repeating: 0, count: 37)])
        let index = try XCTUnwrap(fixture.factory(workers: 16).makeDictionaryResetIndex())
        XCTAssertEqual(index.filter(\.isRestartable).count, 1)
        XCTAssertTrue(try fixture.factory(workers: 16).makeDecoder() is LZMA2Decoder)
    }

    func testRawResetPreloadsEarlierPropertiesInParallelUnit() throws {
        let first = Array(try Hex.data("e00011000800003099abddc0cb070000").dropLast())
        var continued = first
        continued[0] = 0xA0; continued.remove(at: 5)
        let text = Data("abcabcabcabcabcabc".utf8)
        let fixture = SevenZipParallelTestSupport.Fixture(
            packed: Data(first + [1, 0, 2, 120, 121, 122] + continued + [0]),
            payloads: [text, Data("xyz".utf8) + text])
        let factory = try fixture.factory(workers: 16)
        XCTAssertTrue(try factory.makeDecoder() is ParallelIndependentDecompressor)
        XCTAssertEqual(try factory.decodeAll(limit: 1 << 20), fixture.output)
        for chunk in [1, 7, 128] {
            XCTAssertEqual(outcome(try factory.makeDecoder(), chunk: chunk),
                           outcome(try fixture.factory(workers: 1).makeDecoder(), chunk: chunk))
        }
    }

    func testBCJAndARM64FiltersKeepStateAcrossResetAndEntryBoundaries() throws {
        let sizes = [65_003, 70_005, 80_008], count = sizes.reduce(0, +)
        for arm64 in [false, true] {
            var original = Data(repeating: arm64 ? 0 : 0x90, count: count), encoded = original
            for offset in stride(from: 0, to: count - 8, by: 8) {
                if arm64 {
                    original.replaceSubrange(offset..<(offset + 4), with: SevenZipEditTestBytes.little(UInt32(0x9400_0000)))
                    encoded.replaceSubrange(offset..<(offset + 4), with: SevenZipEditTestBytes.little(UInt32(0x9400_0000) | UInt32(offset / 4)))
                } else {
                    original.replaceSubrange(offset..<(offset + 5), with: [0xE8, 0, 0, 0, 0])
                    encoded.replaceSubrange(offset..<(offset + 5), with: [0xE8] + SevenZipEditTestBytes.little(UInt32(offset + 5)))
                }
            }
            var packed = Data(), payloads: [Data] = [], offset = 0
            for size in sizes {
                packed.append(SevenZipParallelTestSupport.rawUnit(Data(encoded[offset..<(offset + size)])))
                payloads.append(Data(original[offset..<(offset + size)])); offset += size
            }
            packed.append(0)
            let fixture = SevenZipParallelTestSupport.Fixture(packed: packed, payloads: payloads,
                filters: [([arm64 ? 0x0A : 0x04], [])], folderCRC: CRC32.checksum(original))
            let diagnostics = ParallelIndependentDecompressor.Diagnostics()
            let factory = try fixture.factory(workers: 16, diagnostics: diagnostics)
            XCTAssertNil(try factory.makeDictionaryResetIndex()) // filter 付き seek は先頭から。
            XCTAssertEqual(try factory.parallelUnits()?.count, 3)
            XCTAssertEqual(try factory.decodeAll(limit: 1 << 20), original)
            XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
            for threads: Int? in [1, nil, 16] {
                let reader = try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(decodeThreads: threads))
                for index in reader.entries.indices { XCTAssertEqual(try reader.read(reader.entries[index]), payloads[index]) }
                XCTAssertEqual(try reader.read(reader.entries[1]), payloads[1])
            }
        }
    }

    func testSevenZipMultithreadedCompressedSolidArchive() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-parallel-compressed")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: ($0 / 1_021) ^ ($0 % 251)) })
        let paths = (0..<3).map { "entry-\($0).bin" }
        for path in paths { try SevenZipTestSupport.write(payload, relativePath: path, below: temporary) }
        let url = temporary.appendingPathComponent("solid.7z")
        try SevenZipTestSupport.makeArchive(sourceDirectory: temporary, paths: paths, archiveURL: url,
            options: ["-m0=lzma2:d=64k", "-mmt=4", "-ms=on", "-mhc=off"])
        let archive = try Data(contentsOf: url)
        let next = try SevenZipHeaderDecoder.readNextHeader(source: DataByteSource(archive), limits: ReadLimits(), editRecorder: nil)
        let header = try SevenZipHeaderParser.parse(bytes: next.bytes, limits: ReadLimits(),
            budget: SevenZipMetadataBudget(limit: ReadLimits().maxTotalMetadataSize)) { _, _ in
                throw KaitoError.malformed("unexpected external metadata in test archive")
            }
        let streams = try XCTUnwrap(header.streams)
        let ranges = try SevenZipFolderLayout.ranges(for: streams, sourceLength: UInt64(archive.count), packedDataEnd: next.absoluteOffset)
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let factory = try SevenZipFolderDecoderFactory(source: DataByteSource(archive), folder: streams.folders[0],
            packedRanges: ranges[0], limits: ReadLimits(), password: nil, keyCache: SevenZipAESKeyCache(),
            maximumAESCyclesPower: 24, workers: 16, parallelDiagnostics: diagnostics)
        XCTAssertGreaterThan(try XCTUnwrap(factory.makeDictionaryResetIndex()).count, 1)
        XCTAssertTrue(try factory.makeDecoder() is ParallelIndependentDecompressor)
        XCTAssertEqual(try factory.decodeAll(limit: 8 << 20), payload + payload + payload)
        for threads: Int? in [1, nil, 16] {
            let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: threads))
            for entry in reader.entries { XCTAssertEqual(try reader.read(entry), payload) }
        }
        // opt-in の短い release probe。worker を含む process 全体の user + system CPU のみ測る。
        if ProcessInfo.processInfo.environment["KAITO_7Z_CPU_PROBE"] == "1" {
            for threads in [1, 16] {
                let start = cpuSeconds()
                for _ in 0..<3 {
                    let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: threads))
                    for entry in reader.entries { XCTAssertEqual(try reader.read(entry), payload) }
                }
                print("7Z-CPU threads=\(threads) bytes=\(payload.count * 9) seconds=\(cpuSeconds() - start)")
            }
        }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testCorruptMiddleUnitPreservesPartialBytesAndEarlierEntries() throws {
        let first = Data(repeating: 65, count: 65_003), prefix = Data(repeating: 66, count: 65_019)
        var compressed = try Hex.data("e00011000800003099abddc0cb070000")
        compressed.removeLast(); compressed[0] = 0xC0; compressed[6] = 1
        let last = Data(repeating: 67, count: 65_021)
        let packed = SevenZipParallelTestSupport.rawUnit(first)
            + SevenZipParallelTestSupport.rawUnit(prefix) + compressed
            + SevenZipParallelTestSupport.rawUnit(last) + Data([0])
        let fixture = SevenZipParallelTestSupport.Fixture(packed: packed,
            payloads: [first, prefix + Data("abcabcabcabcabcabc".utf8), last])
        XCTAssertTrue(try fixture.factory(workers: 16).makeDecoder() is ParallelIndependentDecompressor)
        for chunk in [1, 7, 65_537, 262_144] {
            let expected = outcome(try fixture.factory(workers: 1).makeDecoder(), chunk: chunk)
            XCTAssertNotNil(expected.error)
            XCTAssertEqual(outcome(try fixture.factory(workers: 16).makeDecoder(), chunk: chunk), expected)
        }
        var errors: [KaitoError?] = []
        for threads: Int? in [1, nil, 16] {
            let reader = try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(decodeThreads: threads))
            XCTAssertEqual(try reader.read(reader.entries[0]), first)
            XCTAssertThrowsError(try reader.read(reader.entries[1])) { errors.append($0 as? KaitoError) }
        }
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors[0], errors[1]); XCTAssertEqual(errors[0], errors[2])
        // header 破損は事前走査で報告せず、先行 entry を返してから直列で同じ error を出す。
        var malformed = fixture
        malformed.packed[first.count + 3] = 3
        for threads in [1, 16] {
            let reader = try ArchiveReader.open(data: malformed.archive(), options: ReaderOptions(decodeThreads: threads))
            XCTAssertEqual(try reader.read(reader.entries[0]), first)
            XCTAssertThrowsError(try reader.read(reader.entries[1])) {
                XCTAssertEqual($0 as? KaitoError, .malformed("invalid LZMA2 control byte"))
            }
        }
    }

    func testFolderAndEntryCRCMismatchOrderMatchesSerial() throws {
        let fixture = SevenZipParallelTestSupport.raw()
        for entryMismatch in [false, true] {
            var changed = fixture
            if entryMismatch {
                changed.entryCRCs = fixture.payloads.map { CRC32.checksum($0) }
                changed.entryCRCs![1] ^= 1
                changed.folderCRC = nil
            } else { changed.folderCRC! ^= 1 }
            for threads: Int? in [1, nil, 16] {
                let reader = try ArchiveReader.open(data: changed.archive(), options: ReaderOptions(decodeThreads: threads))
                let failed = entryMismatch ? 1 : fixture.payloads.count - 1
                for index in 0..<failed { XCTAssertEqual(try reader.read(reader.entries[index]), fixture.payloads[index]) }
                XCTAssertThrowsError(try reader.read(reader.entries[failed])) {
                    XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: entryMismatch ? failed : -1))
                }
            }
            if !entryMismatch {
                for workers in [1, 16] {
                    XCTAssertThrowsError(try changed.factory(workers: workers).decodeAll(limit: 1 << 20)) {
                        XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1))
                    }
                }
            }
        }
    }

    func testDictionaryOutputAndMetadataBudgetsForceSerial() throws {
        let fixture = SevenZipParallelTestSupport.raw()
        let units = try XCTUnwrap(fixture.factory(workers: 16).parallelUnits())
        let maximum = try XCTUnwrap(units.map(\.heldBytes).max())
        for limits in [ReadLimits(parallelDecodeMemory: UInt64(maximum * 3 - 1)),
                       ReadLimits(maxInMemorySize: 65_536), ReadLimits(maxMetadataRecordCount: 1)] {
            let diagnostics = ParallelIndependentDecompressor.Diagnostics()
            let decoder = try fixture.factory(workers: 16, limits: limits, diagnostics: diagnostics).makeDecoder()
            XCTAssertTrue(decoder is LZMA2Decoder)
            XCTAssertEqual(try drain(decoder, bufferSize: 65_537), fixture.output)
            XCTAssertEqual(diagnostics.peakWorkers, 1)
        }
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let limits = ReadLimits(parallelDecodeMemory: UInt64(maximum * 3))
        let decoder = try fixture.factory(workers: 16, limits: limits, diagnostics: diagnostics).makeDecoder()
        XCTAssertTrue(decoder is ParallelIndependentDecompressor)
        XCTAssertEqual(try drain(decoder, bufferSize: 65_537), fixture.output)
        waitForRelease(diagnostics)
        XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
        XCTAssertLessThanOrEqual(diagnostics.peakWorkers, 2)
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, maximum * 3)
        // 1.5 GiB の宣言辞書を予算に含める。小さな出力でも worker を増やさない。
        var hugeDictionary = fixture; hugeDictionary.property = 37
        let hugeDiagnostics = ParallelIndependentDecompressor.Diagnostics()
        let hugeLimits = ReadLimits(maxDictionarySize: 2 << 30, parallelDecodeMemory: 64 << 20)
        let serial = try hugeDictionary.factory(workers: 16, limits: hugeLimits, diagnostics: hugeDiagnostics).makeDecoder()
        XCTAssertTrue(serial is LZMA2Decoder)
        XCTAssertEqual(try drain(serial, bufferSize: 65_537), fixture.output)
        XCTAssertEqual(hugeDiagnostics.peakWorkers, 1)
        XCTAssertThrowsError(try hugeDictionary.factory(workers: 16).makeDecoder()) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: fixture.archive(), options: ReaderOptions(
            limits: ReadLimits(maxEntrySize: 65_000), decodeThreads: 16)))
    }

    func testReadersExceedingActiveCPUsFinishWithoutStarvation() async throws {
        let fixture = SevenZipParallelTestSupport.raw(sizes: [65_539, 65_541, 65_543, 65_545])
        let archive = fixture.archive(), readers = max(12, 2 * ProcessInfo.processInfo.activeProcessorCount)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<readers {
                group.addTask {
                    let reader = try ArchiveReader.open(data: archive, options: ReaderOptions(decodeThreads: 16))
                    var output = Data()
                    for entry in reader.entries { output.append(try reader.read(entry)) }
                    return output
                }
            }
            var completed = 0
            for try await output in group { XCTAssertEqual(output, fixture.output); completed += 1 }
            XCTAssertEqual(completed, readers)
        }
    }

    func testCancellationAndAbandonmentReleaseWorkers() async throws {
        let fixture = SevenZipParallelTestSupport.raw(sizes: [1 << 20, 1 << 20, 1 << 20, 1 << 20])
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let task = Task.detached {
            let decoder = try fixture.factory(workers: 16, diagnostics: diagnostics).makeDecoder()
            var byte: UInt8 = 0
            while !decoder.isFinished { _ = try withUnsafeMutableBytes(of: &byte) { try decoder.read(into: $0) } }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while diagnostics.peakWorkers == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        waitForRelease(diagnostics)
        let abandonedDiagnostics = ParallelIndependentDecompressor.Diagnostics()
        var abandoned: (any Decompressor)? = try fixture.factory(workers: 16, diagnostics: abandonedDiagnostics).makeDecoder()
        var byte: UInt8 = 0
        XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try abandoned!.read(into: $0) }, 1)
        abandoned = nil
        waitForRelease(abandonedDiagnostics)
    }

    private func waitForRelease(_ diagnostics: ParallelIndependentDecompressor.Diagnostics) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while (diagnostics.liveWorkers > 0 || diagnostics.heldBytes > 0), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertEqual(diagnostics.heldBytes, 0)
    }
}
