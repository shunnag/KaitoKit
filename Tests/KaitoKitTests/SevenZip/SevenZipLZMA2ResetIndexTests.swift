import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipLZMA2ResetIndexTests: XCTestCase {
    private struct Read: Equatable {
        let offset: UInt64
        let count: Int
    }

    private final class RecordingSource: ByteSource, @unchecked Sendable {
        private let source: any ByteSource
        private let lock = NSLock()
        private var recorded: [Read] = []

        init(_ source: any ByteSource) { self.source = source }
        var length: UInt64 { source.length }
        var reads: [Read] { lock.withLock { recorded } }
        func reset() { lock.withLock { recorded.removeAll() } }

        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let count = try source.read(into: buffer, at: offset)
            lock.withLock { recorded.append(Read(offset: offset, count: count)) }
            return count
        }
    }

    // 数百 MiB の payload を確保せず、位置指定で raw chunk の header と零 byte を返す。
    private struct RawSource: ByteSource {
        static let chunkSize: UInt64 = 65_539
        let chunks: Int
        let resetChunks: Set<Int>
        var length: UInt64 { UInt64(chunks) * Self.chunkSize + 1 }
        var outputSize: UInt64 { UInt64(chunks) * 65_536 }

        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length else { return 0 }
            let count = Int(min(UInt64(buffer.count), length - offset))
            for index in 0..<count {
                let position = offset + UInt64(index)
                if position == length - 1 {
                    buffer[index] = 0
                } else {
                    switch position % Self.chunkSize {
                    case 0: buffer[index] = resetChunks.contains(Int(position / Self.chunkSize)) ? 1 : 2
                    case 1, 2: buffer[index] = 0xFF
                    default: buffer[index] = 0
                    }
                }
            }
            return count
        }
    }

    private func factory(raw: RawSource, source: any ByteSource, property: UInt8 = 8) throws -> SevenZipFolderDecoderFactory {
        let coder = SevenZipCoder(methodID: [0x21], inputCount: 1, outputCount: 1,
                                  properties: [property], firstInput: 0, firstOutput: 0)
        let folder = SevenZipFolder(coders: [coder], bindPairs: [], packedIndices: [0],
            inputCount: 1, outputCount: 1, finalOutputIndex: 0, unpackSizes: [raw.outputSize],
            digest: SevenZipDigest(value: nil))
        return try SevenZipFolderDecoderFactory(source: source, folder: folder,
            packedRanges: [0: SevenZipPackRange(offset: 0, size: raw.length, digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(parallelDecodeMemory: 1 << 30), password: nil,
            keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24, workers: 16)
    }

    func testSingleResetStopsAtOutputBoundAndCachesSerialDecision() throws {
        // 64 KiB 辞書は 64 MiB、32 MiB 辞書は 4 × dict の 128 MiB まで探索する。
        for (property, boundChunks): (UInt8, Int) in [(8, 1_024), (26, 2_048)] {
            let raw = RawSource(chunks: boundChunks + 512, resetChunks: [0])
            let source = RecordingSource(raw)
            let factory = try factory(raw: raw, source: source, property: property)
            XCTAssertNil(try factory.parallelUnits())
            let reads = source.reads
            XCTAssertEqual(reads.count, (boundChunks + 1) * 3)
            XCTAssertTrue(reads.allSatisfy { $0.count == 1 && $0.offset % RawSource.chunkSize < 3 })
            XCTAssertEqual(reads.last?.offset, UInt64(boundChunks) * RawSource.chunkSize + 2)
            XCTAssertNil(try factory.parallelUnits())
            XCTAssertNil(try factory.makeDictionaryResetIndex())
            XCTAssertEqual(source.reads, reads)
        }
    }

    func testSecondResetWithinBoundCompletesIndexAndLateResetKeepsSerial() throws {
        for secondReset in [1_000, 1_024, 1_025] {
            let raw = RawSource(chunks: 1_536, resetChunks: [0, secondReset])
            let source = RecordingSource(raw), factory = try factory(raw: raw, source: source)
            let index = try factory.makeDictionaryResetIndex(forParallelDecode: true)
            if secondReset <= 1_024 {
                XCTAssertEqual(index?.map(\.uncompressedOffset), [0, UInt64(secondReset) * 65_536])
                XCTAssertEqual(source.reads.count, raw.chunks * 3 + 1)
                XCTAssertEqual(source.reads.last?.offset, raw.length - 1)
            } else {
                XCTAssertNil(index)
                XCTAssertEqual(source.reads.count, 1_025 * 3)
            }
            let reads = source.reads
            XCTAssertEqual(try factory.makeDictionaryResetIndex(), index)
            XCTAssertEqual(source.reads, reads)
        }
    }

    func testCompressedIndexReadsOnlyHeadersAndSharesSeekIndex() throws {
        let fixture = try SevenZipParallelTestSupport.compressed()
        let source = RecordingSource(DataByteSource(fixture.packed))
        let factory = try fixture.factory(workers: 16, source: source)
        let index = try XCTUnwrap(factory.makeDictionaryResetIndex())
        let expectedOffsets = index.flatMap { point in
            (0..<6).map { point.compressedOffset + UInt64($0) }
        } + [UInt64(fixture.packed.count - 1)]
        XCTAssertEqual(source.reads, expectedOffsets.map { Read(offset: $0, count: 1) })
        XCTAssertEqual(try factory.parallelUnits()?.count, 3)
        XCTAssertEqual(try factory.makeDictionaryResetIndex(), index)
        XCTAssertEqual(source.reads.count, expectedOffsets.count)
    }

    func testSeekIndexRemainsUnboundedAndParallelReusesIt() throws {
        let raw = RawSource(chunks: 1_536, resetChunks: [0])
        let source = RecordingSource(raw), factory = try factory(raw: raw, source: source)
        XCTAssertEqual(try factory.makeDictionaryResetIndex()?.count, 1)
        XCTAssertEqual(source.reads.count, raw.chunks * 3 + 1)
        XCTAssertEqual(source.reads.last?.offset, raw.length - 1)
        let reads = source.reads
        XCTAssertNil(try factory.parallelUnits())
        XCTAssertEqual(source.reads, reads)
    }

    // size の先頭 byte は index だけが 1 byte で読む。worker の再開時に読む
    // control byte や、live decoder の通常の先読みとは区別して数える。
    private func scanCount(_ source: RecordingSource) -> Int {
        source.reads.filter { $0 == Read(offset: 33, count: 1) }.count
    }

    private func read(_ reader: SevenZipReader, _ index: Int) throws -> Data {
        try reader.stream(for: reader.entries[index], limits: ReadLimits()).readAll()
    }

    func testPositiveIndexBuiltOnceAcrossEntriesAndRestarts() throws {
        var fixture = SevenZipParallelTestSupport.raw()
        fixture.folderCRC = nil
        let source = RecordingSource(DataByteSource(fixture.archive()))
        let reader = try SevenZipReader(source: source, options: ReaderOptions(decodeThreads: 16))
        source.reset()
        for index in reader.entries.indices { XCTAssertEqual(try read(reader, index), fixture.payloads[index]) }
        for index in [1, 0, 3, 0] { XCTAssertEqual(try read(reader, index), fixture.payloads[index]) }
        // password 更新で coordinator を破棄しても、非暗号化 folder の index は再利用する。
        reader.setPassword("unused")
        XCTAssertEqual(try read(reader, 0), fixture.payloads[0])
        XCTAssertEqual(scanCount(source), 1)
    }

    func testNonSolidOpensShareIndexButReopenedReaderBuildsItsOwn() throws {
        let units = try SevenZipParallelTestSupport.compressed()
        let fixture = SevenZipParallelTestSupport.Fixture(packed: units.packed, payloads: [units.output])
        let source = RecordingSource(DataByteSource(fixture.archive()))
        let options = ReaderOptions(decodeThreads: 16)
        let reader = try SevenZipReader(source: source, options: options)
        XCTAssertEqual(reader.entries[0].solidGroup, -1)
        source.reset()
        for _ in 0..<3 { XCTAssertEqual(try read(reader, 0), fixture.output) }
        XCTAssertEqual(scanCount(source), 1)
        let reopened = try XCTUnwrap(reader.reopened(options: options))
        XCTAssertEqual(try reopened.stream(for: reopened.entries[0], limits: ReadLimits()).readAll(), fixture.output)
        XCTAssertEqual(scanCount(source), 2)
    }

    func testSingleResetNegativeIndexCachedAcrossSolidAndNonSolidOpens() throws {
        let entries = SevenZipParallelTestSupport.raw(sizes: [65_003, 70_005])
        let packed = SevenZipParallelTestSupport.rawUnit(entries.output) + Data([0])
        for payloads in [entries.payloads, [entries.output]] {
            let fixture = SevenZipParallelTestSupport.Fixture(packed: packed, payloads: payloads)
            let source = RecordingSource(DataByteSource(fixture.archive()))
            let reader = try SevenZipReader(source: source, options: ReaderOptions(decodeThreads: 16))
            source.reset()
            for _ in 0..<3 {
                for index in reader.entries.indices { XCTAssertEqual(try read(reader, index), payloads[index]) }
            }
            XCTAssertEqual(scanCount(source), 1)
        }
    }

    func testMalformedIndexCachedAfterReadFailureAndKeepsEarlierEntry() throws {
        var fixture = SevenZipParallelTestSupport.raw()
        fixture.folderCRC = nil
        fixture.packed[SevenZipParallelTestSupport.rawUnit(fixture.payloads[0]).count] = 0x03
        let serial = try SevenZipReader(source: DataByteSource(fixture.archive()), options: ReaderOptions(decodeThreads: 1))
        var expectedError: KaitoError?
        XCTAssertThrowsError(try read(serial, 1)) { expectedError = $0 as? KaitoError }
        XCTAssertNotNil(expectedError)
        let source = RecordingSource(DataByteSource(fixture.archive()))
        let reader = try SevenZipReader(source: source, options: ReaderOptions(decodeThreads: 16))
        source.reset()
        for _ in 0..<3 {
            XCTAssertEqual(try read(reader, 0), fixture.payloads[0])
            XCTAssertThrowsError(try read(reader, 1)) { XCTAssertEqual($0 as? KaitoError, expectedError) }
        }
        XCTAssertEqual(scanCount(source), 1)
    }

    func testCancelledSerialBackwardSeekStillBuildsIndexAndSucceeds() async throws {
        var fixture = SevenZipParallelTestSupport.raw()
        fixture.folderCRC = nil
        let payloads = fixture.payloads
        let value = try await Task.detached {
            let coordinator = SevenZipFolderCoordinator(factory: try fixture.factory(workers: 1))
            let laterOffset = UInt64(payloads[0].count + payloads[1].count)
            let later = try coordinator.stream(offset: laterOffset, length: 1)
            var byte: UInt8 = 0
            _ = try withUnsafeMutableBytes(of: &byte) { try later.read(into: $0) }
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            let earlier = try coordinator.stream(offset: UInt64(payloads[0].count), length: 1)
            XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try earlier.read(into: $0) }, 1)
            return byte
        }.value
        XCTAssertEqual(value, payloads[1][0])
    }

    func testCancelledParallelIndexBuildStillStops() async throws {
        let fixture = SevenZipParallelTestSupport.raw()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try fixture.factory(workers: 16).parallelUnits()
        }
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
