import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class LHAIntegrationTests: XCTestCase {
    func testCRC16ANSIIBMVector() {
        XCTAssertEqual(CRC16.checksum(Array("123456789".utf8)), 0xBB3D)
    }

    func testStoredMembersAcrossHeaderLevelsAndDeclaredCodePage() throws {
        let level0Name = "漫画\\表紙0.txt"
        let level1Name = "画像1.txt"
        let level2Directory = "章立て"
        let level2Name = "表紙2.txt"
        let directoryName = "空フォルダ"
        let level0Raw = Array(try XCTUnwrap(level0Name.data(using: .shiftJIS)))
        let level1Raw = Array(try XCTUnwrap(level1Name.data(using: .shiftJIS)))
        let level2DirectoryRaw = Array(
            try XCTUnwrap(level2Directory.data(using: .shiftJIS))
        ) + [0xFF]
        let level2Raw = Array(try XCTUnwrap(level2Name.data(using: .shiftJIS)))
        let directoryRaw = Array(try XCTUnwrap(directoryName.data(using: .shiftJIS)))
        let payloads = [
            Data("level zero".utf8),
            Data("level one".utf8),
            Data("level two".utf8),
            Data(),
        ]
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                rawName: level0Raw,
                contents: payloads[0],
                headerLevel: 0,
                permissions: nil
            ),
            HandLHAEntry(
                rawName: level1Raw,
                contents: payloads[1],
                headerLevel: 1
            ),
            HandLHAEntry(
                rawName: level2Raw,
                contents: payloads[2],
                headerLevel: 2,
                directoryBytes: level2DirectoryRaw,
                codepage: 932
            ),
            HandLHAEntry(
                rawName: directoryRaw,
                method: "-lhd-",
                headerLevel: 2,
                codepage: 932,
                permissions: 0o755
            ),
        ])

        XCTAssertEqual(try FormatDetector.detect(data: archive), ArchiveFormat.lha)
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.format, ArchiveFormat.lha)
        XCTAssertEqual(reader.nameEncoding, String.Encoding.shiftJIS)
        XCTAssertEqual(
            reader.entries.map(\.name),
            [
                "漫画/表紙0.txt",
                level1Name,
                "\(level2Directory)/\(level2Name)",
                directoryName,
            ]
        )
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .file, .file, .directory])
        XCTAssertEqual(reader.entries.map(\.solidGroup), [-1, -1, -1, -1])
        XCTAssertEqual(
            reader.entries.map { $0.formatSpecific["headerLevel"] },
            ["0", "1", "2", "2"]
        )
        XCTAssertEqual(reader.entries.map(\.methodDescription), [
            "-lh0-", "-lh0-", "-lh0-", "-lhd-",
        ])
        XCTAssertNil(reader.entries[0].rawName.declaredEncoding)
        XCTAssertNil(reader.entries[1].rawName.declaredEncoding)
        XCTAssertEqual(reader.entries[2].rawName.declaredEncoding, .shiftJIS)
        XCTAssertEqual(reader.entries[3].rawName.declaredEncoding, .shiftJIS)
        XCTAssertEqual(reader.entries[2].posixPermissions, 0o644)
        XCTAssertEqual(reader.entries[3].posixPermissions, 0o755)

        for (index, payload) in payloads.enumerated() {
            XCTAssertEqual(try reader.read(reader.entries[index]), payload)
        }
        let reopened = try reader.reopen()
        XCTAssertEqual(reopened.entries, reader.entries)
        XCTAssertEqual(try reopened.read(reopened.entries[2]), payloads[2])
    }

    func testCodePage65001And936AreDeclaredAndSkipArchiveGuessing() throws {
        let utf8Name = "宣言済み.txt"
        let gbkName: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4] + Array(".txt".utf8)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                rawName: Array(utf8Name.utf8),
                contents: Data("utf8".utf8),
                headerLevel: 2,
                codepage: 65_001
            ),
            HandLHAEntry(
                rawName: gbkName,
                contents: Data("gbk".utf8),
                headerLevel: 2,
                codepage: 936
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertNil(reader.nameEncoding)
        XCTAssertEqual(reader.entries.map(\.name), [utf8Name, "中文.txt"])
        XCTAssertEqual(reader.entries[0].rawName.declaredEncoding, .utf8)
        XCTAssertNotNil(reader.entries[1].rawName.declaredEncoding)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("utf8".utf8))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data("gbk".utf8))
    }

    func testWindowsCreatorOSGuidesUndeclaredLegacyNameDecoding() throws {
        let name = "表紙.txt"
        let rawName = Array(try XCTUnwrap(name.data(using: .shiftJIS)))
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                rawName: rawName,
                contents: Data("page".utf8),
                headerLevel: 0,
                creatorOS: UInt8(ascii: "W"),
                permissions: nil
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.nameEncoding, String.Encoding.shiftJIS)
        XCTAssertEqual(entry.name, name)
        XCTAssertEqual(entry.formatSpecific["osID"], "W")
        XCTAssertEqual(entry.formatSpecific["os"], "Windows NT")
        XCTAssertEqual(try reader.read(entry), Data("page".utf8))
    }

    func testBackslashIsASeparatorOnlyForHeaderLevelsZeroAndOne() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "zero\\page.txt", headerLevel: 0, permissions: nil),
            HandLHAEntry(name: "one\\page.txt", headerLevel: 1),
            HandLHAEntry(name: "two\\page.txt", headerLevel: 2),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(
            reader.entries.map(\.name),
            ["zero/page.txt", "one/page.txt", "two\\page.txt"]
        )
        XCTAssertEqual(
            reader.entries.map(\.pathComponents),
            [["zero", "page.txt"], ["one", "page.txt"], ["two\\page.txt"]]
        )
    }

    func testEmptyDuplicateNameExtensionsDoNotClearEarlierValues() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "page.txt",
                headerLevel: 2,
                directoryBytes: Array("chapter".utf8) + [0xFF],
                extraHeaders: [
                    HandLHAExtendedHeader(0x01, []),
                    HandLHAExtendedHeader(0x02, []),
                ]
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.first?.name, "chapter/page.txt")
    }

    func testExtendedMetadataAnd64BitSizeRecord() throws {
        var sizePayload: [UInt8] = []
        LHATestSupport.appendUInt64LE(5, to: &sizePayload) // packed
        LHATestSupport.appendUInt64LE(5, to: &sizePayload) // original
        var ids: [UInt8] = []
        LHATestSupport.appendUInt16LE(20, to: &ids) // gid
        LHATestSupport.appendUInt16LE(501, to: &ids) // uid
        var unixTime: [UInt8] = []
        LHATestSupport.appendUInt32LE(1_800_000_123, to: &unixTime)

        let fileTime = (UInt64(1_750_000_000) + 11_644_473_600) * 10_000_000
        var windowsTimes: [UInt8] = []
        LHATestSupport.appendUInt64LE(fileTime - 20_000_000, to: &windowsTimes)
        LHATestSupport.appendUInt64LE(fileTime, to: &windowsTimes)
        LHATestSupport.appendUInt64LE(fileTime + 20_000_000, to: &windowsTimes)

        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "metadata.txt",
                contents: Data("12345".utf8),
                headerLevel: 2,
                permissions: 0o640,
                extraHeaders: [
                    HandLHAExtendedHeader(0x3F, Array("comment".utf8)),
                    HandLHAExtendedHeader(0x40, [0x21, 0x00]),
                    HandLHAExtendedHeader(0x41, windowsTimes),
                    HandLHAExtendedHeader(0x42, sizePayload),
                    HandLHAExtendedHeader(0x51, ids),
                    HandLHAExtendedHeader(0x52, Array("staff".utf8)),
                    HandLHAExtendedHeader(0x53, Array("reader".utf8)),
                    HandLHAExtendedHeader(0x54, unixTime),
                    HandLHAExtendedHeader(0x7F, [1, 2]),
                    HandLHAExtendedHeader(0xFF, [3, 4]),
                ]
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.uncompressedSize, 5)
        XCTAssertEqual(entry.compressedSize, 5)
        XCTAssertEqual(entry.posixPermissions, 0o640)
        XCTAssertEqual(entry.modificationDate?.timeIntervalSince1970, 1_800_000_123)
        XCTAssertEqual(entry.formatSpecific["dosAttributes"], "0x0021")
        XCTAssertEqual(entry.formatSpecific["uid"], "501")
        XCTAssertEqual(entry.formatSpecific["gid"], "20")
        XCTAssertEqual(entry.formatSpecific["group"], "staff")
        XCTAssertEqual(entry.formatSpecific["user"], "reader")
        XCTAssertEqual(entry.formatSpecific["comment"], "comment")
        XCTAssertNotNil(entry.formatSpecific["creationTime"])
        XCTAssertNotNil(entry.formatSpecific["accessTime"])
        XCTAssertEqual(try reader.read(entry), Data("12345".utf8))
    }

    func testWindowsTimestampOverridesLevel1ButNotLevel2UnixTime() throws {
        let windowsModificationTime: UInt64 = 1_750_000_000
        let fileTime = (windowsModificationTime + 11_644_473_600) * 10_000_000
        var windowsTimes: [UInt8] = []
        LHATestSupport.appendUInt64LE(fileTime - 10_000_000, to: &windowsTimes)
        LHATestSupport.appendUInt64LE(fileTime, to: &windowsTimes)
        LHATestSupport.appendUInt64LE(fileTime + 10_000_000, to: &windowsTimes)
        let extensionHeader = HandLHAExtendedHeader(0x41, windowsTimes)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "level1-time.txt",
                headerLevel: 1,
                extraHeaders: [extensionHeader]
            ),
            HandLHAEntry(
                name: "level2-time.txt",
                headerLevel: 2,
                extraHeaders: [extensionHeader]
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(
            reader.entries[0].modificationDate?.timeIntervalSince1970,
            Double(windowsModificationTime)
        )
        XCTAssertEqual(
            reader.entries[1].modificationDate?.timeIntervalSince1970,
            Double(LHATestSupport.unixTimestamp)
        )
        XCTAssertNotNil(reader.entries[0].formatSpecific["creationTime"])
        XCTAssertNotNil(reader.entries[1].formatSpecific["creationTime"])
        XCTAssertNotNil(reader.entries[0].formatSpecific["accessTime"])
        XCTAssertNotNil(reader.entries[1].formatSpecific["accessTime"])
    }

    func testZeroWindowsTimestampsLeaveLevel1DOSTimeIntact() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "zero-windows-time.txt",
                headerLevel: 1,
                extraHeaders: [
                    HandLHAExtendedHeader(0x41, [UInt8](repeating: 0, count: 24)),
                ]
            ),
        ])

        let entry = try XCTUnwrap(ArchiveReader.open(data: archive).entries.first)
        let date = try XCTUnwrap(entry.modificationDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 4)
        XCTAssertEqual(components.second, 6)
        XCTAssertNil(entry.formatSpecific["creationTime"])
        XCTAssertNil(entry.formatSpecific["accessTime"])
    }

    func testLevel2AuthenticatedTrailingHeaderPaddingIsAccepted() throws {
        let payload = Data("padded".utf8)
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "padding.txt",
                contents: payload,
                headerLevel: 2
            ),
        ]))
        let headerSize = Int(bytes[0]) | (Int(bytes[1]) << 8)
        let padding = [UInt8](repeating: 0xA5, count: 16)
        let paddedHeaderSize = headerSize + padding.count
        XCTAssertNotEqual(paddedHeaderSize & 0xFF, 0)

        // The extension chain already terminates at zero. Insert a nonzero
        // padding tail before the payload, grow the declared header, and
        // authenticate the entire padded header with the common CRC.
        bytes.insert(contentsOf: padding, at: headerSize)
        bytes[0] = UInt8(truncatingIfNeeded: paddedHeaderSize)
        bytes[1] = UInt8(truncatingIfNeeded: paddedHeaderSize >> 8)
        bytes[27] = 0
        bytes[28] = 0
        let headerCRC = CRC16.checksum(Array(bytes[..<paddedHeaderSize]))
        bytes[27] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[28] = UInt8(truncatingIfNeeded: headerCRC >> 8)

        let reader = try ArchiveReader.open(data: Data(bytes))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "padding.txt")
        XCTAssertEqual(try reader.read(entry), payload)

        var limits = ReadLimits()
        limits.maxMetadataSize = UInt64(paddedHeaderSize - 1)
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(bytes),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected metadata limit, got \(error)")
            }
        }

        var unauthenticated = bytes
        unauthenticated[headerSize + 3] ^= 0x01
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(unauthenticated))) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("expected malformed header CRC, got \(error)")
            }
            XCTAssertTrue(reason.contains("CRC"))
        }
    }

    func testLevel2CommonHeaderCRCIsOptionalIncludingWithPadding() throws {
        let payload = Data("optional-crc".utf8)
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "no-common-crc.txt",
                contents: payload,
                headerLevel: 2,
                includeLevel2HeaderCRC: false
            ),
        ]))
        let headerSize = Int(bytes[0]) | (Int(bytes[1]) << 8)
        let padding = [UInt8](repeating: 0xA5, count: 8)
        let paddedHeaderSize = headerSize + padding.count
        XCTAssertNotEqual(paddedHeaderSize & 0xFF, 0)
        bytes.insert(contentsOf: padding, at: headerSize)
        bytes[0] = UInt8(truncatingIfNeeded: paddedHeaderSize)
        bytes[1] = UInt8(truncatingIfNeeded: paddedHeaderSize >> 8)

        let reader = try ArchiveReader.open(data: Data(bytes))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "no-common-crc.txt")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func test64BitSizeExtensionUsesPackedThenOriginalOrder() throws {
        let original = Data(repeating: 0x41, count: 7)
        let packed = Data(repeating: 0x42, count: 3)
        var sizes: [UInt8] = []
        LHATestSupport.appendUInt64LE(UInt64(packed.count), to: &sizes)
        LHATestSupport.appendUInt64LE(UInt64(original.count), to: &sizes)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "sizes.pm2",
                contents: original,
                method: "-pm2-",
                headerLevel: 2,
                extraHeaders: [HandLHAExtendedHeader(0x42, sizes)],
                packedContents: packed
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.compressedSize, UInt64(packed.count))
        XCTAssertEqual(entry.uncompressedSize, UInt64(original.count))
    }

    func testLevel1CommonHeaderCRCIsValidated() throws {
        let payload = Data("level-one-crc".utf8)
        var bytes = Array(try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "level1-common-crc.txt",
                contents: payload,
                headerLevel: 1,
                extraHeaders: [HandLHAExtendedHeader(0x00, [0, 0])]
            ),
        ]))

        let baseEnd = Int(bytes[0]) + 2
        var currentSize = Int(bytes[baseEnd - 2]) | (Int(bytes[baseEnd - 1]) << 8)
        var cursor = baseEnd
        var commonCRCOffset: Int?
        while currentSize != 0 {
            let end = cursor + currentSize
            XCTAssertLessThanOrEqual(end, bytes.count)
            if bytes[cursor] == 0 { commonCRCOffset = cursor + 1 }
            currentSize = Int(bytes[end - 2]) | (Int(bytes[end - 1]) << 8)
            cursor = end
        }
        let crcOffset = try XCTUnwrap(commonCRCOffset)
        bytes[crcOffset] = 0
        bytes[crcOffset + 1] = 0
        let headerCRC = CRC16.checksum(Array(bytes[..<cursor]))
        bytes[crcOffset] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[crcOffset + 1] = UInt8(truncatingIfNeeded: headerCRC >> 8)

        let reader = try ArchiveReader.open(data: Data(bytes))
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)

        bytes[crcOffset] ^= 0x01
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(bytes))) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("expected malformed header CRC, got \(error)")
            }
            XCTAssertTrue(reason.contains("CRC"))
        }
    }

    func testLevel1UsesPackedThenOriginalOrderFor64BitSizeExtension() throws {
        let original = Data(repeating: 0x41, count: 7)
        let packed = Data(repeating: 0x42, count: 3)
        var sizes: [UInt8] = []
        LHATestSupport.appendUInt64LE(UInt64(packed.count), to: &sizes)
        LHATestSupport.appendUInt64LE(UInt64(original.count), to: &sizes)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "level1-sizes.pm2",
                contents: original,
                method: "-pm2-",
                headerLevel: 1,
                extraHeaders: [HandLHAExtendedHeader(0x42, sizes)],
                packedContents: packed
            ),
        ])

        let entry = try XCTUnwrap(ArchiveReader.open(data: archive).entries.first)
        XCTAssertEqual(entry.compressedSize, UInt64(packed.count))
        XCTAssertEqual(entry.uncompressedSize, UInt64(original.count))
    }

    func testPayloadCRC16MismatchIsReportedForMember() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "bad-crc.bin",
                contents: Data("payload".utf8),
                headerLevel: 2,
                dataCRC16: 0x1234
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testLargeStoredDirectReadPathValidatesCRC16() throws {
        let payload = Data(repeating: 0xA5, count: 1 * 1_024 * 1_024 + 1)
        let validArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "large-valid.bin",
                contents: payload,
                headerLevel: 2
            ),
        ])
        let validReader = try ArchiveReader.open(data: validArchive)
        XCTAssertEqual(try validReader.read(validReader.entries[0]), payload)

        let invalidArchive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "large-invalid.bin",
                contents: payload,
                headerLevel: 2,
                dataCRC16: 0
            ),
        ])
        let invalidReader = try ArchiveReader.open(data: invalidArchive)
        XCTAssertThrowsError(try invalidReader.read(invalidReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testLZ4AndPM0StoredAliases() throws {
        let lz4 = Data("LArc stored".utf8)
        let pm0 = Data("PMarc stored".utf8)
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "legacy.lz4",
                contents: lz4,
                method: "-lz4-",
                headerLevel: 0
            ),
            HandLHAEntry(
                name: "legacy.pm0",
                contents: pm0,
                method: "-pm0-",
                headerLevel: 1
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(
            reader.entries.map(\.methodDescription),
            ["-lz4-", "-pm0-"]
        )
        XCTAssertEqual(try reader.read(reader.entries[0]), lz4)
        XCTAssertEqual(try reader.read(reader.entries[1]), pm0)
    }

    func testPM2ListsButFailsAtStreamCreation() throws {
        let archive = try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "legacy.pma",
                contents: Data([1, 2, 3]),
                method: "-pm2-",
                headerLevel: 1
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries[0].methodDescription, "-pm2-")
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedMethod("-pm2-"))
        }
    }

    func testCooViewerBookFixtureMatchesLhasaMemberDigests() throws {
        let fixture = URL(
            fileURLWithPath: "/Users/nagash/cooViewer/CooViewerTests/Fixtures/book.lzh"
        )
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("cooViewer book.lzh is not installed on this host")
        }
        let temporary = try temporaryDirectory(label: "book")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("book.lzh")
        try FileManager.default.copyItem(at: fixture, to: archive)

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["p0.png", "p1.png", "p2.png", "p3.png"])
        XCTAssertTrue(reader.entries.allSatisfy { $0.methodDescription == "-lh0-" })
        XCTAssertTrue(reader.entries.allSatisfy {
            $0.formatSpecific["headerLevel"] == "2"
        })
        XCTAssertTrue(reader.entries.allSatisfy { $0.uncompressedSize == 8_276 })

        try requireLhasa()
        for entry in reader.entries {
            let decoded = try reader.read(entry)
            let oracle = try lhasaMember(archive: archive, name: entry.name)
            XCTAssertTrue(
                SHA256.hash(data: decoded).elementsEqual(SHA256.hash(data: oracle)),
                "digest differs for \(entry.name)"
            )
        }
    }

    func testOptionalLHAFixtureCorpusAgainstLhasa() throws {
        try requireLhasa()
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureDirectory = testDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lha", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: fixtureDirectory.path) else {
            throw XCTSkip("Tests/Fixtures/lha is empty")
        }
        let extensions = Set(["lha", "lzh", "lzs", "pma"])
        let files = (manager.enumerator(
            at: fixtureDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )?.allObjects as? [URL] ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw XCTSkip("Tests/Fixtures/lha is empty") }

        let supported = Set([
            "-lh0-", "-lh1-", "-lh4-", "-lh5-", "-lh6-", "-lh7-",
            "-lz4-", "-lz5-", "-lzs-", "-pm0-",
        ])
        for archive in files {
            let reader = try ArchiveReader.open(url: archive)
            for entry in reader.entries where entry.kind != EntryKind.directory {
                guard supported.contains(entry.methodDescription) else {
                    XCTAssertThrowsError(try reader.stream(entry))
                    continue
                }
                let decoded = try reader.read(entry)
                let oracle = try lhasaMember(archive: archive, name: entry.name)
                XCTAssertTrue(
                    SHA256.hash(data: decoded).elementsEqual(SHA256.hash(data: oracle)),
                    "digest differs for \(archive.lastPathComponent):\(entry.name)"
                )
            }
        }
    }

    func testCLIListIncludesLHAHeaderLevel() throws {
        let temporary = try temporaryDirectory(label: "cli")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli.lzh")
        try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(
                name: "page.txt",
                contents: Data("page".utf8),
                headerLevel: 2
            ),
        ]).write(to: archive)

        let output = try runKaito(
            findKaitoExecutable(),
            arguments: ["list", archive.path]
        ).trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        XCTAssertEqual(
            output,
            ["0", "4", "file", "-lh0-", "plain", "page.txt", "level=2"]
        )
    }

    private func requireLhasa() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/lha") else {
            throw XCTSkip("/opt/homebrew/bin/lha is not installed")
        }
    }

    private func lhasaMember(archive: URL, name: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/lha")
        process.arguments = ["-pq", archive.path, name]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail(
                "lhasa rejected \(archive.lastPathComponent):\(name): "
                    + String(decoding: diagnostic, as: UTF8.self)
            )
            return Data()
        }
        return data
    }

    private func temporaryDirectory(label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-LHA-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func runKaito(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == Process.TerminationReason.exit,
              process.terminationStatus == 0 else {
            throw TarTestSupportError.commandFailed(
                String(decoding: errors, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func findKaitoExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KAITO_EXECUTABLE"] {
            let candidate = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        var candidates: [URL] = [
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("kaito"),
        ]
        var ancestor = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(ancestor.appendingPathComponent("kaito"))
            ancestor.deleteLastPathComponent()
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repository.appendingPathComponent(".build/debug/kaito"))
        candidates.append(repository.appendingPathComponent(".build/out/Products/Debug/kaito"))
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let buildDirectory = repository.appendingPathComponent(".build", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        ) {
            for case let candidate as URL in enumerator
                where candidate.lastPathComponent == "kaito" {
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw TarTestSupportError.commandFailed("built kaito executable was not found")
    }
}
