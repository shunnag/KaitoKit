import Foundation
import XCTest
@testable import KaitoKit

final class RARVerifiedPackedPartsTests: XCTestCase {
    func testCheckedRangesAreReadOnceInMemoryAndOnDiskWithShortReads() throws {
        for memoryLimit: UInt64 in [0, 1 << 20] {
            let payloads = [Data(repeating: 0x15, count: 9001), Data([1, 2, 3]),
                            Data(repeating: 0x41, count: 17003), Data([4, 5])]
            let sources = payloads.map { CallCountingByteSource(RARIOShortSource($0, maximum: 53)) }
            let segments = zip(sources, payloads).map { SourceSegment(source: $0, offset: 0, length: UInt64($1.count)) }
            let checked = [true, false, true, false]
            var limits = ReadLimits()
            limits.inMemorySingleFileLimit = memoryLimit
            limits.stagingFreeSpaceReserve = 0
            let retained = try RARVerifiedPackedParts.prepare(segments: segments, checked: checked, limits: limits) { index in
                checked[index] ? RARVerifiedPackedParts.Check(crc32: CRC32.checksum(payloads[index]), entryIndex: 7) : nil
            }
            XCTAssertEqual(sources.map(\.readBytes), [9001, 0, 17003, 0])
            XCTAssertEqual(retained[0].source is FileByteSource, memoryLimit == 0)
            let joined = try ConcatenatedByteSource(segments: retained, maximumLength: 1 << 20, label: "test")
            let output = try readByteRange(source: joined, offset: 0, count: Int(joined.length))
            XCTAssertEqual(Data(output), payloads.reduce(Data(), +))
            XCTAssertEqual(sources.map(\.readBytes), payloads.map(\.count))
        }
    }

    func testUnavailableStagingKeepsUpfrontVerificationAndOriginalSources() throws {
        let bytes = Data(repeating: 0x27, count: 600 << 10)
        for corrupt in [false, true] {
            let source = CallCountingByteSource(DataByteSource(bytes))
            let segment = SourceSegment(source: source, offset: 0, length: UInt64(bytes.count))
            var limits = ReadLimits()
            limits.inMemorySingleFileLimit = 0
            try SingleFileMaterializer.$availableTemporarySpace.withValue({ 0 }) {
                let prepare = {
                    try RARVerifiedPackedParts.prepare(segments: [segment], checked: [true], limits: limits) { _ in
                        RARVerifiedPackedParts.Check(crc32: CRC32.checksum(bytes) ^ (corrupt ? 1 : 0), entryIndex: 7)
                    }
                }
                if corrupt {
                    XCTAssertThrowsError(try prepare()) { error in
                        XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 7))
                    }
                } else {
                    let retained = try prepare()
                    XCTAssertTrue((retained[0].source as AnyObject) === source)
                    XCTAssertEqual(source.readBytes, bytes.count)
                    _ = try readByteRange(source: retained[0].source, offset: 0, count: bytes.count)
                }
                XCTAssertEqual(source.readBytes, bytes.count * (corrupt ? 1 : 2))
            }
        }
    }

    func testEarlierChecksumFailurePrecedesLaterPartMetadataFailure() throws {
        let source = DataByteSource(Data([1, 2, 3]))
        let segments = [SourceSegment(source: source, offset: 0, length: 3),
                        SourceSegment(source: source, offset: 0, length: 0)]
        XCTAssertThrowsError(try RARVerifiedPackedParts.prepare(
            segments: segments, checked: [true, false], limits: ReadLimits()
        ) { index in
            if index == 1 { throw KaitoError.malformed("later part") }
            return RARVerifiedPackedParts.Check(crc32: 0, entryIndex: 9)
        }) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 9))
        }
    }

    func testBlake2spAndPasswordDependentChecksKeepMismatchClassification() throws {
        let bytes = Data(repeating: 0x62, count: 1234)
        let segment = SourceSegment(source: DataByteSource(bytes), offset: 0, length: UInt64(bytes.count))
        var hash = Blake2sp()
        bytes.withUnsafeBytes { hash.update($0) }
        let digest = [UInt8](hash.finalize())
        for keyed in [false, true] {
            for corrupt in [false, true] {
                let key = keyed ? Data(repeating: 0x31, count: 32) : nil
                let expected = try key.map { [UInt8](try RAR5ChecksumMAC.blake2sp(Data(digest), hashKey: $0)) } ?? digest
                var candidate = expected
                if corrupt { candidate[0] ^= 1 }
                let prepare = {
                    try RARVerifiedPackedParts.prepare(segments: [segment], checked: [true], limits: ReadLimits()) { _ in
                        RARVerifiedPackedParts.Check(crc32: nil, blake2sp: candidate, hashKey: key,
                                                     mismatchIsWrongPassword: true, entryIndex: 3)
                    }
                }
                if corrupt {
                    XCTAssertThrowsError(try prepare()) { error in
                        XCTAssertEqual(error as? KaitoError, keyed ? .wrongPassword : .checksumMismatch(entry: 3))
                    }
                } else { _ = try prepare() }
            }
        }
    }

    func testTruncatedCheckedPartAndEmptyPartAreVerifiedBeforeReturn() throws {
        let source = RARIOShortSource(Data([1, 2, 3]), maximum: 1, advertisedLength: 5)
        XCTAssertThrowsError(try RARVerifiedPackedParts.prepare(
            segments: [SourceSegment(source: source, offset: 0, length: 5)], checked: [true], limits: ReadLimits()
        ) { _ in RARVerifiedPackedParts.Check(crc32: 0, entryIndex: 1) }) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertThrowsError(try RARVerifiedPackedParts.prepare(
            segments: [SourceSegment(source: source, offset: 0, length: 0)], checked: [true], limits: ReadLimits()
        ) { _ in RARVerifiedPackedParts.Check(crc32: 1, entryIndex: 2) }) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 2))
        }
    }
}

private final class RARIOShortSource: ByteSource {
    private let base: DataByteSource
    private let maximum: Int
    let length: UInt64
    init(_ bytes: Data, maximum: Int, advertisedLength: UInt64? = nil) {
        base = DataByteSource(bytes)
        self.maximum = maximum
        length = advertisedLength ?? UInt64(bytes.count)
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try base.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<min(maximum, buffer.count)]), at: offset)
    }
}
