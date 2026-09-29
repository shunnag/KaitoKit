internal import Foundation
@_spi(TarEditLayout) @testable internal import KaitoKit
internal import XCTest

final class ParallelXZDecompressorTests: XCTestCase {
    func testGeneratedTextAndRandomMultiBlockStreamsMatchSerial() throws {
        try ParallelXZTestSupport.requireXZ()
        for size in [130_001, 600_007, 1_100_003] {
            let text = Data(String(repeating: "XZ 並列復号の比較\n", count: size / 10).utf8.prefix(size))
            for body in [text, ParallelXZTestSupport.random(size)] {
                for blockSize in [65_536, 262_144] {
                    let bytes = try ParallelXZTestSupport.compress(body, blockSize: blockSize)
                    for workers in [2, 8] {
                        XCTAssertEqual(try ParallelXZTestSupport.compare(bytes, workers: workers, target: blockSize * 2), body)
                    }
                    // 目標より大きい block は単独の job として復号する。
                    XCTAssertEqual(try ParallelXZTestSupport.compare(bytes, target: blockSize / 2), body)
                }
            }
        }
    }

    func testSingleBlockConcatenatedAndEmptyStreamsFallBack() throws {
        try ParallelXZTestSupport.requireXZ()
        let body = ParallelXZTestSupport.random(140_003)
        let single = try ParallelXZTestSupport.compress(body, threads: 1, blockSize: nil)
        let empty = try ParallelXZTestSupport.compress(Data(), threads: 1, blockSize: nil)
        var concatenated = [UInt8](single); concatenated.append(contentsOf: single)
        for (bytes, expected) in [(single, body), (Data(concatenated), Data([UInt8](body) + [UInt8](body))), (empty, Data())] {
            let diagnostics = ParallelXZDecompressor.Diagnostics()
            let decoder = try ParallelXZDecompressor(source: DataByteSource(bytes), limits: ReadLimits(), diagnostics: diagnostics)
            XCTAssertEqual(try drain(decoder, bufferSize: 17), expected)
            XCTAssertTrue(decoder.isFinished)
            XCTAssertTrue(diagnostics.fellBackToSerial)
            XCTAssertEqual(diagnostics.peakWorkers, 0)
            XCTAssertEqual(try ParallelXZTestSupport.compare(bytes), expected)
        }
    }

