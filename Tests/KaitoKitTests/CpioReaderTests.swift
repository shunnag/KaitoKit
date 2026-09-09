import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class CpioReaderTests: XCTestCase {
    private typealias B = CpioArchiveBuilder
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).cpio.b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }
    private func direct(_ b: B, limits: ReadLimits = ReadLimits(), recover: Bool = false) throws -> CpioReader {
        try CpioReader(source: DataByteSource(data: b.data), options: ReaderOptions(limits: limits, recoverDamagedArchives: recover))
    }
    private func assertError(_ expected: String, _ operation: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
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
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testExistingFixturesAndReopen() throws {
        let expected = ["", "70bf6ca40d63eeb669f684aafbf02a896c396de1b3aab3b0efe107d66279c202",
            "e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c", "",
            "4e7267fd5c54130fe83e69920d63e38117957e56f9172965b8db27c75a3c1a96"]
        for name in ["newc", "odc", "bin"] {
            let reader = try ArchiveReader.open(data: fixture(name))
            XCTAssertEqual(reader.format, .cpio)
            XCTAssertEqual(reader.entries.map(\.name), [".", "./a.txt", "./b.bin", "./sub", "./sub/nested.txt"])
            XCTAssertEqual(reader.entries.map(\.uncompressedSize), [0, 27, 4096, 0, 15])
            for (index, entry) in reader.entries.enumerated() {
                let data = try reader.read(entry)
                XCTAssertEqual(sha(data), expected[index].isEmpty ? sha(Data()) : expected[index])
                XCTAssertEqual(entry.formatSpecific["variant"], name == "bin" ? "bin-le" : name)
            }
            XCTAssertEqual(try reader.reopen().entries, reader.entries)
        }
    }

    func testSmallWriterFixturesAllMissingVariantsAndExtraction() throws {
        for name in ["crc", "bcpio", "hpbin", "hpodc"] {
            let reader = try ArchiveReader.open(data: fixture(name))
            XCTAssertEqual(reader.format, .cpio)
            XCTAssertEqual(reader.entries.count, 6)
            let file = try XCTUnwrap(reader.entries.first { $0.name == "./a.txt" || $0.name == "a.txt" })
            let link = try XCTUnwrap(reader.entries.first { $0.kind == .symlink })
            XCTAssertEqual(link.formatSpecific["linkPath"], "a.txt")
            XCTAssertEqual(try reader.read(link), Data("a.txt".utf8))
            let expectedVariant = ["crc": "crc", "bcpio": "bin-be", "hpbin": "bin-le", "hpodc": "odc"][name]
            XCTAssertEqual(file.formatSpecific["variant"], expectedVariant)
            if (file.uncompressedSize ?? 0) > 0 { XCTAssertEqual(try reader.read(file), Data("hello\n".utf8)) }
            XCTAssertEqual(try reader.reopen().entries, reader.entries)
            let temp = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            for entry in reader.entries { _ = try reader.extract(entry, to: temp) }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: temp.appendingPathComponent("link.txt").path), "a.txt")
            XCTAssertEqual(try Data(contentsOf: temp.appendingPathComponent("sub/n.txt")), Data("nested\n".utf8))
        }
    }

    func testPDPWordsAnd32BitFileSizesInBothOrders() throws {
        for variant in [B.Variant.binLittle, .binBig] {
            var b = B()
            b.record(payload: Array(repeating: 73, count: 0x12345), variant: variant, mtime: 0x12345678)
            XCTAssertEqual(Array(b.bytes[16..<20]), variant == .binLittle ? [0x34, 0x12, 0x78, 0x56] : [0x12, 0x34, 0x56, 0x78])
            XCTAssertEqual(Array(b.bytes[22..<26]), variant == .binLittle ? [1, 0, 0x45, 0x23] : [0, 1, 0x23, 0x45])
            b.trailer(variant)
            let reader = try ArchiveReader.open(data: b.data)
            XCTAssertEqual(reader.entries[0].modificationDate?.timeIntervalSince1970, TimeInterval(0x12345678))
            XCTAssertEqual(try reader.read(reader.entries[0]), Data(repeating: 73, count: 0x12345))
        }
        var b = B(); b.record(variant: .binLittle)
        XCTAssertEqual(Array(b.bytes[16..<20]), [0xA0, 0x6A, 0x6F, 0xB0])
        XCTAssertEqual(try direct(b).entries[0].modificationDate?.timeIntervalSince1970, 1_788_915_823)
        b = B(); b.record(variant: .binBig, mtime: 0x6AA0F819)
        XCTAssertEqual(Array(b.bytes[16..<20]), [0x6A, 0xA0, 0xF8, 0x19])
        XCTAssertEqual(try direct(b).entries[0].modificationDate?.timeIntervalSince1970, TimeInterval(0x6AA0F819))
    }

    func testAlignmentAndCleanEOFForEveryEnvelope() throws {
        for variant in B.Variant.allCases {
            var b = B()
            b.record("aa", payload: [1, 2, 3], variant: variant)
            let second = b.record("z", payload: [4], variant: variant)
            XCTAssertEqual(second, variant == .odc ? 82 : (variant == .binLittle || variant == .binBig ? 34 : 120))
            let r = try ArchiveReader.open(data: b.data)
            XCTAssertEqual(r.entries.count, 2)
            XCTAssertEqual(try r.entries.map { try r.read($0) }, [Data([1, 2, 3]), Data([4])])
        }
        var b = B(); b.record(".", mode: 0o040755)
        XCTAssertEqual(b.bytes.count, 112)
        b.trailer(); XCTAssertEqual(b.bytes.count, 236)
        XCTAssertEqual(try ArchiveReader.open(data: b.data).entries.count, 1)
    }

    func testSymlinkAndHardLinksRespectStoredSize() throws {
        for variant in B.Variant.allCases {
            var b = B()
            b.record("日本語.txt", variant: variant, ino: 4, nlink: 2)
            b.record("carrier", payload: [4, 5], variant: variant, ino: 4, nlink: 2)
            b.record("link", payload: Array("a.txt".utf8), variant: variant, mode: 0o120777, check: 0)
            b.trailer(variant)
            let r = try ArchiveReader.open(data: b.data)
            XCTAssertEqual(r.entries[0].name, "日本語.txt")
            XCTAssertEqual(r.entries[0].uncompressedSize, 0)
            XCTAssertEqual(try r.read(r.entries[0]), Data())
            XCTAssertEqual(r.entries[0].formatSpecific["hardLinkGroup"], r.entries[1].formatSpecific["hardLinkGroup"])
            XCTAssertNil(r.entries[0].formatSpecific["hardLinkDataIndex"])
            XCTAssertEqual(try r.read(r.entries[1]), Data([4, 5]))
            XCTAssertEqual(r.entries[2].formatSpecific["linkPath"], "a.txt")
            XCTAssertEqual(try r.read(r.entries[2]), Data("a.txt".utf8))
        }
    }

    func testChecksumUsesOnlyDataAndMismatchIsMalformed() throws {
        var b = B(); b.record("aa", payload: [0xFF, 0x80, 1], variant: .crc)
        b.bytes[113] = 99 // name padding is outside the checksum
        b.bytes[119] = 98 // data padding is outside the checksum
        b.record("bad", payload: [1], variant: .crc, check: 2)
        b.record("good", payload: [2], variant: .crc)
        let r = try ArchiveReader.open(data: b.data)
        XCTAssertNil(r.entries[0].crc32)
        XCTAssertEqual(r.entries[0].formatSpecific["check"], "00000180")
        XCTAssertEqual(try r.read(r.entries[0]), Data([0xFF, 0x80, 1]))
        assertError("malformed") { _ = try r.read(r.entries[1]) }
        XCTAssertEqual(try r.read(r.entries[2]), Data([2]))
    }

    func testNamesDigitsAndNegativeSize() throws {
        for bytes: [UInt8] in [[], [0], [0, 0], [97, 98], [97, 0, 98, 0]] {
            var b = B(); b.record(nameBytes: bytes)
            assertError("malformed") { _ = try direct(b) }
        }
        var b = B(); b.record(nameBytes: [97, 0, 0, 0, 0]); b.trailer()
        XCTAssertEqual(try direct(b).entries.map(\.name), ["a"])
        b = B(); b.record(); b.bytes.replaceSubrange(94..<102, with: Array("00100000".utf8))
        assertError("limit") { _ = try direct(b) }
        for variant in [B.Variant.odc, .newc] {
            b = B(); b.record(variant: variant); b.bytes[6] = variant == .odc ? 56 : 103
            assertError("malformed") { _ = try direct(b) }
        }
        b = B(); b.record(mtime: 0xABCDEFAB)
        for i in 6..<110 where (97...102).contains(b.bytes[i]) { b.bytes[i] -= 32 }
        XCTAssertEqual(try direct(b).entries[0].modificationDate?.timeIntervalSince1970, TimeInterval(0xABCDEFAB))
        b = B(); b.record(variant: .binLittle, declaredSize: 0x80000000)
        assertError("malformed") { _ = try direct(b) }
    }

    func testTruncationAndRecoveryAtHeaderNameDataAndPadding() throws {
        for variant in B.Variant.allCases {
            var b = B(); b.record("first", variant: variant)
            let start = b.record("next", payload: [1, 2, 3, 4, 5], variant: variant)
            let full = b
            for cut in start + 1..<full.bytes.count {
                b.bytes = Array(full.bytes.prefix(cut))
                assertError("truncated") { _ = try direct(b) }
                let recovered = try direct(b, recover: true)
                XCTAssertEqual(recovered.entries[0].name, "first")
                XCTAssertLessThanOrEqual(recovered.entries.count, 2)
                if recovered.entries.count == 2 { XCTAssertTrue(recovered.entries[1].isIncomplete) }
            }
        }
        var b = B(); b.record("first"); b.record("short", payload: [1, 2], variant: .crc, declaredSize: 30, check: 999)
        let r = try direct(b, recover: true)
        XCTAssertTrue(r.entries[1].isIncomplete)
        XCTAssertEqual(r.entries[1].uncompressedSize, 4) // two stored bytes and two physical pad bytes
        _ = try r.stream(for: r.entries[1], limits: ReadLimits()).readAll()
    }

    func testLimits() throws {
        var b = B(); b.record("a/b", payload: [1, 2]); b.record("second")
        for limits in [ReadLimits(maxEntrySize: 1), ReadLimits(maxEntryCount: 1), ReadLimits(maxMetadataSize: 2),
                       ReadLimits(maxPathComponentCount: 1), ReadLimits(maxTotalMetadataSize: 1)] {
            assertError("limit") { _ = try direct(b, limits: limits) }
        }
        assertError("limit") { _ = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 1))) }
        let r = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 1)))
        assertError("limit") { _ = try r.read(r.entries[0]) }
        b = B(); b.record(variant: .odc, declaredSize: 6 * 1024 * 1024 * 1024)
        assertError("limit") { _ = try direct(b) }
        b = B(); b.record(payload: [1], mode: 0o120777, declaredSize: 65_537)
        assertError("limit") { _ = try direct(b, recover: true) }
        b = B(); b.record(payload: Array("a/b".utf8), mode: 0o120777)
        assertError("limit") { _ = try direct(b, limits: ReadLimits(maxPathComponentCount: 1)) }
    }

    func testTrailerConcatenationNULCapAndSpecialKinds() throws {
        var b = B()
        for mode: UInt32 in [0o040755, 0o010600, 0o020600, 0o060600, 0o140600, 0] {
            b.record("special", payload: [1, 2, 3], mode: mode)
        }
        b.record("TRAILER!!!", payload: [7, 8, 9, 10], nameBytes: Array("TRAILER!!!".utf8) + [0, 0, 0])
        b.bytes += Array(repeating: 0, count: 19)
        b.record("next", payload: [11], variant: .odc)
        b.trailer(.odc); b.bytes += [42, 43] // undefined trailing bytes
        let r = try ArchiveReader.open(data: b.data)
        XCTAssertEqual(r.entries.count, 7)
        XCTAssertEqual(r.entries.prefix(6).map(\.uncompressedSize), Array(repeating: 0, count: 6))
        XCTAssertEqual(r.entries[0].kind, .directory)
        XCTAssertTrue(r.entries[1..<6].allSatisfy { $0.kind == .other })
        XCTAssertEqual(r.entries[6].formatSpecific["archiveIndex"], "1")
        XCTAssertEqual(try r.read(r.entries[6]), Data([11]))
        b = B(); b.record(); b.bytes += Array(repeating: 0, count: 2 << 20); b.record("hidden")
        XCTAssertEqual(try direct(b).entries.count, 1)
        b = B(); b.record(); b.bytes += Array(repeating: 0, count: 1 << 20); b.record("visible")
        XCTAssertEqual(try direct(b).entries.count, 2)
        b = B(); b.record(payload: [97, 0, 98], mode: 0o120777)
        assertError("malformed") { _ = try direct(b) }
        b = B(); b.record(mode: 0o120777)
        assertError("malformed") { _ = try direct(b) }
    }

    func testDetectionChainLongNameAndExistingPriority() throws {
        var b = B(); b.record(String(repeating: "n", count: 1024))
        XCTAssertEqual(try FormatDetector.detect(data: b.data), .cpio)
        for variant in [B.Variant.binLittle, .binBig] {
            b = B(); b.record(variant: variant); b.bytes += [42, 42, 42, 42, 42, 42]
            XCTAssertFalse(CpioHeader.probeBinary(source: DataByteSource(data: b.data)))
            assertError("format") { _ = try FormatDetector.detect(data: b.data) }
            b = B(); b.record(payload: Array(repeating: 1, count: 5000), variant: variant); b.trailer(variant)
            XCTAssertEqual(try FormatDetector.detect(data: b.data), .cpio)
            let temp = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let url = temp.appendingPathComponent("hint.tar"); try b.data.write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .tar)
        }
        for bytes in [Array("070703".utf8), Array("07070X".utf8), Array(repeating: UInt8(0), count: 4096)] {
            assertError("format") { _ = try FormatDetector.detect(data: Data(bytes)) }
        }
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        // 0xC7 は properties として合法だが、辞書の LSB=0x71 は既存の保守的 probe を通らない。
        let url = temp.appendingPathComponent("collision.lzma")
        try Data([0xC7, 0x71, 0, 0, 0] + Array(repeating: 0xFF, count: 8) + [0, 0, 0, 0, 0]).write(to: url)
        assertError("format") { _ = try FormatDetector.detect(url: url) }
        try Data([0x5D, 0, 0, 0x80, 0] + Array(repeating: 0xFF, count: 8) + [0, 0, 0, 0, 0]).write(to: url)
        XCTAssertEqual(try FormatDetector.detect(url: url), .lzma)
    }
    func testBinaryRecoveryRequiresTwoCompleteRecordsAndOnlyEOF() throws {
        let options = ReaderOptions(recoverDamagedArchives: true)
        for variant in [B.Variant.binLittle, .binBig] {
            for completeCount in 0...2 {
                var b = B()
                for i in 0..<completeCount { b.record("complete\(i)", payload: [1, 2], variant: variant) }
                let tail = b.record("cut", payload: Array(0..<9), variant: variant)
                let intact = b.bytes
                // Missing header/name/data/padding bytes, but at least the binary magic must remain.
                for cut in tail + 2..<intact.count {
                    b.bytes = Array(intact.prefix(cut))
                    XCTAssertFalse(CpioHeader.probeBinary(source: DataByteSource(data: b.data)))
                    if completeCount < 2 {
                        assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
                    } else {
                        XCTAssertEqual(try FormatDetector.detect(data: b.data, options: options), .cpio)
                        XCTAssertEqual(try FormatDetector.detect(source: DataByteSource(data: b.data), options: options), .cpio)
                        let r = try ArchiveReader.open(data: b.data, options: options)
                        XCTAssertEqual(r.entries.prefix(2).map(\.name), ["complete0", "complete1"])
                        if let entry = r.entries.last, entry.name == "cut" {
                            XCTAssertTrue(entry.isIncomplete)
                            let stream = try r.stream(entry)
                            let expected = Data(Array(0..<9).prefix(min(9, cut - tail - 30)))
                            if !expected.isEmpty { XCTAssertEqual(stream.remaining, UInt64.max) }
                            XCTAssertEqual(try stream.readAll(), expected)
                        }
                    }
                }
                b.bytes = Array(intact.prefix(tail)) + [0xC7] // incomplete magic supplies insufficient evidence
                assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
            }
            var prefix = B(); prefix.record("one", variant: variant); prefix.record("two", variant: variant)
            for name in [[UInt8](), [0], [97, 98], [97, 0, 98, 0]] {
                var b = prefix
                b.record(variant: variant, declaredSize: 1000, nameBytes: name)
                assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
            }
            for mode: UInt32 in [0o030000, 0o170000] {
                var b = prefix; b.record(variant: variant, mode: mode, declaredSize: 1000)
                assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
            }
            var b = prefix; b.record(variant: variant, declaredSize: 0x80000000)
            assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
            for garbage: [UInt8] in [[42], [42, 42], [0xC7, 0x70], [42, 42, 42, 42, 42, 42]] {
                b = prefix; b.bytes += garbage
                assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
            }
            b = prefix; b.record(variant: variant, declaredSize: 1000); b.bytes[0] = 42
            assertError("format") { _ = try ArchiveReader.open(data: b.data, options: options) }
        }
    }

    func testBinaryRecoveryURLReopenAndLimits() throws {
        var b = B(); b.record("one", variant: .binLittle); b.record("two", variant: .binLittle)
        b.record("cut", payload: [1, 2, 3, 4], variant: .binLittle, declaredSize: 10)
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("cut.cpio"); try b.data.write(to: url)
        let options = ReaderOptions(recoverDamagedArchives: true)
        assertError("format") { _ = try FormatDetector.detect(url: url) }
        assertError("format") { _ = try ArchiveReader.open(url: url) }
        XCTAssertEqual(try FormatDetector.detect(url: url, options: options), .cpio)
        let r = try ArchiveReader.open(url: url, options: options)
        XCTAssertEqual(r.entries.count, 3)
        XCTAssertEqual(try r.reopen().entries, r.entries)
        XCTAssertEqual(try r.read(r.entries[2]), Data([1, 2, 3, 4]))
        for limits in [ReadLimits(maxEntrySize: 9), ReadLimits(maxEntryCount: 2), ReadLimits(maxTotalUncompressedSize: 3)] {
            assertError("limit") { _ = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: limits, recoverDamagedArchives: true)) }
        }
    }

    func testExternalBinaryRecoveryAcceptanceWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_CPIO_ORACLE"] else {
            throw XCTSkip("set KAITOKIT_CPIO_ORACLE to the supplied cpio fixture directory")
        }
        let root = URL(fileURLWithPath: path)
        let hpbin = try Data(contentsOf: root.appendingPathComponent("gnu-hpbin.cpio"))
        let cases: [(String, Data, [String], Int)] = [
            ("bin-t60", try Data(contentsOf: root.appendingPathComponent("hostile/bin-t60.cpio")), [".", "./a.txt", "./b.txt", "./data.bin"], 30_258),
            ("hpbin-t60", Data(hpbin.prefix(hpbin.count * 60 / 100)), [".", "a.txt", "b.txt", "data.bin"], 30_264)
        ]
        for (label, data, names, size) in cases {
            assertError("format") { _ = try ArchiveReader.open(data: data) }
            let r = try ArchiveReader.open(data: data, options: ReaderOptions(recoverDamagedArchives: true))
            XCTAssertEqual(r.entries.map(\.name), names)
            XCTAssertEqual(r.entries.map(\.uncompressedSize), [0, 6, 14, UInt64(size)])
            XCTAssertEqual(r.entries.map(\.isIncomplete), [false, false, false, true])
            var digests = ""
            for entry in r.entries {
                let bytes = try r.read(entry)
                let expected = entry.kind == .directory ? Data() : Data(try Data(contentsOf: root.appendingPathComponent("src/\(entry.name)")).prefix(Int(entry.uncompressedSize!)))
                XCTAssertEqual(bytes, expected)
                digests += sha(bytes)
                print("CPIO_RECOVER \(label) \(entry.name) size=\(bytes.count) sha256=\(sha(bytes))")
            }
            let expectedDigest = label == "bin-t60"
                ? "dd08768ab0db5e521363a12eddc486a6e4cf923b432fb7234c4f0a2a8908407a"
                : "9c973ba687a794e3e7e5c428d0fbc517382014742c1e79ecf82565ec09cbbef6"
            XCTAssertEqual(sha(Data(digests.utf8)), expectedDigest)
            print("CPIO_RECOVER_TOTAL \(label) \(sha(Data(digests.utf8)))")
        }
    }

    func testExternalDetectionCorpusWithRecoveryWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_CPIO_DETECTION_BASELINE"] else {
            throw XCTSkip("set KAITOKIT_CPIO_DETECTION_BASELINE to the pre-change detection JSON")
        }
        struct Case: Decodable { let path: String; let status: Int; let stdout: String }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for item in cases {
            for recover in [false, true] {
                let options = ReaderOptions(recoverDamagedArchives: recover)
                if item.status == 0 {
                    XCTAssertEqual(try FormatDetector.detect(url: URL(fileURLWithPath: item.path), options: options).rawValue,
                                   item.stdout.trimmingCharacters(in: .whitespacesAndNewlines), item.path)
                } else {
                    assertError("format") { _ = try FormatDetector.detect(url: URL(fileURLWithPath: item.path), options: options) }
                }
            }
        }
        print("CPIO_RECOVERY_CORPUS \(cases.count) archives, strict/recovery unchanged")
    }

    func testExternalOracleAcceptanceWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_CPIO_ORACLE"] else {
            throw XCTSkip("set KAITOKIT_CPIO_ORACLE to the supplied cpio fixture directory")
        }
        let root = URL(fileURLWithPath: path)
        var newcByName: [String: String] = [:]
        for fixture in ["bin", "odc", "newc", "gnu-crc", "gnu-newc", "gnu-odc", "gnu-bin", "gnu-hpodc", "gnu-hpbin", "tar-newc"] {
            for recover in [false, true] {
                let r = try ArchiveReader.open(url: root.appendingPathComponent("\(fixture).cpio"), options: ReaderOptions(recoverDamagedArchives: recover))
                XCTAssertEqual(r.format, .cpio)
                XCTAssertEqual(r.entries.count, 12, fixture)
                XCTAssertEqual(try r.reopen().entries, r.entries)
                var digests = ""
                var byName: [String: String] = [:]
                for entry in r.entries {
                    let contents = try r.read(entry)
                    let name = entry.name.hasPrefix("./") ? String(entry.name.dropFirst(2)) : entry.name
                    let hash = sha(contents)
                    digests += hash
                    byName[name] = "\(entry.uncompressedSize ?? 0):\(hash)"
                    if name == "data.bin" {
                        XCTAssertEqual(contents.count, 50_000)
                        XCTAssertEqual(contents, try Data(contentsOf: root.appendingPathComponent("src/data.bin")))
                    }
                    if entry.kind == .symlink {
                        XCTAssertEqual(entry.formatSpecific["linkPath"], "a.txt")
                        XCTAssertEqual(contents, Data("a.txt".utf8))
                    } else if entry.kind == .file, !contents.isEmpty {
                        XCTAssertEqual(contents, try Data(contentsOf: root.appendingPathComponent("src/\(name)")))
                    }
                }
                XCTAssertNotNil(byName["日本語.txt"])
                let aggregate = sha(Data(digests.utf8))
                let expected: String
                if fixture == "tar-newc" {
                    expected = "2f164c10f679679b63186ff46af5cc0b7b06467eb51d89fed05657edb1b7bd03"
                    XCTAssertEqual(byName, newcByName)
                } else if ["newc", "gnu-newc", "gnu-crc"].contains(fixture) {
                    expected = "b380629a345afd99a978e71da779336ed37d09ace9c95bf96b5db5bb10b96f27"
                    if fixture == "newc" { newcByName = byName }
                    else { XCTAssertEqual(byName, newcByName) }
                } else {
                    expected = "5b136084392db8a1b265ebe0490c85c27382e918666b31207e6f064f011c0be3"
                }
                XCTAssertEqual(aggregate, expected, fixture)
                print("CPIO_ACCEPT \(fixture) recover=\(recover) entries=\(r.entries.count) sha256=\(aggregate) data.bin=match japanese=match symlink=a.txt")
            }
        }
    }

}
