import Foundation
@testable import KaitoKit
import XCTest

final class RAR5ReadAheadTests: XCTestCase {
    func testDenseHeadersShareBoundedReadAheadAndPreserveMetadata() throws {
        let archive = RAR5TestSupport.archive(blocks: (0..<300).map { index in
            RAR5TestSupport.storedFile(
                name: "file-\(index)", contents: Data(), attributes: 0x81a4
            )
        })
        for budget: UInt64 in [64, 512, 16 * 1_024] {
            let source = RAR5HeaderCountingSource(data: archive)
            let reader = try RAR5Reader(
                source: source,
                options: ReaderOptions(limits: ReadLimits(maxMetadataSize: budget))
            )
            XCTAssertEqual(reader.entries.count, 300)
            XCTAssertLessThan(source.readCount, 200)
            XCTAssertLessThanOrEqual(source.maximumRequest, Int(budget))
            for (index, entry) in reader.entries.enumerated() {
                XCTAssertEqual(entry.name, "file-\(index)")
                XCTAssertEqual(entry.formatSpecific["attributes"], "0x81a4")
                XCTAssertEqual(entry.formatSpecific["compressionInfo"], "0x0")
            }
        }
    }

    func testLargeHeaderShortReadsAndPayloadSeekPreserveBytes() throws {
        let name = String(repeating: "n", count: 17_000)
        let payload = RAR5TestSupport.deterministicPayload(count: 50_000, seed: 5)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: name, contents: payload),
            RAR5TestSupport.storedFile(name: "tail", contents: Data([1, 2, 3])),
        ])
        for maximumRead in [1, 7, 16_384] {
            let source = RAR5HeaderCountingSource(data: archive, maximumRead: maximumRead)
            let reader = try ArchiveReader.open(
                source: source,
                options: ReaderOptions(limits: ReadLimits(maxMetadataSize: 20_000))
            )
            XCTAssertEqual(reader.entries.map(\.name), [name, "tail"])
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(try reader.read(reader.entries[1]), Data([1, 2, 3]))
        }
    }

    func testRefillRejectsInvalidSourceCountsWithoutReadingUnfilledBytes() throws {
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "file", contents: Data()),
        ])
        for count in [-1, 0, 16_385] {
            let source = RAR5HeaderCountingSource(data: archive, invalidHeaderCount: count)
            XCTAssertThrowsError(try RAR5Reader(source: source, options: ReaderOptions())) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }
}

private final class RAR5HeaderCountingSource: ByteSource, @unchecked Sendable {
    let data: Data
    let maximumRead: Int
    let invalidHeaderCount: Int?
    private let lock = NSLock()
    private var calls = 0
    private var largestRequest = 0
    var length: UInt64 { UInt64(data.count) }
    var readCount: Int { lock.withLock { calls } }
    var maximumRequest: Int { lock.withLock { largestRequest } }

    init(data: Data, maximumRead: Int = Int.max, invalidHeaderCount: Int? = nil) {
        self.data = data
        self.maximumRead = maximumRead
        self.invalidHeaderCount = invalidHeaderCount
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        lock.withLock {
            calls += 1
            largestRequest = max(largestRequest, buffer.count)
        }
        if offset >= 8, let invalidHeaderCount { return invalidHeaderCount }
        guard offset < length else { return 0 }
        let count = min(buffer.count, maximumRead, data.count - Int(offset))
        data.withUnsafeBytes { bytes in
            buffer.copyMemory(from: UnsafeRawBufferPointer(
                rebasing: bytes[Int(offset)..<(Int(offset) + count)]
            ))
        }
        return count
    }
}
