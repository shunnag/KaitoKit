import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class ArchiveVolumeSetTests: XCTestCase {
    private let payload = Data((0..<512).map { UInt8($0 % 251) })

    private func archive() throws -> Data {
        try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "payload.bin", uncompressedData: payload)])
    }

    private func temporaryDirectory() throws -> URL {
        try ZipTestSupport.temporaryDirectory(label: "volume-set")
    }

    private func numbered(_ bytes: Data, below directory: URL, width: Int = 3) throws -> [URL] {
        let parts = [Data(bytes.prefix(23)), Data(bytes[23..<260]), Data(bytes.dropFirst(260))]
        return try parts.enumerated().map { index, part in
            // 期待する名前は reader の命名 helper から生成しない。
            try ZipTestSupport.write(part,
                relativePath: "sample.zip." + String(repeating: "0", count: width - 1) + String(index + 1),
                below: directory)
        }
    }

    private func information(at url: URL) throws -> stat {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else { throw KaitoError.io(errno) }
        return information
    }

    private func assertVolumes(_ set: ArchiveVolumeSet, urls: [URL],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(set.volumes.map(\.url), urls, file: file, line: line)
        XCTAssertEqual(set.volumes.count, urls.count, file: file, line: line)
        for (volume, url) in zip(set.volumes, urls) {
            let expected = try information(at: url)
            XCTAssertEqual(volume.length, UInt64(expected.st_size), file: file, line: line)
            XCTAssertEqual(volume.device, UInt64(UInt32(bitPattern: expected.st_dev)), file: file, line: line)
            XCTAssertEqual(volume.inode, UInt64(expected.st_ino), file: file, line: line)
            XCTAssertEqual(volume.mode, UInt16(expected.st_mode), file: file, line: line)
            XCTAssertEqual(volume.modificationSeconds, Int64(expected.st_mtimespec.tv_sec), file: file, line: line)
            XCTAssertEqual(volume.modificationNanoseconds, Int64(expected.st_mtimespec.tv_nsec), file: file, line: line)
        }
    }

    func testNumberedVolumesCaptureIdentityAndPreserveWidth() throws {
        for width in [3, 4] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let urls = try numbered(archive(), below: directory, width: width)
            XCTAssertEqual(Darwin.chmod(urls[1].path, 0o640), 0)
            let reader = try ArchiveReader.open(url: urls[0])
            let set = try XCTUnwrap(reader.volumeSet)
            XCTAssertEqual(set.scheme, .numbered(stem: "sample.zip", width: width))
            XCTAssertEqual(set.openedVolumeIndex, 0)
            XCTAssertEqual(set.gateIndex, 0)
            try assertVolumes(set, urls: urls)
            XCTAssertEqual(set.volumes.map(\.length), [23, 237, UInt64(try archive().count - 260)])
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(set.fileName(forVolumeAt: 1), width == 3 ? "sample.zip.002" : "sample.zip.0002")
            XCTAssertEqual(set.fileName(forVolumeAt: 998), width == 3 ? "sample.zip.999" : "sample.zip.0999")
            XCTAssertEqual(set.fileName(forVolumeAt: 999), "sample.zip.1000")
            XCTAssertEqual(set.fileName(forVolumeAt: 1000), "sample.zip.1001")
            XCTAssertEqual(set.fileName(forVolumeAt: .max), "sample.zip.9223372036854775808")
            XCTAssertEqual(set.fileName(forVolumeAt: 1, count: 1), set.fileName(forVolumeAt: 1))
            XCTAssertEqual(try reader.reopen().volumeSet, set)
        }
    }

    func testStandaloneAndNonURLInputsHaveNoVolumeSet() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try archive()
        for name in ["single.zip", "alone.zip.001", "alone.zip.0001"] {
            let url = try ZipTestSupport.write(bytes, relativePath: name, below: directory)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertNil(reader.volumeSet)
            XCTAssertNil(try reader.reopen().volumeSet)
            let source = try FileByteSource(url: url)
            XCTAssertNil(try ArchiveReader.open(source: source).volumeSet)
            XCTAssertNil(try ArchiveReader.open(source: source, sourceURL: url).volumeSet)
        }
        XCTAssertNil(try ArchiveReader.open(data: bytes).volumeSet)
        let urls = try numbered(bytes, below: directory)
        let assembled = try XCTUnwrap(SplitVolumeSet.assemble(firstVolumeURL: urls[0],
            firstVolumeSource: FileByteSource(url: urls[0]),
            directory: FileByteSource.DirectoryAnchor(path: directory.path), limits: ReadLimits()))
        // 呼び出し元が連結済み source を渡しても、ファイルからの組み立てとは報告しない。
        XCTAssertNil(try ArchiveReader.open(source: assembled.source, sourceURL: urls[0]).volumeSet)
    }

    func testExplicitSymlinkDoesNotReportOrDiscoverVolumes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try ZipTestSupport.write(archive(), relativePath: "target.zip", below: directory)
        for (first, sibling) in [("linked.zip.001", "linked.zip.002"), ("linked.z01", "linked.zip")] {
            let url = directory.appendingPathComponent(first)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            try ZipTestSupport.write(Data([0xff]), relativePath: sibling, below: directory)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertNil(reader.volumeSet)
            XCTAssertNil(try reader.reopen().volumeSet)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testNativeZIPFromFinalFirstAndMiddleVolumes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, prefix, ext) in [("split.zip", "z", "zip"), ("upper.ZIP", "Z", "ZIP"),
                                     ("extended.zipx", "zx", "zipx"), ("upperx.ZIPX", "ZX", "ZIPX")] {
            let split = try ZipSplitFixture(archive(), below: directory, name: name) { _ in [8, 110, 300] }
            let stem = (name as NSString).deletingPathExtension
            var expectedVolumes: [ArchiveVolumeSet.Volume]?
            for index in [3, 0, 2] {
                let reader = try ArchiveReader.open(url: split.urls[index])
                let set = try XCTUnwrap(reader.volumeSet)
                XCTAssertEqual(set.scheme, .zipSpanned(stem: stem, volumePrefix: prefix, lastExtension: ext))
                XCTAssertEqual(set.openedVolumeIndex, index)
                XCTAssertEqual(set.gateIndex, 3)
                try assertVolumes(set, urls: split.urls)
                if let expectedVolumes { XCTAssertEqual(set.volumes, expectedVolumes) }
                expectedVolumes = set.volumes
                XCTAssertEqual(try reader.read(reader.entries[0]), payload)
                XCTAssertEqual(try reader.reopen().volumeSet, set)
                XCTAssertEqual(set.fileName(forVolumeAt: 3), name)
                XCTAssertEqual(set.fileName(forVolumeAt: 98), stem + "." + prefix + "99")
                XCTAssertEqual(set.fileName(forVolumeAt: 99), stem + "." + prefix + "100")
                XCTAssertEqual(set.fileName(forVolumeAt: .max), stem + "." + prefix + "9223372036854775808")
                // 巻数が増えると元の最終巻の位置に番号が付き、最終巻名は新しい末尾へ動く。
                XCTAssertEqual(set.fileName(forVolumeAt: 3, count: 5), stem + "." + prefix + "04")
                XCTAssertEqual(set.fileName(forVolumeAt: 4, count: 5), name)
                XCTAssertEqual(set.fileName(forVolumeAt: 1, count: 2), name)
                XCTAssertEqual(set.fileName(forVolumeAt: 0, count: 1), name)
                XCTAssertEqual(set.fileName(forVolumeAt: 4, count: 2), stem + "." + prefix + "05")
            }
        }
    }

    func testZIPFinalExtensionAndPerVolumeCaseArePreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try ZipSplitFixture(archive(), below: directory, name: "mixed.ZiPx") { _ in [8, 110] }
        let reader = try ArchiveReader.open(url: split.urls[2])
        let set = try XCTUnwrap(reader.volumeSet)
        XCTAssertEqual(set.scheme, .zipSpanned(stem: "mixed", volumePrefix: "ZX", lastExtension: "ZiPx"))
        XCTAssertEqual(set.fileName(forVolumeAt: 2), "mixed.ZiPx")
        XCTAssertEqual(set.fileName(forVolumeAt: 3, count: 4), "mixed.ZiPx")

        // 大小文字混在の既存巻名は、出力の巻数が変わっても正規化しない。
        let mixedURL = try ZipTestSupport.write(Data(), relativePath: "mixed.zx02", below: directory)
        let mixed = ArchiveVolumeSet(scheme: set.scheme,
            volumes: [set.volumes[0], try FileByteSource(url: mixedURL).volume(at: mixedURL), set.volumes[2]],
            openedVolumeIndex: 2)
        XCTAssertEqual(mixed.fileName(forVolumeAt: 1), "mixed.zx02")
        XCTAssertEqual(mixed.fileName(forVolumeAt: 1, count: 4), "mixed.zx02")
        XCTAssertEqual(mixed.fileName(forVolumeAt: 2, count: 4), "mixed.ZX03")
    }

    func testParseNamesWithoutIO() throws {
        for (name, stem, width, index) in [("a.tar.gz.001", "a.tar.gz", 3, 0), ("a.003", "a", 3, 2),
                                            ("a.0002", "a", 4, 1), ("a.999", "a", 3, 998),
                                            ("a.1000", "a", 4, 999),
                                            ("a.9223372036854775808", "a", 19, Int.max)] {
            let parsed = try XCTUnwrap(ArchiveVolumeSet.parse(fileName: name))
            XCTAssertEqual(parsed.scheme, .numbered(stem: stem, width: width))
            XCTAssertEqual(parsed.index, index)
            XCTAssertEqual(parsed.scheme.fileName(forVolumeAt: index, count: 1), name)
            XCTAssertEqual(parsed.scheme.fileName(forVolumeAt: 0, count: 1),
                           stem + "." + String(repeating: "0", count: width - 1) + "1")
        }
        for (name, prefix, ext, index) in [("a.z01", "z", "zip", 0), ("a.Z03", "Z", "ZIP", 2),
                                           ("a.zx99", "zx", "zipx", 98), ("a.ZX100", "ZX", "ZIPX", 99),
                                           ("a.zx001", "zx", "zipx", 0), ("a.zX01", "zx", "zipx", 0),
                                           ("a.zip", "z", "zip", -1), ("a.ZiP", "Z", "ZiP", -1),
                                           ("a.zipx", "zx", "zipx", -1), ("a.ZIPX", "ZX", "ZIPX", -1)] {
            let parsed = try XCTUnwrap(ArchiveVolumeSet.parse(fileName: name))
            XCTAssertEqual(parsed.scheme, .zipSpanned(stem: "a", volumePrefix: prefix, lastExtension: ext))
            XCTAssertEqual(parsed.index, index)
        }
        for name in ["", ".001", ".zip", "a.01", "a.000", "a.0000", "a.+01", "a.００１", "a.0０1",
                     "a.z00", "a.zx00", "a.z1", "a.z-1", "a.z０１", "a.tar", "a.9223372036854775809",
                     "a.z9223372036854775809", "a.z18446744073709551616", "a.18446744073709551616"] {
            XCTAssertNil(ArchiveVolumeSet.parse(fileName: name), name)
        }
    }

    func testIdentityUsesOpenDescriptorAfterPathReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ZipTestSupport.write(payload, relativePath: "retained.001", below: directory)
        let source = try FileByteSource(url: url)
        let original = try information(at: url)
        try Data([1, 2]).write(to: url, options: .atomic)
        let snapshot = try source.volume(at: url)
        XCTAssertNotEqual(snapshot.inode, UInt64(try information(at: url).st_ino))
        XCTAssertEqual(snapshot.inode, UInt64(original.st_ino))
        XCTAssertEqual(snapshot.device, UInt64(UInt32(bitPattern: original.st_dev)))
        XCTAssertEqual(snapshot.length, UInt64(payload.count))
        XCTAssertEqual(snapshot.mode, UInt16(original.st_mode))
        XCTAssertEqual(snapshot.modificationSeconds, Int64(original.st_mtimespec.tv_sec))
        XCTAssertEqual(snapshot.modificationNanoseconds, Int64(original.st_mtimespec.tv_nsec))
    }

    func testReopenRetainsAssembledIdentityAndNewOpenReassembles() throws {
        for nativeZIP in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let urls = try nativeZIP
                ? ZipSplitFixture(archive(), below: directory) { _ in [8, 110, 300] }.urls
                : numbered(archive(), below: directory)
            let openedIndex = nativeZIP ? 2 : 0
            let reader = try ArchiveReader.open(url: urls[openedIndex])
            let original = try XCTUnwrap(reader.volumeSet)
            for url in urls {
                let bytes = try Data(contentsOf: url)
                try bytes.write(to: url, options: .atomic)
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.volumeSet, original)
            let current = try XCTUnwrap(ArchiveReader.open(url: urls[openedIndex]).volumeSet)
            XCTAssertNotEqual(current.volumes, original.volumes)
            try assertVolumes(current, urls: urls)
            for url in urls { try FileManager.default.removeItem(at: url) }
            XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
            XCTAssertEqual(try reopened.reopen().volumeSet, original)
        }
    }

    func testReopenFallbackAndStagedCpioRetainVolumeSet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["container/newc.cpio.b64", "pbzx/payload-raw-xz.pbzx.b64"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/" + path), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let urls = try numbered(bytes, below: directory)
            let reader = try ArchiveReader.open(url: urls[0])
            XCTAssertEqual(reader.format, .cpio)
            let original = try XCTUnwrap(reader.volumeSet)
            for url in urls { try FileManager.default.removeItem(at: url) }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.volumeSet, original)
            XCTAssertEqual(try reopened.reopen().volumeSet, original)
            XCTAssertEqual(try reopened.entries.map { try reopened.read($0) },
                           try reader.entries.map { try reader.read($0) })
        }
    }
}
