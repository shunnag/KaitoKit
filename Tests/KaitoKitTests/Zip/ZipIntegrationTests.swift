import Foundation
import KaitoKit
import XCTest

final class ZipIntegrationTests: XCTestCase {
    func testHandBuiltEntryModelMetadataTimestampsDirectoriesAndSymlinks() throws {
        let targetData = Data("target payload\n".utf8)
        let unixTime: UInt32 = 1_690_000_000
        let ntfsTime: UInt64 = 1_700_000_000
        var timeExtras = try ZipTestSupport.extendedTimestampExtra(seconds: unixTime)
        timeExtras.append(try ZipTestSupport.ntfsTimestampExtra(secondsSince1970: ntfsTime))
        timeExtras.append(
            try ZipTestSupport.extraField(identifier: 0x7875, payload: Data([1, 1, 42, 1, 43]))
        )

        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "target.txt",
                uncompressedData: targetData,
                centralExtra: timeExtras,
                versionMadeBy: 0x031E,
                externalAttributes: UInt32(0o100640) << 16
            ),
            HandZipEntry(
                name: "empty-directory",
                externalAttributes: 0x10
            ),
            HandZipEntry(
                name: "shortcut",
                uncompressedData: Data("target.txt".utf8),
                versionMadeBy: 0x031E,
                externalAttributes: UInt32(0o120777) << 16
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        XCTAssertEqual(reader.format, .zip)
        XCTAssertEqual(reader.entries.count, 3)
        let target = reader.entries[0]
        XCTAssertEqual(target.name, "target.txt")
        XCTAssertEqual(target.kind, .file)
        XCTAssertEqual(target.posixPermissions, 0o640)
        XCTAssertEqual(target.solidGroup, -1)
        XCTAssertEqual(target.methodDescription, "stored")
        XCTAssertEqual(target.formatSpecific["method"], "0")
        XCTAssertEqual(target.formatSpecific["versionMadeBy"], String(0x031E))
        XCTAssertEqual(target.formatSpecific["flags"], "0x0800")
        XCTAssertEqual(target.formatSpecific["hostOS"], "3")
        XCTAssertEqual(
            try XCTUnwrap(target.modificationDate).timeIntervalSince1970,
            TimeInterval(ntfsTime),
            accuracy: 0.001
        )
        XCTAssertEqual(try reader.read(target), targetData)

        XCTAssertEqual(reader.entries[1].kind, .directory)
        XCTAssertTrue(reader.entries[1].rawName.isDirectoryHint)
        XCTAssertEqual(reader.entries[2].kind, .symlink)
        XCTAssertEqual(reader.entries[2].formatSpecific["linkTargetStoredAsData"], "true")
        XCTAssertEqual(try reader.read(reader.entries[2]), Data("target.txt".utf8))

        let temporary = try ZipTestSupport.temporaryDirectory(label: "symlink-extraction")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        _ = try reader.extract(target, to: output)
        _ = try reader.extract(reader.entries[2], to: output)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: output.appendingPathComponent("shortcut").path
            ),
            "target.txt"
        )
    }

    func testStandaloneExtendedTimestampAndDOSLocalFallback() throws {
        let unixTime: UInt32 = 1_690_000_000
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "extended-time.txt",
                centralExtra: try ZipTestSupport.extendedTimestampExtra(seconds: unixTime)
            ),
            HandZipEntry(name: "dos-time.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(
            try XCTUnwrap(reader.entries[0].modificationDate).timeIntervalSince1970,
            TimeInterval(unixTime),
            accuracy: 0.001
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expectedDOSDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2020,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 6
        )))
        XCTAssertEqual(
            try XCTUnwrap(reader.entries[1].modificationDate).timeIntervalSince1970,
            expectedDOSDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testInfoZipStoredAndDeflateReadAndStream() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "infozip-methods")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let storedData = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 73) })
        let deflatedData = Data(repeating: 0x41, count: 128 * 1_024)
            + Data("日本語 deflate tail\n".utf8)
        _ = try ZipTestSupport.write(storedData, relativePath: "stored.bin", below: source)
        _ = try ZipTestSupport.write(deflatedData, relativePath: "deflated.txt", below: source)

        let storedArchive = temporary.appendingPathComponent("stored.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["stored.bin"],
            archiveURL: storedArchive,
            options: ["-0"]
        )
        let storedReader = try ArchiveReader.open(url: storedArchive)
        let stored = try XCTUnwrap(storedReader.entries.first)
        XCTAssertEqual(stored.methodDescription, "stored")
        XCTAssertEqual(try storedReader.read(stored), storedData)

        let deflatedArchive = temporary.appendingPathComponent("deflated.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["deflated.txt"],
            archiveURL: deflatedArchive
        )
        let deflatedReader = try ArchiveReader.open(url: deflatedArchive)
        let deflated = try XCTUnwrap(deflatedReader.entries.first)
        XCTAssertEqual(deflated.methodDescription, "deflate")
        XCTAssertEqual(try drain(deflatedReader.stream(deflated), bufferSize: 257), deflatedData)
        XCTAssertEqual(try deflatedReader.read(deflated), deflatedData)
    }

    func testBSDTarCreatedZipListsDirectoryAndReadsFile() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "bsdtar-zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("bsdtar ZIP fixture 日本語\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "folder/payload.txt", below: source)

        let archive = temporary.appendingPathComponent("fixture.zip")
        try ZipTestSupport.makeBSDTarZip(
            sourceDirectory: source,
            paths: ["folder"],
            archiveURL: archive
        )
        let reader = try ArchiveReader.open(url: archive)
        let file = try XCTUnwrap(reader.entries.first { $0.name == "folder/payload.txt" })
        XCTAssertEqual(try reader.read(file), payload)
        XCTAssertTrue(reader.entries.contains { $0.name == "folder/" && $0.kind == .directory })
        XCTAssertTrue(reader.entries.allSatisfy { $0.solidGroup == -1 })
    }

    func testCP932FixtureScriptCreatesLegacyWindowsNames() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.pythonPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "cp932")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let memberName = "日本語/画像 01.txt"
        let payload = Data("CP932 name payload\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: memberName, below: source)
        let archive = temporary.appendingPathComponent("cp932.zip")

        let result = try ZipTestSupport.checkedRun(
            ZipTestSupport.pythonPath,
            arguments: [
                ZipTestSupport.cp932FixtureScript.path,
                source.path,
                archive.path,
            ]
        )
        XCTAssertTrue(
            String(decoding: result.standardOutput, as: UTF8.self).contains("bit 11 clear")
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, memberName)
        XCTAssertNil(entry.rawName.declaredEncoding)
        XCTAssertEqual(entry.rawName.bytes, Array(try XCTUnwrap(memberName.data(using: .shiftJIS))))
        XCTAssertEqual(entry.formatSpecific["hostOS"], "0")
        XCTAssertEqual(entry.formatSpecific["flags"], "0x0000")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testSFXPrefixAndMaximumEOCDCommentAreAccepted() throws {
        let payload = Data("prefixed archive payload".utf8)
        let prefix = ZipTestSupport.makePEPrefix(count: 1_024, fill: 0xCC)
        let comment = Data(repeating: 0x5A, count: Int(UInt16.max))
        let archive = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "prefixed.txt", uncompressedData: payload)],
            prefix: prefix,
            comment: comment
        )

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(scanForSFXInData: true)
        )
        XCTAssertEqual(reader.entries.map(\.name), ["prefixed.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testUnicodePathExtraRequiresMatchingRawNameCRC() throws {
        let validRawName = Array("legacy-one.txt".utf8)
        let invalidRawName = Array("legacy-two.txt".utf8)
        let validExtra = try ZipTestSupport.unicodePathExtra(
            rawName: validRawName,
            unicodeName: "日本語/正しい.txt"
        )
        let invalidExtra = try ZipTestSupport.unicodePathExtra(
            rawName: invalidRawName,
            unicodeName: "日本語/使わない.txt",
            validCRC: false
        )
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                rawName: validRawName,
                uncompressedData: Data("valid".utf8),
                centralExtra: validExtra
            ),
            HandZipEntry(
                rawName: invalidRawName,
                uncompressedData: Data("invalid".utf8),
                centralExtra: invalidExtra
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries[0].name, "日本語/正しい.txt")
        XCTAssertEqual(reader.entries[0].rawName.bytes, validRawName)
        XCTAssertEqual(reader.entries[1].name, "legacy-two.txt")
    }

    func testDataDescriptorUsesCentralDirectorySizesAndCRC() throws {
        let payload = Data("descriptor payload 日本語".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "descriptor.txt",
                uncompressedData: payload,
                hasDataDescriptor: true
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.formatSpecific["flags"], "0x0808")
        XCTAssertEqual(entry.compressedSize, UInt64(payload.count))
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testZIP64EntryCountAboveZIP32Limit() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "python-zip64")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("many-empty.zip")
        try ZipTestSupport.makePythonZIP64EmptyArchive(archiveURL: archive)

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.count, 65_536)
        XCTAssertEqual(reader.entries.first?.name, "empty-00000")
        XCTAssertEqual(reader.entries.last?.name, "empty-65535")
        XCTAssertTrue(reader.entries.allSatisfy { $0.uncompressedSize == 0 })
    }

    private func drain(_ stream: EntryStream, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            XCTAssertGreaterThan(count, 0)
            result.append(contentsOf: buffer.prefix(count))
        }
        let final = try buffer.withUnsafeMutableBytes { storage in
            try stream.read(into: storage)
        }
        XCTAssertEqual(final, 0)
        return result
    }
}
