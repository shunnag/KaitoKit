private import Foundation
@testable internal import KaitoKit
internal import XCTest

final class CompressedNamingTests: XCTestCase {
    func testFallbackNames() throws {
        let fixtures: [ArchiveFormat: Data] = [
            .gzip: try CompressedTarFramingTestSupport.gzip(Data("payload".utf8)).data,
            .bzip2: try ZipTestSupport.checkedInFixture("tar-edit/third-bzip2.tar.bz2"),
            .xz: try ZipTestSupport.checkedInFixture("singlefile/x86.xz"),
            .zstd: try ZipTestSupport.checkedInFixture("zstd/one-l1.zst"),
            .compress: try ZipTestSupport.checkedInFixture("singlefile/tar-compress.tar.Z"),
            .lz4: try ZipTestSupport.checkedInFixture("lz4-frame/tiny.lz4"),
            .lzma: try ZipTestSupport.checkedInFixture("singlefile/alone.lzma"),
            .lzip: try ZipTestSupport.checkedInFixture("lzip/one.lz"),
            .brotli: try ZipTestSupport.checkedInFixture("brotli/one.br"),
            .pbzx: try ZipTestSupport.checkedInFixture("pbzx/text.pbzx"),
        ]
        let cases: [(fileName: String?, format: ArchiveFormat, expected: String)] = [
            ("x.tar.gz", .gzip, "x.tar"),
            ("x.tgz", .gzip, "x.tar"),
            ("x.gz", .gzip, "x"),
            ("x.tar.bz2", .bzip2, "x.tar"),
            ("x.tbz2", .bzip2, "x.tar"),
            ("x.tbz", .bzip2, "x.tar"),
            ("x.bz2", .bzip2, "x"),
            ("x.bz", .bzip2, "x"),
            ("x.tar.bz", .bzip2, "x.tar"),
            ("x.tar.xz", .xz, "x.tar"),
            ("x.txz", .xz, "x.tar"),
            ("x.xz", .xz, "x"),
            ("x.tar.zst", .zstd, "x.tar"),
            ("x.tzst", .zstd, "x.tar"),
            ("x.zst", .zstd, "x"),
            ("x.tar.z", .compress, "x.tar"),
            ("x.tz", .compress, "x.tar"),
            ("x.taz", .compress, "x.tar"),
            ("x.z", .compress, "x"),
            ("x.tar.lz4", .lz4, "x.tar"),
            ("x.lz4", .lz4, "x"),
            ("x.tar.lzma", .lzma, "x.tar"),
            ("x.tlz", .lzma, "x.tar"),
            ("x.lzma", .lzma, "x"),
            ("x.tar.lz", .lzip, "x.tar"),
            ("x.tlz", .lzip, "x.tar"),
            ("x.lz", .lzip, "x"),
            ("x.tar.br", .brotli, "x.tar"),
            ("x.tbr", .brotli, "x.tar"),
            ("x.br", .brotli, "x"),
            ("x.pbzx", .pbzx, "x"),
            ("X.TAR.GZ", .gzip, "X.tar"),
            ("X.TBZ2", .bzip2, "X.tar"),
            ("X.TBZ", .bzip2, "X.tar"),
            ("X.TAR.BZ", .bzip2, "X.TAR"),
            ("X.TXZ", .xz, "X.tar"),
            ("X.TZST", .zstd, "X.tar"),
            ("X.TZ", .compress, "X.tar"),
            ("X.TAZ", .compress, "X.tar"),
            ("X.TAR.LZ4", .lz4, "X.tar"),
            ("X.TLZ", .lzma, "X.tar"),
            ("X.TLZ", .lzip, "X.tar"),
            ("X.TBR", .brotli, "X.tar"),
            ("X.PBZX", .pbzx, "X"),
            ("原稿.GZ", .gzip, "原稿"),
            ("x.cpio.gz", .gzip, "x.cpio"),
            ("x.cpio.bz2", .bzip2, "x.cpio"),
            ("x.cpio.xz", .xz, "x.cpio"),
            ("x.cpio.zst", .zstd, "x.cpio"),
            ("x.cpio.z", .compress, "x.cpio"),
            ("x.cpio.lz4", .lz4, "x.cpio"),
            ("x.cpio.lzma", .lzma, "x.cpio"),
            ("x.cpio.lz", .lzip, "x.cpio"),
            ("x.cpio.br", .brotli, "x.cpio"),
            ("x.cpgz", .gzip, "x.cpgz"),
            ("x.gz", .bzip2, "x.gz"),
            ("x.bz", .gzip, "x.bz"),
            ("x.tlz", .gzip, "x.tlz"),
            ("x.tar.gz.backup", .gzip, "x.tar.gz.backup"),
            (".tar.gz", .gzip, "data"),
            (".tgz", .gzip, "data"),
            (".gz", .gzip, "data"),
            (".taz", .compress, "data"),
            (".pbzx", .pbzx, "data"),
            (nil, .gzip, "data"),
            ("", .gzip, "data"),
            ("x", .gzip, "x"),
        ]
        for (fileName, format, expected) in cases {
            let label = "\(fileName ?? "nil") / \(format)"
            let reader = try SingleFileReader(
                source: DataByteSource(data: XCTUnwrap(fixtures[format])),
                format: format,
                options: ReaderOptions(),
                fallbackFileName: fileName
            )
            let entry = try XCTUnwrap(reader.entries.first, label)
            XCTAssertEqual(entry.name, expected, label)
            XCTAssertEqual(entry.rawName.bytes, Array(expected.utf8), label)
            XCTAssertEqual(entry.rawName.declaredEncoding, .utf8, label)
            XCTAssertNil(entry.modificationDate, label)
        }
    }