    func testMemoryBudgetCapsWorkersAndCompressedReads() throws {
        try ParallelXZTestSupport.requireXZ()
        let body = ParallelXZTestSupport.random(2 * 1_048_576)
        let bytes = try ParallelXZTestSupport.compress(body)
        let source = CountingByteSource(DataByteSource(bytes))
        let stream = try XCTUnwrap(XZResourceValidator.validate(source: source, dictionaryLimit: ReadLimits().maxDictionarySize).streams.first)
        let structuralReads = source.bytesRead
        // 64 KiB の block 二つが一つの job になる。
        var perJobBytes = 0
        for index in stride(from: 0, to: stream.blocks.count, by: 2) {
            let run = stream.blocks[index..<min(index + 2, stream.blocks.count)]
            let compressed = run.last!.compressedRange.upperBound - run.first!.compressedRange.lowerBound
            perJobBytes = max(perJobBytes, Int(run.reduce(0) { $0 + $1.outputSize } + compressed))
        }
        for (budget, fallback) in [(3 * perJobBytes, true), (4 * perJobBytes, false)] {
            source.reset()
            let diagnostics = ParallelXZDecompressor.Diagnostics()
            let recorder = CompressedTarMapRecorder(format: .xz)
            let decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), recorder: recorder,
                                                     workers: 8, memoryBudget: budget, targetJobOutput: 131_072, diagnostics: diagnostics)
            XCTAssertEqual(try drain(decoder, bufferSize: 65_536), body)
            XCTAssertEqual(diagnostics.fellBackToSerial, fallback)
            XCTAssertNotNil(recorder.finish(imageLength: UInt64(body.count), archiveLength: source.length).map)
            if !fallback {
                XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
                XCTAssertLessThanOrEqual(diagnostics.peakWorkers, 2)
                XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, 4 * perJobBytes)
                // payload は worker と recorder が各一回、三度の枠走査には窓の読先を含める。
                let headerAllowance = 3 * structuralReads + UInt64(stream.blocks.count * 2 * 1_024)
                XCTAssertLessThanOrEqual(source.bytesRead, 2 * source.length + headerAllowance)
            }
        }
    }

    func testGyoshukuHeaderAndBodyBlocksMatchSerialAndChunkMap() throws {
        let bytes = try TestFixtures.base64(ParallelXZTestSupport.fixture)
        let stream = try XCTUnwrap(ParallelXZTestSupport.layout(bytes).streams.first)
        XCTAssertTrue(stream.blocks.contains { $0.outputSize == 512 })
        XCTAssertTrue(stream.blocks.contains { $0.outputSize > 1_048_576 })
        for block in stream.blocks { XCTAssertEqual(bytes[Int(block.compressedRange.lowerBound) + 1] & 0xc0, 0xc0) }
        _ = try ParallelXZTestSupport.compare(bytes, target: 16 * 1_048_576)
        _ = try ParallelXZTestSupport.compare(bytes, target: 65_536)
        try compareMap(bytes)
    }

    func testFourAndSixteenMiBBodyBlocksMatchSerial() throws {
        for blockSize in [4 * 1_048_576, 16 * 1_048_576] {
            let body = Data(repeating: 65, count: 2 * blockSize + 512)
            let bytes = try CompressedTarFramingTestSupport.xz(body, chunkSize: blockSize).data
            XCTAssertEqual(try ParallelXZTestSupport.compare(bytes, target: blockSize), body)
        }
    }

    func testArchiveReaderStagingChunkMapMatchesSerial() throws {
        try ParallelXZTestSupport.requireXZ()
        let image = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "random.bin", contents: ParallelXZTestSupport.random(800_003)),
            // 既定の 16 MiB を越え、staging hook でも複数の job を順に記録する。
            HandTarEntry(name: "text.txt", contents: Data(repeating: 65, count: 17 * 1_048_576 + 300_001))
        ])
        try compareMap(ParallelXZTestSupport.compress(image))
    }

    func testExistingFilterFixturesMatchSerial() throws {
        _ = try ParallelXZTestSupport.compare(TestFixtures.base64("singlefile/x86.xz"))
        for name in ["riscv.xz", "riscv.tar.xz"] {
            let source = DataByteSource(try TestFixtures.base64("singlefile/\(name)"))
            XCTAssertThrowsError(try ParallelXZDecompressor(source: source, limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("XZ RISC-V filter"))
            }
            XCTAssertThrowsError(try XZDecompressor(source: source, limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("XZ RISC-V filter"))
            }
        }
    }

    func testMultiBlockBCJAndDeltaFiltersMatchSerial() throws {
        try ParallelXZTestSupport.requireXZ()
        let body = ParallelXZTestSupport.random(400_003)
        for filters in [["--x86", "--lzma2=preset=1"], ["--delta=dist=4", "--lzma2=preset=1"]] {
            XCTAssertEqual(try ParallelXZTestSupport.compare(ParallelXZTestSupport.compress(body, filters: filters)), body)
        }
    }

    func testTruncationAtBlockBoundaryAndWithinBlockMatchesSerial() throws {
        let body = ParallelXZTestSupport.random(300_001)
        let bytes = try CompressedTarFramingTestSupport.xz(body, chunkSize: ParallelXZTestSupport.blockSize).data
        let block = try XCTUnwrap(ParallelXZTestSupport.layout(bytes).streams.first?.blocks[1])
        for end in [block.compressedRange.lowerBound, block.compressedRange.lowerBound + 32, block.compressedRange.upperBound - 4] {
            let source = DataByteSource(Data(bytes.prefix(Int(end))))
            var serialError: KaitoError?
            XCTAssertThrowsError(try XZDecompressor(source: source, limits: ReadLimits())) { serialError = $0 as? KaitoError }
            XCTAssertThrowsError(try ParallelXZDecompressor(source: source, limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, serialError)
            }
        }
    }

    func testBlockCheckFailureIsEmittedAtItsJobBoundary() throws {
        let body = ParallelXZTestSupport.random(600_003)
        let valid = try CompressedTarFramingTestSupport.xz(body, chunkSize: ParallelXZTestSupport.blockSize).data
        let stream = try XCTUnwrap(ParallelXZTestSupport.layout(valid).streams.first)
        for failingJob in [0, 2, stream.blocks.count - 1] {
            var bytes = valid
            bytes[Int(stream.blocks[failingJob].compressedRange.upperBound - stream.checkSize)] ^= 1
            let source = DataByteSource(bytes)
            let diagnostics = ParallelXZDecompressor.Diagnostics()
            let decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), workers: 8,
                                                     targetJobOutput: ParallelXZTestSupport.blockSize, diagnostics: diagnostics)
            let parallel = TarEditTestSupport.decodeOutcome(decoder)
            let serial = TarEditTestSupport.decodeOutcome(try XZDecompressor(source: source, limits: ReadLimits()))
            XCTAssertNotNil(parallel.error)
            XCTAssertEqual(parallel.error, serial.error)
            XCTAssertEqual(parallel.bytes, Data(body.prefix(failingJob * ParallelXZTestSupport.blockSize)))
            XCTAssertTrue(body.starts(with: serial.bytes))
            XCTAssertFalse(decoder.isFinished)
            ParallelXZTestSupport.waitForAbandonment(diagnostics)
        }
    }

    func testOriginalIndexCRCIsValidatedAfterEarlierJobs() throws {
        let body = ParallelXZTestSupport.random(300_001)
        var bytes = try CompressedTarFramingTestSupport.xz(body, chunkSize: ParallelXZTestSupport.blockSize).data
        let stream = try XCTUnwrap(ParallelXZTestSupport.layout(bytes).streams.first)
        bytes[Int(stream.indexRange.upperBound - 1)] ^= 1
        let source = DataByteSource(bytes)
        let decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), targetJobOutput: ParallelXZTestSupport.blockSize)
        let parallel = TarEditTestSupport.decodeOutcome(decoder)
        let serial = TarEditTestSupport.decodeOutcome(try XZDecompressor(source: source, limits: ReadLimits()))
        XCTAssertNotNil(parallel.error)
        XCTAssertEqual(parallel.error, serial.error)
        XCTAssertEqual(parallel.bytes, Data(body.prefix((stream.blocks.count - 1) * ParallelXZTestSupport.blockSize)))
        XCTAssertFalse(decoder.isFinished)
    }

    func testStreamPaddingPreservesRecorderReason() throws {
        var bytes = [UInt8](try CompressedTarFramingTestSupport.xz(Data(repeating: 65, count: 200_001), chunkSize: 65_536).data)
        bytes.append(contentsOf: [0, 0, 0, 0])
        let source = DataByteSource(Data(bytes))
        let recorder = CompressedTarMapRecorder(format: .xz)
        let output = try drain(ParallelXZDecompressor(source: source, limits: ReadLimits(), recorder: recorder,
                                                     targetJobOutput: 65_536), bufferSize: 65_536)
        XCTAssertEqual(recorder.finish(imageLength: UInt64(output.count), archiveLength: source.length).reason, .xzStreamPadding)
        XCTAssertEqual(try ParallelXZTestSupport.compare(Data(bytes)), output)
    }

    func testDeinitAbandonsWorkersWithinTwoSeconds() throws {
        let bytes = try TestFixtures.base64(ParallelXZTestSupport.fixture)
        let diagnostics = ParallelXZDecompressor.Diagnostics()
        var decoder: ParallelXZDecompressor? = try ParallelXZDecompressor(source: DataByteSource(bytes), limits: ReadLimits(), workers: 8,
                                                                          targetJobOutput: 65_536, diagnostics: diagnostics)
        var buffer = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder!.read(into: $0) }, 1)
        let start = Date()
        decoder = nil
        ParallelXZTestSupport.waitForAbandonment(diagnostics)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
    }

    func testCancellationAbandonsWorkersWithinTwoSeconds() async throws {
        let bytes = try TestFixtures.base64(ParallelXZTestSupport.fixture)
        let diagnostics = ParallelXZDecompressor.Diagnostics()
        let task = Task.detached {
            let decoder = try ParallelXZDecompressor(source: DataByteSource(bytes), limits: ReadLimits(), workers: 8,
                                                     targetJobOutput: 65_536, diagnostics: diagnostics)
            let stream = try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
            return try SingleFileMaterializer.materialize(stream, limits: ReadLimits()).length
        }
        let startedDeadline = Date(timeIntervalSinceNow: 2)
        while diagnostics.liveWorkers == 0 && Date() < startedDeadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThan(diagnostics.liveWorkers, 0)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        while diagnostics.liveWorkers > 0 && Date().timeIntervalSince(start) < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private func compareMap(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = DataByteSource(bytes)
        let serialRecorder = CompressedTarMapRecorder(format: .xz)
        let serial = try XZDecompressor(source: source, limits: ReadLimits(), recorder: serialRecorder)
        let image = try drain(serial, bufferSize: 65_536)
        let expected = serialRecorder.finish(imageLength: UInt64(image.count), archiveLength: source.length)
        XCTAssertNil(expected.reason, file: file, line: line)
        XCTAssertNotNil(expected.map, file: file, line: line)
        // snapshot は ArchiveReader の staging hook を通って記録する。
        let snapshot = try TarEditTestSupport.snapshot(bytes, suffix: "txz")
        XCTAssertEqual(try TarEditTestSupport.bytes(snapshot.image), image, file: file, line: line)
        XCTAssertEqual(snapshot.chunkMap, expected.map, file: file, line: line)
        XCTAssertEqual(snapshot.chunkMapUnavailableReason, expected.reason, file: file, line: line)
    }
}
