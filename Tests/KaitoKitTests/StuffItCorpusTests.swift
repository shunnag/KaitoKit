// Clean-room format inputs: Ch.00・01・02・04・06、archive-verification.json と CC0 の oracle 出力。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItCorpusTests: XCTestCase {
    struct Row: Decodable {
        let name: String
        let path: [String]?
        let size: UInt64
        let sha256: String
        let fork: String
    }
    struct Fixture: Decodable {
        let file: String
        let sha256: String
        let size: Int
        let encrypted: Bool
        let entries: [Row]
    }
    struct Verified: Decodable {
        let file: String
        let sha256: String
        let forks: [Row]
    }
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    var fixtureRoot: URL { root.appendingPathComponent("Tests/Fixtures/stuffit") }
    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func fixture(_ name: String) throws -> Data {
        let encoded = try Data(contentsOf: fixtureRoot.appendingPathComponent(name + ".b64"))
        XCTAssertLessThanOrEqual(encoded.count, 40_000)
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }
    func testCheckedInCC0Fixtures() throws {
        let manifest = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json")))
        XCTAssertLessThanOrEqual(manifest.count, 30)
        for spec in manifest {
            let bytes = try fixture(spec.file)
            XCTAssertEqual(bytes.count, spec.size, spec.file); XCTAssertEqual(sha(bytes), spec.sha256, spec.file)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .stuffIt)
            XCTAssertEqual(reader.entries.count, spec.entries.count, spec.file)
            if spec.encrypted {
                XCTAssertTrue(reader.entries.contains(where: \.isEncrypted), spec.file)
            }
            for expected in spec.entries {
                let entry = try XCTUnwrap(reader.entries.first { $0.pathComponents == expected.path }, "\(spec.file): \(expected.name)")
                XCTAssertEqual(entry.name, expected.path?.joined(separator: "/")); XCTAssertEqual(entry.uncompressedSize, expected.size)
                XCTAssertEqual(entry.kind == .directory ? "directory" : entry.formatSpecific["fork"] ?? "", expected.fork)
                if spec.encrypted {
                    if entry.isEncrypted {
                        let expected: KaitoError = entry.formatSpecific["container"] == "classic" && !spec.file.hasSuffix(".bin")
                            ? .unsupportedMethod("StuffIt encryption without archive resource fork") : .passwordRequired
                        XCTAssertThrowsError(try reader.stream(entry)) { XCTAssertEqual($0 as? KaitoError, expected) }
                    }
                } else {
                    XCTAssertEqual(sha(try reader.read(entry)), expected.sha256, "\(spec.file): \(expected.name)")
                }
            }
        }
    }
    func testReportVerifiedCC0Forks() throws {
        let specs = try JSONDecoder().decode([Verified].self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("verified-forks.json")))
        for spec in specs where spec.file.hasPrefix("testfile.") {
            let bytes = try fixture(spec.file)
            XCTAssertEqual(sha(bytes), spec.sha256)
            try verify(try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "password")), rows: spec.forks)
        }
    }
    private func verify(_ reader: ArchiveReader, rows: [Row]) throws {
        XCTAssertEqual(reader.entries.filter { $0.kind != .directory }.count, rows.count)
        for row in rows {
            let name = row.name + (row.fork == "resource" ? "/..namedfork/rsrc" : "")
            let entry = try XCTUnwrap(reader.entries.first { $0.pathComponents.joined(separator: "/") == name && $0.formatSpecific["fork"] == row.fork })
            XCTAssertEqual(entry.name, name)
            XCTAssertEqual(entry.uncompressedSize, row.size)
            XCTAssertEqual(sha(try reader.read(entry)), row.sha256, name)
        }
    }
    func testExternalReportVerifiedGoForks() throws {
        let specs = try JSONDecoder().decode([Verified].self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("verified-forks.json")))
        for name in ["v5-comment.sit", "v1-fhf-faster.sit"] {
            let source = root.appendingPathComponent("inbox/stuffit-corpus/go/\(name)")
            guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("外部の go 標本は fixture に収録しない") }
            let spec = try XCTUnwrap(specs.first { $0.file == name })
            let bytes = try Data(contentsOf: source)
            XCTAssertEqual(sha(bytes), spec.sha256)
            try verify(try ArchiveReader.open(data: bytes), rows: spec.forks)
        }
    }
    func testExternalGoDataForkOracles() throws {
        let corpus = root.appendingPathComponent("inbox/stuffit-corpus")
        guard FileManager.default.fileExists(atPath: corpus.appendingPathComponent("go").path) else { throw XCTSkip("外部オラクル入力は fixture に収録しない") }
        let names = ["SITv1-13.sit", "v1-huffman.sit", "v1-lzw.sit", "v1-lzw+huffman.sit", "v1-nocompression.sit",
                     "v1.5-lzw-comment.sit", "v1-lzw-fast.sit", "v5-comment.sit", "v5-selfextractor.sea",
                     "v1-lzw+h-better.sit", "v1-optimal-with-comment.sit", "v1-huffman-optimal.sit"]
        for name in names {
            let reader = try ArchiveReader.open(url: corpus.appendingPathComponent("go/\(name)"))
            let oracle = try String(contentsOf: corpus.appendingPathComponent("oracle/go/\(name).sha"), encoding: .utf8)
            var expected: [String] = []
            for line in oracle.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields[0] != "total", fields[1] != "0" { expected.append("\(fields[1])\t\(fields[2])\t\(fields[3])") }
            }
            var actual: [String] = []
            for entry in reader.entries where entry.formatSpecific["fork"] == "data" && entry.uncompressedSize != 0 {
                let data = try reader.read(entry)
                actual.append("\(data.count)\t\(sha(data))\t\(entry.name)")
            }
            XCTAssertEqual(actual.sorted(), expected.sorted(), name)
        }
    }
    func testExternalGoWrapperOraclesAndMissingArchiveResource() throws {
        let corpus = root.appendingPathComponent("inbox/stuffit-corpus")
        guard FileManager.default.fileExists(atPath: corpus.appendingPathComponent("go").path) else { throw XCTSkip("外部オラクル入力は fixture に収録しない") }
        for name in ["SITv1-2.sit", "doom-i-101.hqx"] {
            let source = try FileByteSource(url: corpus.appendingPathComponent("go/\(name)"))
            let envelope = try XCTUnwrap(FormatDetector.stuffItInput(source: source, limits: ReadLimits()))
            let oracle = try String(contentsOf: corpus.appendingPathComponent("oracle/go/\(name).sha"), encoding: .utf8)
            let row = try XCTUnwrap(oracle.split(separator: "\n").first).split(separator: "\t")
            // この 2 本の支給オラクルは、内側の書庫を展開せず wrapper の data を返す。
            let data = Data(try readByteRange(source: envelope.data, offset: 0, count: Int(envelope.data.length)))
            XCTAssertEqual(String(data.count), String(row[1])); XCTAssertEqual(sha(data), String(row[2]))
            let reader = try ArchiveReader.open(source: source)
            for entry in reader.entries { _ = try reader.read(entry) }
        }
        for name in ["v1-lzm-des-password123.sit", "v1-lzm-newde-password123.sit"] {
            let reader = try ArchiveReader.open(url: corpus.appendingPathComponent("go/\(name)"), options: ReaderOptions(password: "password123"))
            let entry = try XCTUnwrap(reader.entries.first(where: \.isEncrypted))
            XCTAssertThrowsError(try reader.read(entry)) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt encryption without archive resource fork"))
            }
        }
    }
    func testExternalHuffmanDuplicateLeafAndDamagedResource() throws {
        let corpus = root.appendingPathComponent("inbox/stuffit-corpus/go")
        guard FileManager.default.fileExists(atPath: corpus.path) else { throw XCTSkip("外部オラクル入力は fixture に収録しない") }
        let good = try ArchiveReader.open(url: corpus.appendingPathComponent("v1.5-lzw-comment.sit"))
        let entry = try XCTUnwrap(good.entries.first { $0.name == "SimpleText/..namedfork/rsrc" })
        XCTAssertEqual(sha(try good.read(entry)), "e723b7dba9c45f352e366898dc3b9d377f6b7531a7a365c6e51b40368af79ced")
        let bad = try ArchiveReader.open(url: corpus.appendingPathComponent("v1-huffman.sit"))
        XCTAssertThrowsError(try bad.read(bad.entries[0])) { XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 0)) }
    }
}