    func testContainerDecisions() {
        let cases: [(name: String?, detected: ArchiveFormat, expected: CompressedNaming.Container?)] = [
            ("x.tar.gz", .gzip, .tar),
            ("x.tar.bz2", .bzip2, .tar),
            ("x.tar.xz", .xz, .tar),
            ("x.tar.zst", .zstd, .tar),
            ("x.tar.lz4", .lz4, .tar),
            ("x.tar.lzma", .lzma, .tar),
            ("x.tar.lz", .lzip, .tar),
            ("x.tar.br", .brotli, .tar),
            ("x.tar.z", .compress, .tar),
            ("x.cpio.gz", .gzip, .cpio),
            ("x.cpio.bz2", .bzip2, .cpio),
            ("x.cpio.xz", .xz, .cpio),
            ("x.cpio.zst", .zstd, .cpio),
            ("x.cpio.lz4", .lz4, .cpio),
            ("x.cpio.lzma", .lzma, .cpio),
            ("x.cpio.lz", .lzip, .cpio),
            ("x.cpio.br", .brotli, .cpio),
            ("x.cpio.z", .compress, .cpio),
            ("x.tgz", .gzip, .tar),
            ("x.tbz2", .bzip2, .tar),
            ("x.tbz", .bzip2, .tar),
            ("x.txz", .xz, .tar),
            ("x.tzst", .zstd, .tar),
            ("x.tlz", .lzma, .tar),
            ("x.tlz", .lzip, .tar),
            ("x.tbr", .brotli, .tar),
            ("x.tz", .compress, .tar),
            ("x.taz", .compress, .tar),
            ("x.cpgz", .gzip, .cpio),
            ("X.TAR.GZ", .gzip, .tar),
            ("X.CPIO.XZ", .xz, .cpio),
            ("X.TAZ", .compress, .tar),
            ("X.TLZ", .lzma, .tar),
            ("X.TLZ", .lzip, .tar),
            ("X.CPGZ", .gzip, .cpio),
            ("x.tar.bz", .bzip2, nil),
            ("x.cpio.bz", .bzip2, nil),
            ("x.bz", .bzip2, nil),
            ("x.gz", .gzip, nil),
            ("x.tar.gz", .bzip2, nil),
            ("x.cpio.gz", .xz, nil),
            ("x.taz", .gzip, nil),
            ("x.tlz", .gzip, nil),
            ("x.cpgz", .compress, nil),
            ("x.tar.lzma", .lzip, nil),
            ("x.tar.lz", .lzma, nil),
            ("x.tar.gz", .zip, nil),
            ("x.tar.gz.backup", .gzip, nil),
            ("x.tar.gz.cpio.xz", .xz, .cpio),
            ("x.cpio.gz.tar.xz", .xz, .tar),
            ("x", .gzip, nil),
            (nil, .gzip, nil),
            ("", .gzip, nil),
            ("x.pbzx", .pbzx, .pbzxAuto),
            ("x.tar.gz", .pbzx, .pbzxAuto),
            ("Payload", .pbzx, .pbzxAuto),
            (nil, .pbzx, .pbzxAuto),
            ("", .pbzx, .pbzxAuto),
            ("x.pbzx", .xz, nil),
        ]
        for (name, detected, expected) in cases {
            XCTAssertEqual(
                CompressedNaming.compressedContainer(name: name, detected: detected),
                expected,
                "\(name ?? "nil") / \(detected)"
            )
        }
    }

    func testTarBzRemainsASingleEntry() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tar = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "payload.txt", contents: Data("payload".utf8))
        ])
        let url = directory.appendingPathComponent("x.tar.bz")
        try CompressedTarFramingTestSupport.bzip2(tar).data.write(to: url)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.format, .bzip2)
        XCTAssertEqual(reader.entries.map(\.name), ["x.tar"])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), tar)
    }
}
