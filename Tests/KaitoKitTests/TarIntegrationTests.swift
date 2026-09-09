import Foundation
import KaitoKit
import XCTest

final class TarIntegrationTests: XCTestCase {
    func testUstarListsReadsStreamsAndExtractsMetadataAndLinks() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("hello from ustar".utf8)
        let file = try TarTestSupport.write(
            payload,
            relativePath: "folder/hello.txt",
            below: source
        )
        let expectedTime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: expectedTime, .posixPermissions: 0o640],
            ofItemAtPath: file.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("shortcut").path,
            withDestinationPath: "folder/hello.txt"
        )

        let archiveURL = temporary.appendingPathComponent("fixture-ustar.tar")
        try TarTestSupport.createBSDTar(
            format: "ustar",
            sourceDirectory: source,
            paths: ["folder", "shortcut"],
            archiveURL: archiveURL
        )

        let reader = try ArchiveReader.open(url: archiveURL)
        XCTAssertEqual(reader.format, .tar)
        let byName = Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.name, $0) })
        let directory = try XCTUnwrap(byName["folder/"])
        let regular = try XCTUnwrap(byName["folder/hello.txt"])
        let symbolicLink = try XCTUnwrap(byName["shortcut"])
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(regular.kind, .file)
        XCTAssertEqual(symbolicLink.kind, .symlink)
        XCTAssertEqual(symbolicLink.formatSpecific["linkPath"], "folder/hello.txt")
        XCTAssertEqual(regular.posixPermissions, 0o640)
        XCTAssertEqual(
            try XCTUnwrap(regular.modificationDate).timeIntervalSince1970,
            expectedTime.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(try reader.read(regular), payload)

        let stream = try reader.stream(regular)
        var streamed = Data()
        var buffer = [UInt8](repeating: 0, count: 3)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // 不変条件: storage は buffer の全領域で、stream は最大 3 バイトだけ書く。
                try stream.read(into: storage)
            }
            XCTAssertGreaterThan(count, 0)
            streamed.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(streamed, payload)
        let finalRead = try buffer.withUnsafeMutableBytes { storage in
            // 不変条件: 枯渇後の読み取り先も buffer の全領域に限定する。
            try stream.read(into: storage)
        }
        XCTAssertEqual(finalRead, 0)

        let extraction = temporary.appendingPathComponent("extracted", isDirectory: true)
        for entry in reader.entries {
            _ = try reader.extract(entry, to: extraction)
        }
        let extractedFile = extraction.appendingPathComponent("folder/hello.txt")
        XCTAssertEqual(try Data(contentsOf: extractedFile), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: extractedFile.path)
        let extractedDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(
            extractedDate.timeIntervalSince1970,
            expectedTime.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: extraction.appendingPathComponent("shortcut").path
            ),
            "folder/hello.txt"
        )
    }

    func testPAXLongUTF8JapanesePath() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let name = String(repeating: "日本語の長い名前", count: 8) + ".txt"
        XCTAssertGreaterThan(name.utf8.count, 100)
        let payload = Data("pax-日本語".utf8)
        _ = try TarTestSupport.write(payload, relativePath: name, below: source)
        let archiveURL = temporary.appendingPathComponent("fixture-pax.tar")
        try TarTestSupport.createBSDTar(
            format: "pax",
            sourceDirectory: source,
            paths: [name],
            archiveURL: archiveURL
        )

        let reader = try ArchiveReader.open(url: archiveURL)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
        XCTAssertEqual(entry.rawName.declaredEncoding, .utf8)
        XCTAssertEqual(entry.rawName.bytes, Array(name.utf8))
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testGNULongName() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let name = String(repeating: "long-name-", count: 15) + "payload.bin"
        XCTAssertGreaterThan(name.utf8.count, 100)
        let payload = Data([0x00, 0x7f, 0x80, 0xff])
        _ = try TarTestSupport.write(payload, relativePath: name, below: source)
        let archiveURL = temporary.appendingPathComponent("fixture-gnu.tar")
        try TarTestSupport.createBSDTar(
            format: "gnutar",
            sourceDirectory: source,
            paths: [name],
            archiveURL: archiveURL
        )

        let reader = try ArchiveReader.open(url: archiveURL)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testCorruptAndTruncatedTarThrow() throws {
        let entry = HandTarEntry(name: "payload.txt", contents: Data("value".utf8))
        let valid = try TarTestSupport.makeTar(entries: [entry])

        var corrupt = valid
        corrupt[0] ^= 0x01
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corruptURL = directory.appendingPathComponent("corrupt.tar")
        try corrupt.write(to: corruptURL)
        XCTAssertThrowsError(try ArchiveReader.open(url: corruptURL)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }

        let truncated = Data(valid.prefix(514))
        XCTAssertThrowsError(try ArchiveReader.open(data: truncated)) { error in
            guard case KaitoError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }

        let missingTerminator = try TarTestSupport.makeTar(entries: [entry], terminated: false)
        XCTAssertThrowsError(try ArchiveReader.open(data: missingTerminator)) { error in
            guard case KaitoError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testExtractionRejectsTraversalAndSymlinkEscapes() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let extraction = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)

        let traversalArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "../escaped.txt", contents: Data("escape".utf8)),
        ])
        let traversalReader = try ArchiveReader.open(data: traversalArchive)
        XCTAssertThrowsError(
            try traversalReader.extract(
                try XCTUnwrap(traversalReader.entries.first),
                to: extraction
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporary.appendingPathComponent("escaped.txt").path
            )
        )

        let absoluteArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "/absolute.txt", contents: Data("escape".utf8)),
        ])
        let absoluteReader = try ArchiveReader.open(data: absoluteArchive)
        XCTAssertThrowsError(
            try absoluteReader.extract(
                try XCTUnwrap(absoluteReader.entries.first),
                to: extraction
            )
        )

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let pivot = extraction.appendingPathComponent("pivot")
        try FileManager.default.createSymbolicLink(
            atPath: pivot.path,
            withDestinationPath: "../outside"
        )
        let pivotArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "pivot/written.txt", contents: Data("escape".utf8)),
        ])
        let pivotReader = try ArchiveReader.open(data: pivotArchive)
        XCTAssertThrowsError(
            try pivotReader.extract(try XCTUnwrap(pivotReader.entries.first), to: extraction)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("written.txt").path
            )
        )

        let linkArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(
                name: "bad-link",
                type: Character("2").asciiValue ?? 0,
                linkName: "../outside"
            ),
        ])
        let linkReader = try ArchiveReader.open(data: linkArchive)
        XCTAssertThrowsError(
            try linkReader.extract(try XCTUnwrap(linkReader.entries.first), to: extraction)
        )
    }

    func testReadHonorsInMemoryLimitWhileStreamingRemainsAvailable() throws {
        let payload = Data(repeating: 0xa5, count: 16)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "limited.bin", contents: payload),
        ])
        let limits = ReadLimits(
            maxEntrySize: 1_024,
            maxInMemorySize: 8,
            maxEntryCount: 10,
            maxMetadataSize: 1_024
        )
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }

        let stream = try reader.stream(entry)
        var streamed = Data()
        var buffer = [UInt8](repeating: 0, count: 4)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // 不変条件: storage は 4 バイトの配列全体で、stream はその範囲内だけを書く。
                try stream.read(into: storage)
            }
            streamed.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(streamed, payload)
    }
}
