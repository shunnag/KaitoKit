import Foundation
@testable import KaitoKit
import XCTest

final class CompressedTarAliasTests: XCTestCase {
    func testTAZAliasListsTarMembersAndReopensAfterUnlink() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") else {
            throw XCTSkip("compress is required to generate the tar.Z fixture")
        }
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("fixture.tar")
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "folder/payload.txt", contents: Data("payload".utf8))
        ]).write(to: input)
        _ = try ZipTestSupport.checkedRun("/usr/bin/compress", arguments: ["-f", "-b", "16", input.path],
                                              currentDirectory: directory)
        let bytes = try Data(contentsOf: input.appendingPathExtension("Z"))
        for suffix in ["taz", "TAZ"] {
            for threshold in [UInt64(0), UInt64.max] {
                let url = directory.appendingPathComponent("archive." + suffix)
                try bytes.write(to: url)
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(
                    limits: ReadLimits(inMemorySingleFileLimit: threshold)))
                XCTAssertEqual(reader.format, .tar, "\(suffix) must be a compressed-tar alias")
                XCTAssertEqual(reader.entries.map(\.name), ["folder/payload.txt"],
                               "\(suffix) must list tar members")
                try FileManager.default.removeItem(at: url)
                guard reader.format == .tar else { continue }
                XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload".utf8))
                let reopened = try reader.reopen()
                XCTAssertEqual(reopened.format, .tar)
                XCTAssertEqual(reopened.entries.map(\.name), ["folder/payload.txt"])
                XCTAssertEqual(try reopened.read(reopened.entries[0]), Data("payload".utf8))
            }
        }
    }

    private func fixture(in directory: URL, codec: String = "lzma", lc: Int = 3) throws -> Data {
        let output = directory.appendingPathComponent("generated")
        _ = try ZipTestSupport.checkedRun("/usr/bin/python3", arguments: ["-c", """
        import bz2, io, lzma, sys, tarfile
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode='w') as writer:
            entry = tarfile.TarInfo('folder/payload.txt'); entry.size = 7
            writer.addfile(entry, io.BytesIO(b'payload'))
        data = tar.getvalue()
        if sys.argv[2] == 'lzma':
            data = lzma.compress(data, format=lzma.FORMAT_ALONE,
                filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20, 'lc': int(sys.argv[3]), 'lp': 0, 'pb': 2}])
        else:
            data = bz2.compress(data)
        open(sys.argv[1], 'wb').write(data)
        """, output.path, codec, String(lc)], currentDirectory: directory)
        return try Data(contentsOf: output)
    }

    func testLZMAAndBzip2TarAliasesListMembersAndReopenAfterUnlink() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (codec, aliases) in [("lzma", ["tar.lzma", "tlz", "TAR.LZMA", "TLZ"]), ("bzip2", ["tbz", "TBZ"])] {
            for lc in [3, 4] {
                let bytes = try fixture(in: directory, codec: codec, lc: lc)
                for suffix in aliases {
                    for threshold in [UInt64(0), UInt64.max] {
                        let url = directory.appendingPathComponent("archive." + suffix)
                        try bytes.write(to: url)
                        let options = ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: threshold))
                        let reader = try ArchiveReader.open(url: url, options: options)
                        XCTAssertEqual(reader.format, .tar, suffix)
                        XCTAssertEqual(reader.entries.map(\.name), ["folder/payload.txt"], suffix)
                        try FileManager.default.removeItem(at: url)
                        XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload".utf8), suffix)
                        let reopened = try reader.reopen()
                        XCTAssertEqual(reopened.format, .tar, suffix)
                        XCTAssertEqual(try reopened.read(reopened.entries[0]), Data("payload".utf8), suffix)
                    }
                }
            }
        }
    }

    func testStandaloneLZMAKeepsItsSingleFileSemantics() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.lzma")
        try fixture(in: directory).write(to: url)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.format, .lzma)
        XCTAssertEqual(reader.entries.map(\.name), ["archive"])
        XCTAssertEqual(try ArchiveReader.open(data: reader.read(reader.entries[0])).format, .tar)
    }

    func testCompressedLZMATarRejectsTruncationAndEnforcesStagingAndDictionaryLimits() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try fixture(in: directory)
        for suffix in ["tar.lzma", "tlz"] {
            let url = directory.appendingPathComponent("archive." + suffix)
            try bytes.write(to: url)
            XCTAssertThrowsError(try ArchiveReader.open(url: url,
                options: ReaderOptions(limits: ReadLimits(maxEntrySize: 1024))))
            XCTAssertThrowsError(try ArchiveReader.open(url: url,
                options: ReaderOptions(limits: ReadLimits(maxDictionarySize: (1 << 20) - 1))))
            for end in [0, 14, bytes.count - 1] {
                try bytes.prefix(end).write(to: url)
                XCTAssertThrowsError(try ArchiveReader.open(url: url), "\(suffix), \(end)")
            }
            try Data(repeating: 0, count: 128).write(to: url)
            XCTAssertThrowsError(try ArchiveReader.open(url: url), "拡張子だけでは LZMA と判定しない")
        }
    }
}
