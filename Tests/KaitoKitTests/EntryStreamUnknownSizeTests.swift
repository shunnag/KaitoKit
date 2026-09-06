import Foundation
@testable import KaitoKit
import XCTest

final class EntryStreamUnknownSizeTests: XCTestCase {
    func testUnknownSizeStreamsUntilDecoderEndAndVerifiesCRC() throws {
        let payload = Data("RAR5 unknown-size stream\n".utf8)
        let decoder = UnknownLengthTestDecompressor(payload)
        let stream = try EntryStream(
            decompressor: decoder,
            length: nil,
            expectedCRC32: CRC32.checksum(payload),
            entryIndex: 7,
            limits: ReadLimits()
        )

        XCTAssertEqual(stream.remaining, UInt64.max)
        XCTAssertEqual(try stream.readAll(), payload)
        XCTAssertEqual(stream.remaining, 0)
    }

    func testUnknownSizeCannotProducePastEntryLimit() throws {
        let decoder = UnknownLengthTestDecompressor(Data(repeating: 0x41, count: 5))
        var limits = ReadLimits()
        limits.maxEntrySize = 4
        limits.maxInMemorySize = 4
        let stream = try EntryStream(
            decompressor: decoder,
            length: nil,
            expectedCRC32: nil,
            entryIndex: 0,
            limits: limits
        )

        XCTAssertThrowsError(try stream.readAll()) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUnknownSizeReadAllHonorsInMemoryLimit() throws {
        let decoder = UnknownLengthTestDecompressor(Data(repeating: 0x42, count: 9))
        var limits = ReadLimits()
        limits.maxEntrySize = 32
        limits.maxInMemorySize = 8
        let stream = try EntryStream(
            decompressor: decoder,
            length: nil,
            expectedCRC32: nil,
            entryIndex: 0,
            limits: limits
        )

        XCTAssertThrowsError(try stream.readAll()) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testChecksumTransformSupportsPasswordDependentStoredCRC() throws {
        let payload = Data("tweaked checksum".utf8)
        let plainCRC = CRC32.checksum(payload)
        let stream = try EntryStream(
            decompressor: UnknownLengthTestDecompressor(payload),
            length: UInt64(payload.count),
            expectedCRC32: plainCRC ^ 0xa5a5_a5a5,
            entryIndex: 0,
            limits: ReadLimits(),
            crc32Transform: { $0 ^ 0xa5a5_a5a5 }
        )
        XCTAssertEqual(try stream.readAll(), payload)
    }
}

private final class UnknownLengthTestDecompressor: Decompressor {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isFinished: Bool { offset == bytes.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset < bytes.count, !buffer.isEmpty else { return 0 }
        let count = min(buffer.count, bytes.count - offset)
        bytes.withUnsafeBytes { source in
            buffer.baseAddress?.copyMemory(
                from: source.baseAddress!.advanced(by: offset),
                byteCount: count
            )
        }
        offset += count
        return count
    }
}
