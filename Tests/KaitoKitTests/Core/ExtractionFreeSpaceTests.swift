import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ExtractionFreeSpaceTests: XCTestCase {
    func testDeclaredSizeChecksExactBoundaryAndLeavesOldFileOnFailure() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data([1, 2, 3])
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "file", contents: payload)
        ]))
        let file = root.appendingPathComponent("file")
        try Data([9]).write(to: file)
        var options = ExtractionOptions()
        options.destinationFreeSpaceReserve = 10
        try Extractor.$availableDestinationSpace.withValue({ _ in 12 }) {
            XCTAssertThrowsError(try reader.extract(reader.entries[0], to: root, options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("destination free space"))
            }
            XCTAssertEqual(try Data(contentsOf: file), Data([9]))
        }
        try Extractor.$availableDestinationSpace.withValue({ _ in 13 }) {
            _ = try reader.extract(reader.entries[0], to: root, options: options)
        }
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func testUnknownOutputRechecksActualWritesAndCleansUpTemporaryFile() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 1, count: 2 << 20)
        let reader = try ArchiveReader.open(data: RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "unknown", contents: payload, fileFlags: 0x0008)
        ]))
        XCTAssertNil(reader.entries[0].uncompressedSize)
        var options = ExtractionOptions()
        options.destinationFreeSpaceReserve = 32
        let checks = Mutex(0)
        try Extractor.$availableDestinationSpace.withValue({ _ in
            checks.withLock { count in
                count += 1
                return count <= 2 ? UInt64.max : 32
            }
        }) {
            XCTAssertThrowsError(try reader.extract(reader.entries[0], to: root, options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("destination free space"))
            }
        }
        XCTAssertEqual(checks.withLock { $0 }, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testFilesystemMaximumAppliesToDeclaredAndUnknownSizes() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data([1, 2, 3])
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "known", contents: data)])
        let unknown = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "unknown", contents: data, attributes: 0o100644, fileFlags: 0x0008)
        ])
        var options = ExtractionOptions()
        options.destinationFreeSpaceReserve = 0
        for reader in [try ArchiveReader.open(data: tar), try ArchiveReader.open(data: unknown)] {
            let entry = reader.entries[0]
            try Extractor.$maximumDestinationFileSize.withValue({ _ in 2 }) {
                XCTAssertThrowsError(try reader.extract(entry, to: root, options: options)) {
                    XCTAssertEqual($0 as? KaitoError, .io(EFBIG))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.name).path))
            }
            let out = try Extractor.$maximumDestinationFileSize.withValue({ _ in 3 }) {
                try reader.extract(entry, to: root, options: options)
            }
            XCTAssertEqual(try Data(contentsOf: out), data)
        }
    }

    func testHardLinkWriteFailureRestoresTargetAndKeepsExistingDestination() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldData = Data(repeating: 0x31, count: 1 << 19)
        let newData = Data(repeating: 0x42, count: 2 << 20)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "target", contents: oldData, mode: 0o400),
            HandTarEntry(name: "first-link", type: 0x31, linkName: "target"),
            HandTarEntry(name: "second-link", contents: newData, type: 0x31, linkName: "target"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let target = try reader.extract(reader.entries[0], to: root)
        let first = try reader.extract(reader.entries[1], to: root)
        let second = root.appendingPathComponent("second-link")
        let existing = Data("keep this file".utf8)
        try existing.write(to: second)
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        var options = ExtractionOptions()
        options.destinationFreeSpaceReserve = 0
        let sawPartialWrite = Mutex(false)
        try Extractor.$availableDestinationSpace.withValue({ fd in
            // The target's file offset advances only after the first real write succeeds.
            if Darwin.lseek(fd, 0, SEEK_CUR) > 0 {
                sawPartialWrite.withLock { $0 = true }
                return 0
            }
            return .max
        }) {
            XCTAssertThrowsError(try reader.extract(reader.entries[2], to: root, options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("destination free space"))
            }
        }
        XCTAssertTrue(sawPartialWrite.withLock { $0 })
        for url in [target, first] {
            XCTAssertEqual(try Data(contentsOf: url), oldData)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            for key: FileAttributeKey in [.systemFileNumber, .posixPermissions, .modificationDate] {
                XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject)
            }
        }
        XCTAssertEqual(try Data(contentsOf: second), existing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                       ["first-link", "second-link", "target"])
        _ = try reader.extract(reader.entries[2], to: root)
        for url in [target, first, second] { XCTAssertEqual(try Data(contentsOf: url), newData) }
    }

    func testHardLinkBackupOnVolumeWithoutCloningRestoresTruncatedTail() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original")
        let oldData = Data("old data including the tail".utf8)
        try oldData.write(to: url)
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { _ = Darwin.close(parent) }
        var original = stat()
        XCTAssertEqual(Darwin.fstat(file.fileDescriptor, &original), 0)
        var spaceChecks: [UInt64] = []
        XCTAssertThrowsError(try HardLinkContentBackup.withBackup(
            of: file.fileDescriptor, status: original, below: parent,
            clone: { _, _, _ in errno = ENOTSUP; return -1 },
            checkSpace: { spaceChecks.append($0) }
        ) {
            try file.write(contentsOf: Data("new".utf8))
            try file.truncate(atOffset: 3)
            throw KaitoError.io(EIO)
        }) { XCTAssertEqual($0 as? KaitoError, .io(EIO)) }
        XCTAssertEqual(spaceChecks, [UInt64(oldData.count), UInt64(oldData.count)])
        XCTAssertEqual(try Data(contentsOf: url), oldData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original"])
    }

    func testDisabledCheckAndResourceForkPreflight() throws {
        let root = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "file/..namedfork/rsrc", contents: Data([1]))
        ]))
        let entry = reader.entries[0]
        let fork = try Extractor.$availableDestinationSpace.withValue({ _ in
            XCTFail("unexpected free-space query")
            return 0
        }) { try reader.extract(entry, to: root) }
        try Data([9]).write(to: fork)
        var options = ExtractionOptions()
        options.destinationFreeSpaceReserve = .max
        XCTAssertThrowsError(try reader.extract(entry, to: root, options: options)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("destination free space"))
        }
        XCTAssertEqual(try Data(contentsOf: fork), Data([9]))
    }
}
