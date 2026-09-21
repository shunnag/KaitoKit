import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// brotli（RFC 7932 / RFC 9841 large window）。fixture は brotli CLI 1.2.0 が書き、同 CLI で
/// 復号を確認したもの（Tests/Fixtures/brotli）。KaitoKit 側の decoder は Apple Compression。
final class BrotliTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Fixture: Decodable {
            let file: String
            let size: Int
            let sha256: String
            let dataSize: Int
            let dataSHA256: String
            let firstByte: String
        }
        let fixtures: [Fixture]
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/brotli")
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
        let decoder = try BrotliDecompressor(source: DataByteSource(bytes), limits: limits)
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

    // MARK: - header

    func testStreamHeaderDecodesEveryWBITSPatternOfRFC7932AndRFC9841() throws {
        // brotli CLI の出力から採った先頭 byte: 既定 / -w 10 / -w 16 / -w 17 / --large_window=30。
        let observed: [([UInt8], Int, Bool)] = [
            ([0x3F], 24, false), ([0x0F], 24, false), ([0x21], 10, false), ([0x40], 16, false),
            ([0x01], 17, false), ([0x11, 0x1E], 30, true),
        ]
        for (prefix, bits, large) in observed {
            let header = try BrotliStreamHeader(prefix: prefix)
            XCTAssertEqual(header.windowBits, bits, prefix.description)
            XCTAssertEqual(header.isLargeWindow, large, prefix.description)
            XCTAssertEqual(header.windowSize, (UInt64(1) << UInt64(bits)) - 16)
        }
        // RFC 7932 §9.1 の表を bit 列から組み立てて全 15 値を確認する。
        let table: [(Int, String)] = [
            (10, "0100001"), (11, "0110001"), (12, "1000001"), (13, "1010001"), (14, "1100001"),
            (15, "1110001"), (16, "0"), (17, "0000001"), (18, "0011"), (19, "0101"), (20, "0111"),
            (21, "1001"), (22, "1011"), (23, "1101"), (24, "1111"),
        ]
        for (value, pattern) in table {
            // 表は右から左へ読む並びなので、末尾の文字が bit 0。
            var byte: UInt8 = 0
            for (index, character) in pattern.reversed().enumerated() where character == "1" {
                byte |= 1 << UInt8(index)
            }
            XCTAssertEqual(try BrotliStreamHeader(prefix: [byte]).windowBits, value, pattern)
        }
        XCTAssertThrowsError(try BrotliStreamHeader(prefix: [0x91, 0x0A, 0x42, 0x52])) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try BrotliStreamHeader(prefix: [0x11])) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        for invalid: UInt8 in [0x3F, 0x09, 0x00] {
            XCTAssertThrowsError(try BrotliStreamHeader(prefix: [0x11, invalid]), "\(invalid)") {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertThrowsError(try BrotliStreamHeader(prefix: []))
    }

    // MARK: - fixtures

    func testAllIndependentFixturesMatchEveryDecodedByte() throws {
        for item in try manifest().fixtures {
            let name = String(item.file.dropLast(4))
            let bytes = try fixture(name)
            XCTAssertEqual(bytes.count, item.size, name)
            XCTAssertEqual(sha(bytes), item.sha256, name)
            XCTAssertEqual(String(format: "%02x", bytes[0]), item.firstByte, name)
            for chunk in [1, 7, 4_096, 65_537] where chunk == 1 ? item.dataSize < 100 : true {
                let output = try decode(bytes, chunk: chunk)
                XCTAssertEqual(output.count, item.dataSize, "\(name) chunk \(chunk)")
                XCTAssertEqual(sha(output), item.dataSHA256, "\(name) chunk \(chunk)")
            }
        }
    }

    func testWindowLimitTrailingBytesTruncationAndCorruptionAreHandled() throws {
        let large = try fixture("large-window.br")
        XCTAssertEqual(try BrotliDecompressor.validateHeader(source: DataByteSource(large), limits: ReadLimits()).windowBits, 30)
        XCTAssertThrowsError(try BrotliDecompressor(source: DataByteSource(large), limits: ReadLimits(maxDictionarySize: 1 << 20))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let small = try fixture("window-10.br")
        XCTAssertEqual(try decode(small, limits: ReadLimits(maxDictionarySize: 1_024)).count, 24_000)

        let text = try fixture("text-q11.br")
        for trailing in [Data([0]), Data("garbage".utf8)] {
            XCTAssertThrowsError(try decode(text + trailing)) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        // 切り詰めは gzip / xz と同じく truncated（decoder は入力を全部受け取った後の空の FINALIZE 呼び出しで
        // 失敗する）。header の途中で切れた 1 byte も含む。
        for cutoff in [1, 2, text.count / 2, text.count - 1] {
            XCTAssertThrowsError(try decode(Data(text.prefix(cutoff))), "cutoff \(cutoff)") {
                XCTAssertEqual($0 as? KaitoError, .truncated, "cutoff \(cutoff)")
            }
        }
        XCTAssertThrowsError(try decode(Data()))
        // checksum の無い形式なので破損は検出できない場合がある。落ちずに error か出力で終わること。
        for index in stride(from: 1, to: text.count, by: 61) {
            var damaged = text
            damaged[index] ^= 0x5A
            _ = try? decode(damaged)
        }
    }

    func testProbeAndDecoderHandleStreamsLargerThanTheProbeAndChunk() throws {
        // 64 KiB の試し復号と 256 KiB の decoder の入力 chunk の両方をまたぐ stream は fixture に収まらないので、
        // brotli CLI があるときだけ生成する（seed 固定: 乱数英数字 300,000 byte + ほぼ縮まない乱数 300,000
        // byte。-q 5 で約 500 KB になり、入力の refill が 2 回以上起きる）。
        let brotliPath = ZipTestSupport.brotliPath
        try ZipTestSupport.requireExecutable(brotliPath, reason: "brotli CLI is unavailable; large stream probe skipped")
        let directory = try ZipTestSupport.temporaryDirectory(label: "brotli-long")
        defer { try? FileManager.default.removeItem(at: directory) }
        var seed: UInt64 = 0x5EED_B107
        var bytes = [UInt8]()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 \n".utf8)
        for index in 0..<600_000 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            bytes.append(index < 300_000 ? alphabet[Int(seed % UInt64(alphabet.count))] : UInt8(truncatingIfNeeded: seed >> 24))
        }
        let plain = directory.appendingPathComponent("long.txt")
        try Data(bytes).write(to: plain)
        try ZipTestSupport.checkedRun(brotliPath, arguments: ["-q", "5", "-k", "long.txt"], currentDirectory: directory)
        let long = try Data(contentsOf: directory.appendingPathComponent("long.txt.br"))
        XCTAssertGreaterThan(long.count, BrotliDecompressor.chunkSize, "stream must span more than one input chunk")
        XCTAssertEqual(try decode(long), Data(bytes))
        XCTAssertTrue(BrotliDecompressor.isPlausibleStream(source: DataByteSource(long), limits: ReadLimits()))
        XCTAssertEqual(try decode(long, chunk: 600_001).count, 600_000)
        XCTAssertEqual(try decode(long, chunk: 4_097).count, 600_000)
        // 2 つ目以降の入力 chunk の後ろに付いた末尾ゴミも END 時点の消費位置で検出する。
        XCTAssertThrowsError(try decode(long + Data([0x00]))) {
            XCTAssertEqual($0 as? KaitoError, .malformed("brotli stream has trailing bytes"))
        }
        // 2 つ目の入力 chunk の途中で切れた stream は truncated。
        XCTAssertThrowsError(try decode(Data(long.prefix(BrotliDecompressor.chunkSize + 1_000)))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        // 試し復号の範囲より後ろで壊れていても検出は通り、読み取りで失敗するか出力が変わる。
        var damaged = long
        damaged[long.count - 100] ^= 0xFF
        XCTAssertTrue(BrotliDecompressor.isPlausibleStream(source: DataByteSource(damaged), limits: ReadLimits()))
        _ = try? decode(damaged)
        // 試し復号は先頭 64 KiB を FINALIZE なしで走らせるので、切り詰めた stream も検出は通る。
        let cut = Data(long.prefix(70_000))
        XCTAssertTrue(BrotliDecompressor.isPlausibleStream(source: DataByteSource(cut), limits: ReadLimits()))
        XCTAssertThrowsError(try decode(cut))
    }

    // MARK: - public reader

    func testDetectionRequiresNameHeaderAndTrialDecode() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let text = try fixture("text-q1.br")
        let expected = try decode(text)

        // 名前の無い Data は magic が無いため受理しない。
        XCTAssertThrowsError(try FormatDetector.detect(data: text)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
        for (name, entryName) in [("notes.br", "notes"), ("NOTES.BR", "NOTES"), ("archive.tar.br", nil)] {
            let url = temporary.appendingPathComponent(name)
            try text.write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .brotli, name)
            if let entryName {
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(reader.format, .brotli, name)
                XCTAssertEqual(reader.entries[0].name, entryName, name)
                XCTAssertEqual(reader.entries[0].methodDescription, "Brotli", name)
                XCTAssertNil(reader.entries[0].uncompressedSize, name)
                XCTAssertEqual(reader.entries[0].compressedSize, UInt64(text.count), name)
                XCTAssertEqual(try reader.read(reader.entries[0]), expected, name)
                try FileManager.default.removeItem(at: url)
                XCTAssertEqual(try reader.reopen().read(reader.entries[0]), expected, name)
            } else {
                // `.tar.br` の中身が tar でなければ他の圧縮 tar 別名と同じく失敗する。
                XCTAssertThrowsError(try ArchiveReader.open(url: url), name)
            }
        }
        // 署名を持つ形式が `.br` を名乗っても署名が勝つ。
        let zip = temporary.appendingPathComponent("really.br")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
        XCTAssertEqual(try FormatDetector.detect(url: zip), .zip)
        // 無効な header（shared brotli framing の署名）と、END 後に余分な byte が続くものは受理しない。
        for bytes in [Data([0x91, 0x0A, 0x42, 0x52, 0, 0, 0, 0]), text + Data("tail".utf8)] {
            let url = temporary.appendingPathComponent("bad.br")
            try bytes.write(to: url)
            XCTAssertThrowsError(try FormatDetector.detect(url: url)) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
            }
        }
        // 辞書上限を超える window は検出段階で除外し、reader も open で拒否する。
        let large = temporary.appendingPathComponent("large.br")
        try fixture("large-window.br").write(to: large)
        XCTAssertEqual(try FormatDetector.detect(url: large), .brotli)
        XCTAssertThrowsError(try ArchiveReader.open(url: large, options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 1 << 24)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testCompressedTarAliasesRouteBrotliToTar() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = try fixture("bundle.tar.br")
        let text = try decode(try fixture("text-q1.br")), binary = try decode(try fixture("binary-q5.br"))
        for name in ["bundle.tar.br", "BUNDLE.TAR.BR", "bundle.tbr"] {
            let url = temporary.appendingPathComponent(name)
            try bundle.write(to: url)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .tar, name)
            XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "b.bin"], name)
            XCTAssertEqual(try reader.read(reader.entries[0]), text.prefix(5_000), name)
            XCTAssertEqual(try reader.read(reader.entries[1]), binary.prefix(3_000), name)
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(try reader.reopen().entries.map(\.name), ["a.txt", "b.bin"], name)
        }
        let single = temporary.appendingPathComponent("bundle.tbr")
        try bundle.write(to: single)
        let reader = try ArchiveReader.open(url: single)
        XCTAssertEqual(reader.format, .tar)
    }

    func testEntryLimitsApplyToUnknownSizeOutput() throws {
        let text = try fixture("text-q1.br")
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("limits.br")
        try text.write(to: url)
        for keyPath in [\ReadLimits.maxEntrySize, \ReadLimits.maxTotalUncompressedSize, \ReadLimits.maxInMemorySize] {
            var exact = ReadLimits()
            exact[keyPath: keyPath] = 24_000
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: exact))
            XCTAssertEqual(try reader.read(reader.entries[0]).count, 24_000)
            var short = exact
            short[keyPath: keyPath] = 23_999
            XCTAssertThrowsError(try {
                let rejected = try ArchiveReader.open(url: url, options: ReaderOptions(limits: short))
                _ = try rejected.read(rejected.entries[0])
            }()) { guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") } }
        }
    }
}
