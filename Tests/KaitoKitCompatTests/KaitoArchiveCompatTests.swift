import Darwin
import Foundation
@testable import KaitoKit
@testable import KaitoKitCompat
import XCTest

final class KaitoArchiveCompatTests: XCTestCase {
    private static let restrictiveUmaskChild = "KAITOKIT_COMPAT_RESTRICTIVE_UMASK_CHILD"
    private static let restrictiveUmaskArchive = "KAITOKIT_COMPAT_RESTRICTIVE_UMASK_ARCHIVE"
    private static let restrictiveUmaskOutput = "KAITOKIT_COMPAT_RESTRICTIVE_UMASK_OUTPUT"

    func testCrossVolumeCopyFallbackPreservesContentsModeAndModificationTime() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatRelocationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = temporary.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: false
        )
        let source = sourceDirectory.appendingPathComponent("page.txt")
        let destination = destinationDirectory.appendingPathComponent("page.txt")
        let payload = Data("cross-volume hard-link payload".utf8)
        try payload.write(to: source)
        try Data("old destination".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_650_123_456.25)],
            ofItemAtPath: source.path
        )
        guard Darwin.chmod(source.path, mode_t(0)) == 0 else {
            throw KaitoError.io(errno)
        }

        var sourceBeforeCopy = stat()
        guard Darwin.lstat(source.path, &sourceBeforeCopy) == 0 else {
            throw KaitoError.io(errno)
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let sourceParent = Darwin.open(sourceDirectory.path, flags)
        guard sourceParent >= 0 else { throw KaitoError.io(errno) }
        defer { _ = Darwin.close(sourceParent) }
        let destinationParent = Darwin.open(destinationDirectory.path, flags)
        guard destinationParent >= 0 else { throw KaitoError.io(errno) }
        defer { _ = Darwin.close(destinationParent) }

        try KaitoArchiveFileRelocator.copyRegularFile(
            from: sourceParent,
            sourceLeaf: source.lastPathComponent,
            to: destinationParent,
            destinationLeaf: destination.lastPathComponent
        )

        var sourceAfterCopy = stat()
        var destinationAfterCopy = stat()
        guard Darwin.lstat(source.path, &sourceAfterCopy) == 0,
              Darwin.lstat(destination.path, &destinationAfterCopy) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertEqual(sourceAfterCopy.st_mode & mode_t(0o7777), 0)
        XCTAssertEqual(destinationAfterCopy.st_mode & mode_t(0o7777), 0)
        XCTAssertEqual(destinationAfterCopy.st_mtimespec.tv_sec, sourceBeforeCopy.st_mtimespec.tv_sec)
        XCTAssertEqual(
            destinationAfterCopy.st_mtimespec.tv_nsec,
            sourceBeforeCopy.st_mtimespec.tv_nsec
        )
        XCTAssertNotEqual(destinationAfterCopy.st_ino, sourceAfterCopy.st_ino)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
                .contains { $0.hasPrefix(".kaitokit-relocate-") }
        )

        guard Darwin.chmod(destination.path, mode_t(0o400)) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testCompatibilitySurfaceOverTarDataAndFile() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("compatibility payload".utf8)
        let sourceFile = source.appendingPathComponent("page.txt")
        try payload.write(to: sourceFile)
        let sourceHardLink = source.appendingPathComponent("page-link.txt")
        try FileManager.default.linkItem(at: sourceFile, to: sourceHardLink)
        let sourceDirectory = source.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )

        let archiveURL = temporary.appendingPathComponent("compat.tar")
        try createTar(
            sourceDirectory: source,
            paths: ["page.txt", "page-link.txt", "folder"],
            archiveURL: archiveURL
        )
        let archiveData = try Data(contentsOf: archiveURL)

        let dataArchive = try XCTUnwrap(KaitoArchive(data: archiveData))
        try assertSurface(dataArchive, payload: payload, temporary: temporary)

        let fileArchive = try XCTUnwrap(XADArchive(file: archiveURL.path))
        XCTAssertEqual(fileArchive.numberOfEntries(), 3)
        XCTAssertNotNil(fileArchive.name(ofEntry: 0))
    }

    func testRestrictiveUmaskHardLinkStagingIsRemovedAndDestinationModeIsRestored() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment[Self.restrictiveUmaskChild] == "1" {
            let archivePath = try XCTUnwrap(environment[Self.restrictiveUmaskArchive])
            let outputPath = try XCTUnwrap(environment[Self.restrictiveUmaskOutput])
            try assertRestrictiveUmaskHardLinkExtraction(
                archiveURL: URL(fileURLWithPath: archivePath),
                output: URL(fileURLWithPath: outputPath, isDirectory: true)
            )
            return
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatRestrictiveUmaskTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let targetParent = source.appendingPathComponent("nested/deeper", isDirectory: true)
        let linkParent = source.appendingPathComponent("links", isDirectory: true)
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        defer {
            // A failing regression can leave umask-derived mode-000 directories behind.
            // Open the known private paths enough for the test harness to remove its fixture.
            _ = Darwin.chmod(output.path, mode_t(0o700))
            if let children = try? FileManager.default.contentsOfDirectory(atPath: output.path) {
                for child in children where child.hasPrefix(".kaitokit-") {
                    let staging = output.appendingPathComponent(child, isDirectory: true)
                    _ = Darwin.chmod(staging.path, mode_t(0o700))
                    _ = Darwin.chmod(
                        staging.appendingPathComponent("nested", isDirectory: true).path,
                        mode_t(0o700)
                    )
                    _ = Darwin.chmod(
                        staging.appendingPathComponent("nested/deeper", isDirectory: true).path,
                        mode_t(0o700)
                    )
                    _ = Darwin.chmod(
                        staging.appendingPathComponent("links", isDirectory: true).path,
                        mode_t(0o700)
                    )
                }
            }
            _ = Darwin.chmod(
                output.appendingPathComponent("links", isDirectory: true).path,
                mode_t(0o700)
            )
            try? FileManager.default.removeItem(at: temporary)
        }

        try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
        let payload = Data("restrictive umask hard-link payload\n".utf8)
        let target = targetParent.appendingPathComponent("page.txt")
        try payload.write(to: target)
        try FileManager.default.linkItem(
            at: target,
            to: linkParent.appendingPathComponent("copy.txt")
        )
        let archiveURL = temporary.appendingPathComponent("nested-hardlink.tar")
        try createTar(
            sourceDirectory: source,
            paths: ["nested/deeper/page.txt", "links/copy.txt"],
            archiveURL: archiveURL
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        guard Darwin.chmod(output.path, mode_t(0o500)) == 0 else {
            throw KaitoError.io(errno)
        }

        try runCurrentTestWithRestrictiveUmask(
            archiveURL: archiveURL,
            output: output
        )
    }

    func testRelocatedSymbolicLinkCannotTraverseDestinationPivot() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("archive-link").path,
            withDestinationPath: "pivot/target.txt"
        )
        let sentinel = outside.appendingPathComponent("target.txt")
        try Data("outside-sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            atPath: output.appendingPathComponent("pivot").path,
            withDestinationPath: "../outside"
        )

        let archiveURL = temporary.appendingPathComponent("symlink.tar")
        try createTar(
            sourceDirectory: source,
            paths: ["archive-link"],
            archiveURL: archiveURL
        )
        let archive = try XCTUnwrap(KaitoArchive(file: archiveURL.path))
        let destination = output.appendingPathComponent("archive-link")

        XCTAssertFalse(archive.extractEntry(0, to: output.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside-sentinel".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testZipDirectoryNameMatchesXADWithoutChangingModernName() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let folder = source.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archiveURL = temporary.appendingPathComponent("directory.zip")
        try createArchive(
            sourceDirectory: source,
            paths: ["folder"],
            archiveURL: archiveURL,
            format: "zip"
        )

        let modern = try ArchiveReader.open(url: archiveURL)
        let modernDirectory = try XCTUnwrap(modern.entries.first { $0.kind == .directory })
        XCTAssertEqual(modernDirectory.name, "folder/")

        let archive = try XCTUnwrap(KaitoArchive(file: archiveURL.path))
        let directoryIndex = try XCTUnwrap(
            (0..<archive.numberOfEntries()).first { archive.entryIsDirectory($0) }
        )
        XCTAssertEqual(archive.name(ofEntry: directoryIndex), "folder")
    }

    func testUnknownUncompressedSizeUsesXADSentinel() throws {
        let payload = Data("unknown RAR5 stored size\n".utf8)
        let archive = try XCTUnwrap(KaitoArchive(data: makeUnknownSizeRAR5(payload: payload)))

        XCTAssertEqual(archive.numberOfEntries(), 1)
        XCTAssertFalse(archive.entryHasSize(0))
        XCTAssertEqual(archive.uncompressedSize(ofEntry: 0), Int64.max)
        XCTAssertEqual(archive.contents(ofEntry: 0), payload)
        XCTAssertEqual(archive.uncompressedSize(ofEntry: Int32.max), 0)
    }

    func testTinyInfoZipStoredZipCryptoOpensNormally() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKitCompatTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("hello".utf8)
        try payload.write(to: source.appendingPathComponent("tiny.txt"))
        let archiveURL = temporary.appendingPathComponent("tiny-zipcrypto.zip")
        try runCommand(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-0", "-P", "compat-password", archiveURL.path, "tiny.txt"],
            currentDirectory: source
        )

        for archive in [
            try XCTUnwrap(KaitoArchive(file: archiveURL.path)),
            try XCTUnwrap(KaitoArchive(data: Data(contentsOf: archiveURL))),
        ] {
            XCTAssertEqual(archive.numberOfEntries(), 1)
            XCTAssertTrue(archive.entryIsEncrypted(0))
            archive.setPassword("compat-password")
            XCTAssertEqual(archive.contents(ofEntry: 0), payload)
        }
    }

    private func assertSurface(
        _ archive: KaitoArchive,
        payload: Data,
        temporary: URL
    ) throws {
        XCTAssertEqual(archive.numberOfEntries(), 3)
        var fileIndex: Int32?
        var hardLinkIndex: Int32?
        var directoryIndex: Int32?
        for index in 0..<archive.numberOfEntries() {
            switch archive.name(ofEntry: index) {
            case "page.txt": fileIndex = index
            case "page-link.txt": hardLinkIndex = index
            case "folder": directoryIndex = index
            default: break
            }
        }
        let file = try XCTUnwrap(fileIndex)
        let hardLink = try XCTUnwrap(hardLinkIndex)
        let directory = try XCTUnwrap(directoryIndex)

        XCTAssertEqual(archive.contents(ofEntry: file), payload)
        XCTAssertEqual(archive.uncompressedSize(ofEntry: file), Int64(payload.count))
        XCTAssertTrue(archive.entryHasSize(file))
        XCTAssertFalse(archive.entryIsDirectory(file))
        XCTAssertTrue(archive.entryIsDirectory(directory))
        XCTAssertFalse(archive.entryIsEncrypted(file))
        XCTAssertFalse(archive.isEncrypted())
        XCTAssertEqual(archive.solidGroup(ofEntry: file), -1)
        // tar type-1 自体のデータは空だが、単独展開時は非公開 staging 内へ参照先も展開する。
        XCTAssertEqual(archive.contents(ofEntry: hardLink), Data())
        XCTAssertEqual(archive.uncompressedSize(ofEntry: hardLink), 0)
        archive.setPassword("unused-in-tar")
        XCTAssertEqual(archive.contents(ofEntry: file), payload)
        archive.setPassword(nil)

        XCTAssertNil(archive.name(ofEntry: -1))
        XCTAssertNil(archive.contents(ofEntry: Int32.max))
        XCTAssertEqual(archive.uncompressedSize(ofEntry: Int32.max), 0)
        XCTAssertFalse(archive.entryHasSize(Int32.max))
        XCTAssertFalse(archive.entryIsDirectory(Int32.max))
        XCTAssertFalse(archive.entryIsEncrypted(Int32.max))
        XCTAssertEqual(archive.solidGroup(ofEntry: Int32.max), -1)

        let output = temporary.appendingPathComponent("compat-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = output.appendingPathComponent("page.txt")
        XCTAssertTrue(archive.extractEntry(file, to: output.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)

        let newOutput = temporary.appendingPathComponent("new-output", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newOutput.path))
        XCTAssertTrue(archive.extractEntry(file, to: newOutput.path))
        XCTAssertEqual(
            try Data(contentsOf: newOutput.appendingPathComponent("page.txt")),
            payload
        )

        let hardLinkDestination = output.appendingPathComponent("page-link.txt")
        XCTAssertTrue(archive.extractEntry(hardLink, to: output.path))
        XCTAssertEqual(try Data(contentsOf: hardLinkDestination), payload)

        let newHardLinkOutput = temporary.appendingPathComponent(
            "new-hardlink-output",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: newHardLinkOutput.path))
        XCTAssertTrue(archive.extractEntry(hardLink, to: newHardLinkOutput.path))
        XCTAssertEqual(
            try Data(contentsOf: newHardLinkOutput.appendingPathComponent("page-link.txt")),
            payload
        )

        let spelledHardLinkOutput = temporary
            .appendingPathComponent("spelling", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("standardized-hardlink-output", isDirectory: true)
        XCTAssertTrue(archive.extractEntry(hardLink, to: spelledHardLinkOutput.path))
        let standardizedHardLinkOutput = temporary.appendingPathComponent(
            "standardized-hardlink-output",
            isDirectory: true
        )
        XCTAssertEqual(
            try Data(
                contentsOf: standardizedHardLinkOutput.appendingPathComponent("page-link.txt")
            ),
            payload
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: standardizedHardLinkOutput.path)
                .contains { $0.hasPrefix(".kaitokit-") }
        )

        try Data("old contents".utf8).write(to: destination)
        XCTAssertTrue(archive.extractEntry(file, to: output.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)

        let protectedDirectory = temporary.appendingPathComponent("caller-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: protectedDirectory,
            withIntermediateDirectories: false
        )
        let extractedDirectory = protectedDirectory.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extractedDirectory,
            withIntermediateDirectories: false
        )
        let sentinel = protectedDirectory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let rootDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700, .modificationDate: rootDate],
            ofItemAtPath: protectedDirectory.path
        )
        XCTAssertTrue(archive.extractEntry(directory, to: protectedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: protectedDirectory.path
        )
        XCTAssertEqual(
            (rootAttributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            0o700
        )
        XCTAssertEqual(
            try XCTUnwrap(rootAttributes[.modificationDate] as? Date).timeIntervalSince1970,
            rootDate.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertFalse(archive.extractEntry(Int32.max, to: output.path))
    }

    private func createTar(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL
    ) throws {
        try createArchive(
            sourceDirectory: sourceDirectory,
            paths: paths,
            archiveURL: archiveURL,
            format: "ustar"
        )
    }

    private func assertRestrictiveUmaskHardLinkExtraction(
        archiveURL: URL,
        output: URL
    ) throws {
        let payload = Data("restrictive umask hard-link payload\n".utf8)
        let archive = try XCTUnwrap(KaitoArchive(file: archiveURL.path))
        let hardLinkIndex = try XCTUnwrap(
            (0..<archive.numberOfEntries()).first {
                archive.name(ofEntry: $0) == "links/copy.txt"
            }
        )

        XCTAssertTrue(archive.extractEntry(hardLinkIndex, to: output.path))
        XCTAssertEqual(try mode(of: output), 0o500)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: output.path)
                .contains { $0.hasPrefix(".kaitokit-") }
        )

        let extractedParent = output.appendingPathComponent("links", isDirectory: true)
        XCTAssertEqual(try mode(of: extractedParent), 0)
        guard Darwin.chmod(extractedParent.path, mode_t(0o700)) == 0 else {
            throw KaitoError.io(errno)
        }
        XCTAssertEqual(
            try Data(contentsOf: extractedParent.appendingPathComponent("copy.txt")),
            payload
        )
    }

    private func runCurrentTestWithRestrictiveUmask(
        archiveURL: URL,
        output: URL
    ) throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "umask 0777; exec \"$@\"",
            "kaitokit-compat-restrictive-umask",
            "/usr/bin/xcrun",
            "xctest",
            "-XCTest",
            "KaitoKitCompatTests.KaitoArchiveCompatTests/" +
                "testRestrictiveUmaskHardLinkStagingIsRemovedAndDestinationModeIsRestored",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.restrictiveUmaskChild] = "1"
        environment[Self.restrictiveUmaskArchive] = archiveURL.path
        environment[Self.restrictiveUmaskOutput] = output.path
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let outputText = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let errorText = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CompatTestError.commandFailed(outputText + errorText)
        }
    }

    private func mode(of url: URL) throws -> UInt16 {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        return UInt16(information.st_mode & mode_t(0o7777))
    }

    private func createArchive(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL,
        format: String
    ) throws {
        try runCommand(
            executable: "/usr/bin/bsdtar",
            arguments: [
                "-cf", archiveURL.path,
                "--format", format,
                "-C", sourceDirectory.path,
            ] + paths
        )
    }

    private func runCommand(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CompatTestError.commandFailed(message)
        }
    }

    private func makeUnknownSizeRAR5(payload: Data) -> Data {
        let fileFlags: UInt64 = 0x000c // data CRC plus unknown unpacked size
        let name = Array("unknown.txt".utf8)
        var specific = rar5VInt(fileFlags)
        specific += rar5VInt(UInt64(payload.count)) // ignored when bit 3 is set
        specific += rar5VInt(0) // attributes
        appendLittleEndian(CRC32.checksum(payload), to: &specific)
        specific += rar5VInt(0) // stored compression information
        specific += rar5VInt(1) // Unix host
        specific += rar5VInt(UInt64(name.count))
        specific += name

        var archive = Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00])
        archive.append(rar5Block(type: 1, specific: rar5VInt(0)))
        archive.append(rar5Block(type: 2, specific: specific, data: payload))
        archive.append(rar5Block(type: 5, specific: rar5VInt(0)))
        return archive
    }

    private func rar5Block(type: UInt64, specific: [UInt8], data: Data = Data()) -> Data {
        let flags: UInt64 = data.isEmpty ? 0 : 0x0002
        var body = rar5VInt(type) + rar5VInt(flags)
        if !data.isEmpty {
            body += rar5VInt(UInt64(data.count))
        }
        body += specific

        let size = rar5VInt(UInt64(body.count))
        let covered = size + body
        var result = Data()
        var checksum: [UInt8] = []
        appendLittleEndian(CRC32.checksum(Data(covered)), to: &checksum)
        result.append(contentsOf: checksum)
        result.append(contentsOf: covered)
        result.append(data)
        return result
    }

    private func rar5VInt(_ value: UInt64) -> [UInt8] {
        var remainder = value
        var result: [UInt8] = []
        repeat {
            var byte = UInt8(remainder & 0x7f)
            remainder >>= 7
            if remainder != 0 { byte |= 0x80 }
            result.append(byte)
        } while remainder != 0
        return result
    }

    private func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

private enum CompatTestError: Error {
    case commandFailed(String)
}
