import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class ExtractionDirectoryCacheTests: XCTestCase {
    private func reader() throws -> ArchiveReader {
        try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "folder/first", contents: Data("first".utf8)),
            HandTarEntry(name: "folder/second", contents: Data("second".utf8)),
        ]))
    }

    func testReplacedRootDoesNotReuseThePreviousDirectoryTree() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("output")
        let previous = temporary.appendingPathComponent("previous")
        let replacement = temporary.appendingPathComponent("replacement")
        let reader = try reader()
        _ = try reader.extract(reader.entries[0], to: root)
        try FileManager.default.createDirectory(
            at: replacement.appendingPathComponent("folder"),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: root, to: previous)
        try FileManager.default.moveItem(at: replacement, to: root)
        _ = try reader.extract(reader.entries[1], to: root)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("folder/second")),
            Data("second".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: previous.appendingPathComponent("folder/second").path
        ))
    }

    func testCachedParentCannotBecomeASymbolicLinkPivot() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("output")
        let moved = temporary.appendingPathComponent("moved")
        let reader = try reader()
        _ = try reader.extract(reader.entries[0], to: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("folder"), to: moved)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("folder").path,
            withDestinationPath: moved.path
        )
        XCTAssertThrowsError(try reader.extract(reader.entries[1], to: root))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("second").path
        ))
    }

    func testCachedParentWithChangedModeIsReopenedAndRestored() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        let root = temporary.appendingPathComponent("output")
        let folder = root.appendingPathComponent("folder")
        defer {
            _ = Darwin.chmod(folder.path, mode_t(0o700))
            try? FileManager.default.removeItem(at: temporary)
        }
        let reader = try reader()
        _ = try reader.extract(reader.entries[0], to: root)
        guard Darwin.chmod(folder.path, mode_t(0o500)) == 0 else { throw KaitoError.io(errno) }
        _ = try reader.extract(reader.entries[1], to: root)
        var information = stat()
        guard Darwin.lstat(folder.path, &information) == 0 else { throw KaitoError.io(errno) }
        XCTAssertEqual(information.st_mode & 0o7777, 0o500)
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("second")),
            Data("second".utf8)
        )
    }
}
