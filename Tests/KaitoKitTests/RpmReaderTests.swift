// Linux Standard Base「Package File Format」、rpm(8)、rpm.org の prose、
// RFC 1950/1951/1952 を許可資料とする利用者提供の実測 byte 表と固定 fixture に基づく検証。
// rpm / libarchive / 7-Zip / XADMaster / The Unarchiver / dpkg 等、他の実装 source は参照していない。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RpmReaderTests: XCTestCase {
    private struct Row: Equatable {
        let name: String
        let size: UInt64
        let sha256: String
        init(_ name: String, _ size: UInt64, _ sha256: String) {
            self.name = name; self.size = size; self.sha256 = sha256
        }
    }

    private let variants = ["gzip", "xz", "bzip2", "none"]
    private var binaryRows: [Row] {
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        return [
            Row("./usr/share/kaitotest", 0, empty),
            Row("./usr/share/kaitotest/a.txt", 10, "7ccc92b5adfd832a3f56064ad8304349e7b373a3b90c76de110a012251ed3455"),
            Row("./usr/share/kaitotest/b.bin", 4096, "0d356260eaf09e3b3dc81a65b2ad2399aa7c4921c0274bd2cbb54c2a21c46e3b"),
            Row("./usr/share/kaitotest/link.txt", 5, "18b7cb099a9ea3f50ba899b5ba81e0d377a5f3b16f8f6eeb8b3e58cd4692b993"),
            Row("./usr/share/kaitotest/sub", 0, empty),
            Row("./usr/share/kaitotest/sub/nested.txt", 20, "5d0e5bc93dbc8febbb6b3cea0503bfd7460284e544c2f689538fd55da59accb2")
        ]
    }

    private func fixture(_ variant: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/rpm-\(variant).rpm.b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }

    private func rows(_ reader: ArchiveReader) throws -> [Row] {
        try reader.entries.map { entry in
            let data = try reader.read(entry)
            XCTAssertEqual(UInt64(data.count), entry.uncompressedSize, entry.name)
            return Row(entry.name, try XCTUnwrap(entry.uncompressedSize),
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    func testClassicPayloadsMatchEveryGoldenRowInOrderAndPreserveMetadata() throws {
        var baseline: [Row]?
        for variant in variants {
            let bytes = try fixture(variant)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .rpm)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .rpm)
            XCTAssertEqual(reader.entries.count, 6)
            let actual = try rows(reader)
            XCTAssertEqual(actual, binaryRows, variant)
            if let baseline { XCTAssertEqual(actual, baseline, variant) } else { baseline = actual }
            XCTAssertEqual(reader.entries.map(\.kind), [.directory, .file, .file, .symlink, .directory, .file])
            XCTAssertEqual(reader.entries[3].formatSpecific["linkPath"], "a.txt")
            for entry in reader.entries {
                XCTAssertEqual(entry.formatSpecific["rpmName"], "kaitotest")
                XCTAssertEqual(entry.formatSpecific["rpmVersion"], "1.0")
                XCTAssertEqual(entry.formatSpecific["rpmRelease"], "1")
                XCTAssertEqual(entry.formatSpecific["rpmArch"], "noarch")
                XCTAssertEqual(entry.formatSpecific["rpmPayloadFormat"], "cpio")
                XCTAssertEqual(entry.formatSpecific["rpmPayloadCompressor"], variant == "none" ? nil : variant)
                XCTAssertEqual(entry.formatSpecific["rpmPayloadCompressorDetected"], variant == "none" ? "none" : nil)
                XCTAssertNil(entry.formatSpecific["rpmSourcePackage"])
                XCTAssertEqual(entry.formatSpecific["variant"], "newc")
                for key in ["uid", "gid", "nlink", "ino", "dev"] { XCTAssertNotNil(entry.formatSpecific[key]) }
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries)
            XCTAssertEqual(try rows(reopened), actual)
        }
    }

    private func assertClassicPayload(_ bytes: Data) throws -> ArchiveReader {
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.format, .rpm)
        XCTAssertEqual(reader.entries.count, 6)
        let actual = try rows(reader)
        XCTAssertEqual(actual, binaryRows)
        let aggregate = SHA256.hash(data: Data(actual.map(\.sha256).joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(aggregate, "058d0a9d9c28c2133c547d0a13fed38414a921b21f2b4109fef179c979d9150c")
        return reader
    }

    func testGzipPayloadWithoutCompressorTagUsesMagic() throws {
        let stored = try fixture("none")
        let positions = layout(stored)
        XCTAssertFalse(stride(from: positions.main + 16, to: positions.store, by: 16)
            .contains { be32(stored, $0) == 1125 })
        let compressed = try fixture("gzip")
        let bytes = Data(stored.prefix(positions.payload)) + Data(compressed.dropFirst(layout(compressed).payload))
        let reader = try assertClassicPayload(bytes)
        for entry in reader.entries {
            XCTAssertNil(entry.formatSpecific["rpmPayloadCompressor"])
            XCTAssertEqual(entry.formatSpecific["rpmPayloadCompressorDetected"], "gzip")
        }
    }

    func testGzipMagicOverridesFalseCompressorTagAndPreservesDeclaration() throws {
        var bytes = try fixture("gzip")
        let originalSize = bytes.count
        let tag = try index(1125, in: bytes)
        let offset = layout(bytes).store + be32(bytes, tag + 8)
        XCTAssertEqual(Data(bytes[offset..<(offset + 5)]), Data("gzip\0".utf8))
        bytes.replaceSubrange(offset..<(offset + 4), with: Array("none".utf8))
        XCTAssertEqual(bytes.count, originalSize)
        let reader = try assertClassicPayload(bytes)
        for entry in reader.entries {
            XCTAssertEqual(entry.formatSpecific["rpmPayloadCompressor"], "none")
            XCTAssertEqual(entry.formatSpecific["rpmPayloadCompressorDetected"], "gzip")
        }
    }

    func testSourceAndBlobFixturesMatchEveryGoldenRow() throws {
        for (variant, expected) in [
            ("src", Row("t.spec", 644, "88c78ecac96f3da9bffd0099da3d31e9f4bee59f8d1d0f40a9e2029db99342ab")),
            ("zstd", Row("kaitotest.cpio.zst", 486, "65ee8557f6e6aee264731ba5e5e1b358debf93bf830d69ec45729e0b4c8983d3")),
            ("v6", Row("kaitotest.cpio.gz", 418, "5e8621a9c3769319a89f5da60e48490db631133c4a78e21fa240229acbb9e7bb"))
        ] {
            let bytes = try fixture(variant)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .rpm)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .rpm)
            XCTAssertEqual(reader.entries.count, 1)
            XCTAssertEqual(try rows(reader), [expected], variant)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(entry.formatSpecific["rpmName"], "kaitotest")
            XCTAssertEqual(entry.formatSpecific["rpmSourcePackage"], variant == "src" ? "true" : nil)
            if variant != "src" {
                XCTAssertEqual(entry.formatSpecific["rpmArch"], "noarch")
                XCTAssertTrue(entry.methodDescription.hasPrefix("rpm payload"))
                XCTAssertEqual(try reader.read(entry), Data(bytes.dropFirst(layout(bytes).payload)))
            }
        }
    }

    // parser の計算を共有せず、利用者の配置式から mutation 位置を求める。
    private func be32(_ bytes: Data, _ offset: Int) -> Int {
        bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
    }

    private func layout(_ bytes: Data) -> (main: Int, store: Int, payload: Int) {
        let sigEnd = 96 + 16 + be32(bytes, 104) * 16 + be32(bytes, 108)
        let main = sigEnd + (8 - sigEnd % 8) % 8
        let store = main + 16 + be32(bytes, main + 8) * 16
        return (main, store, store + be32(bytes, main + 12))
    }

    private func writeBE(_ value: UInt32, into bytes: inout Data, at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
    }

    private func index(_ tag: Int, in bytes: Data) throws -> Int {
        let main = layout(bytes).main
        return try XCTUnwrap(stride(from: main + 16, to: layout(bytes).store, by: 16).first { be32(bytes, $0) == tag })
    }

    private func assertError(_ expected: String, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let category: String
            switch error {
            case KaitoError.malformed: category = "malformed"
            case KaitoError.truncated: category = "truncated"
            case KaitoError.limitExceeded: category = "limit"
            case KaitoError.unsupportedFormat: category = "format"
            case KaitoError.notFound: category = "notFound"
            default: category = String(describing: error)
            }
            XCTAssertEqual(category, expected, file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, file: file, line: line)
    }

    func testHeaderMutationsFailFastWithTypedErrors() throws {
        let original = try fixture("gzip")
        let positions = layout(original)
        // 提供された位置例と設置済み fixture の差は検証記録へ残し、固定 offset に依存しない。
        XCTAssertEqual(positions.main % 8, 0)
        XCTAssertEqual(try RpmHeader(source: DataByteSource(original), limits: ReadLimits()).payloadStart,
            UInt64(positions.payload))
        var damaged = original
        damaged[0] ^= 1
        assertError("format") { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; damaged[96] ^= 1
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        damaged = original; damaged[positions.main] ^= 1
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        for offset in [104, positions.main + 12] {
            damaged = original
            writeBE(0x7fffffff, into: &damaged, at: offset)
            assertError("limit") { _ = try ArchiveReader.open(data: damaged) }
        }
        for section in [96, positions.main] {
            damaged = original
            writeBE(UInt32(be32(original, section + 12)), into: &damaged, at: section + 16 + 8)
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
            damaged = original
            writeBE(UInt32.max, into: &damaged, at: section + 16 + 12)
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        }
        assertError("truncated") { _ = try ArchiveReader.open(data: original.prefix(positions.payload - 1)) }
        assertError("truncated") { _ = try ArchiveReader.open(data: original.prefix(95)) }
    }

    func testStringsCannotReadPastStoreOrAllocateFromAbsurdCounts() throws {
        let original = try fixture("gzip")
        let positions = layout(original)
        let nameIndex = try index(1000, in: original)
        for type: UInt32 in [6, 8, 9] {
            var damaged = original
            writeBE(type, into: &damaged, at: nameIndex + 4)
            writeBE(UInt32(positions.payload - positions.store - 1), into: &damaged, at: nameIndex + 8)
            writeBE(1, into: &damaged, at: nameIndex + 12)
            damaged[positions.payload - 1] = 65
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
            damaged = original
            writeBE(type, into: &damaged, at: nameIndex + 4)
            writeBE(UInt32.max, into: &damaged, at: nameIndex + 12)
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        }
    }

    func testCorruptCompressedPayloadIsRejectedWhileStagingForEntryReads() throws {
        for variant in ["gzip", "xz", "bzip2"] {
            var damaged = try fixture(variant)
            // 圧縮 envelope を保ち、終端検証まで進んでも破損を成功扱いしないことを確認する。
            damaged[damaged.count - (variant == "gzip" ? 8 : 4)] ^= 0x80
            let start = Date()
            XCTAssertThrowsError(try {
                let reader = try ArchiveReader.open(data: damaged)
                for entry in reader.entries { _ = try reader.read(entry) }
            }()) { error in XCTAssertTrue(error is KaitoError, "\(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        }
    }

    // RFC 1951 の stored block と RFC 1952 の envelope で小さな非 cpio stream を自作する。
    private func gzipStored(_ input: Data) -> Data {
        precondition(input.count < 65536)
        var bytes = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255, 1])
        let size = UInt16(input.count)
        for value in [size, ~size] {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        bytes.append(input)
        for value in [CRC32.checksum(input), UInt32(input.count)] {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return bytes
    }

    func testNonCpioAndDrpmFallbackPreserveRawBytesAndExtensions() throws {
        for variant in ["gzip", "none"] {
            let original = try fixture(variant)
            for plain in [Data("not a cpio archive".utf8), Data(), Data("07070X".utf8)] {
                let payload = variant == "gzip" ? gzipStored(plain) : plain
                let bytes = Data(original.prefix(layout(original).payload)) + payload
                let reader = try ArchiveReader.open(data: bytes)
                XCTAssertEqual(reader.format, .rpm)
                XCTAssertEqual(reader.entries.count, 1)
                let entry = try XCTUnwrap(reader.entries.first)
                XCTAssertEqual(entry.name, "kaitotest.cpio" + (variant == "gzip" ? ".gz" : ""))
                XCTAssertEqual(entry.methodDescription, "rpm payload (\(variant == "gzip" ? "gzip" : "stored"))")
                XCTAssertEqual(try reader.read(entry), payload)
            }
        }
        for variant in variants + ["zstd"] {
            var bytes = try fixture(variant)
            let tag = try index(1124, in: bytes)
            let offset = layout(bytes).store + be32(bytes, tag + 8)
            bytes.replaceSubrange(offset..<(offset + 4), with: Array("drpm".utf8))
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.entries.count, 1)
            let entry = try XCTUnwrap(reader.entries.first)
            let ext = ["gzip": ".gz", "xz": ".xz", "bzip2": ".bz2", "zstd": ".zst"][variant] ?? ""
            XCTAssertEqual(entry.name, "kaitotest.cpio" + ext)
            XCTAssertEqual(entry.formatSpecific["rpmPayloadFormat"], "drpm")
            XCTAssertEqual(try reader.read(entry), Data(bytes.dropFirst(layout(bytes).payload)))
        }
    }

    func testAbsentPayloadFormatAndLegacyLeadFieldsStillDescend() throws {
        var bytes = try fixture("gzip")
        let tag = try index(1124, in: bytes)
        writeBE(9999, into: &bytes, at: tag)
        for offset in [4, 5, 8, 9] { bytes[offset] = 255 }
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(try rows(reader), binaryRows)
        XCTAssertNil(reader.entries[0].formatSpecific["rpmPayloadFormat"])
    }

    func testMetadataEntryAndStagingLimitsAndTemporaryFilePath() throws {
        let bytes = try fixture("gzip")
        for limits in [ReadLimits(maxEntrySize: 100), ReadLimits(maxEntryCount: 5),
                       ReadLimits(maxMetadataSize: 100), ReadLimits(maxMetadataRecordCount: 1),
                       ReadLimits(maxPathComponentCount: 2), ReadLimits(maxTotalMetadataSize: 7100)] {
            assertError("limit") { _ = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: limits)) }
        }
        let staged = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 1)))
        XCTAssertEqual(try rows(staged), binaryRows)
        for limits in [ReadLimits(maxEntrySize: 100), ReadLimits(maxEntryCount: 0), ReadLimits(maxPathComponentCount: 0)] {
            assertError("limit") { _ = try ArchiveReader.open(data: fixture("zstd"), options: ReaderOptions(limits: limits)) }
        }
    }
}
