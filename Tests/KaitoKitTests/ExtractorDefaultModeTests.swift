import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class ExtractorDefaultModeTests: XCTestCase {
    func testInfoZIPWithoutDirectoryEntriesUsesUmaskDerivedDefaults() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.infoZipPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "extract-zip-D-modes")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let implicit = source.appendingPathComponent("implicit", isDirectory: true)
        try FileManager.default.createDirectory(at: implicit, withIntermediateDirectories: true)
        let payload = Data("Info-ZIP -D implicit parent\n".utf8)
        try payload.write(to: implicit.appendingPathComponent("page.txt"))

        let archive = temporary.appendingPathComponent("without-directories.zip")
        _ = try ZipTestSupport.checkedRun(
            ZipTestSupport.infoZipPath,
            arguments: ["-q", "-D", archive.path, "implicit/page.txt"],
            currentDirectory: source
        )
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["implicit/page.txt"])
        XCTAssertFalse(reader.entries.contains { $0.kind == .directory })

        let output = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let expectedFileMode = try createModeReferenceFile(below: output)
        let expectedDirectoryMode = try createModeReferenceDirectory(below: output)
        _ = try reader.extract(
            reader.entries[0],
            to: output,
            options: ExtractionOptions(preserveMetadata: false)
        )

        let extracted = output.appendingPathComponent("implicit/page.txt")
        XCTAssertEqual(try Data(contentsOf: extracted), payload)
        XCTAssertEqual(try mode(of: extracted), expectedFileMode)
        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("implicit", isDirectory: true)),
            expectedDirectoryMode
        )
    }

    func testRestrictiveUmaskStillExtractsAndRestoresKernelDerivedModes() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(
            label: "extract-restrictive-umask"
        )
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let implicit = output.appendingPathComponent("implicit", isDirectory: true)
        let empty = output.appendingPathComponent("empty", isDirectory: true)
        defer {
            _ = Darwin.chmod(output.path, mode_t(0o700))
            _ = Darwin.chmod(implicit.path, mode_t(0o700))
            _ = Darwin.chmod(empty.path, mode_t(0o700))
            try? FileManager.default.removeItem(at: temporary)
        }

        let firstPayload = Data("first restrictive payload\n".utf8)
        let secondPayload = Data("second restrictive payload\n".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "implicit/first.txt",
                uncompressedData: firstPayload,
                versionMadeBy: 0x0014,
                externalAttributes: 0
            ),
            HandZipEntry(
                name: "implicit/second.txt",
                uncompressedData: secondPayload,
                versionMadeBy: 0x0014,
                externalAttributes: 0
            ),
            HandZipEntry(
                name: "shortcut",
                uncompressedData: Data("implicit/first.txt".utf8),
                versionMadeBy: 0x031E,
                externalAttributes: UInt32(0o120777) << 16
            ),
            HandZipEntry(
                name: "empty/",
                versionMadeBy: 0x0014,
                externalAttributes: 0x10
            ),
        ])
        let archiveURL = temporary.appendingPathComponent("restrictive.zip")
        try archive.write(to: archiveURL)

        try runKaitoWithRestrictiveUmask(
            try findKaitoExecutable(),
            archive: archiveURL,
            output: output
        )

        XCTAssertEqual(try mode(of: output), 0)
        guard Darwin.chmod(output.path, mode_t(0o700)) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertTrue(
            try isSymbolicLink(output.appendingPathComponent("shortcut"))
        )
        XCTAssertEqual(try mode(of: implicit), 0)
        XCTAssertEqual(try mode(of: empty), 0)
        guard Darwin.chmod(implicit.path, mode_t(0o700)) == 0 else {
            throw KaitoError.io(errno)
        }

        let first = implicit.appendingPathComponent("first.txt")
        let second = implicit.appendingPathComponent("second.txt")
        XCTAssertEqual(try mode(of: first), 0)
        XCTAssertEqual(try mode(of: second), 0)
        guard Darwin.chmod(first.path, mode_t(0o400)) == 0,
              Darwin.chmod(second.path, mode_t(0o400)) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertEqual(try Data(contentsOf: first), firstPayload)
        XCTAssertEqual(try Data(contentsOf: second), secondPayload)
    }

    func testWindowsZipUsesUmaskDerivedModesForFilesAndDirectories() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "extract-default-modes")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        let expectedFileMode = try createModeReferenceFile(below: output)
        let expectedDirectoryMode = try createModeReferenceDirectory(below: output)
        let payload = Data("Windows ZIP without POSIX attributes\n".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "implicit/page.txt",
                uncompressedData: payload,
                versionMadeBy: 0x0014,
                externalAttributes: 0
            ),
            HandZipEntry(
                name: "empty/",
                versionMadeBy: 0x0014,
                externalAttributes: 0x10
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertTrue(reader.entries.allSatisfy { $0.posixPermissions == nil })

        for entry in reader.entries {
            _ = try reader.extract(entry, to: output)
        }

        let extractedFile = output.appendingPathComponent("implicit/page.txt")
        XCTAssertEqual(try Data(contentsOf: extractedFile), payload)
        XCTAssertEqual(try mode(of: extractedFile), expectedFileMode)
        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("implicit", isDirectory: true)),
            expectedDirectoryMode
        )
        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("empty", isDirectory: true)),
            expectedDirectoryMode
        )
    }

    func testDisablingMetadataPreservationUsesUmaskDerivedModes() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        let expectedFileMode = try createModeReferenceFile(below: output)
        let expectedDirectoryMode = try createModeReferenceDirectory(below: output)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "folder/", type: 0x35, mode: 0o500),
            HandTarEntry(
                name: "implicit/page.txt",
                contents: Data("ignore archived permissions".utf8),
                mode: 0o400
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let options = ExtractionOptions(preserveMetadata: false)
        for entry in reader.entries {
            _ = try reader.extract(entry, to: output, options: options)
        }

        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("folder", isDirectory: true)),
            expectedDirectoryMode
        )
        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("implicit/page.txt")),
            expectedFileMode
        )
        XCTAssertEqual(
            try mode(of: output.appendingPathComponent("implicit", isDirectory: true)),
            expectedDirectoryMode
        )
    }

    func testOwnedRestrictiveDestinationModesAreTemporarilyAddedAndRestored() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(
            label: "extract-restrictive-existing-root"
        )
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let locked = output.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            _ = Darwin.chmod(output.path, mode_t(0o700))
            _ = Darwin.chmod(locked.path, mode_t(0o700))
            try? FileManager.default.removeItem(at: temporary)
        }
        guard Darwin.chmod(output.path, mode_t(0o500)) == 0,
              Darwin.chmod(locked.path, mode_t(0o500)) == 0 else {
            throw KaitoError.io(errno)
        }

        let payload = Data("temporarily accessible destination\n".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "locked/page.txt", uncompressedData: payload),
        ])
        let reader = try ArchiveReader.open(data: archive)
        _ = try reader.extract(reader.entries[0], to: output)

        XCTAssertEqual(try mode(of: output), 0o500)
        XCTAssertEqual(try mode(of: locked), 0o500)
        guard Darwin.chmod(output.path, mode_t(0o700)) == 0,
              Darwin.chmod(locked.path, mode_t(0o700)) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertEqual(
            try Data(contentsOf: locked.appendingPathComponent("page.txt")),
            payload
        )
    }

    private func createModeReferenceFile(below directory: URL) throws -> UInt16 {
        let url = directory.appendingPathComponent("mode-reference-file-\(UUID().uuidString)")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o666)
        )
        guard descriptor >= 0 else { throw KaitoError.io(errno) }
        guard Darwin.close(descriptor) == 0 else { throw KaitoError.io(errno) }
        return try mode(of: url)
    }

    private func createModeReferenceDirectory(below directory: URL) throws -> UInt16 {
        let url = directory.appendingPathComponent(
            "mode-reference-directory-\(UUID().uuidString)",
            isDirectory: true
        )
        guard Darwin.mkdir(url.path, mode_t(0o777)) == 0 else {
            throw KaitoError.io(errno)
        }
        return try mode(of: url)
    }

    private func mode(of url: URL) throws -> UInt16 {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        return UInt16(information.st_mode & mode_t(0o7777))
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private func runKaitoWithRestrictiveUmask(
        _ executable: URL,
        archive: URL,
        output: URL
    ) throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "umask 0777; exec \"$@\"",
            "kaito-restrictive-umask",
            executable.path,
            "extract",
            archive.path,
            "-o",
            output.path,
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        _ = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ZipTestSupportError.commandFailed(
                String(decoding: errors, as: UTF8.self)
            )
        }
    }

    private func findKaitoExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KAITO_EXECUTABLE"] {
            let candidate = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        var candidates = [
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
        throw ZipTestSupportError.fixture("built kaito executable was not found")
    }
}
