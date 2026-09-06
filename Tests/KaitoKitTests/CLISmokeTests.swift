import Foundation
import XCTest

final class CLISmokeTests: XCTestCase {
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
