import Darwin
import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import Synchronization
import XCTest

final class TarEditingSnapshotTests: XCTestCase {
    func testSourcesStagingReopenAndConcurrentReads() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data(repeating: 65, count: 1024))])
        let variants: [(String, TarContainer, Data)] = [
            ("tar", .plain, tar), ("tgz", .gzip, try CompressedTarFramingTestSupport.gzip(tar).data),
            ("tbz", .bzip2, try CompressedTarFramingTestSupport.bzip2(tar).data), ("txz", .xz, try CompressedTarFramingTestSupport.xz(tar).data)]
        for (suffix, container, bytes) in variants {
            for disk in [false, true] {
                let url = directory.appendingPathComponent("archive." + suffix); try bytes.write(to: url)
                var limits = ReadLimits(); if disk { limits.inMemorySingleFileLimit = 0 }
                var options = ReaderOptions(limits: limits, appleDoublePolicy: .expose); options.recordsTarEditLayout = true
                let source = try FileByteSource(url: url)
                let reader = try ArchiveReader.open(source: source, sourceURL: url, options: options)
                let snapshot = try XCTUnwrap(reader.tarEditingSnapshot())
                XCTAssertEqual(snapshot.container, container); XCTAssertEqual(snapshot.image.length, UInt64(tar.count))
                XCTAssertEqual(snapshot.archiveIdentity, try source.fileIdentity()); XCTAssertTrue(snapshot.archiveIsUnchanged())
                XCTAssertEqual(try TarEditTestSupport.bytes(snapshot.image), tar)
                if container != .plain { XCTAssertEqual(snapshot.image is FileByteSource, disk) }
                let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
                let reopened = try reader.reopen(), again = try XCTUnwrap(reopened.tarEditingSnapshot())
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, descriptors)
                XCTAssertEqual(again.chunkMap, snapshot.chunkMap)
                XCTAssertTrue(again.archive as AnyObject === snapshot.archive as AnyObject)
                XCTAssertTrue(again.image as AnyObject === snapshot.image as AnyObject)
                let failures = Mutex<[String]>([])
                DispatchQueue.concurrentPerform(iterations: 16) { _ in
                    do {
                        if try TarEditTestSupport.bytes(snapshot.image) != tar || snapshot.headerGroup(ofMember: 0).headerOffset != 0 {
                            failures.withLock { $0.append("snapshot bytes") }
                        }
                    } catch { failures.withLock { $0.append(String(describing: error)) } }
                }
                XCTAssertTrue(failures.withLock { $0.isEmpty })
                let counting = CountingByteSource(source)
                let wrapped = try ArchiveReader.open(source: counting, sourceURL: url, options: options)
                XCTAssertNil(wrapped.tarEditingSnapshot()?.archiveIdentity)
                XCTAssertFalse(try XCTUnwrap(wrapped.tarEditingSnapshot()).archiveIsUnchanged())
                counting.reset()
                _ = try wrapped.reopen().tarEditingSnapshot()
                XCTAssertEqual(counting.bytesRead, 0)
            }
        }
    }

    func testDescriptorIdentityIgnoresPathReplacementAndAttributeRestoration() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.tar"), renamed = directory.appendingPathComponent("renamed.tar")
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file")]); try tar.write(to: url)
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let snapshot = try XCTUnwrap(ArchiveReader.open(url: url, options: options).tarEditingSnapshot())
        try FileManager.default.moveItem(at: url, to: renamed)
        XCTAssertTrue(snapshot.archiveIsUnchanged())
        XCTAssertEqual(chmod(renamed.path, 0o640), 0)
        let value = Data([1, 2, 3])
        XCTAssertEqual(value.withUnsafeBytes { setxattr(renamed.path, "com.kaitokit.snapshot", $0.baseAddress, $0.count, 0, 0) }, 0)
        XCTAssertTrue(snapshot.archiveIsUnchanged())
        try tar.write(to: url)
        XCTAssertNotEqual(try FileByteSource(url: url).fileIdentity(), snapshot.archiveIdentity)
        XCTAssertTrue(snapshot.archiveIsUnchanged())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)], ofItemAtPath: renamed.path)
        XCTAssertFalse(snapshot.archiveIsUnchanged())

        let second = try XCTUnwrap(ArchiveReader.open(url: renamed, options: options).tarEditingSnapshot())
        let handle = try FileHandle(forWritingTo: renamed); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertFalse(second.archiveIsUnchanged())
    }

    func testSplitCpioOtherCodecsAndIdentityChangesDuringOpen() throws {
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1]))])
        let compressed = try CompressedTarFramingTestSupport.gzip(tar).data
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<3 {
            try Data(compressed[(compressed.count * i / 3)..<(compressed.count * (i + 1) / 3)]).write(to: directory.appendingPathComponent(String(format: "archive.tar.gz.%03d", i + 1)))
        }
        let split = try ArchiveReader.open(url: directory.appendingPathComponent("archive.tar.gz.001"), options: options)
        XCTAssertEqual(split.volumeSet?.volumes.count, 3); XCTAssertNil(split.tarEditingSnapshot())
        var cpio = CpioArchiveBuilder(); cpio.record(); cpio.trailer()
        XCTAssertNil(try ArchiveReader.open(data: cpio.data, options: options).tarEditingSnapshot())
        let cpgz = try CompressedTarFramingTestSupport.gzip(cpio.data).data
        XCTAssertNil(try ArchiveReader.open(source: DataByteSource(cpgz), sourceURL: URL(fileURLWithPath: "/x.cpgz"), options: options).tarEditingSnapshot())
        for input in try TarGoldenCorpus.inputs() where input.origin == "existing" && ["tar.zst", "tar.lz", "tar.br", "tar.lz4", "tar.Z"].contains(input.suffix) {
            let snapshot = try TarEditTestSupport.snapshot(TarGoldenCorpus.decoded(input), suffix: input.suffix)
            guard case .other(let format) = snapshot.container else { return XCTFail(input.id) }
            XCTAssertEqual(snapshot.chunkMapUnavailableReason, .unsupportedCodec(format))
            XCTAssertNotNil(snapshot.layout)
        }
        for (suffix, bytes) in [("tar", tar), ("tgz", compressed)] {
            let source = ChangingIdentitySource(bytes)
            let snapshot = try XCTUnwrap(ArchiveReader.open(source: source, sourceURL: URL(fileURLWithPath: "/x." + suffix), options: options).tarEditingSnapshot())
            XCTAssertNil(snapshot.archiveIdentity); XCTAssertNil(snapshot.chunkMap)
            XCTAssertEqual(snapshot.chunkMapUnavailableReason, .archiveChangedDuringOpen)
            XCTAssertFalse(snapshot.archiveIsUnchanged())
        }
    }
}

private final class ChangingIdentitySource: ByteSourceFileIdentityProviding {
    let source: DataByteSource
    let calls = Mutex<Int64>(0)
    init(_ data: Data) { source = DataByteSource(data) }
    var length: UInt64 { source.length }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int { try source.read(into: buffer, at: offset) }
    func currentFileIdentity() throws -> ByteSourceFileIdentity {
        let version = calls.withLock { value in defer { value += 1 }; return value }
        return ByteSourceFileIdentity(device: 1, inode: 2, size: length, modificationSeconds: version, modificationNanoseconds: 0)
    }
}
