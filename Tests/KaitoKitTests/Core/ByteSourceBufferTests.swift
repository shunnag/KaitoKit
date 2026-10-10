import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ByteSourceBufferTests: XCTestCase {
    func testReadByteRangeFillsEveryByteAcrossShortReads() throws {
        let payload = Data((0..<251).map(UInt8.init))
        let source = BufferTestSource(payload, maximum: 3)
        XCTAssertEqual(try readByteRange(source: source, offset: 7, count: 197), Array(payload[7..<204]))
        XCTAssertEqual(try readByteRange(source: source, offset: source.length, count: 0), [])
    }

    func testReadByteRangeDoesNotReturnUninitializedSuffixOnFailure() throws {
        for failure in [KaitoError.truncated, .io(5)] {
            let source = BufferTestSource(Data(repeating: 0x71, count: 20), maximum: 3, failure: failure)
            XCTAssertThrowsError(try readByteRange(source: source, offset: 0, count: 20)) {
                XCTAssertEqual($0 as? KaitoError, failure)
            }
        }
    }

    func testChunkedSourceInputSmallRangeShortReadsAndIndependentCopies() throws {
        let payload = Data((0..<20).map(UInt8.init))
        let source = BufferTestSource(payload, maximum: 3)
        var input = ChunkedSourceInput(source: source, offset: 5, endOffset: 12, chunkSize: 262_144)
        try input.refill()
        XCTAssertEqual(input.withUnsafeBytes { Array($0) }, [5, 6, 7])
        var copy = input
        input.consume(3)
        try input.refill()
        XCTAssertEqual(input.withUnsafeBytes { Array($0) }, [8, 9, 10])
        XCTAssertEqual(copy.withUnsafeBytes { Array($0) }, [5, 6, 7])
        XCTAssertEqual(try copy.consumedSourceOffset, 5)
        copy.reset(to: 5)
        try copy.refill()
        XCTAssertEqual(copy.withUnsafeBytes { Array($0) }, [5, 6, 7])
        input.consume(3)
        try input.refill()
        XCTAssertEqual(input.withUnsafeBytes { Array($0) }, [11])
        input.consume(1)
        try input.refill()
        XCTAssertEqual(input.availableCount, 0)
        XCTAssertTrue(input.isSourceExhausted)
        var empty = ChunkedSourceInput(source: source, offset: 20, endOffset: 20, chunkSize: 262_144)
        try empty.refill()
        XCTAssertEqual(empty.withUnsafeBytes { Array($0) }, [])
    }

    func testUnknownEntryStreamReadAllAppendsOnlyInitializedShortReads() throws {
        let payload = Data((0..<251).map(UInt8.init))
        let source = BufferTestSource(payload, maximum: 3)
        let stream = try EntryStream(decompressor: CopyDecompressor(source: source, offset: 0, compressedSize: source.length),
                                     length: nil, expectedCRC32: CRC32.checksum(payload), entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try stream.readAll(), payload)
    }

    func testChunkedSourceInputCopiedStorageRemainsInitializedAfterRefillFailure() throws {
        let source = BufferTestSource(Data((0..<20).map(UInt8.init)), maximum: 3, failure: .io(5))
        var input = ChunkedSourceInput(source: source, offset: 0, endOffset: 20, chunkSize: 262_144)
        try input.refill()
        let copy = input
        XCTAssertThrowsError(try input.refill()) { XCTAssertEqual($0 as? KaitoError, .io(5)) }
        XCTAssertEqual(input.withUnsafeBytes { Array($0) }, [0, 1, 2])
        XCTAssertEqual(copy.withUnsafeBytes { Array($0) }, [0, 1, 2])
    }

    func testUnknownEntryStreamReadAllKeepsSourceFailureTerminal() throws {
        let source = BufferTestSource(Data(repeating: 0x71, count: 20), maximum: 3, failure: .io(5))
        let stream = try EntryStream(decompressor: CopyDecompressor(source: source, offset: 0, compressedSize: source.length),
                                     length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        for _ in 0..<2 {
            XCTAssertThrowsError(try stream.readAll()) { XCTAssertEqual($0 as? KaitoError, .io(5)) }
        }
    }
}

private final class BufferTestSource: ByteSource {
    private let source: DataByteSource
    private let maximum: Int
    private let failure: KaitoError?
    private let calls = Mutex(0)
    init(_ bytes: Data, maximum: Int, failure: KaitoError? = nil) {
        source = DataByteSource(bytes); self.maximum = maximum; self.failure = failure
    }
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let call = calls.withLock { $0 += 1; return $0 }
        if call > 1, let failure {
            if failure == .truncated { return 0 }
            throw failure
        }
        return try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer.prefix(maximum)), at: offset)
    }
}
