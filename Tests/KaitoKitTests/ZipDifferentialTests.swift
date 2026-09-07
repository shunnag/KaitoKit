import CryptoKit
import Foundation
import KaitoKit
import XCTest

final class ZipDifferentialTests: XCTestCase {
    func testCP932FixtureMatchesSelectorFreeUnzipBySHA256() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.pythonPath)
        try ZipTestSupport.requireExecutable(ZipTestSupport.unzipPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-cp932")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let memberName = "日本語/画像 01.txt"
        let payload = Data("CP932 differential payload\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: memberName, below: source)
        let archive = temporary.appendingPathComponent("cp932.zip")
        _ = try ZipTestSupport.checkedRun(
            ZipTestSupport.pythonPath,
            arguments: [
                ZipTestSupport.cp932FixtureScript.path,
                source.path,
                archive.path,
            ]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.only)
        XCTAssertEqual(entry.name, memberName)
        let oracle = try ZipTestSupport.checkedRun(
            ZipTestSupport.unzipPath,
            arguments: ["-p", archive.path]
        ).standardOutput
        XCTAssertEqual(sha256(try reader.read(entry)), sha256(oracle))
        XCTAssertEqual(sha256(oracle), sha256(payload))
    }

    func testHandBuiltDescriptorAndSFXFixturesMatchUnzipBySHA256() throws {
        let descriptorPayload = Data("descriptor differential 日本語\n".utf8)
        let sfxPayload = Data("SFX differential payload\n".utf8)
        let fixtures: [(label: String, name: String, payload: Data, archive: Data)] = [
            (
                "descriptor",
                "descriptor.txt",
                descriptorPayload,
                try ZipTestSupport.makeArchive(entries: [
                    HandZipEntry(
                        name: "descriptor.txt",
                        uncompressedData: descriptorPayload,
                        hasDataDescriptor: true
                    ),
                ])
            ),
            (
                "sfx",
                "prefixed.txt",
                sfxPayload,
                try ZipTestSupport.makeArchive(
                    entries: [
                        HandZipEntry(name: "prefixed.txt", uncompressedData: sfxPayload),
                    ],
                    prefix: Data(repeating: 0xCC, count: 1_024)
                )
            ),
        ]
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-structural")
        defer { try? FileManager.default.removeItem(at: temporary) }

        for fixture in fixtures {
            let archiveURL = temporary.appendingPathComponent("\(fixture.label).zip")
            try fixture.archive.write(to: archiveURL)
            try assertDifferential(
                archiveURL: archiveURL,
                entryName: fixture.name,
                expected: fixture.payload,
                expectedMethod: "stored"
            ) {
                if fixture.label == "sfx" {
                    try unzipSFXData(archiveURL: archiveURL, entryName: fixture.name)
                } else {
                    try ZipTestSupport.unzipData(
                        archiveURL: archiveURL,
                        entryName: fixture.name
                    )
                }
            }
        }
    }

    func testZIP64EmptyFixtureMatchesUnzipEndpointsAndEveryKaitoDigest() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-zip64-empty")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("many-empty.zip")
        try ZipTestSupport.makePythonZIP64EmptyArchive(archiveURL: archive)

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.count, 65_536)
        let first = try XCTUnwrap(reader.entries.first)
        let last = try XCTUnwrap(reader.entries.last)
        let emptyDigest = SHA256.hash(data: Data())
        for endpoint in [first, last] {
            let oracle = try ZipTestSupport.unzipData(
                archiveURL: archive,
                entryName: endpoint.name
            )
            XCTAssertTrue(SHA256.hash(data: oracle).elementsEqual(emptyDigest))
        }

        // 65,536 個の外部 process は避け、全 Kaito 出力を in-process で hash する。
        // 独立 unzip oracle は一件目と末尾で ZIP64 offset 解決を確認する。
        var mismatchingEntry: Int?
        for entry in reader.entries {
            if !SHA256.hash(data: try reader.read(entry)).elementsEqual(emptyDigest) {
                mismatchingEntry = entry.index
                break
            }
        }
        XCTAssertNil(mismatchingEntry, "every empty ZIP64 entry must hash as empty data")
    }

    func testInfoZipStoredAndDeflateMatchUnzipBySHA256() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-infozip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let stored = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 &* 131) })
        let deflated = Data(repeating: 0x4B, count: 256 * 1_024)
            + Data("differential deflate 日本語\n".utf8)
        _ = try ZipTestSupport.write(stored, relativePath: "stored.bin", below: source)
        _ = try ZipTestSupport.write(deflated, relativePath: "deflated.txt", below: source)

        let storedArchive = temporary.appendingPathComponent("stored.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["stored.bin"],
            archiveURL: storedArchive,
            options: ["-0"]
        )
        try assertDifferential(
            archiveURL: storedArchive,
            entryName: "stored.bin",
            expected: stored,
            expectedMethod: "stored"
        ) {
            try ZipTestSupport.unzipData(archiveURL: storedArchive, entryName: "stored.bin")
        }

        let deflatedArchive = temporary.appendingPathComponent("deflated.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["deflated.txt"],
            archiveURL: deflatedArchive
        )
        try assertDifferential(
            archiveURL: deflatedArchive,
            entryName: "deflated.txt",
            expected: deflated,
            expectedMethod: "deflate"
        ) {
            try ZipTestSupport.unzipData(archiveURL: deflatedArchive, entryName: "deflated.txt")
        }
    }

    func testInfoZipBzip2MatchesUnzipBySHA256WhenSupported() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.infoZipPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-infozip-bzip2")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(repeating: 0x42, count: 192 * 1_024)
            + Data("Info-ZIP bzip2 oracle\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "bzip2.txt", below: source)
        let archive = temporary.appendingPathComponent("bzip2.zip")

        let creation = try ZipTestSupport.run(
            ZipTestSupport.infoZipPath,
            arguments: ["-q", "-Z", "bzip2", archive.path, "bzip2.txt"],
            currentDirectory: source
        )
        guard creation.succeeded else {
            throw XCTSkip(
                "Info-ZIP was built without bzip2 support; fixture skipped: \(creation.diagnostics)"
            )
        }
        try assertDifferential(
            archiveURL: archive,
            entryName: "bzip2.txt",
            expected: payload,
            expectedMethod: "bzip2"
        ) {
            try ZipTestSupport.unzipData(archiveURL: archive, entryName: "bzip2.txt")
        }
    }

    func testInfoZipZipCryptoMatchesUnzipBySHA256() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-zipcrypto")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data((0..<96_001).map { UInt8(truncatingIfNeeded: $0 &* 29) })
            + Data("ZipCrypto differential 日本語\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "encrypted.bin", below: source)
        let archive = temporary.appendingPathComponent("zipcrypto.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["encrypted.bin"],
            archiveURL: archive,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "fixed-password")
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "encrypted.bin" })
        XCTAssertEqual(entry.formatSpecific["encryption"], "ZipCrypto")
        let kaitoData = try reader.read(entry)
        let oracleData = try ZipTestSupport.unzipData(
            archiveURL: archive,
            entryName: "encrypted.bin",
            password: "fixed-password"
        )
        XCTAssertEqual(sha256(kaitoData), sha256(oracleData))
        XCTAssertEqual(sha256(kaitoData), sha256(payload))
    }

    func testBSDTarZipMatchesUnzipBySHA256ForEveryUniqueFile() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-bsdtar")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fixtures: [(String, Data)] = [
            ("book/page-001.bin", Data(repeating: 0x01, count: 32_769)),
            ("book/page-002.bin", Data((0..<49_153).map { UInt8(truncatingIfNeeded: $0) })),
            ("notes.txt", Data("bsdtar differential 日本語\n".utf8)),
        ]
        for (name, contents) in fixtures {
            _ = try ZipTestSupport.write(contents, relativePath: name, below: source)
        }
        let archive = temporary.appendingPathComponent("bsdtar.zip")
        try ZipTestSupport.makeBSDTarZip(
            sourceDirectory: source,
            paths: ["book", "notes.txt"],
            archiveURL: archive
        )

        let reader = try ArchiveReader.open(url: archive)
        let names = reader.entries.filter { $0.kind == .file }.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "oracle extraction requires unique names")
        for (name, expected) in fixtures {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
            let kaitoData = try reader.read(entry)
            let oracleData = try ZipTestSupport.unzipData(
                archiveURL: archive,
                entryName: name
            )
            XCTAssertEqual(sha256(kaitoData), sha256(oracleData), name)
            XCTAssertEqual(sha256(kaitoData), sha256(expected), name)
        }
    }

    func testSevenZipDeflate64LZMABzip2MatchSevenZipBySHA256() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable at \(ZipTestSupport.sevenZipPath); method fixture set skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-7zz-methods")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = makeCompressiblePayload()
        _ = try ZipTestSupport.write(payload, relativePath: "payload.bin", below: source)

        let methods: [(command: String, description: String)] = [
            ("Deflate64", "deflate64"),
            ("LZMA", "lzma"),
            ("BZip2", "bzip2"),
        ]
        for method in methods {
            let archive = temporary.appendingPathComponent("\(method.command).zip")
            try ZipTestSupport.makeSevenZip(
                sourceDirectory: source,
                paths: ["payload.bin"],
                archiveURL: archive,
                method: method.command
            )
            try assertDifferential(
                archiveURL: archive,
                entryName: "payload.bin",
                expected: payload,
                expectedMethod: method.description
            ) {
                try ZipTestSupport.sevenZipData(
                    archiveURL: archive,
                    entryName: "payload.bin"
                )
            }
        }
    }

    func testSevenZipAES256MatchesSevenZipBySHA256() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable at \(ZipTestSupport.sevenZipPath); AES fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "diff-7zz-aes")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = makeCompressiblePayload() + Data("AES tail 日本語".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "encrypted.bin", below: source)
        let archive = temporary.appendingPathComponent("aes256.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: source,
            paths: ["encrypted.bin"],
            archiveURL: archive,
            method: "Deflate",
            password: "fixed-password"
        )

        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "fixed-password")
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "encrypted.bin" })
        XCTAssertEqual(entry.formatSpecific["encryption"], "AES-256")
        let kaitoData = try reader.read(entry)
        let oracleData = try ZipTestSupport.sevenZipData(
            archiveURL: archive,
            entryName: "encrypted.bin",
            password: "fixed-password"
        )
        XCTAssertEqual(sha256(kaitoData), sha256(oracleData))
        XCTAssertEqual(sha256(kaitoData), sha256(payload))
    }

    private func assertDifferential(
        archiveURL: URL,
        entryName: String,
        expected: Data,
        expectedMethod: String,
        oracle: () throws -> Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reader = try ArchiveReader.open(url: archiveURL)
        let matches = reader.entries.filter { $0.name == entryName }
        XCTAssertEqual(matches.count, 1, "entry names must be unique", file: file, line: line)
        let entry = try XCTUnwrap(matches.first, file: file, line: line)
        XCTAssertEqual(entry.methodDescription, expectedMethod, file: file, line: line)
        let kaitoData = try reader.read(entry)
        let oracleData = try oracle()
        XCTAssertEqual(sha256(kaitoData), sha256(oracleData), file: file, line: line)
        XCTAssertEqual(sha256(kaitoData), sha256(expected), file: file, line: line)
    }

    private func unzipSFXData(archiveURL: URL, entryName: String) throws -> Data {
        try ZipTestSupport.requireExecutable(ZipTestSupport.unzipPath)
        let result = try ZipTestSupport.run(
            ZipTestSupport.unzipPath,
            arguments: ["-p", archiveURL.path, entryName]
        )
        let diagnostics = String(decoding: result.standardError, as: UTF8.self)
        let expectedWarning =
            "warning [\(archiveURL.path)]:  1024 extra bytes at beginning or within zipfile\n"
            + "  (attempting to process anyway)\n"
        switch result.terminationStatus {
        case 0:
            guard diagnostics.isEmpty else {
                throw ZipTestSupportError.commandFailed(
                    "unzip succeeded with unexpected SFX diagnostics: \(diagnostics)"
                )
            }
        case 1:
            guard diagnostics == expectedWarning else {
                throw ZipTestSupportError.commandFailed(
                    "unzip returned an unexpected SFX warning: \(diagnostics)"
                )
            }
        default:
            throw ZipTestSupportError.commandFailed(
                "unzip exited with \(result.terminationStatus): \(result.diagnostics)"
            )
        }
        guard !result.standardOutput.isEmpty else {
            throw ZipTestSupportError.commandFailed("unzip produced no SFX payload")
        }
        return result.standardOutput
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeCompressiblePayload() -> Data {
        var data = Data()
        data.reserveCapacity(512 * 1_024)
        for index in 0..<8_192 {
            data.append(contentsOf: "page-\(index % 37)-KaitoKit-日本語\n".utf8)
        }
        data.append(Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 &* 17) }))
        return data
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
