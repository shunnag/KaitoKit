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

    private let variants = ["gzip", "xz", "bzip2", "none", "zstd"]
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

    func testSourceFixtureMatchesGoldenRow() throws {
        for (variant, expected) in [
            ("src", Row("t.spec", 644, "88c78ecac96f3da9bffd0099da3d31e9f4bee59f8d1d0f40a9e2029db99342ab"))
        ] {
            let bytes = try fixture(variant)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .rpm)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .rpm)
            XCTAssertEqual(reader.entries.count, 1)
            XCTAssertEqual(try rows(reader), [expected], variant)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(entry.formatSpecific["rpmName"], "kaitotest")
            XCTAssertEqual(entry.formatSpecific["rpmSourcePackage"], "true")
        }
    }

    func testExistingV6FixtureListsAndReadsEveryFile() throws {
        let reader = try ArchiveReader.open(data: fixture("v6"))
        XCTAssertEqual(try rows(reader), binaryRows)
        XCTAssertEqual(reader.entries.map(\.kind), [.directory, .file, .file, .symlink, .directory, .file])
        XCTAssertEqual(reader.entries[3].formatSpecific["linkPath"], "a.txt")
        XCTAssertEqual(reader.entries[0].formatSpecific["rpmFormat"], "6")
        XCTAssertEqual(try reader.reopen().entries, reader.entries)
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
            case KaitoError.checksumMismatch: category = "checksum"
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
        for variant in ["gzip", "xz", "bzip2", "zstd"] {
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
            for plain in [Data("not a cpio archive".utf8), Data()] {
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
            let short = Data("07070X".utf8)
            let bytes = Data(original.prefix(layout(original).payload)) + (variant == "gzip" ? gzipStored(short) : short)
            assertError("truncated") { _ = try ArchiveReader.open(data: bytes) }
        }
        for variant in variants {
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

    private struct Oracle: Decodable {
        struct PayloadRow: Decodable {
            let name, mode, sha256: String
            let size: UInt64
            let nlink: Int
        }
        struct Stripped: Decodable {
            struct Member: Decodable {
                let index, headerOffset, dataOffset, size: Int
            }
            let rows: [Member]
            let trailerOffset: Int
        }
        let payloadRows: [PayloadRow]
        let stripped: Stripped?
    }

    private func oracles() throws -> [String: Oracle] {
        struct Manifest: Decodable { let packages: [String: Oracle] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("Fixtures/container/rpm-stripped-manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: bytes).packages
    }

    func testStrippedAndClassicFixturesMatchIndependentPayloadDigestsAndMetadata() throws {
        let oracles = try oracles()
        var baseline: [ArchiveEntry]?
        var golden: [Row]?
        for variant in ["stripped-v4-gzip", "stripped-v6-zstd", "stripped-v6-gzip"] {
            let reader = try ArchiveReader.open(data: fixture(variant))
            let oracle = try XCTUnwrap(oracles["rpm-" + variant])
            let expected = oracle.payloadRows.map { Row($0.name, $0.size, $0.sha256) }
            let actual = try rows(reader)
            XCTAssertEqual(actual, expected, variant)
            XCTAssertEqual(reader.entries.count, 10)
            XCTAssertFalse(reader.entries.contains { $0.name.contains("ghost") })
            let sorted = reader.entries.sorted { $0.name < $1.name }
            if let baseline, let golden {
                XCTAssertEqual(sorted.map(\.name), baseline.map(\.name))
                XCTAssertEqual(sorted.map(\.kind), baseline.map(\.kind))
                XCTAssertEqual(sorted.map(\.uncompressedSize), baseline.map(\.uncompressedSize))
                XCTAssertEqual(sorted.map(\.methodDescription), baseline.map(\.methodDescription))
                XCTAssertEqual(sorted.map(\.posixPermissions), baseline.map(\.posixPermissions))
                XCTAssertEqual(sorted.map(\.modificationDate), baseline.map(\.modificationDate))
                XCTAssertEqual(actual.sorted { $0.name < $1.name }, golden)
            } else {
                baseline = sorted
                golden = actual.sorted { $0.name < $1.name }
            }
            for (entry, reference) in zip(reader.entries, oracle.payloadRows) {
                let mode = try XCTUnwrap(UInt32(reference.mode.dropFirst(2), radix: 8))
                XCTAssertEqual(entry.posixPermissions, UInt16(mode & 0o7777))
                XCTAssertEqual(entry.compressedSize, entry.uncompressedSize)
                XCTAssertEqual(entry.formatSpecific["nlink"], String(reference.nlink))
                if variant.contains("v6") {
                    XCTAssertEqual(entry.formatSpecific["rpmFormat"], "6")
                    XCTAssertEqual(entry.formatSpecific["rpmFileDigestAlgorithm"], "8")
                    XCTAssertNil(entry.formatSpecific["uid"])
                    XCTAssertNil(entry.formatSpecific["gid"])
                    XCTAssertEqual(entry.methodDescription, "cpio (stored)")
                    if entry.kind == .file, reference.size > 0 {
                        XCTAssertEqual(entry.formatSpecific["rpmFileDigest"], reference.sha256)
                    }
                }
            }
            let symlink = try XCTUnwrap(reader.entries.first { $0.kind == .symlink })
            XCTAssertEqual(symlink.formatSpecific["linkPath"], "日本語.txt")
            XCTAssertEqual(try reader.read(symlink), Data("日本語.txt".utf8))
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries)
            XCTAssertEqual(try rows(reopened), actual)
        }
    }

    func testStrippedHardLinksUseHighestNonGhostFileIndexRegardlessOfOrder() throws {
        let (rpm, payload, oracle) = try strippedPayload()
        // carrier を先頭へ移す。後続 placeholder のサイズは走査順に依存しない。
        var reordered = Data()
        let members = oracle.rows
        for i in [7, 9, 8, 6, 5, 4, 3, 2, 1, 0] {
            let end = i + 1 < members.count ? members[i + 1].headerOffset : oracle.trailerOffset
            reordered.append(payload[members[i].headerOffset..<end])
        }
        reordered.append(payload[oracle.trailerOffset...])
        let reader = try ArchiveReader.open(data: wrapped(reordered, in: rpm))
        XCTAssertEqual(reader.entries.map { $0.formatSpecific["rpmFileIndex"] }, ["4", "8", "7", "3", "2", "11", "6", "5", "1", "0"])
        for (prefix, carrierIndex, count, carrierFile) in [("hard-", 0, 3, "4"), ("partial-", 1, 2, "8")] {
            let set = reader.entries.filter { $0.name.contains("/" + prefix) }
            XCTAssertEqual(set.count, count)
            let carrier = reader.entries[carrierIndex]
            let dev = try XCTUnwrap(carrier.formatSpecific["dev"])
            let ino = try XCTUnwrap(carrier.formatSpecific["ino"])
            for entry in set {
                XCTAssertEqual(entry.formatSpecific["nlink"], String(count))
                XCTAssertEqual(entry.formatSpecific["hardLinkGroup"], "\(carrierIndex):\(dev):\(ino)")
                if entry.formatSpecific["rpmFileIndex"] == carrierFile {
                    XCTAssertGreaterThan(try reader.read(entry).count, 0)
                } else {
                    XCTAssertEqual(entry.uncompressedSize, 0)
                    XCTAssertEqual(try reader.read(entry), Data())
                }
            }
        }
    }

    private func strippedPayload() throws -> (Data, Data, Oracle.Stripped) {
        let rpm = try fixture("stripped-v6-gzip")
        let compressed = Data(rpm.dropFirst(layout(rpm).payload))
        let reader = try SingleFileReader(source: DataByteSource(compressed), format: .gzip,
            options: ReaderOptions(), fallbackFileName: nil)
        let payload = try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll()
        let oracle = try XCTUnwrap(oracles()["rpm-stripped-v6-gzip"]?.stripped)
        return (rpm, payload, oracle)
    }

    private func wrapped(_ payload: Data, in rpm: Data, stored: Bool = false) -> Data {
        Data(rpm.prefix(layout(rpm).payload)) + (stored ? payload : gzipStored(payload))
    }

    func testStrippedDigestIsVerifiedAtCompletionAndOtherAlgorithmsAreOnlyExposed() throws {
        let (rpm, payload, oracle) = try strippedPayload()
        let large = try XCTUnwrap(oracle.rows.first { $0.index == 5 })
        var corrupted = payload
        corrupted[large.dataOffset] ^= 1
        let reader = try ArchiveReader.open(data: wrapped(corrupted, in: rpm))
        let entry = try XCTUnwrap(reader.entries.first { $0.name.hasSuffix("/large.txt") })
        let stream = try reader.stream(entry)
        var prefix = [UInt8](repeating: 0, count: 17)
        XCTAssertEqual(try prefix.withUnsafeMutableBytes { try stream.read(into: $0) }, 17)
        assertError("checksum") { _ = try stream.readAll() }
        assertError("checksum") { _ = try stream.readAll() }
        assertError("checksum") { _ = try reader.read(entry) }

        var other = rpm
        let tag = try index(5011, in: other)
        writeBE(1, into: &other, at: layout(other).store + be32(other, tag + 8))
        let unverified = try ArchiveReader.open(data: wrapped(corrupted, in: other))
        let raw = unverified.entries[entry.index]
        XCTAssertEqual(raw.formatSpecific["rpmFileDigestAlgorithm"], "1")
        XCTAssertNotNil(raw.formatSpecific["rpmFileDigest"])
        XCTAssertEqual(try unverified.read(raw), Data(corrupted[large.dataOffset..<(large.dataOffset + large.size)]))
    }

    func testStrippedIndexAndTrailerMutationsAreRejected() throws {
        let (rpm, payload, oracle) = try strippedPayload()
        for value in ["00000009", "ffffffff", "0000000g"] {
            var damaged = payload
            damaged.replaceSubrange(6..<14, with: value.utf8)
            assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(damaged, in: rpm)) }
        }
        var repeated = payload
        repeated.replaceSubrange(22..<30, with: "00000000".utf8)
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(repeated, in: rpm)) }
        var padding = payload
        padding[14] = 1
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(padding, in: rpm)) }
        padding = payload
        let large = try XCTUnwrap(oracle.rows.first { $0.index == 5 })
        padding[large.dataOffset + large.size] = 1
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(padding, in: rpm)) }
        let trailer = Data(payload[oracle.trailerOffset...])
        for misplaced in [Data(payload.prefix(16)) + trailer, Data(payload.prefix(16)) + trailer + payload.dropFirst(16),
                          payload + Data([1]), payload + Data(repeating: 0, count: 513)] {
            assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(misplaced, in: rpm)) }
        }
        var wrongName = payload
        wrongName[oracle.trailerOffset + 110] = 88
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(wrongName, in: rpm)) }
        var wrongTrailer = payload
        wrongTrailer[wrongTrailer.count - 1] = 1
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(wrongTrailer, in: rpm)) }
        wrongTrailer = payload
        wrongTrailer[oracle.trailerOffset + 61] = 49
        assertError("malformed") { _ = try ArchiveReader.open(data: wrapped(wrongTrailer, in: rpm)) }
        for count in [6, 15, large.dataOffset + large.size - 1, oracle.trailerOffset, payload.count - 1] {
            assertError("truncated") { _ = try ArchiveReader.open(data: wrapped(Data(payload.prefix(count)), in: rpm)) }
        }
        let padded = try ArchiveReader.open(data: wrapped(payload + Data(repeating: 0, count: 512), in: rpm))
        XCTAssertEqual(padded.entries.count, 10)
    }

    func testFileListCountsTypesDirectoryIndexesAndLongSizesAreValidated() throws {
        let (rpm, payload, _) = try strippedPayload()
        let positions = layout(rpm)
        for tag in [1030, 1034, 1035, 1036, 1037, 1095, 1096, 1116, 1117, 5008] {
            var damaged = rpm
            writeBE(11, into: &damaged, at: try index(tag, in: rpm) + 12)
            assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        }
        var damaged = rpm
        let dirs = try index(1116, in: rpm)
        writeBE(UInt32.max, into: &damaged, at: positions.store + be32(rpm, dirs + 8))
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        damaged = rpm
        writeBE(4, into: &damaged, at: try index(1030, in: rpm) + 4)
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }
        damaged = rpm
        writeBE(1095, into: &damaged, at: try index(1096, in: rpm))
        assertError("malformed") { _ = try ArchiveReader.open(data: damaged) }

        let long = try index(5008, in: rpm)
        let data = positions.store + be32(rpm, long + 8)
        var short = rpm
        writeBE(1028, into: &short, at: long)
        writeBE(4, into: &short, at: long + 4)
        for i in 0..<12 { writeBE(UInt32(be32(rpm, data + i * 8 + 4)), into: &short, at: data + i * 4) }
        XCTAssertEqual(try rows(ArchiveReader.open(data: short)), try rows(ArchiveReader.open(data: rpm)))

        // LONGFILESIZES と短い tag が共存しても 64-bit 側を優先する。
        var both = rpm
        let spare = try index(1126, in: rpm)
        for (value, delta): (UInt32, Int) in [(1028, 0), (4, 4), (UInt32(be32(rpm, long + 8)), 8), (12, 12)] {
            writeBE(value, into: &both, at: spare + delta)
        }
        XCTAssertEqual(try rows(ArchiveReader.open(data: both)), try rows(ArchiveReader.open(data: rpm)))
        var huge = rpm
        writeBE(1, into: &huge, at: data + 5 * 8)
        let header = try RpmHeader(source: DataByteSource(huge), limits: ReadLimits())
        XCTAssertEqual(header.fileList?.files[5].size, (UInt64(1) << 32) + 10537)
        assertError("truncated") {
            _ = try ArchiveReader.open(data: wrapped(payload, in: huge),
                options: ReaderOptions(limits: ReadLimits(maxEntrySize: UInt64.max)))
        }
    }

    func testMissingFileListPreservesBlobFallback() throws {
        var rpm = try fixture("stripped-v6-gzip")
        writeBE(9999, into: &rpm, at: try index(1117, in: rpm))
        let reader = try ArchiveReader.open(data: rpm)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].name, "kaito-rpm6.cpio.gz")
        XCTAssertEqual(try reader.read(reader.entries[0]), Data(rpm.dropFirst(layout(rpm).payload)))
    }

    func testStrippedLimitsStoredPayloadAndDiskStagingReopen() throws {
        let (rpm, payload, _) = try strippedPayload()
        for limits in [ReadLimits(maxEntryCount: 0), ReadLimits(maxEntryCount: 9), ReadLimits(maxEntryCount: 10),
                       ReadLimits(maxEntrySize: 5000), ReadLimits(maxTotalUncompressedSize: 10000),
                       ReadLimits(maxMetadataSize: 1000), ReadLimits(maxMetadataRecordCount: 1),
                       ReadLimits(maxTotalMetadataSize: 15000), ReadLimits(maxPathComponentCount: 2)] {
            assertError("limit") { _ = try ArchiveReader.open(data: rpm, options: ReaderOptions(limits: limits)) }
        }
        // file list は ghost 込み 12 件。配列の +1 slack と実体の 10 件を別々に検査する。
        let options = ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 1, maxEntryCount: 11))
        let reader = try ArchiveReader.open(data: rpm, options: options)
        XCTAssertEqual(try reader.reopen().entries, reader.entries)
        XCTAssertEqual(try rows(reader.reopen()), try rows(reader))
        let stored = try ArchiveReader.open(data: wrapped(payload, in: rpm, stored: true))
        XCTAssertEqual(try rows(stored), try rows(reader))
        XCTAssertEqual(stored.entries[0].formatSpecific["rpmPayloadCompressorDetected"], "none")
    }
}
