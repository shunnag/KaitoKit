import Foundation
@testable import KaitoKit
import XCTest

final class LHAHardeningTests: XCTestCase {
    func testLevel0HeaderChecksumMismatchIsRejected() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "checksum.txt",
                contents: Data("payload".utf8),
                headerLevel: 0
            ),
        ]))
        bytes[1] ^= 0x01
        assertMalformed(tryResult { try self.openDirect(bytes) }, contains: "checksum")
    }

    func testLevel2HeaderCRC16MismatchIsRejected() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "header-crc.txt",
                contents: Data("payload".utf8),
                headerLevel: 2
            ),
        ]))
        bytes[19] ^= 0x01
        assertMalformed(tryResult { try self.openDirect(bytes) }, contains: "CRC")
    }

    func testTruncatedMemberPayloadIsRejectedWhileOpening() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "truncated.bin",
                contents: Data(repeating: 0xA5, count: 32),
                headerLevel: 1
            ),
        ]))
        bytes.removeLast(12)
        XCTAssertThrowsError(try openDirect(bytes)) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.truncated)
        }
    }

    func testZeroLengthEffectiveNameIsRejected() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(rawName: [], headerLevel: 2),
        ])
        assertMalformed(
            tryResult { try self.openDirect(Array(bytes)) },
            contains: "empty filename"
        )
    }

    func testDirectoryPathCannotStandInForAnEmptyFileName() throws {
        let pathOnlyFile = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                rawName: [],
                method: "-lh0-",
                headerLevel: 2,
                directoryBytes: Array("dir".utf8) + [0xFF]
            ),
        ])
        assertMalformed(
            tryResult { try self.openDirect(Array(pathOnlyFile)) },
            contains: "empty filename"
        )

        let pathOnlyDirectory = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                rawName: [],
                method: "-lhd-",
                headerLevel: 2,
                directoryBytes: Array("dir".utf8) + [0xFF]
            ),
        ])
        let reader = try openDirect(Array(pathOnlyDirectory))
        XCTAssertEqual(reader.entries.first?.name, "dir/")
        XCTAssertEqual(reader.entries.first?.kind, EntryKind.directory)
    }

    func testUndersizedExtendedHeaderCannotLoop() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "extension.txt", headerLevel: 2),
        ]))
        // Level 2's first extension size is at byte 24. A record must hold a
        // type and its trailing two-byte next-size field.
        bytes[24] = 2
        bytes[25] = 0
        assertMalformed(tryResult { try self.openDirect(bytes) }, contains: "envelope")
    }

    func testExtendedHeaderCountLimitIsAppliedAcrossMembers() throws {
        let extras = (0..<8).map {
            HandLHAExtendedHeader(UInt8(0x60 + $0), [UInt8($0)])
        }
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "many-extensions.txt",
                headerLevel: 2,
                extraHeaders: extras
            ),
        ])
        var limits = compactLimits
        limits.maxMetadataRecordCount = 5
        XCTAssertThrowsError(
            try LHAReader(
                source: DataByteSource(data: bytes),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testDirectoryMethodCannotCarryPackedData() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "not-empty",
                contents: Data([0x41]),
                method: "-lhd-",
                headerLevel: 2
            ),
        ])
        assertMalformed(tryResult { try self.openDirect(Array(bytes)) }, contains: "has data")
    }

    func testDirectoryIgnoresNominalDataCRC() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "empty-directory",
                method: "-lhd-",
                headerLevel: 2,
                dataCRC16: 0x1234
            ),
        ])
        let reader = try ArchiveReader.open(data: bytes)
        let directory = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(directory.kind, EntryKind.directory)
        XCTAssertEqual(try reader.read(directory), Data())
    }

    func testStoredMemberOvershootFailureRemainsTerminal() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "overshoot.bin",
                contents: Data([0x41]),
                headerLevel: 2,
                packedContents: Data([0x41, 0x42]),
                declaredOriginalSize: 1
            ),
        ])
        let reader = try ArchiveReader.open(data: bytes)
        let stream = try reader.stream(reader.entries[0])
        var byte: UInt8 = 0
        for _ in 0..<2 {
            XCTAssertThrowsError(
                try withUnsafeMutableBytes(of: &byte) { try stream.read(into: $0) }
            ) { error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .malformed("entry output exceeds its declared size")
                )
            }
        }
    }

    func testDeclaredSizesHonorEntryLimitBeforeStreamCreation() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "large.bin",
                contents: Data(repeating: 0, count: 64),
                headerLevel: 2
            ),
        ])
        var limits = compactLimits
        limits.maxEntrySize = 32
        XCTAssertThrowsError(
            try LHAReader(
                source: DataByteSource(data: bytes),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testPendingExtendedMetadataHonorsAggregateLimit() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "metadata-limit.txt",
                headerLevel: 2,
                extraHeaders: [
                    HandLHAExtendedHeader(0x3F, [UInt8](repeating: 0x41, count: 512)),
                ]
            ),
        ])
        var limits = compactLimits
        limits.maxTotalMetadataSize = 300
        XCTAssertThrowsError(
            try LHAReader(
                source: DataByteSource(data: bytes),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testPathComponentLimitIsCheckedBeforeComponentPublication() throws {
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "a/b/c.txt", headerLevel: 2),
        ])
        var limits = compactLimits
        limits.maxPathComponentCount = 2
        XCTAssertThrowsError(
            try LHAReader(
                source: DataByteSource(data: bytes),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testHeaderLevel3IsExplicitlyUnsupported() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "level3.txt", headerLevel: 2),
        ]))
        bytes[20] = 3
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(bytes))) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedMethod("LHA header level 3"))
        }
    }

    func testLevel2HeaderSizeWithZeroLowByteIsNotDetectedAsAnEmptyArchive() throws {
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes[0] = 0
        bytes[1] = 1
        bytes.replaceSubrange(2..<7, with: Array("-lh0-".utf8))
        bytes[20] = 2

        XCTAssertThrowsError(try ArchiveReader.open(data: Data(bytes))) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.unsupportedFormat)
        }
    }

    func testDeterministic384MemberMutantsDoNotCrashOrStall() throws {
        let seed = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "zero.txt",
                contents: Data("zero payload".utf8),
                headerLevel: 0,
                permissions: nil
            ),
            HandLHAEntry(
                name: "one.txt",
                contents: Data("one payload".utf8),
                headerLevel: 1
            ),
            HandLHAEntry(
                name: "two.txt",
                contents: Data("two payload".utf8),
                headerLevel: 2
            ),
        ]))
        var completed = 0

        for mutation in 0..<384 {
            var bytes = seed
            switch mutation % 6 {
            case 0:
                let index = (mutation &* 17 &+ 3) % bytes.count
                bytes[index] ^= UInt8(truncatingIfNeeded: mutation | 1)
            case 1:
                let retained = (mutation &* 31) % bytes.count
                bytes.removeSubrange(retained..<bytes.count)
            case 2:
                let index = (mutation &* 13 &+ 1) % max(1, bytes.count - 1)
                bytes[index] = 0xFF
                bytes[index + 1] = UInt8(truncatingIfNeeded: mutation)
            case 3:
                let index = (mutation &* 7 &+ 2) % bytes.count
                bytes[index] = 0
            case 4:
                bytes.append(contentsOf: [0x2D, 0x6C, 0x68, 0x35, 0x2D])
                bytes.append(UInt8(truncatingIfNeeded: mutation))
            default:
                let start = (mutation &* 19) % bytes.count
                let count = min(1 + mutation % 11, bytes.count - start)
                for index in start..<(start + count) {
                    bytes[index] = UInt8(truncatingIfNeeded: index &+ mutation)
                }
            }

            do {
                let reader = try LHAReader(
                    source: DataByteSource(data: Data(bytes)),
                    options: ReaderOptions(limits: compactLimits)
                )
                for entry in reader.entries where entry.kind != EntryKind.directory {
                    _ = try reader.stream(for: entry, limits: compactLimits).readAll()
                }
            } catch {
                // Rejection is the expected result for most malformed mutants.
            }
            completed += 1
        }
        XCTAssertEqual(completed, 384)
    }

    private var compactLimits: ReadLimits {
        ReadLimits(
            maxEntrySize: 4_096,
            maxInMemorySize: 4_096,
            maxEntryCount: 32,
            maxMetadataSize: 4_096,
            maxMetadataRecordCount: 64,
            maxPathComponentCount: 32,
            maxTotalMetadataSize: 64 * 1_024,
            maxDictionarySize: 128 * 1_024
        )
    }

    private func openDirect(_ bytes: [UInt8]) throws -> LHAReader {
        try LHAReader(
            source: DataByteSource(data: Data(bytes)),
            options: ReaderOptions(limits: compactLimits)
        )
    }

    private func tryResult<T>(_ operation: () throws -> T) -> Result<T, Error> {
        Result(catching: operation)
    }

    private func assertMalformed<T>(
        _ result: Result<T, Error>,
        contains text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected malformed LHA input", file: file, line: line)
        case let .failure(error):
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("expected malformed, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(text), "reason was: \(reason)", file: file, line: line)
        }
    }
}
