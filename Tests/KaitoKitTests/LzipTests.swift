import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// lzip（draft-diaz-lzip §2）。fixture は Tests/Fixtures/lzip（自作 framing + Python raw LZMA1、
/// bundle.tar.lz は bsdtar --lzip）で、すべて XZ Utils の `xz -d --format=lzip` で照合済み。
final class LzipTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            let file: String
            let size: Int
            let sha256: String
            let dataSize: Int
            let dataSHA256: String
        }
        let fixtures: [Fixture]
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lzip")
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    private func fixture(_ name: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Data(contentsOf: root.appendingPathComponent(name + ".b64")),
                           options: .ignoreUnknownCharacters))
    }

    private func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ bytes: Data, chunk: Int = 8_191, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try LzipDecompressor(source: DataByteSource(bytes), limits: limits)
        var result = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        XCTAssertEqual(try decoder.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            if count == 0 { break }
            result.append(contentsOf: buffer[..<count])
        }
        XCTAssertTrue(decoder.isFinished)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }, 0)
        return result
    }

    // MARK: - fixtures

    func testAllIndependentFixturesMatchEveryDecodedByteAndDeclaredSizes() throws {
        for item in try manifest().fixtures {
            let name = String(item.file.dropLast(4))
            let bytes = try fixture(name)
            XCTAssertEqual(bytes.count, item.size, name)
            XCTAssertEqual(sha(bytes), item.sha256, name)
            for chunk in [1, 7, 4_096, 65_537] where chunk == 1 ? item.dataSize < 100 : true {
                let output = try decode(bytes, chunk: chunk)
                XCTAssertEqual(output.count, item.dataSize, "\(name) chunk \(chunk)")
                XCTAssertEqual(sha(output), item.dataSHA256, "\(name) chunk \(chunk)")
            }
            let index = try LzipMemberIndex(source: DataByteSource(bytes), limits: ReadLimits())
            XCTAssertEqual(index.totalDataSize, UInt64(item.dataSize), name)
            XCTAssertEqual(index.members.map(\.size).reduce(0, +), UInt64(bytes.count), name)
            XCTAssertEqual(index.members.first?.offset, 0, name)
        }
    }

    func testMultimemberIndexAndConcatenationOfSingleMembers() throws {
        let multi = try fixture("multi.lz")
        let index = try LzipMemberIndex(source: DataByteSource(multi), limits: ReadLimits())
        XCTAssertEqual(index.members.count, 3)
        XCTAssertEqual(index.members.map(\.dataSize), [24_000, 22_048, 1])
        XCTAssertEqual(index.members.map(\.dictionarySize), [1 << 20, 1 << 16, 4_096])
        let text = try fixture("text.lz"), binary = try fixture("binary.lz"), one = try fixture("one.lz")
        XCTAssertEqual(try decode(text + binary + one), try decode(multi))
        XCTAssertEqual(try decode(one + one + one), Data([0x2A, 0x2A, 0x2A]))
        // 4 KiB 辞書と 320 KiB (0xD3) の分数辞書は同じ入力を復号する。
        XCTAssertEqual(try decode(try fixture("fraction.lz")), try decode(binary))
    }

    func testDictionarySizeCodingFollowsTheSpecificationExampleAndRange() throws {
        XCTAssertEqual(try LzipMember.dictionarySize(coded: 0xD3), 320 * 1_024)
        XCTAssertEqual(try LzipMember.dictionarySize(coded: 0x0C), 4_096)
        XCTAssertEqual(try LzipMember.dictionarySize(coded: 0x1D), 512 * 1_024 * 1_024)
        XCTAssertEqual(try LzipMember.dictionarySize(coded: 0xFD), (1 << 29) - 7 * (1 << 25))
        for invalid: UInt8 in [0x00, 0x0B, 0x1E, 0x1F, 0xFF, 0xEB] {
            XCTAssertThrowsError(try LzipMember.dictionarySize(coded: invalid), "\(invalid)") {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    // MARK: - rejection

    func testStructuralCorruptionIsRejectedWithTypedErrors() throws {
        let text = try fixture("text.lz")
        let trailerStart = text.count - 20

        var version0 = text
        version0[4] = 0
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(version0), limits: ReadLimits())) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        var version2 = text
        version2[4] = 2
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(version2), limits: ReadLimits()))

        var badMagic = text
        badMagic[0] = 0x4D
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(badMagic), limits: ReadLimits())) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        var badCRC = text
        badCRC[trailerStart] ^= 0x01
        XCTAssertThrowsError(try decode(badCRC)) {
            guard case .checksumMismatch = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        var shortDataSize = text
        shortDataSize[trailerStart + 4] -= 1
        XCTAssertThrowsError(try decode(shortDataSize)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        var longDataSize = text
        longDataSize[trailerStart + 4] += 1
        XCTAssertThrowsError(try decode(longDataSize)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        // member size が file と合わない: 大きすぎ / 小さすぎ（後者は先頭の magic 検査で落ちる）。
        var hugeMember = text
        hugeMember[trailerStart + 12] += 1
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(hugeMember), limits: ReadLimits())) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        var smallMember = text
        smallMember[trailerStart + 12] -= 1
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(smallMember), limits: ReadLimits()))

        // 末尾の余分な byte、切り詰め、先頭の余分な byte。
        for trailing in [Data([0]), Data(repeating: 0, count: 26)] {
            XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(text + trailing), limits: ReadLimits()))
        }
        for cutoff in [0, 5, 25, text.count / 2, text.count - 1] {
            XCTAssertThrowsError(try decode(Data(text.prefix(cutoff))), "cutoff \(cutoff)")
        }
        XCTAssertThrowsError(try decode(Data([0]) + text))

        // LZMA stream が trailer より前で終わる（余分な byte が挟まる）member は、索引は通るが
        // 消費 byte 数の検査で拒否される。
        var padded = Data(text.prefix(trailerStart)) + Data([0]) + Data(text.suffix(20))
        let memberSize = UInt64(padded.count)
        for i in 0..<8 { padded[padded.count - 8 + i] = UInt8(truncatingIfNeeded: memberSize >> (8 * UInt64(i))) }
        XCTAssertEqual(try LzipMemberIndex(source: DataByteSource(padded), limits: ReadLimits()).members.count, 1)
        XCTAssertThrowsError(try decode(padded)) {
            guard case .malformed(let message) = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(message.contains("LZMA stream"), message)
        }

        // multimember の空 member は仕様で禁止。単独の空 member は許される。
        let empty = try fixture("empty.lz")
        XCTAssertEqual(try decode(empty), Data())
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(empty + text), limits: ReadLimits())) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testStreamPayloadCorruptionCannotProduceUncheckedOutput() throws {
        let text = try fixture("text.lz")
        for index in stride(from: 6, to: text.count - 20, by: 97) {
            var damaged = text
            damaged[index] ^= 0x5A
            XCTAssertThrowsError(try decode(damaged), "byte \(index)")
        }
    }

    func testLimitsAreAppliedAtOpenAndDuringDecode() throws {
        let multi = try fixture("multi.lz")
        let expected = try decode(multi)
        for keyPath in [\ReadLimits.maxEntrySize, \ReadLimits.maxTotalUncompressedSize] {
            var exact = ReadLimits()
            exact[keyPath: keyPath] = UInt64(expected.count)
            XCTAssertEqual(try decode(multi, limits: exact), expected)
            var short = exact
            short[keyPath: keyPath] -= 1
            XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(multi), limits: short)) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(multi), limits: ReadLimits(maxMetadataRecordCount: 2))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try decode(multi, limits: ReadLimits(maxMetadataRecordCount: 3)), expected)
        // 辞書上限は open 時に header の宣言値で検査する（text.lz は 1 MiB を宣言）。
        XCTAssertThrowsError(try LzipDecompressor(source: DataByteSource(try fixture("text.lz")), limits: ReadLimits(maxDictionarySize: 1 << 19))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try decode(try fixture("random.lz"), limits: ReadLimits(maxDictionarySize: 4_096)).count, 8_192)
    }

    // MARK: - public reader

    func testPublicReaderDetectsNamesAndReopensLzipStreams() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let text = try fixture("text.lz")
        let expected = try decode(text)

        XCTAssertEqual(try FormatDetector.detect(data: text), .lzip)
        let fromData = try ArchiveReader.open(data: text)
        XCTAssertEqual(fromData.format, .lzip)
        XCTAssertEqual(fromData.entries[0].name, "data")
        XCTAssertEqual(fromData.entries[0].methodDescription, "LZMA (lzip)")
        XCTAssertEqual(fromData.entries[0].uncompressedSize, UInt64(expected.count))
        XCTAssertEqual(fromData.entries[0].compressedSize, UInt64(text.count))
        XCTAssertEqual(try fromData.read(fromData.entries[0]), expected)

        // `.tlz` は圧縮 tar の名前なので、tar でない lzip 本文は他の圧縮 tar 別名と同じく失敗する。
        let tlz = temporary.appendingPathComponent("plain.tlz")
        try text.write(to: tlz)
        XCTAssertEqual(try FormatDetector.detect(url: tlz), .lzip)
        XCTAssertThrowsError(try ArchiveReader.open(url: tlz)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        for (name, entryName) in [("notes.lz", "notes"), ("NOTES.LZ", "NOTES"), ("unrelated.zip", "unrelated.zip")] {
            let url = temporary.appendingPathComponent(name)
            try text.write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .lzip, name)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .lzip, "Content takes precedence over suffix: \(name)")
            XCTAssertEqual(reader.entries[0].name, entryName, name)
            try FileManager.default.removeItem(at: url)
            let reopened = try reader.reopen()
            XCTAssertEqual(try reopened.read(reopened.entries[0]), expected, name)
        }
    }

    func testCompressedTarAliasesRouteLzipToTarAndKeepLZMAAloneForTlz() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = try fixture("bundle.tar.lz")
        let entrySHA = ["a.txt": "text", "b.bin": "binary"]
        for name in ["bundle.tar.lz", "BUNDLE.TAR.LZ", "bundle.tlz", "bundle.TLZ"] {
            let url = temporary.appendingPathComponent(name)
            try bundle.write(to: url)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .tar, name)
            XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "b.bin"], name)
            for entry in reader.entries {
                let source = try fixture(try XCTUnwrap(entrySHA[entry.name]) + ".lz")
                let payload = try decode(source)
                XCTAssertEqual(try reader.read(entry), payload.prefix(entry.name == "a.txt" ? 5_000 : 3_000), name)
            }
            try FileManager.default.removeItem(at: url)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries.map(\.name), ["a.txt", "b.bin"], name)
        }
        // LZMA_Alone の `.tlz` が従来どおり tar.lzma として扱われることは CompressedTarAliasTests が固定する。
    }

    /// 公開 enum の raw value と allCases。CLI の `detect` 出力は CLISmokeTests、Compat の `formatName()` は
    /// KaitoArchiveSingleFileNamesTests が固定する。
    func testPublicFormatCaseAndRawValue() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("sample.lz")
        try fixture("one.lz").write(to: url)
        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.format, .lzip)
        XCTAssertEqual(reader.format.rawValue, "lzip")
        XCTAssertTrue(ArchiveFormat.allCases.contains(.lzip))
    }
}
