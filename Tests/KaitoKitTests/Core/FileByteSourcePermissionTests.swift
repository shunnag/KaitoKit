import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class FileByteSourcePermissionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = try TarTestSupport.temporaryDirectory()
        addTeardownBlock {
            // 途中で失敗しても、削除前に親の読み取り・書き込み権限を復元する。
            XCTAssertEqual(Darwin.chmod(directory.path, mode_t(0o700)), 0)
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeExecuteOnly(_ directory: URL) throws {
        XCTAssertEqual(Darwin.chmod(directory.path, mode_t(0o111)), 0)
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let code = errno
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
        // root 等で権限制限を再現できない実行を、fallback の成功と取り違えない。
        XCTAssertEqual(descriptor, -1)
        XCTAssertEqual(code, EACCES)
    }

    func testExecuteOnlyParentOpensArchiveAndPublicFileByteSource() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("small.a")
        var builder = ArArchiveBuilder()
        builder.member("page.txt", payload: Array("page\n".utf8))
        try builder.data.write(to: url)
        try makeExecuteOnly(directory)

        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.format, .ar)
        XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), Data("page\n".utf8))

        let source = try FileByteSource(url: url)
        XCTAssertEqual(try readByteRange(source: source, offset: 0, count: builder.bytes.count), builder.bytes)
        XCTAssertNil(try FileByteSource.openAnchored(url: url).directory)
    }

    func testReadableParentRetainsWorkingDirectoryAnchorForRARVolumes() throws {
        let directory = try temporaryDirectory()
        let firstURL = directory.appendingPathComponent("small.part1.rar")
        let secondURL = directory.appendingPathComponent("small.part2.rar")
        try RAR5TestSupport.archive(mainFlags: 1, endFlags: 1, blocks: []).write(to: firstURL)
        try RAR5TestSupport.archive(mainFlags: 3, mainVolumeNumber: 1, blocks: [
            RAR5TestSupport.storedFile(rawName: Array("page.txt".utf8), contents: Data("page\n".utf8))
        ]).write(to: secondURL)

        let opened = try FileByteSource.openAnchored(url: firstURL)
        let anchor = try XCTUnwrap(opened.directory)
        let locator = try RARVolumeLocator(
            firstVolumeURL: firstURL,
            firstVolumeSource: opened.source,
            firstVolumeDirectory: anchor,
            naming: .rar5
        )
        XCTAssertEqual(try locator.locate(volumeNumber: 1).url, secondURL)
        let reader = try ArchiveReader.open(url: firstURL)
        XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), Data("page\n".utf8))
    }

    func testExecuteOnlyParentReportsUnsupportedMultiVolumeRAR() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("small.part1.rar")
        try RAR5TestSupport.archive(mainFlags: 1, endFlags: 1, blocks: []).write(to: url)
        try makeExecuteOnly(directory)

        let opened = try FileByteSource.openAnchored(url: url)
        XCTAssertNil(opened.directory)
        let locator = try RARVolumeLocator(
            firstVolumeURL: url,
            firstVolumeSource: opened.source,
            firstVolumeDirectory: opened.directory,
            naming: .rar5
        )
        let directLocator = try RARVolumeLocator(firstVolumeURL: url, naming: .rar5)
        for locator in [locator, directLocator] {
            XCTAssertEqual(try locator.locate(volumeNumber: 0).number, 0)
            XCTAssertThrowsError(try locator.locate(volumeNumber: 1)) { error in
                XCTAssertEqual(error as? KaitoError, .unsupportedMethod("multi-volume from Data"))
            }
        }
        XCTAssertThrowsError(try ArchiveReader.open(url: url)) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedMethod("multi-volume from Data"))
        }
    }

    func testMissingParentPreservesENOENT() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("missing/small.a")
        XCTAssertThrowsError(try FileByteSource(url: url)) { error in
            XCTAssertEqual(error as? KaitoError, .io(ENOENT))
        }
        XCTAssertThrowsError(try ArchiveReader.open(url: url)) { error in
            XCTAssertEqual(error as? KaitoError, .io(ENOENT))
        }
    }

    @MainActor
    func testReopenedReaderCanBeSentFromActorToExtractionWorker() async throws {
        var builder = ArArchiveBuilder()
        builder.member("page.txt", payload: Array("page\n".utf8))
        let session = try ReaderSession(data: builder.data)
        let reopened = try await session.reopen()
        let payload = try await Task.detached {
            try reopened.read(XCTUnwrap(reopened.entries.first))
        }.value
        XCTAssertEqual(payload, Data("page\n".utf8))
        let originalPayload = try await session.readFirstEntry()
        XCTAssertEqual(originalPayload, payload)
    }

    private actor ReaderSession {
        private let reader: ArchiveReader

        init(data: Data) throws {
            reader = try ArchiveReader.open(data: data)
        }

        func reopen() throws -> sending ArchiveReader {
            try reader.reopen()
        }

        func readFirstEntry() throws -> Data {
            try reader.read(XCTUnwrap(reader.entries.first))
        }
    }
}
