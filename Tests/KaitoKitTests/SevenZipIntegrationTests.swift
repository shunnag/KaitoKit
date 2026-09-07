import CryptoKit
import Foundation
import KaitoKit
import XCTest

final class SevenZipIntegrationTests: XCTestCase {
    func testCopyLZMALZMA2DeflateAndBZip2MatchSevenZipBySHA256() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-methods")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = deterministicPayload(count: 257 * 1_024, seed: 0x4B)
            + Data(repeating: 0x41, count: 64 * 1_024)
            + Data("KaitoKit 7z differential 日本語\n".utf8)
        _ = try SevenZipTestSupport.write(
            payload,
            relativePath: "payload.bin",
            below: source
        )

        let methods: [(option: String, description: String)] = [
            ("Copy", "Copy"),
            ("LZMA", "LZMA"),
            ("LZMA2", "LZMA2"),
            ("Deflate", "Deflate"),
            ("BZip2", "BZip2"),
        ]
        for method in methods {
            let archive = temporary.appendingPathComponent("\(method.option).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: ["payload.bin"],
                archiveURL: archive,
                options: ["-ms=off", "-m0=\(method.option)"]
            )

            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(reader.format, .sevenZip)
            let entry = try XCTUnwrap(reader.entries.first { $0.name == "payload.bin" })
            XCTAssertTrue(entry.methodDescription.contains(method.description))
            let decoded = try reader.read(entry)
            let oracle = try SevenZipTestSupport.extractedData(
                archiveURL: archive,
                entryName: entry.name
            )
            assertSameSHA256(decoded, oracle, method.option)
            assertSameSHA256(decoded, payload, method.option)
        }
    }

    func testPPMdOrdersMatchSevenZipBySHA256() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-ppmd")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = deterministicPayload(count: 64 * 1_024, seed: 0x50_50_4D_44)
            + Data(String(repeating: "PPMd var.H 日本語 differential\n", count: 512).utf8)
        _ = try SevenZipTestSupport.write(payload, relativePath: "payload.bin", below: source)

        // 7zz 26.03 の encoder は order 64 を拒否するため、生成可能な上限 32 までを照合する。
        // decoder 側の order 64 受理は PPMd7DecoderTests で別途検証する。
        let configurations = [(order: 2, memory: "16m"),
                              (order: 6, memory: "64k"),
                              (order: 32, memory: "16m")]
        for configuration in configurations {
            let order = configuration.order
            let archive = temporary.appendingPathComponent("order-\(order).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: ["payload.bin"],
                archiveURL: archive,
                options: [
                    "-m0=PPMd:o=\(order):mem=\(configuration.memory)",
                    "-mhc=off",
                    "-ms=off",
                ]
            )

            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first { $0.name == "payload.bin" })
            XCTAssertTrue(entry.methodDescription.contains("PPMd7"))
            let decoded = try reader.read(entry)
            let oracle = try SevenZipTestSupport.extractedData(
                archiveURL: archive,
                entryName: entry.name
            )
            assertSameSHA256(decoded, oracle, "PPMd order \(order)")
            assertSameSHA256(decoded, payload, "PPMd order \(order)")
        }
    }

    func testJapaneseUTF16NamesEmptyFileAndDirectoryMetadata() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-metadata")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let payload = Data("UTF-16LE の名前を持つ 7z entry\n".utf8)
        _ = try SevenZipTestSupport.write(
            payload,
            relativePath: "日本語/画像 01.txt",
            below: source
        )
        _ = try SevenZipTestSupport.write(Data(), relativePath: "empty.txt", below: source)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("空のディレクトリ", isDirectory: true),
            withIntermediateDirectories: false
        )

        let archive = temporary.appendingPathComponent("metadata.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: ["日本語", "empty.txt", "空のディレクトリ"],
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=off"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertNil(reader.nameEncoding)
        let japanese = try XCTUnwrap(
            reader.entries.first { $0.name == "日本語/画像 01.txt" }
        )
        XCTAssertEqual(japanese.rawName.declaredEncoding, .utf16LittleEndian)
        XCTAssertEqual(japanese.kind, .file)
        XCTAssertEqual(try reader.read(japanese), payload)

        let empty = try XCTUnwrap(reader.entries.first { $0.name == "empty.txt" })
        XCTAssertEqual(empty.kind, .file)
        XCTAssertEqual(empty.uncompressedSize, 0)
        XCTAssertEqual(empty.formatSpecific["emptyFile"], "true")
        XCTAssertEqual(try reader.read(empty), Data())

        let directory = try XCTUnwrap(
            reader.entries.first { $0.name == "空のディレクトリ" }
        )
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(directory.uncompressedSize, 0)
        XCTAssertEqual(directory.solidGroup, -1)
    }

    func testGeneratedSolidAndBlockSplitArchivesSupportBackwardReads() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-solid")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        var expected: [String: Data] = [:]
        var paths: [String] = []
        for index in 0..<12 {
            let name = String(format: "page-%02d.bin", index)
            let contents = deterministicPayload(count: 9 * 1_024 + index, seed: UInt64(index + 1))
            expected[name] = contents
            paths.append(name)
            _ = try SevenZipTestSupport.write(contents, relativePath: name, below: source)
        }

        let cases: [(name: String, solidOption: String, minimumGroups: Int)] = [
            ("solid", "-ms=on", 1),
            ("blocks", "-ms=20k", 2),
        ]
        for fixture in cases {
            let archive = temporary.appendingPathComponent("\(fixture.name).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: paths,
                archiveURL: archive,
                options: ["-m0=LZMA2", fixture.solidOption]
            )
            let reader = try ArchiveReader.open(url: archive)
            let files = reader.entries.filter { $0.kind == .file }
            XCTAssertEqual(files.count, paths.count)
            let groups = Set(files.map(\.solidGroup).filter { $0 >= 0 })
            XCTAssertGreaterThanOrEqual(groups.count, fixture.minimumGroups, fixture.name)

            for entry in files {
                XCTAssertEqual(try reader.read(entry), expected[entry.name], entry.name)
            }
            for entry in files.reversed() {
                XCTAssertEqual(try reader.read(entry), expected[entry.name], entry.name)
            }
        }
    }

    func testTenMegabyteLZMA2EntryStreamsAndMatchesSevenZipBySHA256() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-large")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = deterministicPayload(count: 10 * 1_024 * 1_024, seed: 0x10_0000)
        _ = try SevenZipTestSupport.write(payload, relativePath: "large.bin", below: source)
        let archive = temporary.appendingPathComponent("large.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: ["large.bin"],
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=off"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "large.bin" })
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        let stream = try reader.stream(entry)
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            XCTAssertGreaterThan(count, 0)
            digest.update(data: Data(buffer[..<count]))
        }

        let oracle = try SevenZipTestSupport.extractedData(
            archiveURL: archive,
            entryName: entry.name
        )
        XCTAssertTrue(digest.finalize().elementsEqual(SHA256.hash(data: oracle)))
        assertSameSHA256(oracle, payload, "10 MiB LZMA2")
    }

    func testBCJBCJ2ARM64AndDeltaArchivesMatchSevenZipBySHA256() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-filters")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let x86 = x86MachOBranchPayload(repetitions: 2_048)
        let arm64 = arm64BranchPayload(repetitions: 2_048)
        let delta = deterministicPayload(count: 513 * 1_024, seed: 0xD3_17_A4)
        _ = try SevenZipTestSupport.write(
            x86,
            relativePath: "x86-mach-o.bin",
            below: source
        )
        _ = try SevenZipTestSupport.write(arm64, relativePath: "arm64.bin", below: source)
        _ = try SevenZipTestSupport.write(delta, relativePath: "delta.bin", below: source)

        let cases: [(name: String, path: String, payload: Data, options: [String], method: String)] = [
            ("bcj", "x86-mach-o.bin", x86, ["-m0=LZMA2", "-mf=BCJ"], "BCJ"),
            ("bcj2", "x86-mach-o.bin", x86, ["-m0=LZMA2", "-mf=BCJ2"], "BCJ2"),
            ("arm64", "arm64.bin", arm64, ["-m0=LZMA2", "-mf=ARM64"], "ARM64"),
            ("delta", "delta.bin", delta, ["-m0=LZMA2", "-mf=Delta:4"], "Delta:4"),
        ]

        for fixture in cases {
            let archive = temporary.appendingPathComponent("\(fixture.name).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: [fixture.path],
                archiveURL: archive,
                options: fixture.options + ["-ms=off"]
            )
            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first { $0.name == fixture.path })
            XCTAssertTrue(entry.methodDescription.contains(fixture.method), fixture.name)
            let decoded = try reader.read(entry)
            let oracle = try SevenZipTestSupport.extractedData(
                archiveURL: archive,
                entryName: fixture.path
            )
            assertSameSHA256(decoded, oracle, fixture.name)
            assertSameSHA256(decoded, fixture.payload, fixture.name)
        }
    }

    func testEncryptedBCJ2AndFiveCoderFoldersMatchSevenZipBySHA256() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-complex-folders")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let entryName = "x86.bin"
        let payload = x86MachOBranchPayload(repetitions: 2_048)
        _ = try SevenZipTestSupport.write(payload, relativePath: entryName, below: source)
        let password = "X"

        let cases: [(name: String, options: [String], coderCount: Int)] = [
            (
                "encrypted-bcj2",
                ["-p\(password)", "-mhe=off", "-mf=BCJ2", "-ms=off"],
                8
            ),
            (
                "five-coder",
                [
                    "-p\(password)", "-mhe=off", "-m0=Delta", "-m1=Delta",
                    "-m2=BCJ", "-m3=LZMA2", "-ms=off",
                ],
                5
            ),
            (
                "encrypted-header-bcj2",
                ["-p\(password)", "-mhe=on", "-mf=BCJ2", "-ms=off"],
                8
            ),
        ]

        for fixture in cases {
            let archive = temporary.appendingPathComponent("\(fixture.name).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: [entryName],
                archiveURL: archive,
                options: fixture.options
            )
            let reader = try ArchiveReader.open(
                url: archive,
                options: ReaderOptions(password: password)
            )
            let entry = try XCTUnwrap(reader.entries.first { $0.name == entryName })
            XCTAssertEqual(
                entry.methodDescription.split(separator: "+").count,
                fixture.coderCount,
                fixture.name
            )
            let decoded = try reader.read(entry)
            let oracle = try SevenZipTestSupport.extractedData(
                archiveURL: archive,
                entryName: entryName,
                password: password
            )
            assertSameSHA256(decoded, oracle, fixture.name)
            assertSameSHA256(decoded, payload, fixture.name)
        }
    }

    func testNonsolidCompressedEntryStreamsHaveIndependentCoordinators() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-nonsolid-streams")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = deterministicPayload(count: 128 * 1_024, seed: 0x51_4E_47_4C)
        _ = try SevenZipTestSupport.write(payload, relativePath: "single.bin", below: source)
        let archive = temporary.appendingPathComponent("single.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: ["single.bin"],
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=off"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "single.bin" })
        XCTAssertEqual(entry.solidGroup, -1)
        let first = try reader.stream(entry)
        let second = try reader.stream(entry)
        XCTAssertEqual(try first.readAll(), payload)
        XCTAssertEqual(try second.readAll(), payload)
    }

    func testTwoThousandTinyNonsolidEntriesKeepKaitoSHAMemoryBounded() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-many-folders")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let entryCount = 2_000
        var paths: [String] = []
        paths.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let name = String(format: "tiny-%04d.bin", index)
            paths.append(name)
            _ = try SevenZipTestSupport.write(
                Data([UInt8(truncatingIfNeeded: index)]),
                relativePath: name,
                below: source
            )
        }

        let archive = temporary.appendingPathComponent("many-folders.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: paths,
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=off"]
        )
        let fixtureReader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(fixtureReader.entries.count, entryCount)
        XCTAssertTrue(fixtureReader.entries.allSatisfy { $0.solidGroup == -1 })

        let measured = try SevenZipTestSupport.runKaitoWithPeakResidentSize(
            arguments: ["sha", archive.path]
        )
        let lines = String(decoding: measured.standardOutput, as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, entryCount + 1)
        XCTAssertEqual(
            lines.last?.split(separator: "\t").prefix(2).map(String.init),
            ["total", String(entryCount)]
        )

        let maximumPeakResidentSize = UInt64(192 * 1_024 * 1_024)
        XCTAssertLessThan(
            measured.peakResidentSize,
            maximumPeakResidentSize,
            "2,000 completed folders must not retain every decoder"
        )
    }

    func testAESWithoutHeaderEncryptionReportsPasswordErrorsAtEntryRead() throws {
        try SevenZipTestSupport.requireSevenZip()
        let fixture = try makeEncryptedFixture(headerEncryption: false)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }

        let reader = try ArchiveReader.open(url: fixture.archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == fixture.entryName })
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertEqual(entry.formatSpecific["encryption"], "7zAES-256")
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }

        reader.password = fixture.password
        XCTAssertEqual(try reader.read(entry), fixture.payload)

        let wrong = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(password: "not-the-password")
        )
        let wrongEntry = try XCTUnwrap(wrong.entries.first { $0.name == fixture.entryName })
        XCTAssertThrowsError(try wrong.read(wrongEntry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testAESHeaderEncryptionRequiresCorrectPasswordWhileOpening() throws {
        try SevenZipTestSupport.requireSevenZip()
        let fixture = try makeEncryptedFixture(headerEncryption: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }

        XCTAssertThrowsError(try ArchiveReader.open(url: fixture.archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: fixture.archive,
                options: ReaderOptions(password: "not-the-password")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let reader = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(password: fixture.password)
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == fixture.entryName })
        XCTAssertEqual(try reader.read(entry), fixture.payload)

        let provider = CountingPasswordProvider(password: fixture.password)
        let providedReader = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(passwordProvider: provider)
        )
        XCTAssertEqual(provider.callCount, 1)
        let providedEntry = try XCTUnwrap(
            providedReader.entries.first { $0.name == fixture.entryName }
        )
        XCTAssertEqual(try providedReader.read(providedEntry), fixture.payload)
        XCTAssertEqual(
            provider.callCount,
            1,
            "the password resolved for the header must be reused for entry data"
        )
    }

    func testRealSevenZipNonsolidSolidAndBoundedBlockFixturesMatchOracle() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-layout-oracle")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        var expected: [String: Data] = [:]
        var paths: [String] = []
        for index in 0..<12 {
            let name = String(format: "page-%02d.bin", index)
            let contents = deterministicPayload(
                count: 9 * 1_024 + index,
                seed: UInt64(index + 101)
            )
            expected[name] = contents
            paths.append(name)
            _ = try SevenZipTestSupport.write(contents, relativePath: name, below: source)
        }

        let fixtures: [(name: String, solidOption: String)] = [
            ("nonsolid", "-ms=off"),
            ("solid", "-ms=on"),
            ("bounded-blocks", "-ms=20k"),
        ]
        for fixture in fixtures {
            let archive = temporary.appendingPathComponent("\(fixture.name).7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: paths,
                archiveURL: archive,
                options: ["-m0=LZMA2", fixture.solidOption]
            )
            let reader = try ArchiveReader.open(url: archive)
            let files = reader.entries.filter { $0.kind == .file }
            XCTAssertFalse(files.isEmpty, fixture.name)
            let groups = Set(files.map(\.solidGroup).filter { $0 >= 0 })
            switch fixture.name {
            case "nonsolid":
                XCTAssertEqual(groups.count, 0, fixture.name)
            case "solid":
                XCTAssertEqual(groups.count, 1, fixture.name)
            default:
                XCTAssertGreaterThan(groups.count, 1, fixture.name)
            }
            for entry in files.reversed() {
                let decoded = try reader.read(entry)
                let oracle = try SevenZipTestSupport.extractedData(
                    archiveURL: archive,
                    entryName: entry.name
                )
                assertSameSHA256(decoded, oracle, "\(fixture.name):\(entry.name)")
                assertSameSHA256(decoded, try XCTUnwrap(expected[entry.name]), entry.name)
            }
        }
    }

    private struct EncryptedFixture {
        let temporary: URL
        let archive: URL
        let entryName: String
        let payload: Data
        let password: String
    }

    private func makeEncryptedFixture(headerEncryption: Bool) throws -> EncryptedFixture {
        let label = headerEncryption ? "7z-aes-header" : "7z-aes-data"
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: label)
        do {
            let source = temporary.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: false
            )
            let entryName = "暗号化.txt"
            let payload = deterministicPayload(count: 96 * 1_024, seed: 0xA5)
                + Data("7zAES 日本語 tail\n".utf8)
            let password = "KaitoKit-7z-passphrase"
            _ = try SevenZipTestSupport.write(
                payload,
                relativePath: entryName,
                below: source
            )
            let archive = temporary.appendingPathComponent("encrypted.7z")
            try SevenZipTestSupport.makeArchive(
                sourceDirectory: source,
                paths: [entryName],
                archiveURL: archive,
                options: [
                    "-m0=LZMA2",
                    "-ms=off",
                    "-p\(password)",
                    headerEncryption ? "-mhe=on" : "-mhe=off",
                ]
            )
            return EncryptedFixture(
                temporary: temporary,
                archive: archive,
                entryName: entryName,
                payload: payload,
                password: password
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func deterministicPayload(count: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            // Fixture PRNG は再現性のため意図的に UInt64 で折り返す。
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        return Data(bytes)
    }

    private func x86MachOBranchPayload(repetitions: Int) -> Data {
        // 最小の little-endian Mach-O 64-bit x86_64 header に分岐命令列を続ける。
        var bytes: [UInt8] = [
            0xCF, 0xFA, 0xED, 0xFE, // MH_MAGIC_64
            0x07, 0x00, 0x00, 0x01, // CPU_TYPE_X86_64
            0x03, 0x00, 0x00, 0x00, // CPU_SUBTYPE_X86_64_ALL
            0x02, 0x00, 0x00, 0x00, // MH_EXECUTE
            0, 0, 0, 0, // ncmds
            0, 0, 0, 0, // sizeofcmds
            0, 0, 0, 0, // flags
            0, 0, 0, 0, // reserved
        ]
        bytes.reserveCapacity(bytes.count + repetitions * 18)
        for index in 0..<repetitions {
            bytes.append(0x41)
            bytes.append(0xE8)
            appendUInt32LE(UInt32(bitPattern: Int32(index &* 13 &- 4_096)), to: &bytes)
            bytes.append(0x42)
            bytes.append(0xE9)
            appendUInt32LE(UInt32(bitPattern: Int32(8_192 &- index &* 7)), to: &bytes)
            bytes.append(contentsOf: [0x0F, 0x85])
            appendUInt32LE(UInt32(index &* 11), to: &bytes)
        }
        return Data(bytes)
    }

    private func arm64BranchPayload(repetitions: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(repetitions * 12)
        for index in 0..<repetitions {
            appendUInt32LE(0x9400_0000 | UInt32(index & 0x03FF_FFFF), to: &bytes)
            appendUInt32LE(0x9000_0000 | UInt32((index & 3) << 29), to: &bytes)
            appendUInt32LE(UInt32(truncatingIfNeeded: index &* 0x9E37_79B1), to: &bytes)
        }
        return Data(bytes)
    }

    private func appendUInt32LE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func assertSameSHA256(
        _ lhs: Data,
        _ rhs: Data,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            SHA256.hash(data: lhs).elementsEqual(SHA256.hash(data: rhs)),
            "SHA-256 mismatch: \(context)",
            file: file,
            line: line
        )
    }
}

private final class CountingPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let storedPassword: String
    private var calls = 0

    init(password: String) {
        storedPassword = password
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func password(for format: ArchiveFormat) throws -> String? {
        guard format == .sevenZip else {
            throw KaitoError.malformed("unexpected password-provider format in test")
        }
        lock.lock()
        calls += 1
        lock.unlock()
        return storedPassword
    }
}
