import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class ResourceForkExtractionTests: XCTestCase {
    func testResourceOnlyCreatesEmptyDataFileAndReturnsItsIdentity() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = Data((0..<600_003).map { UInt8(truncatingIfNeeded: $0) })
        // formatSpecific に fork がなくても、file と末尾 2 成分で認識する。
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "nested/image/..namedfork/rsrc", contents: payload),
        ]))
        let result = try Extractor.extract(
            reader.entries[0], from: reader, to: temporary,
            options: ExtractionOptions(overwriteExisting: false), trustedTargets: [:]
        )
        let dataURL = temporary.appendingPathComponent("nested/image")
        let information = try status(dataURL)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(information.st_size, 0)
        XCTAssertEqual(result.fileIdentity, ExtractedFileIdentity(
            device: information.st_dev, inode: information.st_ino, generation: information.st_gen
        ))
        XCTAssertEqual(result.url, dataURL.appendingPathComponent("..namedfork/rsrc"))
        XCTAssertEqual(try Data(contentsOf: result.url), payload)
        XCTAssertEqual(try resourceAttribute(dataURL), payload)
    }

    func testDataAndResourceOverwritePolicyAndTruncation() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = Array("original data fork".utf8)
        let resource = Array("original resource fork".utf8)
        let reader = try ArchiveReader.open(data: StuffItContainerTests.sit5(payload: data, resource: resource))
        let resourceEntry = reader.entries[0]
        let dataEntry = reader.entries[1]
        let noOverwrite = ExtractionOptions(overwriteExisting: false)
        let dataURL = try reader.extract(dataEntry, to: temporary, options: noOverwrite)
        let originalInode = try status(dataURL).st_ino
        let resourceURL = try reader.extract(resourceEntry, to: temporary, options: noOverwrite)
        for entry in [dataEntry, resourceEntry] {
            XCTAssertThrowsError(try reader.extract(entry, to: temporary, options: noOverwrite)) {
                XCTAssertEqual($0 as? KaitoError, .io(EEXIST))
            }
        }
        XCTAssertEqual(try Data(contentsOf: dataURL), Data(data))
        XCTAssertEqual(try Data(contentsOf: resourceURL), Data(resource))

        let replacement = try ArchiveReader.open(data: StuffItContainerTests.sit5(payload: [1, 2], resource: [3]))
        let overwrite = ExtractionOptions(overwriteExisting: true)
        _ = try replacement.extract(replacement.entries[0], to: temporary, options: overwrite)
        XCTAssertEqual(try Data(contentsOf: dataURL), Data(data))
        XCTAssertEqual(try Data(contentsOf: resourceURL), Data([3]))
        XCTAssertEqual(try status(dataURL).st_ino, originalInode)
        _ = try replacement.extract(replacement.entries[1], to: temporary, options: overwrite)
        XCTAssertNotEqual(try status(dataURL).st_ino, originalInode)
        _ = try replacement.extract(replacement.entries[0], to: temporary, options: overwrite)
        XCTAssertEqual(try Data(contentsOf: dataURL), Data([1, 2]))
        XCTAssertEqual(try resourceAttribute(dataURL), Data([3]))
    }

    func testEmptyExistingResourceForkAllowsFirstNonemptyWrite() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: StuffItContainerTests.sit5(resource: [67]))
        let dataURL = try reader.extract(reader.entries[1], to: temporary)
        let forkURL = dataURL.appendingPathComponent("..namedfork/rsrc")
        let descriptor = Darwin.open(forkURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o666))
        guard descriptor >= 0 else { throw KaitoError.io(errno) }
        _ = Darwin.close(descriptor)
        _ = try reader.extract(reader.entries[0], to: temporary, options: ExtractionOptions(overwriteExisting: false))
        XCTAssertEqual(try Data(contentsOf: dataURL), Data([65, 66]))
        XCTAssertEqual(try Data(contentsOf: forkURL), Data([67]))
    }

    func testResourceForkRejectsSymlinkAndDirectoryDataTargets() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outside = temporary.appendingPathComponent("outside")
        let sentinel = Data("outside data".utf8)
        try sentinel.write(to: outside)
        let outsideFork = outside.appendingPathComponent("..namedfork/rsrc")
        try Data("outside resource".utf8).write(to: outsideFork)
        let reader = try ArchiveReader.open(data: StuffItContainerTests.sit5(resource: [67]))
        for overwrite in [false, true] {
            for target in [outside, temporary.appendingPathComponent("missing")] {
                let output = temporary.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let leaf = output.appendingPathComponent("A")
                try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
                XCTAssertThrowsError(try reader.extract(reader.entries[0], to: output,
                    options: ExtractionOptions(overwriteExisting: overwrite))) {
                    XCTAssertEqual($0 as? KaitoError, .io(ELOOP))
                }
                XCTAssertEqual(try status(leaf).st_mode & S_IFMT, S_IFLNK)
            }
            let output = temporary.appendingPathComponent(UUID().uuidString)
            let leaf = output.appendingPathComponent("A")
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
            XCTAssertThrowsError(try reader.extract(reader.entries[0], to: output,
                options: ExtractionOptions(overwriteExisting: overwrite))) {
                XCTAssertEqual($0 as? KaitoError, .io(EISDIR))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: leaf.path), [])
        }
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        XCTAssertEqual(try Data(contentsOf: outsideFork), Data("outside resource".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("missing").path))
    }

    func testResourceWritePreservesTrustedHardLinkTarget() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "image", contents: Data([1, 2])),
            HandTarEntry(name: "image/..namedfork/rsrc", contents: Data([3, 4])),
            HandTarEntry(name: "alias", type: 0x31, linkName: "image"),
        ]))
        for entry in reader.entries { _ = try reader.extract(entry, to: temporary) }
        let dataURL = temporary.appendingPathComponent("image")
        let aliasURL = temporary.appendingPathComponent("alias")
        XCTAssertEqual(try status(dataURL).st_ino, try status(aliasURL).st_ino)
        XCTAssertEqual(try Data(contentsOf: aliasURL), Data([1, 2]))
        XCTAssertEqual(try resourceAttribute(aliasURL), Data([3, 4]))
    }

    func testOtherNamedForkPathsRemainOrdinaryPathsAndTraversalIsRejected() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "directory/..namedfork/rsrc", type: 0x35),
            HandTarEntry(name: "other/..namedfork/notes", contents: Data([1])),
            HandTarEntry(name: "longer/..namedfork/rsrc/tail", contents: Data([2])),
            HandTarEntry(name: "..namedfork/rsrc", contents: Data([3])),
            HandTarEntry(name: "../escape/..namedfork/rsrc", contents: Data([4])),
        ]))
        for entry in reader.entries.prefix(3) { _ = try reader.extract(entry, to: temporary) }
        // macOS の複合 fork path 解釈を避け、一成分ずつ開いて実 directory を確認する。
        let root = try ExtractionDirectoryAccess.openRoot(at: temporary.path)
        defer { root.close() }
        let directory = try ExtractionDirectoryAccess.open(
            ["directory", "..namedfork", "rsrc"], below: root.descriptor, create: false
        )
        defer { directory.close() }
        var information = stat()
        XCTAssertEqual(Darwin.fstat(directory.descriptor, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("other/..namedfork/notes")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("longer/..namedfork/rsrc/tail")), Data([2]))
        for entry in reader.entries.suffix(2) {
            XCTAssertThrowsError(try reader.extract(entry, to: temporary)) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("..namedfork").path))
    }

    private func status(_ url: URL) throws -> stat {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else { throw KaitoError.io(errno) }
        return information
    }

    private func resourceAttribute(_ url: URL) throws -> Data {
        let size = Darwin.getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw KaitoError.io(errno) }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes {
            Darwin.getxattr(url.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard count == size else { throw KaitoError.io(errno) }
        return data
    }
}
