import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveCompatTests: XCTestCase {
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
        let destination = output.appendingPathComponent("relocated-link")

        XCTAssertFalse(archive.extractEntry(0, to: destination.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside-sentinel".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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
            case "folder/": directoryIndex = index
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

        let destination = temporary.appendingPathComponent("compat-output.txt")
        XCTAssertTrue(archive.extractEntry(file, to: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)

        let hardLinkDestination = temporary.appendingPathComponent("compat-hard-link.txt")
        XCTAssertTrue(archive.extractEntry(hardLink, to: hardLinkDestination.path))
        XCTAssertEqual(try Data(contentsOf: hardLinkDestination), payload)
        try Data("old contents".utf8).write(to: destination)
        XCTAssertTrue(archive.extractEntry(file, to: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)

        let protectedDirectory = temporary.appendingPathComponent(
            "must-not-remove",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: protectedDirectory,
            withIntermediateDirectories: false
        )
        let sentinel = protectedDirectory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertFalse(archive.extractEntry(file, to: protectedDirectory.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertFalse(archive.extractEntry(Int32.max, to: destination.path))
    }

    private func createTar(
        sourceDirectory: URL,
        paths: [String],
        archiveURL: URL
    ) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = [
            "-cf", archiveURL.path,
            "--format", "ustar",
            "-C", sourceDirectory.path,
        ] + paths
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
}

private enum CompatTestError: Error {
    case commandFailed(String)
}
