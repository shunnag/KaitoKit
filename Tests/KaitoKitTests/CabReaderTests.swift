// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表・固定 fixture に基づく検証。
// 他の archiver の実装 source は開かず、参照・引用していない。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class CabReaderTests: XCTestCase {
    private struct Row: Equatable {
        let name: String
        let size: UInt64
        let sha256: String
        init(_ name: String, _ size: UInt64, _ sha256: String) {
            self.name = name; self.size = size; self.sha256 = sha256
        }
    }
    private let variants = ["stored", "mszip", "reserve", "next", "multiblock", "utf8"]
    private let a = Row("a.txt", 10, "acb5e25d4f459ab032633a86f1bfb1605d1f9d40d22b43b9d07ea711810f7958")
    private var classic: [Row] {
        [a,
         Row("b.bin", 4096, "0d356260eaf09e3b3dc81a65b2ad2399aa7c4921c0274bd2cbb54c2a21c46e3b"),
         Row("empty.txt", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
         Row("sub/nested.txt", 20, "5d0e5bc93dbc8febbb6b3cea0503bfd7460284e544c2f689538fd55da59accb2"),
         Row("sub/deep/d.txt", 5, "64896f89fd11190013b70103e603a1c5826e56b7fb7d2197ab279b0690043599"),
         Row("big.txt", 20000, "82d8ba8d086497e77afcbd0bd1a670921a00e141c733e8907c2b91ba447a210d")]
    }

    private func fixture(_ variant: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/cab-\(variant).cab.b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }

    private func rows(_ reader: ArchiveReader) throws -> [Row] {
        try reader.entries.map { entry in
            let data = try reader.read(entry)
            XCTAssertEqual(UInt64(data.count), entry.uncompressedSize)
            return Row(entry.name, try XCTUnwrap(entry.uncompressedSize),
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    func testEveryFixtureMatchesOrderedGoldenRowsAndMetadata() throws {
        var baseline: [Row]?
        for variant in variants {
            let bytes = try fixture(variant)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .cab)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .cab)
            let expected: [Row]
            switch variant {
            case "multiblock":
                XCTAssertEqual(le(bytes, 40, 2), 11)
                expected = [Row("multi.txt", 350070, "1cb0d807794c414b014ddbe05aa98fecd5bc75cb3cbc1c85b4e41f6b95b2342a"), a]
            case "utf8":
                expected = [Row("日本語.txt", 3, "a10ea5adfcc15e3ead98a4fa85e9cee3cc266896a4df04511812b939d4101d22"), a]
                XCTAssertEqual(reader.entries[0].rawName.declaredEncoding, .utf8)
            default: expected = classic
            }
            XCTAssertEqual(reader.entries.count, expected.count, variant)
            let actual = try rows(reader)
            XCTAssertEqual(actual, expected, variant)
            if expected == classic {
                if let baseline { XCTAssertEqual(actual, baseline, variant) } else { baseline = actual }
                XCTAssertTrue(reader.entries[3].rawName.bytes.contains(92))
                XCTAssertEqual(reader.entries[3].pathComponents, ["sub", "nested.txt"])
            }
            for entry in reader.entries {
                XCTAssertEqual(entry.kind, .file)
                XCTAssertEqual(entry.solidGroup, 0)
                XCTAssertNotNil(entry.modificationDate)
                XCTAssertEqual(entry.methodDescription, variant == "stored" ? "cab (stored)" : "cab (MSZIP)")
                XCTAssertEqual(entry.formatSpecific["folder"], "0")
                XCTAssertEqual(entry.formatSpecific["setID"], "0")
                XCTAssertEqual(entry.formatSpecific["cabinetIndex"], "0")
                XCTAssertNotNil(entry.formatSpecific["attributes"])
            }
            XCTAssertEqual(try rows(reader.reopen()), expected, variant)
        }
    }

    private func le(_ bytes: Data, _ offset: Int, _ count: Int = 4) -> Int {
        (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
    }
    private func write(_ value: Int, _ bytes: inout Data, _ offset: Int, _ count: Int = 4) {
        for i in 0..<count { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private func assertError(_ categories: [String], _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let category: String
            switch error {
            case KaitoError.unsupportedFormat: category = "format"
            case KaitoError.limitExceeded: category = "limit"
            case KaitoError.truncated: category = "truncated"
            case KaitoError.malformed: category = "malformed"
            case KaitoError.checksumMismatch: category = "checksum"
            case KaitoError.unsupportedMethod: category = "method"
            default: category = String(describing: error)
            }
            XCTAssertTrue(categories.contains(category), "\(error)", file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, file: file, line: line)
    }

    func testMalformedCountsOffsetsNamesAndExtentsFailFast() throws {
        let original = try fixture("mszip"), files = le(try fixture("mszip"), 16)
        let data = le(original, 36)
        var damaged = original
        damaged[0] ^= 1
        assertError(["format"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; damaged[25] = 2
        assertError(["format"]) { _ = try ArchiveReader.open(data: damaged) }
        for field in [26, 28] {
            damaged = original; write(0xffff, &damaged, field, 2)
            assertError(["limit", "truncated"]) { _ = try ArchiveReader.open(data: damaged) }
        }
        for field in [16, 36] {
            damaged = original; write(original.count + 1, &damaged, field)
            assertError(["truncated"]) { _ = try ArchiveReader.open(data: damaged) }
        }
        damaged = original
        for i in (files + 16)..<damaged.count { damaged[i] = 65 }
        assertError(["malformed"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; write(5, &damaged, files + 8, 2)
        assertError(["malformed"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; write(40000, &damaged, data + 6, 2)
        assertError(["malformed"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; write(0xffffffff, &damaged, files + 4)
        assertError(["malformed"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; write(65535, &damaged, data + 4, 2)
        assertError(["truncated"]) { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; write(original.count + 1, &damaged, 8)
        assertError(["truncated"]) { _ = try ArchiveReader.open(data: damaged) }
    }

    func testChecksumsAreFinalizedForSlicesAndEmptyFilesAndZeroIsSkipped() throws {
        var bytes = try fixture("stored")
        let block = le(bytes, 36)
        XCTAssertNotEqual(le(bytes, block), 0)
        bytes[bytes.count - 1] ^= 1
        let reader = try ArchiveReader.open(data: bytes)
        // 最初の file と空 file でも、その後の folder payload の破損を見落とさない。
        for index in [0, 2, 5] {
            assertError(["checksum"]) { _ = try reader.read(reader.entries[index]) }
        }
        let compressed = try fixture("mszip")
        for offset in [le(compressed, 36) + 8, compressed.count - 1] {
            bytes = compressed; bytes[offset] ^= 1
            let damaged = try ArchiveReader.open(data: bytes)
            assertError(["checksum"]) { _ = try damaged.read(damaged.entries[0]) }
        }
        for variant in ["stored", "mszip", "reserve", "next"] {
            bytes = try fixture(variant)
            var folder = 36
            if variant == "reserve" { folder += 4 + le(bytes, 36, 2) }
            if variant == "next" {
                for _ in 0..<2 { while bytes[folder] != 0 { folder += 1 }; folder += 1 }
            }
            write(0, &bytes, le(bytes, folder))
            XCTAssertEqual(try rows(ArchiveReader.open(data: bytes)), classic)
        }
    }

    func testUnsupportedMethodsAndContinuedFilesStillList() throws {
        let original = try fixture("mszip"), files = le(try fixture("mszip"), 16)
        for (method, name) in [(2, "Quantum"), (0x1503, "LZX")] {
            var bytes = original; write(method, &bytes, 42, 2)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.map(\.name), classic.map(\.name))
            for entry in reader.entries {
                XCTAssertEqual(entry.methodDescription, "cab (\(name))")
                XCTAssertNotNil(entry.modificationDate)
                XCTAssertThrowsError(try reader.stream(entry)) { error in
                    guard case KaitoError.unsupportedMethod(let reason) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(reason, "cab \(name)")
                }
            }
        }
        for (sentinel, name) in [(0xfffd, "previous"), (0xfffe, "next"), (0xffff, "both")] {
            var bytes = original; write(sentinel, &bytes, files + 8, 2)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.count, 6)
            XCTAssertEqual(reader.entries[0].formatSpecific["continued"], name)
            XCTAssertEqual(reader.entries[0].solidGroup, sentinel)
            XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
                guard case KaitoError.unsupportedMethod(let reason) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(reason, "cab multi-cabinet set")
            }
            XCTAssertEqual(try reader.read(reader.entries[1]).count, 4096)
        }
    }

    func testResourceLimitsAndInvalidTimestamp() throws {
        let bytes = try fixture("mszip")
        for limits in [ReadLimits(maxEntrySize: 100), ReadLimits(maxTotalUncompressedSize: 100),
                       ReadLimits(maxEntryCount: 5), ReadLimits(maxMetadataSize: 100),
                       ReadLimits(maxMetadataRecordCount: 0), ReadLimits(maxTotalMetadataSize: 100),
                       ReadLimits(maxPathComponentCount: 2)] {
            assertError(["limit"]) { _ = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: limits)) }
        }
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 32767)))
        assertError(["limit"]) { _ = try reader.stream(reader.entries[0]) }
        var damaged = bytes; write(0xffff, &damaged, le(bytes, 16) + 10, 2)
        let dated = try ArchiveReader.open(data: damaged)
        XCTAssertNil(dated.entries[0].modificationDate)
        XCTAssertEqual(try rows(dated), classic)
    }

    func testTinyReadsAndIndependentFolderStreams() throws {
        var bytes = try fixture("multiblock")
        let files = le(bytes, 16), data = le(bytes, 36)
        // 同じ有効な folder stream を 2 folder から指し、各々の先頭から履歴を作らせる。
        bytes.insert(contentsOf: bytes[36..<44], at: 44)
        write(bytes.count, &bytes, 8); write(files + 8, &bytes, 16); write(2, &bytes, 26, 2)
        write(data + 8, &bytes, 36); write(data + 8, &bytes, 44)
        let secondFile = files + 8 + 16 + "multi.txt".utf8.count + 1
        write(1, &bytes, secondFile + 8, 2)
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 1])
        XCTAssertEqual(try rows(reader), [Row("multi.txt", 350070, "1cb0d807794c414b014ddbe05aa98fecd5bc75cb3cbc1c85b4e41f6b95b2342a"), a])
        let stream = try reader.stream(reader.entries[0])
        var result = Data(), buffer = [UInt8](repeating: 0, count: 7)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined(),
            "1cb0d807794c414b014ddbe05aa98fecd5bc75cb3cbc1c85b4e41f6b95b2342a")
    }
}
