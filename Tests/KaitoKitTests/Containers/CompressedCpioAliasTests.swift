import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// 圧縮 cpio の連鎖: Archive Utility の `.cpgz` と `.cpio.<codec>` は展開結果を CpioReader に渡す。
/// fixture は bsdtar（OS 同梱 libarchive）で生成し、codec ごとの CLI で包む。
final class CompressedCpioAliasTests: XCTestCase {
    private struct Sample {
        let directory: URL
        let plain: Data
        let payloads: [String: Data]
    }

    private func makeSample() throws -> Sample {
        let directory = try TarTestSupport.temporaryDirectory()
        let source = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let payloads: [String: Data] = [
            "a.txt": Data("compressed cpio alias\n".utf8),
            "sub/b.bin": Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 * 31) }),
            "empty": Data(),
        ]
        for (name, data) in payloads {
            try data.write(to: source.appendingPathComponent(name))
        }
        let plainURL = directory.appendingPathComponent("plain.cpio")
        try ZipTestSupport.checkedRun(
            ZipTestSupport.bsdTarPath,
            arguments: ["--format", "newc", "-cf", plainURL.path, "a.txt", "sub/b.bin", "empty"],
            currentDirectory: source
        )
        return Sample(directory: directory, plain: try Data(contentsOf: plainURL), payloads: payloads)
    }

    private func assertCpio(_ reader: ArchiveReader, _ sample: Sample, _ label: String) throws {
        XCTAssertEqual(reader.format, .cpio, label)
        let files = reader.entries.filter { $0.kind == .file }
        XCTAssertEqual(Set(files.map(\.name)), Set(sample.payloads.keys), label)
        for entry in files {
            XCTAssertEqual(try reader.read(entry), sample.payloads[entry.name], "\(label) \(entry.name)")
        }
    }

    func testCpgzAndCodecSuffixedCpioAreListedAsCpio() throws {
        let sample = try makeSample()
        defer { try? FileManager.default.removeItem(at: sample.directory) }
        let plainReader = try ArchiveReader.open(data: sample.plain)
        try assertCpio(plainReader, sample, "plain")

        // gzip: `.cpgz`（Archive Utility）と `.cpio.gz`。
        let gzipURL = sample.directory.appendingPathComponent("x.cpio.gz")
        try sample.plain.write(to: sample.directory.appendingPathComponent("x.cpio"))
        try ZipTestSupport.checkedRun("/usr/bin/gzip", arguments: ["-k", "-n", "x.cpio"], currentDirectory: sample.directory)
        let gzipped = try Data(contentsOf: gzipURL)
        for name in ["archive.cpgz", "ARCHIVE.CPGZ", "archive.cpio.gz", "archive.CPIO.GZ"] {
            let url = sample.directory.appendingPathComponent(name)
            try gzipped.write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .gzip, name)
            let reader = try ArchiveReader.open(url: url)
            try assertCpio(reader, sample, name)
            try FileManager.default.removeItem(at: url)
            // 展開結果は保持済みなので、元 file を消しても reopen できる。
            try assertCpio(try reader.reopen(), sample, name + " reopened")
        }
        // 名前の無い Data は従来どおり単一 stream（gzip）で、展開結果は cpio の byte 列そのもの。
        let single = try ArchiveReader.open(data: gzipped)
        XCTAssertEqual(single.format, .gzip)
        XCTAssertEqual(single.entries[0].name, "data")
        XCTAssertEqual(try single.read(single.entries[0]), sample.plain)

        // 他の codec: bsdtar の filter で cpio + xz / lzip / zstd(CLI) / bzip2 を作る。
        for (suffix, filter) in [("xz", "--xz"), ("lz", "--lzip"), ("bz2", "--bzip2")] {
            let url = sample.directory.appendingPathComponent("filtered.cpio.\(suffix)")
            try ZipTestSupport.checkedRun(
                ZipTestSupport.bsdTarPath,
                arguments: ["--format", "newc", filter, "-cf", url.path, "a.txt", "sub/b.bin", "empty"],
                currentDirectory: sample.directory.appendingPathComponent("src")
            )
            let reader = try ArchiveReader.open(url: url)
            try assertCpio(reader, sample, suffix)
        }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/zstd") {
            let url = sample.directory.appendingPathComponent("x.cpio.zst")
            try ZipTestSupport.checkedRun("/opt/homebrew/bin/zstd", arguments: ["-q", "-o", url.path, "x.cpio"], currentDirectory: sample.directory)
            try assertCpio(try ArchiveReader.open(url: url), sample, "zst")
        }

        // 中身が cpio でない `.cpgz` は他の圧縮 tar 別名と同じく失敗する。
        let bogus = sample.directory.appendingPathComponent("bogus.cpgz")
        try ZipTestSupport.checkedRun("/usr/bin/gzip", arguments: ["-k", "-n", "src/a.txt"], currentDirectory: sample.directory)
        try FileManager.default.moveItem(at: sample.directory.appendingPathComponent("src/a.txt.gz"), to: bogus)
        XCTAssertThrowsError(try ArchiveReader.open(url: bogus)) {
            switch $0 as? KaitoError {
            case .malformed, .unsupportedFormat: break
            default: XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testAggregateLimitsApplyToTheInnerCpioMembers() throws {
        let sample = try makeSample()
        defer { try? FileManager.default.removeItem(at: sample.directory) }
        try sample.plain.write(to: sample.directory.appendingPathComponent("y.cpio"))
        try ZipTestSupport.checkedRun("/usr/bin/gzip", arguments: ["-k", "-n", "y.cpio"], currentDirectory: sample.directory)
        let url = sample.directory.appendingPathComponent("y.cpgz")
        try FileManager.default.moveItem(at: sample.directory.appendingPathComponent("y.cpio.gz"), to: url)
        let total = UInt64(sample.payloads.values.reduce(0) { $0 + $1.count })
        let exact = try ArchiveReader.open(url: url, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: total)))
        for entry in exact.entries where entry.kind == .file { _ = try exact.read(entry) }
        XCTAssertThrowsError(try ArchiveReader.open(url: url, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: total - 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 一時展開が memory / disk のどちらでも同じ結果。
        for threshold: UInt64 in [.max, 0] {
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: threshold)))
            try assertCpio(reader, sample, "threshold \(threshold)")
        }
    }
}
