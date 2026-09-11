import CryptoKit
import Foundation
import KaitoKit
import XCTest

final class CLISmokeTests: XCTestCase {
    func testSplitSevenZipListAndSHAMatchWholeArchive() throws {
        let bytes = try ZipTestSupport.checkedInFixture("sevenzip/chain-lzma-lzma-lzma2-bcj2.7z")
        let directory = try ZipTestSupport.temporaryDirectory(label: "cli-split-7z")
        defer { try? FileManager.default.removeItem(at: directory) }
        let whole = try ZipTestSupport.write(bytes, relativePath: "whole.7z", below: directory)
        // 署名自体が巻をまたぐケースを CLI の detect / list / sha まで通す。
        let first = try ZipTestSupport.write(Data(bytes.prefix(5)), relativePath: "split.7z.001", below: directory)
        try ZipTestSupport.write(Data(bytes.dropFirst(5)), relativePath: "split.7z.002", below: directory)
        let executable = try findKaitoExecutable()
        for command in ["detect", "list", "sha"] {
            XCTAssertEqual(try runKaito(executable, arguments: [command, first.path]),
                           try runKaito(executable, arguments: [command, whole.path]))
        }
    }

    func testXarExtractionDefersForwardLinksAndReportsTargetFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = try findKaitoExecutable()
        for name in ["xar-plain.xar", "xar-links.xar"] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).b64"), encoding: .utf8)
            let archive = temporary.appendingPathComponent(name)
            try XCTUnwrap(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))).write(to: archive)
            for failedTarget in (name == "xar-plain.xar" ? [false, true] : [false]) {
                let output = temporary.appendingPathComponent("\(name)-\(failedTarget)")
                if failedTarget {
                    // 実体の公開を失敗させ、同名の既存 object を link が信用しないことを検査する。
                    try FileManager.default.createDirectory(at: output.appendingPathComponent("hard.txt"), withIntermediateDirectories: true)
                }
                let process = Process()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = ["extract", archive.path, "-o", output.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                try process.run()
                process.waitUntilExit()
                let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationReason, .exit)
                if failedTarget {
                    XCTAssertEqual(process.terminationStatus, 1)
                    XCTAssertTrue(errors.contains("failed entry 7 (hard.txt)"), errors)
                    XCTAssertTrue(errors.contains("failed entry 1 (a.txt)"), errors)
                    XCTAssertTrue(errors.contains("hard-link target was not materialized by this archive reader"), errors)
                    XCTAssertTrue(errors.contains("2 archive entries failed"), errors)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("a.txt").path))
                    continue
                }
                XCTAssertEqual(process.terminationStatus, name == "xar-links.xar" ? 1 : 0, errors)
                if name == "xar-links.xar" {
                    XCTAssertTrue(errors.contains("failed entry 3 (dangling.txt)"), errors)
                    XCTAssertTrue(errors.contains("1 archive entries failed"), errors)
                } else { XCTAssertEqual(errors, "") }
                let members = name == "xar-plain.xar" ? ["a.txt", "hard.txt"] : ["orig.txt", "l1.txt", "l2.txt"]
                let expected = name == "xar-plain.xar"
                    ? "1ddc234bae1b3930239b3d8625224117828d8a576bb8951087cbe6097387fb1e"
                    : "86d7bb82c5856157d89466dc8fc8d52b8e14742702359f500dd09f0f912bb77c"
                var inode: NSNumber?
                for member in members {
                    let url = output.appendingPathComponent(member)
                    let data = try Data(contentsOf: url)
                    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected)
                    let actual = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
                    if let inode { XCTAssertEqual(actual, inode) } else { inode = actual }
                }
            }
        }
    }

    func testArListAndSHA() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/lib.a.b64"), encoding: .utf8)
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("lib.a")
        try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
        let executable = try findKaitoExecutable()
        let output = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertEqual(output.split(separator: "\n").count, 2)
        XCTAssertTrue(output.contains("ar (stored)\tplain\ta.txt"))
        let hashes = try runKaito(executable, arguments: ["sha", url.path])
        XCTAssertTrue(hashes.contains("70bf6ca40d63eeb669f684aafbf02a896c396de1b3aab3b0efe107d66279c202"))
        XCTAssertTrue(hashes.contains("e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c"))
    }

    func testListCpioFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/newc.cpio.b64"), encoding: .utf8)
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("newc.cpio")
        try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
        let output = try runKaito(findKaitoExecutable(), arguments: ["list", url.path])
        XCTAssertEqual(output.split(separator: "\n").count, 5)
        XCTAssertTrue(output.contains("cpio (stored)\tplain\t./a.txt"))
    }

    func testListShowsMethodEncryptionAndOptionalRawName() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-list.tar")
        let name = "page.txt"
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: name, contents: Data("payload".utf8)),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let ordinary = try runKaito(executable, arguments: ["list", archive.path])
        let raw = try runKaito(executable, arguments: ["list", archive.path, "--raw"])
        let expectedRawName = name.utf8.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            ordinary.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "7", "file", "tar (stored)", "plain", "page.txt"]
        )
        XCTAssertEqual(
            raw.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "7", "file", "tar (stored)", "plain", "page.txt", expectedRawName]
        )
    }

    func testListNamesTheZIPEncryptionMethod() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "cli-list-encryption")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try ZipTestSupport.write(
            Data("encrypted list payload".utf8),
            relativePath: "secret.txt",
            below: source
        )
        let archive = temporary.appendingPathComponent("encrypted.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["secret.txt"],
            archiveURL: archive,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let output = try runKaito(
            findKaitoExecutable(),
            arguments: ["list", archive.path]
        )
        XCTAssertEqual(
            output.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "22", "file", "stored", "ZipCrypto", "secret.txt"]
        )
    }

    func testSHAOutputIsStableAcrossRuns() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli.tar")
        let contents = Data("stable cli payload".utf8)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "日本語.txt", contents: contents),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let first = try runKaito(executable, arguments: ["sha", archive.path])
        let second = try runKaito(executable, arguments: ["sha", archive.path])
        XCTAssertEqual(first, second)

        let lines = first.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("0\t\(contents.count)\t"))
        XCTAssertTrue(lines[0].hasSuffix("\t日本語.txt"))
        XCTAssertTrue(lines[1].hasPrefix("total\t1\t"))
    }

    func testSHAStreamsAcrossReusableBufferBoundary() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-sha-large.tar")
        let contents = Data(repeating: 0xA5, count: 4 * 1_024 * 1_024 + 17)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "large.bin", contents: contents),
        ]).write(to: archive)

        let output = try runKaito(
            findKaitoExecutable(),
            arguments: ["sha", archive.path]
        )
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let digest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(lines[0], "0\t\(contents.count)\t\(digest)\tlarge.bin")
    }

    func testBenchSupportsMappedDataAndLegacyArgumentOrder() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-bench.tar")
        let contents = Data("mapped benchmark payload".utf8)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "page.txt", contents: contents),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let outputs = try [
            runKaito(executable, arguments: ["bench", archive.path, "1"]),
            runKaito(executable, arguments: ["bench", "--data", archive.path, "1"]),
            runKaito(executable, arguments: ["bench", archive.path, "1", "--data"]),
            runKaito(executable, arguments: ["bench", "--random", archive.path, "1"]),
            runKaito(
                executable,
                arguments: ["bench", archive.path, "1", "--random", "--data"]
            ),
        ]

        for output in outputs {
            let lines = output.split(separator: "\n")
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines[0], "reps\t1")
            XCTAssertTrue(lines[1].hasPrefix("open-median-ms\t"))
            XCTAssertNotNil(Double(lines[1].dropFirst("open-median-ms\t".count)))
            XCTAssertTrue(lines[2].hasPrefix("extract-median-ms\t"))
            XCTAssertEqual(lines[3], "bytes\t\(contents.count)")
        }
    }

    func testBenchRandomReadsAtMostTwentyNonDirectoryEntries() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-bench-random.tar")
        var entries = [HandTarEntry(name: "folder/", type: 0x35)]
        entries.append(contentsOf: (0..<25).map { index in
            HandTarEntry(
                name: String(format: "folder/page-%02d.bin", index),
                contents: Data(repeating: UInt8(index), count: 1_000 + index)
            )
        })
        try TarTestSupport.makeTar(entries: entries).write(to: archive)

        let executable = try findKaitoExecutable()
        let outputs = try (0..<2).map { _ in
            try runKaito(
                executable,
                arguments: ["bench", "--random", archive.path, "1"]
            )
        }
        let lines = outputs.map { $0.split(separator: "\n") }
        guard lines.allSatisfy({ $0.count == 4 }) else {
            return XCTFail("bench output must keep its four-line format")
        }
        XCTAssertTrue(lines.allSatisfy { $0[0] == "reps\t1" })
        XCTAssertTrue(lines.allSatisfy { $0[2].hasPrefix("extract-median-ms\t") })
        XCTAssertEqual(lines[0][3], lines[1][3], "the fixed sample must be reproducible")
        let byteCount = try XCTUnwrap(Int(lines[0][3].dropFirst("bytes\t".count)))
        XCTAssertTrue((20_000..<21_000).contains(byteCount), "exactly 20 files are read")
    }

    func testBenchRandomReadsTwentyEntriesFromSolidSevenZip() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "cli-7z-random")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        var paths: [String] = []
        for index in 0..<25 {
            let name = String(format: "page-%02d.bin", index)
            paths.append(name)
            _ = try SevenZipTestSupport.write(
                Data(repeating: UInt8(index), count: 1_000 + index),
                relativePath: name,
                below: source
            )
        }
        let archive = temporary.appendingPathComponent("solid.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: paths,
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=on"]
        )

        let executable = try findKaitoExecutable()
        XCTAssertEqual(
            try runKaito(executable, arguments: ["detect", archive.path])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "7z"
        )
        let listed = try runKaito(executable, arguments: ["list", archive.path])
            .split(separator: "\n")
        XCTAssertEqual(listed.count, paths.count)
        XCTAssertTrue(listed.allSatisfy { $0.contains("\tLZMA2\t") })
        let hashes = try runKaito(executable, arguments: ["sha", archive.path])
            .split(separator: "\n")
        XCTAssertEqual(hashes.count, paths.count + 1)
        XCTAssertTrue(hashes.last?.hasPrefix("total\t25\t") == true)

        let output = try runKaito(
            executable,
            arguments: ["bench", "--random", archive.path, "1"]
        )
        let lines = output.split(separator: "\n")
        guard lines.count == 4 else {
            return XCTFail("bench output must keep its four-line format")
        }
        let byteCount = try XCTUnwrap(Int(lines[3].dropFirst("bytes\t".count)))
        XCTAssertTrue((20_000..<21_000).contains(byteCount), "exactly 20 files are read")
    }

    func testListSHAAndBenchPassPasswordToHeaderEncryptedSevenZip() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "cli-7z-password")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let name = "secret.txt"
        let contents = Data("header-encrypted CLI payload".utf8)
        let password = "cli-fixed-password"
        _ = try SevenZipTestSupport.write(contents, relativePath: name, below: source)
        let archive = temporary.appendingPathComponent("encrypted.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: [name],
            archiveURL: archive,
            options: ["-m0=Copy", "-ms=off", "-p\(password)", "-mhe=on"]
        )

        let executable = try findKaitoExecutable()
        let listed = try runKaito(
            executable,
            arguments: ["list", "--raw", "-p", password, archive.path]
        ).trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        XCTAssertEqual(listed.count, 7)
        XCTAssertEqual(listed[1], String(contents.count))
        XCTAssertEqual(listed[4], "7zAES-256")
        XCTAssertEqual(listed[5], name)

        let hashes = try runKaito(
            executable,
            arguments: ["sha", archive.path, "-p", password]
        ).split(separator: "\n")
        XCTAssertEqual(hashes.count, 2)
        XCTAssertTrue(hashes[0].hasPrefix("0\t\(contents.count)\t"))
        XCTAssertTrue(hashes[0].hasSuffix("\t\(name)"))
        XCTAssertTrue(hashes[1].hasPrefix("total\t1\t"))

        let benchmark = try runKaito(
            executable,
            arguments: ["bench", "-p", password, "--data", archive.path, "1"]
        ).split(separator: "\n")
        XCTAssertEqual(benchmark.count, 4)
        XCTAssertEqual(benchmark[0], "reps\t1")
        XCTAssertEqual(benchmark[3], "bytes\t\(contents.count)")
    }

    func testExtractDefersRestrictiveDirectoryMetadataUntilAfterChildren() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let restrictedDirectory = output.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: restrictedDirectory.path
            )
            try? FileManager.default.removeItem(at: temporary)
        }

        let archive = temporary.appendingPathComponent("restrictive-directory.tar")
        let payload = Data("created before final directory metadata".utf8)
        let expectedTime = Date(timeIntervalSince1970: 1_650_000_123)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(
                name: "locked/",
                type: 0x35,
                mode: 0o500,
                modificationTime: 1_650_000_123
            ),
            HandTarEntry(name: "locked/child.txt", contents: payload),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        _ = try runKaito(
            executable,
            arguments: ["extract", archive.path, "-o", output.path]
        )

        XCTAssertEqual(
            try Data(contentsOf: restrictedDirectory.appendingPathComponent("child.txt")),
            payload
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: restrictedDirectory.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value & 0o7777, 0o500)
        XCTAssertEqual(
            try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970,
            expectedTime.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testListAndSHAEscapeTerminalControlCharactersInNames() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("controls.tar")
        let name = "safe\u{1b}[2J\u{7f}\u{85}\u{2028}spoof.txt"
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: name, contents: Data("payload".utf8)),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let list = try runKaito(executable, arguments: ["list", archive.path])
        let sha = try runKaito(executable, arguments: ["sha", archive.path])
        let visibleName = "safe\\u{1b}[2J\\u{7f}\\u{85}\\u{2028}spoof.txt"

        XCTAssertTrue(list.contains(visibleName))
        XCTAssertTrue(sha.contains(visibleName))
        for output in [list, sha] {
            XCTAssertFalse(output.unicodeScalars.contains { scalar in
                scalar.value == 0x1b || scalar.value == 0x7f ||
                    (0x80...0x9f).contains(scalar.value) ||
                    scalar.value == 0x2028 || scalar.value == 0x2029
            })
        }
    }

    func testPerEntryFailureContinuesSHAAndExtractionButReturnsFailure() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("partial.lzh")
        let payload = Data("after unsupported entry".utf8)
        try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "unreadable", method: "-pm2-", headerLevel: 2),
            HandLHAEntry(name: "dir/good.txt", contents: payload, headerLevel: 2),
            HandLHAEntry(name: "dir", method: "-lhd-", headerLevel: 2, permissions: 0o500),
        ]).write(to: archive)
        let output = temporary.appendingPathComponent("output")
        for arguments in [["sha", archive.path], ["extract", archive.path, "-o", output.path]] {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = try findKaitoExecutable()
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 1)
            XCTAssertTrue(errors.contains("entry 0 (unreadable)"))
            XCTAssertTrue(errors.contains("1 archive entries failed"))
            if arguments[0] == "sha" {
                XCTAssertTrue(text.contains("\tdir/good.txt\n"))
                XCTAssertTrue(text.contains("partial\t2\t"))
                XCTAssertTrue(text.contains("0\tERROR\t"))
                XCTAssertFalse(text.contains("total\t"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("dir/good.txt")), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent("dir").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, Double(LHATestSupport.unixTimestamp))
    }

    func testSolidCRCFailureLabelsFailedEntryAndSourceMember() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixture = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/solid_lz_rar300.rar.b64")
        let encoded = try String(contentsOf: fixture, encoding: .utf8)
        var bytes = Array(try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)))
        var offset = 7
        while bytes[offset + 2] != 0x74 {
            offset += Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        }
        let size = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        bytes[offset + 16] ^= 1 // Wrong member CRC; leave the solid compressed stream intact.
        let headerCRC = CRC32.checksum(Array(bytes[(offset + 2)..<(offset + size)]))
        bytes[offset] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let archive = temporary.appendingPathComponent("bad-solid.rar")
        try Data(bytes).write(to: archive)
        for arguments in [["sha", archive.path], ["extract", archive.path, "-o", temporary.appendingPathComponent("out").path]] {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = try findKaitoExecutable()
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 1)
            XCTAssertTrue(errors.contains("error: failed entry 1 ("), errors)
            XCTAssertTrue(errors.contains("Checksum mismatch (source member 0)"), errors)
            XCTAssertFalse(errors.contains("Checksum mismatch for entry"), errors)
            if arguments[0] == "sha" {
                XCTAssertTrue(output.contains("1\tERROR\tfailed entry 1: Checksum mismatch (source member 0)\t"), output)
            }
        }
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
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
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

        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("kaito"))
        var ancestor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
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
            for case let candidate as URL in enumerator where candidate.lastPathComponent == "kaito" {
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw TarTestSupportError.commandFailed("built kaito executable was not found")
    }
}
