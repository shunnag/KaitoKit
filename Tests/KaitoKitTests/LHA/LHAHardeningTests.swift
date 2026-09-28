import Foundation
@testable import KaitoKit
import XCTest

final class LHAHardeningTests: XCTestCase {
    func testIncompleteStoredEntryMatchesOriginalPrefix() throws {
        let original = Data((0..<(2 * 1_024 * 1_024)).map {
            UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16))
        })
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "stored", contents: original, method: "-lh0-", headerLevel: 2),
        ])
        let dataOffset = archive.count - 1 - original.count
        let survived = 1_024 * 1_024 + 193
        let reader = try ArchiveReader.open(
            data: Data(archive.prefix(dataOffset + survived)),
            options: ReaderOptions(recoverDamagedArchives: true)
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isIncomplete)
        XCTAssertEqual(entry.methodDescription, "-lh0-")
        XCTAssertEqual(entry.uncompressedSize, UInt64(original.count))
        let payload = try reader.read(entry)
        XCTAssertEqual(payload.count, survived)
        XCTAssertEqual(payload, Data(original.prefix(survived)))
    }

    func testRecoveryRetainsLHAHeadersAndCutStoredPayloadAcrossAllLevels() throws {
        let first = Data("complete".utf8)
        let last = Data(repeating: 0xA5, count: 4_096)
        for level: UInt8 in 0...3 {
            let firstArchive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(name: "first", contents: first, headerLevel: level),
            ])
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(name: "first", contents: first, headerLevel: level),
                HandLHAEntry(name: "last", contents: last, headerLevel: level),
            ])
            let dataOffset = archive.count - 1 - last.count
            for end in [firstArchive.count - 1 + 10, dataOffset, dataOffset + 777, archive.count - 1] {
                let cut = Data(archive.prefix(end))
                XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { error in
                    guard case KaitoError.truncated = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
                let reader = try ArchiveReader.open(
                    data: cut, options: ReaderOptions(recoverDamagedArchives: true)
                )
                XCTAssertEqual(reader.entries.count, end < dataOffset ? 1 : 2)
                XCTAssertFalse(reader.entries[0].isIncomplete)
                XCTAssertEqual(try reader.read(reader.entries[0]), first)
                if reader.entries.count == 2 {
                    XCTAssertEqual(reader.entries[1].isIncomplete, end < archive.count - 1)
                    XCTAssertEqual(try reader.read(reader.entries[1]), last.prefix(end - dataOffset))
                }
            }
            var corrupt = Data(archive.prefix(dataOffset + 777))
            corrupt[firstArchive.count - 2] ^= 1
            let reader = try ArchiveReader.open(
                data: corrupt, options: ReaderOptions(recoverDamagedArchives: true)
            )
            XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
                guard case KaitoError.checksumMismatch(entry: 0) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            for limits in [ReadLimits(maxEntryCount: 1), ReadLimits(maxEntrySize: 4_095),
                           ReadLimits(maxTotalUncompressedSize: 4_096),
                           ReadLimits(maxMetadataSize: 20), ReadLimits(maxTotalMetadataSize: 100)] {
                XCTAssertThrowsError(try ArchiveReader.open(data: corrupt, options: ReaderOptions(
                    limits: limits, recoverDamagedArchives: true
                ))) { error in
                    guard case KaitoError.limitExceeded = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }


    func testRecoveryReturnsCompressedLHAPrefixesAndPreservesMacBinaryDataForks() throws {
        // 既存の static Huffman テストと同じ単一記号 block を二つ連結する。
        var bits: [UInt8] = []
        for symbol in [75, 76] {
            for (value, width) in [(257, 16), (0, 5), (0, 5), (0, 9), (symbol, 9), (0, 4), (0, 4)] {
                for bit in stride(from: width - 1, through: 0, by: -1) {
                    bits.append(UInt8((value >> bit) & 1))
                }
            }
        }
        let packed = Data(stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<(start + 8)].reduce(UInt8(0)) { ($0 << 1) | $1 }
        })
        let payload = Data(repeating: 75, count: 257) + Data(repeating: 76, count: 257)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "first", contents: payload, method: "-lh5-", headerLevel: 2,
                         packedContents: packed),
            HandLHAEntry(name: "last", contents: payload, method: "-lh5-", headerLevel: 2,
                         packedContents: packed),
        ])
        let dataOffset = archive.count - 1 - packed.count
        for survived in [0, 7] {
            let cut = Data(archive.prefix(dataOffset + survived))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { error in
                XCTAssertEqual(error as? KaitoError, .truncated)
            }
            let reader = try ArchiveReader.open(
                data: cut, options: ReaderOptions(recoverDamagedArchives: true)
            )
            XCTAssertTrue(reader.entries[1].isIncomplete)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(try reader.read(reader.entries[1]), payload.prefix(survived == 0 ? 0 : 257))
        }

        let fork = Data(repeating: 0xA5, count: 1_024)
        var envelope = Data(repeating: 0, count: 128)
        envelope[1] = 1
        envelope[2] = 65
        envelope[85] = 4
        envelope[89] = 4
        envelope.append(fork)
        envelope.append(Data(repeating: 0x5A, count: 1_024))
        let macArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "mac", contents: envelope, headerLevel: 2, creatorOS: 0x6D),
        ])
        let macDataOffset = macArchive.count - 1 - envelope.count
        for survived in [777, 1_024] {
            let cut = Data(macArchive.prefix(macDataOffset + 128 + survived))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut))
            let reader = try ArchiveReader.open(
                data: cut, options: ReaderOptions(recoverDamagedArchives: true)
            )
            XCTAssertTrue(reader.entries[0].isIncomplete)
            XCTAssertEqual(try reader.read(reader.entries[0]), fork.prefix(survived))
        }
    }

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

    func testLevel3HeaderCRC16MismatchIsRejected() throws {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "level-three-crc.txt",
                contents: Data("payload".utf8),
                headerLevel: 3
            ),
        ]))
        bytes[15] ^= 0x01
        assertMalformed(tryResult { try self.openDirect(bytes) }, contains: "CRC")
    }

    func testPortableLevel3MemberUsesFourByteHeaderAndExtensionSizes() throws {
        let payload = Data("portable level three".utf8)
        let bytes = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "entry.txt",
                contents: payload,
                headerLevel: 3,
                directoryBytes: Array("nested".utf8) + [0xFF],
                permissions: 0o640
            ),
        ])
        let reader = try openDirect(Array(bytes))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "nested/entry.txt")
        XCTAssertEqual(entry.formatSpecific["headerLevel"], "3")
        XCTAssertEqual(entry.posixPermissions, 0o640)
        XCTAssertEqual(
            try reader.stream(for: entry, limits: compactLimits).readAll(),
            payload
        )
    }

    func testLevel3SizeWidthAndExtensionChainOverrunAreRejected() throws {
        let archive = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "level-three.txt", headerLevel: 3),
        ]))

        var invalidWidth = archive
        invalidWidth[0] = 2
        invalidWidth[1] = 0
        assertMalformed(
            tryResult { try self.openDirect(invalidWidth) },
            contains: "size-field width"
        )

        let headerSize = Int(archive[24])
            | (Int(archive[25]) << 8)
            | (Int(archive[26]) << 16)
            | (Int(archive[27]) << 24)
        XCTAssertGreaterThanOrEqual(headerSize, 36)
        var unterminatedChain = archive
        unterminatedChain[headerSize - 4] = 5
        assertMalformed(
            tryResult { try self.openDirect(unterminatedChain) },
            contains: "overruns"
        )
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

    func testDirectoryExtensionWithEmptyLeafInfersDirectory() throws {
        for method in ["-lh0-", "-lhd-"] {
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(
                    rawName: [],
                    method: method,
                    headerLevel: 2,
                    directoryBytes: Array("dir".utf8) + [0xFF]
                ),
            ])
            let reader = try openDirect(Array(archive))
            XCTAssertEqual(reader.entries.first?.name, "dir/")
            XCTAssertEqual(reader.entries.first?.kind, EntryKind.directory)
        }
    }

    func testDOSAttributeExtensionInfersDirectoryAtEveryExtendedHeaderLevel() throws {
        for level: UInt8 in [1, 2, 3] {
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(
                    name: "attribute-directory-\(level)",
                    headerLevel: level,
                    permissions: nil,
                    extraHeaders: [
                        HandLHAExtendedHeader(0x40, [0x10, 0x00]),
                    ]
                ),
            ])
            let reader = try openDirect(Array(archive))
            XCTAssertEqual(reader.entries.first?.kind, .directory, "level \(level)")
        }
    }

    func testOnlyDocumentedLArcOrAnonymousCompatibilityMayOmitArchiveTerminator() throws {
        for method in ["-lzs-", "-lz4-", "-lz5-"] {
            let member = try LHATestSupport.makeMember(HandLHAEntry(
                name: "legacy.bin",
                contents: Data(),
                method: method,
                headerLevel: 0,
                permissions: nil
            ))
            let reader = try openDirect(Array(member))
            XCTAssertEqual(reader.entries.first?.methodDescription, method)
        }

        var anonymousCompatibilityArchive = Data()
        anonymousCompatibilityArchive.append(try LHATestSupport.makeMember(HandLHAEntry(
            rawName: [],
            method: "-lh0-",
            headerLevel: 0,
            permissions: nil
        )))
        anonymousCompatibilityArchive.append(try LHATestSupport.makeMember(HandLHAEntry(
            name: "named.bin",
            method: "-lh0-",
            headerLevel: 0,
            permissions: nil
        )))
        let compatibilityReader = try openDirect(Array(anonymousCompatibilityArchive))
        XCTAssertEqual(compatibilityReader.entries.map(\.name), ["named.bin"])

        let unterminated = try LHATestSupport.makeMember(HandLHAEntry(
            name: "ordinary.bin",
            contents: Data(),
            method: "-lh0-",
            headerLevel: 0,
            permissions: nil
        ))
        XCTAssertThrowsError(try openDirect(Array(unterminated))) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testOS9Level2TwoByteUndercountRequiresCreator4B() throws {
        let payload = Data("OS-68K undercount".utf8)
        let accepted = try undercountedLevel2Archive(
            creatorOS: 0x4B,
            contents: payload
        )
        let reader = try openDirect(accepted)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(
            try reader.stream(for: entry, limits: compactLimits).readAll(),
            payload
        )

        let wrongCreator = try undercountedLevel2Archive(
            creatorOS: 0x55,
            contents: payload
        )
        assertMalformed(
            tryResult { try self.openDirect(wrongCreator) },
            contains: "overruns"
        )
    }

    func testOS9Creator4BUndercountRequiresZeroExtensionTerminator() throws {
        var bytes = try undercountedLevel2Archive(
            creatorOS: 0x4B,
            contents: Data()
        )
        let declaredSize = Int(bytes[0]) | (Int(bytes[1]) << 8)
        bytes[declaredSize] = 5
        assertMalformed(
            tryResult { try self.openDirect(bytes) },
            contains: "overruns"
        )
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

    func testTruncatedLevel2FixedHeaderIsRejectedWithoutTrap() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "truncated.txt", headerLevel: 2),
        ])
        let bytes = Array(archive.prefix(23))

        XCTAssertThrowsError(try openDirect(bytes)) { error in
            XCTAssertEqual(error as? KaitoError, KaitoError.truncated)
        }
    }

    func testExtendedHeaderCountLimitIsAppliedPerMember() throws {
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

    func testDefaultExtendedHeaderLimitAllows13108FiveRecordMembers() throws {
        let extra = HandLHAExtendedHeader(0x60, [0x41])
        let counts = [13_107, 13_108]
        for count in counts {
            let archive = try LHATestSupport.makeArchive(entries: (0..<count).map { index in
                HandLHAEntry(
                    name: "member-\(index)",
                    method: "-lhd-",
                    headerLevel: 2,
                    directoryBytes: Array("folder".utf8) + [0xFF],
                    permissions: 0o755,
                    extraHeaders: [extra]
                )
            })
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(reader.entries.count, count)
            XCTAssertEqual(reader.entries.last?.index, count - 1)
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

    func testLongLeadingSlashRunIsTrimmedToARelativeName() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: String(repeating: "/", count: 2_048) + "linear.txt",
                headerLevel: 2,
                permissions: nil
            ),
        ])
        let reader = try openDirect(Array(archive))
        XCTAssertEqual(reader.entries.first?.name, "linear.txt")
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

    private func undercountedLevel2Archive(
        creatorOS: UInt8,
        contents: Data
    ) throws -> [UInt8] {
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "undercounted.bin",
                contents: contents,
                headerLevel: 2,
                creatorOS: creatorOS
            ),
        ]))
        let actualHeaderSize = Int(bytes[0]) | (Int(bytes[1]) << 8)
        guard actualHeaderSize >= 29,
              bytes[26] == 0,
              bytes[actualHeaderSize - 2] == 0,
              bytes[actualHeaderSize - 1] == 0 else {
            throw KaitoError.malformed("unexpected test level-2 header layout")
        }

        let declaredHeaderSize = actualHeaderSize - 2
        bytes[0] = UInt8(truncatingIfNeeded: declaredHeaderSize)
        bytes[1] = UInt8(truncatingIfNeeded: declaredHeaderSize >> 8)
        bytes[27] = 0
        bytes[28] = 0
        let headerCRC = CRC16.checksum(Array(bytes[..<actualHeaderSize]))
        bytes[27] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[28] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        return bytes
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
