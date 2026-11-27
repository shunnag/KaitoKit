import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ParallelDecodeMemoryBudgetTests: XCTestCase {
    private func withBudget<T>(_ budget: ParallelDecodeMemoryBudget, _ body: () throws -> T) rethrows -> T {
        try ParallelDecodeMemoryBudget.$active.withValue(budget, operation: body)
    }

    private func unit(_ byte: UInt8) throws -> ParallelIndependentDecompressor.Unit {
        try .init(outputSize: 1, scratchBytes: 0) {
            try CopyDecompressor(source: DataByteSource(data: Data([byte])), offset: 0, compressedSize: 1)
        }
    }

    private func decoder(_ limits: ReadLimits) -> ParallelIndependentDecompressor? {
        ParallelIndependentDecompressor(
            units: [try! unit(1), try! unit(2)], limits: limits, workers: 4
        )
    }

    private func readAll(_ decoder: any Decompressor) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 2)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func testIndependentDecodersReserveUntilUnreadOutputIsReleased() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 12)
        try withBudget(budget) {
            let limits = ReadLimits(parallelDecodeMemory: 6)
            var first: ParallelIndependentDecompressor? = try XCTUnwrap(decoder(limits))
            var second: ParallelIndependentDecompressor? = try XCTUnwrap(decoder(limits))
            XCTAssertNotNil(first)
            XCTAssertEqual(budget.availableBytes, 0)
            XCTAssertNil(decoder(limits))
            XCTAssertEqual(budget.availableBytes, 0)

            first = nil
            XCTAssertEqual(budget.availableBytes, 6)
            var third: ParallelIndependentDecompressor? = try XCTUnwrap(decoder(limits))
            XCTAssertEqual(budget.availableBytes, 0)
            XCTAssertEqual(try readAll(XCTUnwrap(second)), Data([1, 2]))
            second = nil
            XCTAssertEqual(budget.availableBytes, 6)
            XCTAssertEqual(try readAll(XCTUnwrap(third)), Data([1, 2]))
            third = nil
            XCTAssertEqual(budget.availableBytes, 12)
        }
    }

    func testReadLimitsCopiesReserveAndReleaseIndependently() {
        let budget = ParallelDecodeMemoryBudget(capacity: 6)
        withBudget(budget) {
            let limits = ReadLimits(parallelDecodeMemory: 4)
            var first: ParallelDecodeMemoryReservation? = limits.reserveParallelDecodeMemory()
            XCTAssertEqual(first?.amount, 4)
            let copy = limits
            let second = copy.reserveParallelDecodeMemory()
            XCTAssertEqual(second.amount, 2)
            XCTAssertEqual(budget.availableBytes, 0)
            first = nil
            XCTAssertEqual(budget.availableBytes, 4)
            let third = copy.reserveParallelDecodeMemory()
            XCTAssertEqual(third.amount, 4)
            XCTAssertEqual(budget.availableBytes, 0)
        }
    }

    func testZeroCapacityUsesSerialFallbackWithoutUnderflow() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 0)
        withBudget(budget) {
            let limits = ReadLimits()
            XCTAssertNil(decoder(limits))
            XCTAssertEqual(budget.availableBytes, 0)
            let reservation = limits.reserveParallelDecodeMemory()
            XCTAssertEqual(reservation.amount, 0)
            XCTAssertEqual(budget.availableBytes, 0)
        }
    }

    func testBudgetCanReopenWithinTaskScope() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 1_024)
        try withBudget(budget) {
            let options = ReaderOptions()
            XCTAssertEqual(options.limits, ReadLimits())
            _ = options.limits.reserveParallelDecodeMemory()
            XCTAssertEqual(options.limits, ReadLimits())
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "page", contents: Data("shared budget".utf8)),
            ])
            let reader = try ArchiveReader.open(data: archive, options: options)
            let reopened = try reader.reopen(options: options)
            XCTAssertEqual(reopened.entries, reader.entries)
        }
    }

    func testPoolPropagatesBudgetToNestedDecoderCreation() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 6)
        try withBudget(budget) {
            let limits = ReadLimits(parallelDecodeMemory: 6)
            let observed = Mutex<[Int]>([])
            let units = try (0..<2).map { index in
                try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 0) {
                    observed.withLock { $0.append(limits.reserveParallelDecodeMemory().amount) }
                    return try CopyDecompressor(
                        source: DataByteSource(data: Data([UInt8(index + 1)])), offset: 0, compressedSize: 1
                    )
                }
            }
            let decoder = try XCTUnwrap(ParallelIndependentDecompressor(
                units: units, limits: limits, workers: 2
            ))
            XCTAssertEqual(try readAll(decoder), Data([1, 2]))
            XCTAssertEqual(observed.withLock { $0 }, [0, 0])
        }
    }

    func testInlineJobKeepsTheSubmittersUnscopedBudget() {
        let pool = LeafDecodePool(capacity: 1, executor: { _ in })
        let ticket = pool.submit(group: LeafDecodePool.Group()) {
            XCTAssertNil(ParallelDecodeMemoryBudget.active)
        }
        withBudget(ParallelDecodeMemoryBudget(capacity: 0)) {
            XCTAssertTrue(pool.runInline(ticket))
        }
    }

    func testSevenZipPrefetchedStreamOwnsBatchUntilReleased() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 2)
        try withBudget(budget) {
            let prefetcher = SevenZipFolderPrefetcher(workers: 2, memoryBudget: 2)
            let batch = try SevenZipFolderPrefetcher.Batch(units: [
                .init(folderIndex: 0, entryIndex: 0, outputSize: 1, expectedCRC32: nil,
                      folderCRC32: nil, scratchBytes: 0) {
                    try CopyDecompressor(source: DataByteSource(Data([1])), offset: 0, compressedSize: 1)
                }
            ])
            XCTAssertTrue(prefetcher.submit(batch))
            var stream = try XCTUnwrap(prefetcher.take(folder: 0)) as SevenZipFolderPrefetcher.FolderDecompressor?
            prefetcher.reset()
            XCTAssertFalse(prefetcher.submit(batch))
            XCTAssertEqual(try readAll(XCTUnwrap(stream)), Data([1]))
            stream = nil
            XCTAssertEqual(budget.availableBytes, 2)
        }
    }

    func testAbandonedDecoderKeepsGrantUntilItsLastWorkerExits() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 6)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        try withBudget(budget) {
            let blocked = try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 0) {
                entered.signal()
                guard resume.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
                return try CopyDecompressor(source: DataByteSource(Data([2])), offset: 0, compressedSize: 1)
            }
            var decoder = ParallelIndependentDecompressor(units: [try unit(1), blocked], limits: ReadLimits(), workers: 2)
            var buffer = [UInt8](repeating: 0, count: 1)
            XCTAssertEqual(try buffer.withUnsafeMutableBytes { try XCTUnwrap(decoder).read(into: $0) }, 1)
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            decoder = nil
            XCTAssertEqual(budget.availableBytes, 0)
            resume.signal()
            let deadline = Date().addingTimeInterval(5)
            while budget.availableBytes == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertEqual(budget.availableBytes, budget.capacity)
        }
    }

    func testLZ4PlanningExhaustedBudgetUsesSerialPath() throws {
        let bytes = try TestFixtures.base64("lz4-frame/independent-64k.lz4")
        let expected = try readAll(LZ4FrameDecompressor(source: DataByteSource(data: bytes), limits: ReadLimits()))
        let budget = ParallelDecodeMemoryBudget(capacity: 0)
        try withBudget(budget) {
            let decoder = try LZ4FrameDecompressor.parallel(
                source: DataByteSource(data: bytes), limits: ReadLimits(), workers: 4
            )
            XCTAssertFalse(decoder is ParallelLZ4FrameDecompressor)
            XCTAssertEqual(try readAll(decoder), expected)
        }
    }

    func testSevenZipColdPlanUsesOneGrantAndCacheReleasesIt() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 64 << 20)
        try withBudget(budget) {
            let factory = try SevenZipParallelTestSupport.raw().factory(workers: 2)
            for _ in 0..<2 {
                var decoder: (any Decompressor)? = try factory.makeDecoder()
                XCTAssertTrue(decoder is ParallelIndependentDecompressor)
                XCTAssertLessThan(budget.availableBytes, budget.capacity)
                decoder = nil
                XCTAssertEqual(budget.availableBytes, budget.capacity)
            }
        }
    }

    func testSerialBzip2FallbackReturnsPartialGrant() throws {
        let budget = ParallelDecodeMemoryBudget(capacity: 128)
        let input = Data(repeating: 65, count: 256)
        let packed = try CompressedTarFramingTestSupport.bzip2(input, chunkSize: input.count).data
        try withBudget(budget) {
            let decoder = try ParallelBzip2Decompressor(source: DataByteSource(packed), workers: 2)
            XCTAssertEqual(budget.availableBytes, budget.capacity)
            XCTAssertEqual(try readAll(decoder), input)
        }
    }

    func testSevenZipPlanningExhaustedBudgetUsesSerialPath() throws {
        let archive = try SevenZipParallelTestSupport.compressed().archive()
        let budget = ParallelDecodeMemoryBudget(capacity: 0)
        try withBudget(budget) {
            let options = ReaderOptions(decodeThreads: 4)
            let expected = try ArchiveReader.open(data: archive)
            let reader = try ArchiveReader.open(data: archive, options: options)
            XCTAssertEqual(reader.entries, expected.entries)
            for entry in reader.entries where entry.kind == .file {
                XCTAssertEqual(try reader.read(entry), try expected.read(entry), entry.name)
            }
            XCTAssertEqual(budget.availableBytes, 0)
        }
    }

    func testBzip2ExhaustedBudgetUsesExistingSerialPath() throws {
        let input = Data(repeating: 65, count: 4_096)
        let packed = try CompressedTarFramingTestSupport.bzip2(input, chunkSize: input.count).data
        let budget = ParallelDecodeMemoryBudget(capacity: 0)
        try withBudget(budget) {
            let diagnostics = ParallelBzip2Decompressor.Diagnostics()
            let decoder = try ParallelBzip2Decompressor(
                source: DataByteSource(data: packed), limits: ReadLimits(), workers: 4, diagnostics: diagnostics
            )
            XCTAssertEqual(diagnostics.fallbackCount, 1)
            XCTAssertEqual(try readAll(decoder), input)
            XCTAssertEqual(budget.availableBytes, 0)
        }
    }
}
