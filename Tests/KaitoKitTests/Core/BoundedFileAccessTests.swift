import Darwin
import Foundation
import os
@testable import KaitoKit
import XCTest

final class BoundedFileAccessTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = try TarTestSupport.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func descriptors() -> Int {
        (0..<4096).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }

    func testHundredsOfRetainedReadersKeepBoundedDescriptorsAndParsedEntries() throws {
        let root = try directory()
        var builder = ArArchiveBuilder()
        builder.member("page.txt", payload: Array("page\n".utf8))
        var options = ReaderOptions()
        options.fileAccessPolicy = .bounded
        let initial = descriptors()
        var readers: [ArchiveReader] = []
        for index in 0..<400 {
            let url = root.appendingPathComponent("\(index).a")
            try builder.data.write(to: url)
            readers.append(try ArchiveReader.open(url: url, options: options))
        }
        XCTAssertLessThanOrEqual(descriptors() - initial, 70)
        for index in [0, 399, 1, 200, 100, 0] {
            let reader = readers[index]
            XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
            XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), Data("page\n".utf8))
        }
        let copy = try readers[0].reopen()
        FileAccessPolicy.releaseIdleCachedHandles()
        XCTAssertEqual(try copy.read(XCTUnwrap(copy.entries.first)), Data("page\n".utf8))
        readers.removeAll()
    }

    func testEvictedSourceRejectsReplacementAndSameInodeChanges() throws {
        let root = try directory()
        for replaces in [false, true] {
            let url = root.appendingPathComponent("\(replaces).bin")
            try Data("original".utf8).write(to: url)
            let source = try FileByteSource(url: url, accessPolicy: .bounded)
            FileAccessPolicy.releaseIdleCachedHandles()
            if replaces {
                let replacement = root.appendingPathComponent("replacement")
                try Data("changed!".utf8).write(to: replacement)
                XCTAssertEqual(Darwin.rename(replacement.path, url.path), 0)
            } else { try Data("longer contents".utf8).write(to: url) }
            XCTAssertThrowsError(try readByteRange(source: source, offset: 0, count: 8)) {
                XCTAssertEqual($0 as? KaitoError, .io(ESTALE))
            }
        }
    }

    func testDirectoryContentChangeIsAllowedButReplacementIsRejected() throws {
        let root = try directory()
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let url = parent.appendingPathComponent("page")
        try Data("original".utf8).write(to: url)
        let source = try FileByteSource(url: url, accessPolicy: .bounded)
        FileAccessPolicy.releaseIdleCachedHandles()
        try Data().write(to: parent.appendingPathComponent("unrelated"))
        XCTAssertEqual(try readByteRange(source: source, offset: 0, count: 8), Array("original".utf8))
        FileAccessPolicy.releaseIdleCachedHandles()
        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("old-parent"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data("replaced".utf8).write(to: url)
        XCTAssertThrowsError(try readByteRange(source: source, offset: 0, count: 8))
    }

    func testSplitZIPAndNumericVolumesSurviveIdleEviction() throws {
        let root = try directory()
        var options = ReaderOptions()
        options.fileAccessPolicy = .bounded
        let zipBytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "page", uncompressedData: Data(repeating: 42, count: 7000))])
        let split = try ZipSplitFixture(zipBytes, below: root) { [12, 2048, $0.centralDirectoryOffset + 17] }
        let reader = try ArchiveReader.open(url: split.urls.last!, options: options)
        FileAccessPolicy.releaseIdleCachedHandles()
        XCTAssertEqual(try reader.read(reader.entries[0]), Data(repeating: 42, count: 7000))
        let seven = try ZipTestSupport.checkedInFixture("sevenzip/chain-lzma-lzma-lzma2-bcj2.7z")
        let first = root.appendingPathComponent("book.7z.001")
        try seven.prefix(32).write(to: first)
        try seven.dropFirst(32).write(to: root.appendingPathComponent("book.7z.002"))
        let splitSeven = try ArchiveReader.open(url: first, options: options)
        let expected = try ArchiveReader.open(data: seven)
        FileAccessPolicy.releaseIdleCachedHandles()
        for (entry, reference) in zip(splitSeven.entries, expected.entries) {
            XCTAssertEqual(try splitSeven.read(entry), try expected.read(reference))
        }
    }

    func testRARVolumesSurviveIdleEvictionAndRefuseReplacedSibling() throws {
        let root = try directory(), first = root.appendingPathComponent("book.part1.rar")
        let second = root.appendingPathComponent("book.part2.rar")
        let firstBytes = Data("first".utf8), lastBytes = Data("last".utf8)
        let payload = firstBytes + lastBytes
        try RAR5TestSupport.archive(mainFlags: 1, endFlags: 1, blocks: [
            RAR5TestSupport.storedFile(name: "page", contents: firstBytes, fileFlags: 8, headerFlags: 16)
        ]).write(to: first)
        let tail = RAR5TestSupport.archive(mainFlags: 3, mainVolumeNumber: 1, blocks: [
            RAR5TestSupport.storedFile(name: "page", contents: lastBytes, unpackedSize: UInt64(payload.count),
                dataCRC32: CRC32.checksum(payload), headerFlags: 8)
        ])
        try tail.write(to: second)
        var options = ReaderOptions(); options.fileAccessPolicy = .bounded
        let reader = try ArchiveReader.open(url: first, options: options)
        FileAccessPolicy.releaseIdleCachedHandles()
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        let reopened = try reader.reopen()
        FileAccessPolicy.releaseIdleCachedHandles()
        let replacement = root.appendingPathComponent("replacement")
        try tail.write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, second.path), 0)
        XCTAssertThrowsError(try reopened.read(reopened.entries[0]))
    }

    func testIdentityChecksPreserveIOFailuresInsteadOfReportingChangedFiles() throws {
        let url = try directory().appendingPathComponent("file")
        try Data([1]).write(to: url)
        let opened = try FileByteSource.openAnchored(url: url, accessPolicy: .bounded)
        let directory = try XCTUnwrap(opened.directory)
        let raw = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        defer { Darwin.close(raw) }
        FileAccessPolicy.releaseIdleCachedHandles()
        var saved = rlimit(); XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        var limited = saved; limited.rlim_cur = min(saved.rlim_cur, 256)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limited), 0)
        defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }
        var fds: [Int32] = []
        while true {
            let fd = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            if fd < 0 { break }; fds.append(fd)
        }
        var failures: [KaitoError?] = []
        do { _ = try opened.source.hasSameFileIdentity(as: raw); failures.append(nil) }
        catch { failures.append(error as? KaitoError) }
        do { _ = try directory.matchesRegularFile(opened.source, named: "file"); failures.append(nil) }
        catch { failures.append(error as? KaitoError) }
        do { try directory.verifyFirstVolumeIdentity(of: opened.source, named: "file", label: "test"); failures.append(nil) }
        catch { failures.append(error as? KaitoError) }
        for fd in fds { Darwin.close(fd) }
        XCTAssertEqual(failures, [.io(EMFILE), .io(EMFILE), .io(EMFILE)])
        XCTAssertEqual(try readByteRange(source: opened.source, offset: 0, count: 1), [1])
    }

    func testPersistentSourceKeepsOriginalAcrossUnlink() throws {
        let url = try directory().appendingPathComponent("page")
        try Data("original".utf8).write(to: url)
        let source = try FileByteSource(url: url)
        try FileManager.default.removeItem(at: url)
        try Data("replaced".utf8).write(to: url)
        FileAccessPolicy.releaseIdleCachedHandles()
        XCTAssertEqual(try readByteRange(source: source, offset: 0, count: 8), Array("original".utf8))
    }

    func testBusyHandleCannotBeEvictedAndFullPoolFailsWithoutDeadlock() throws {
        let cache = FileDescriptorCache(capacity: 1)
        let descriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        let source = try InputFileDescriptor(takingOwnershipOf: descriptor, cache: cache) {
            Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        try source.withDescriptor { active in
            XCTAssertEqual(cache.releaseIdleHandles(), 0)
            let next = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertThrowsError(try InputFileDescriptor(takingOwnershipOf: next, cache: cache) {
                Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            }) { XCTAssertEqual($0 as? KaitoError, .io(EMFILE)) }
            XCTAssertNotEqual(fcntl(active, F_GETFD), -1)
        }
        XCTAssertEqual(cache.releaseIdleHandles(), 1)
        try source.withDescriptor { XCTAssertNotEqual(fcntl($0, F_GETFD), -1) }
    }

    func testSlowReopenDoesNotHoldGlobalLock() throws {
        let cache = FileDescriptorCache(capacity: 2)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: false)
        let first = try InputFileDescriptor(
            takingOwnershipOf: Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC), cache: cache) {
                entered.signal()
                resume.wait()
                return Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            }
        cache.releaseIdleHandles()
        // ロックを誤って保持した退行でもテストを永久停止させない。
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume.signal() }
        DispatchQueue.global().async {
            defer { finished.signal() }
            let success = (try? first.withDescriptor { fcntl($0, F_GETFD) >= 0 }) ?? false
            result.withLock { $0 = success }
        }
        defer { resume.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let started = Date()
        let second = try InputFileDescriptor(
            takingOwnershipOf: Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC), cache: cache) {
                Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            }
        try second.withDescriptor { XCTAssertNotEqual(fcntl($0, F_GETFD), -1) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(result.withLock { $0 })
    }

    func testSlowCloseDoesNotHoldGlobalLock() throws {
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let firstClose = OSAllocatedUnfairLock(initialState: true)
        let cache = FileDescriptorCache(capacity: 2, close: { fd in
            let pauses = firstClose.withLock { first in defer { first = false }; return first }
            if pauses { entered.signal(); resume.wait() }
            Darwin.close(fd)
        })
        let first = try InputFileDescriptor(takingOwnershipOf: Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC), cache: cache) {
            Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume.signal() }
        DispatchQueue.global().async { cache.releaseIdleHandles(); finished.signal() }
        defer { resume.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let started = Date()
        let second = try InputFileDescriptor(takingOwnershipOf: Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC), cache: cache) {
            Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        try second.withDescriptor { XCTAssertNotEqual(fcntl($0, F_GETFD), -1) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        withExtendedLifetime(first) {}
    }

    func testConcurrentReadsSurviveRepeatedIdleEviction() throws {
        let url = try directory().appendingPathComponent("page")
        let payload = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: url)
        let source = try FileByteSource(url: url, accessPolicy: .bounded)
        let failures = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index % 3 == 0 { FileAccessPolicy.releaseIdleCachedHandles() }
            do {
                let bytes = try readByteRange(source: source, offset: UInt64(index), count: 1024)
                if bytes != Array(payload[index..<index + 1024]) { failures.withLock { $0 += 1 } }
            } catch { failures.withLock { $0 += 1 } }
        }
        XCTAssertEqual(failures.withLock { $0 }, 0)
    }
}
