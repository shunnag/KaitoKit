import Foundation
import Darwin
@_spi(TarEditLayout) internal import KaitoKit
import XCTest

final class TarEditLayoutSPIImportTests: XCTestCase {
    func testExternalIdentityProviderAndCompressedMap() throws {
        let dir = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("custom.tgz")
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1]))])
        try CompressedTarFramingTestSupport.gzip(tar).data.write(to: url)
        let source = try ExternalTarIdentitySource(url: url)
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let snapshot = try XCTUnwrap(ArchiveReader.open(source: source, sourceURL: url, options: options).tarEditingSnapshot())
        XCTAssertEqual(snapshot.archiveIdentity, try source.currentFileIdentity())
        XCTAssertTrue(snapshot.archiveIsUnchanged())
        XCTAssertEqual(snapshot.chunkMap?.chunks.count, 1)
    }
    func testSPIOnlyImport() throws {
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1]))])
        let reader = try ArchiveReader.open(data: tar, options: options)
        let snapshot: TarEditingSnapshot = try XCTUnwrap(reader.tarEditingSnapshot())
        XCTAssertEqual(snapshot.layout?.memberCount, 1)
        XCTAssertNil(snapshot.chunkMap)
        XCTAssertEqual(snapshot.chunkMapUnavailableReason, .notCompressed)
        XCTAssertEqual(try snapshot.headerGroup(ofMember: 0).headerOffset, 0)
    }
}

private final class ExternalTarIdentitySource: ByteSourceFileIdentityProviding {
    let descriptor: Int32
    let length: UInt64
    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw KaitoError.io(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw KaitoError.io(errno) }
        length = UInt64(info.st_size)
    }
    deinit { Darwin.close(descriptor) }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let count = pread(descriptor, buffer.baseAddress, min(buffer.count, Int(length - offset)), off_t(offset))
        guard count >= 0 else { throw KaitoError.io(errno) }; return count
    }
    func currentFileIdentity() throws -> ByteSourceFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw KaitoError.io(errno) }
        return ByteSourceFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), size: UInt64(info.st_size),
                                      modificationSeconds: Int64(info.st_mtimespec.tv_sec), modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}
