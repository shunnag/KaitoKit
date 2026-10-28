import Darwin
import Foundation
import Synchronization
import XCTest
@testable import KaitoKit

final class MappedReadAheadTests: XCTestCase {
    private final class Advice: Sendable {
        let ranges = Mutex<[Range<UInt>]>([])
        func record(_ range: Range<UInt>) { ranges.withLock { $0.append(range) } }
        var snapshot: [Range<UInt>] { ranges.withLock { $0 } }
    }

    private func mapped(_ bytes: Data) throws -> Data {
        let directory = try TestFixtures.makeTemporaryDirectory(label: "mapped-read-ahead")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.bin")
        try bytes.write(to: url)
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    func testSmallAndHeapReadsDoNotHintAndLargeRangesAreHintedOnce() throws {
        let bytes = Data((0..<(512 << 10)).map { UInt8(truncatingIfNeeded: $0) })
        let advice = Advice()
        let source = try DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
            DataByteSource(try mapped(bytes))
        }
        XCTAssertEqual(try readByteRange(source: source, offset: 123, count: 4096), Array(bytes[123..<4219]))
        XCTAssertTrue(advice.snapshot.isEmpty)
        for offset in [123, 123, 32768, 262144, 123] {
            XCTAssertEqual(try readByteRange(source: source, offset: UInt64(offset), count: 65536),
                           Array(bytes[offset..<offset + 65536]))
        }
        let ranges = advice.snapshot
        XCTAssertEqual(ranges.count, 3)
        for (index, range) in ranges.enumerated() {
            XCTAssertEqual(range.lowerBound % UInt(getpagesize()), 0)
            XCTAssertEqual(range.upperBound % UInt(getpagesize()), 0)
            XCTAssertTrue(ranges.prefix(index).allSatisfy { !$0.overlaps(range) })
        }
        let heap = DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) { DataByteSource(bytes) }
        XCTAssertEqual(try readByteRange(source: heap, offset: 0, count: bytes.count), Array(bytes))
        XCTAssertEqual(advice.snapshot, ranges)
    }

    func testStoredAndChunkedInputsAnnounceWholeBoundedRangeAtStart() throws {
        let bytes = Data(repeating: 0x73, count: 1 << 20)
        let advice = Advice()
        let source = try DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
            DataByteSource(try mapped(bytes))
        }
        let bounded = try BoundedByteSource(source: source, baseOffset: 123, length: 400000)
        let rebased = try RebasedByteSource(source: bounded, baseOffset: 77)
        let copy = try CopyDecompressor(source: rebased, offset: 0, compressedSize: rebased.length)
        XCTAssertEqual(advice.snapshot.count, 1)
        let storedRange = advice.snapshot[0]
        let base = source.data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        XCTAssertLessThanOrEqual(storedRange.lowerBound, base + 200)
        XCTAssertGreaterThanOrEqual(storedRange.upperBound, base + 400123)
        let stream = try EntryStream(decompressor: copy, length: rebased.length,
                                     expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try stream.readAll(), Data(bytes[200..<400123]))
        XCTAssertEqual(advice.snapshot.count, 1)
        var input = ChunkedSourceInput(source: source, offset: 600000, endOffset: 1000000, chunkSize: 256 << 10)
        XCTAssertEqual(advice.snapshot.count, 2)
        try input.refill()
        XCTAssertEqual(input.withUnsafeBytes { Data($0) }, Data(bytes[600000..<600000 + (256 << 10)]))
        XCTAssertEqual(advice.snapshot.count, 2)
    }

    func testLargeStreamStartHintIsCappedAndLaterReadsAdviseTheirRanges() throws {
        let start = 123
        let size = 64 << 20
        let hintSize = 16 << 20
        let chunkSize = 4 << 20
        let bytes = try mapped(Data(repeating: 0x68, count: start + size))
        for chunked in [false, true] {
            let advice = Advice()
            let source = DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
                DataByteSource(bytes)
            }
            let copy = chunked ? nil : try CopyDecompressor(source: source, offset: UInt64(start), compressedSize: UInt64(size))
            var input = chunked ? ChunkedSourceInput(source: source, offset: UInt64(start), endOffset: source.length, chunkSize: chunkSize) : nil
            let initial = try XCTUnwrap(advice.snapshot.first)
            let pageSize = UInt(getpagesize())
            let lower = source.data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } + UInt(start)
            let upper = lower + UInt(hintSize)
            XCTAssertEqual(advice.snapshot.count, 1)
            XCTAssertEqual(initial, (lower - lower % pageSize)..<(((upper - 1) / pageSize + 1) * pageSize))
            XCTAssertLessThanOrEqual(initial.count, hintSize + Int(pageSize))

            var output = Data(count: chunkSize)
            for index in 0..<5 {
                if let copy {
                    XCTAssertEqual(try output.withUnsafeMutableBytes { try copy.read(into: $0) }, chunkSize)
                } else {
                    try input!.refill()
                    output = input!.withUnsafeBytes { Data($0) }
                    input!.consume(chunkSize)
                }
                XCTAssertEqual(output, Data(repeating: 0x68, count: chunkSize))
                XCTAssertEqual(advice.snapshot.count, index < 4 ? 1 : 2)
            }
            let later = try XCTUnwrap(advice.snapshot.last)
            XCTAssertEqual(later.lowerBound, initial.upperBound)
            XCTAssertGreaterThanOrEqual(later.upperBound, lower + UInt(5 * chunkSize))
            print("MAPPED-START-CAP chunked=\(chunked) first=\(initial.count) later=\(later.count) page=\(pageSize)")
        }
    }

    func testConcurrentStreamsShareHintsWithoutChangingOutput() async throws {
        let bytes = Data(repeating: 0xA6, count: 2 << 20)
        let advice = Advice()
        let source = try DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
            DataByteSource(try mapped(bytes))
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let copy = try CopyDecompressor(source: source, offset: 123, compressedSize: 1000000)
                    let stream = try EntryStream(decompressor: copy, length: 1000000,
                                                 expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
                    return try stream.readAll() == Data(bytes[123..<1000123])
                }
            }
            for try await matches in group { XCTAssertTrue(matches) }
        }
        XCTAssertEqual(advice.snapshot.count, 1)
    }

    func testCoveredHintsDoNotWaitForColdAdvice() throws {
        let bytes = try mapped(Data(repeating: 0x59, count: 32 << 20))
        let coldOffset: UInt64 = 16 << 20
        let coldAddress = bytes.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } + UInt(coldOffset)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let coveredReturned = DispatchSemaphore(value: 0), warmReturned = DispatchSemaphore(value: 0)
        let advice = Advice()
        let source = DataByteSource.$testingWillAdvise.withValue({ range in
            if range.contains(coldAddress) {
                // disk/cache の速度に依存せず、未読の range の syscall 待ちを再現する。
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }) {
            DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) { DataByteSource(bytes) }
        }
        source.hintReadAhead(offset: 0, count: 64 << 10)
        XCTAssertEqual(advice.snapshot.count, 1)
        DispatchQueue.global().async {
            source.hintReadAhead(offset: coldOffset, count: 16 << 20)
            finished.signal()
        }
        defer {
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            source.hintReadAhead(offset: coldOffset, count: 16 << 20)
            coveredReturned.signal()
        }
        DispatchQueue.global().async {
            source.hintReadAhead(offset: 0, count: 64 << 10)
            warmReturned.signal()
        }
        XCTAssertEqual(coveredReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(warmReturned.wait(timeout: .now() + 2), .success)
        // cold な syscall はまだ開始しておらず、重複した通知も発生しない。
        XCTAssertEqual(advice.snapshot.count, 1)
    }

    func testShortRegionQueryHintsFileMappingButNotHeapStorage() throws {
        let heap = Data(repeating: 0x42, count: 128 << 10)
        let file = try mapped(heap)
        for mapped in [false, true] {
            let advice = Advice()
            let source = DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
                DataByteSource(mapped ? file : heap)
            }
            source.hintReadAhead(offset: 0, count: source.length)
            XCTAssertEqual(advice.snapshot.count, mapped ? 1 : 0)
            XCTAssertEqual(try readByteRange(source: source, offset: 0, count: 4096),
                           Array(repeating: 0x42, count: 4096))
        }
    }

    func testDeflateInputHintsPackedRangeOnceAndPreservesOutput() throws {
        // 非圧縮 DEFLATE block を 4 個連結し、256 KiB の入力窓を跨ぐ。
        var packed = Data()
        let block = Data(repeating: 0x39, count: 65535)
        for index in 0..<4 {
            packed.append(contentsOf: [index == 3 ? 1 : 0, 0xFF, 0xFF, 0, 0])
            packed.append(block)
        }
        let advice = Advice()
        let source = try DataByteSource.$testingDidAdvise.withValue({ advice.record($0) }) {
            DataByteSource(try mapped(packed))
        }
        let decoder = try DeflateDecompressor(source: source, offset: 0, compressedSize: source.length)
        XCTAssertEqual(advice.snapshot.count, 1)
        let stream = try EntryStream(decompressor: decoder, length: UInt64(4 * block.count),
                                     expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try stream.readAll(), Data(repeating: 0x39, count: 4 * block.count))
        XCTAssertEqual(advice.snapshot.count, 1)
    }
}
