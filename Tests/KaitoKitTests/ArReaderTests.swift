import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class ArReaderTests: XCTestCase {
    private typealias B = ArArchiveBuilder
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).a.b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }
    private func direct(_ b: B, limits: ReadLimits = ReadLimits(), recover: Bool = false) throws -> ArReader {
        try ArReader(source: DataByteSource(data: b.data), options: ReaderOptions(limits: limits, recoverDamagedArchives: recover))
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
            case KaitoError.unsupportedMethod(let method): category = method
            case KaitoError.notFound: category = "notFound"
            default: category = String(describing: error)
            }
            XCTAssertEqual(category, expected, file: file, line: line)
        }
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testExistingFixtureAndSmallWriterFixturesExtractAndReopen() throws {
        let expected: [String: [String]] = [
            "lib": ["a.txt", "b.bin"],
            "ar-names": ["exactly16char.txt", "has space.txt", "sixteen_chars.aa", "s.txt"],
            "ar-symtab": ["__.SYMDEF SORTED", "o1.o", "o2.o"], "ar-tailpad": ["o.txt", "tail3.txt"],
            "ar-deb": ["debian-binary", "control.tar.gz", "data.tar.gz"],
            "ar-sysv": ["/", "a-very-long-member-name-exceeding-sixteen-chars.txt", "sixteen_chars.aa", "sub/deep/long-member-name.o", "short"]]
        for (fixtureName, names) in expected {
            let data = try fixture(fixtureName)
            XCTAssertEqual(try FormatDetector.detect(data: data), .ar)
            let r = try ArchiveReader.open(data: data)
            XCTAssertEqual(r.format, .ar)
            XCTAssertEqual(r.entries.map(\.name), names)
            XCTAssertEqual(r.entries.map(\.index), Array(names.indices))
            XCTAssertEqual(try r.reopen().entries, r.entries)
            let temp = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            for entry in r.entries {
                if entry.name == "/" {
                    // 公開と展開の可否は別。絶対パスの拒否は既存 Extractor の責務。
                    assertError("malformed") { _ = try r.extract(entry, to: temp) }
                } else {
                    _ = try r.extract(entry, to: temp)
                    XCTAssertEqual(try Data(contentsOf: temp.appendingPathComponent(entry.name)), try r.read(entry))
                }
                XCTAssertEqual(entry.compressedSize, entry.uncompressedSize)
                XCTAssertEqual(entry.kind, .file)
                XCTAssertNil(entry.crc32)
            }
            switch fixtureName {
            case "lib":
                XCTAssertEqual(r.entries.map(\.uncompressedSize), [27, 4096])
                XCTAssertEqual(sha(try r.read(r.entries[0])), "70bf6ca40d63eeb669f684aafbf02a896c396de1b3aab3b0efe107d66279c202")
                XCTAssertEqual(sha(try r.read(r.entries[1])), "e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c")
            case "ar-names":
                XCTAssertEqual(r.entries.map(\.uncompressedSize), [6, 3, 2, 2])
                XCTAssertEqual(r.entries.map { $0.formatSpecific["nameForm"] }, ["bsd-extended", "bsd-extended", "plain", "plain"])
                XCTAssertEqual(try r.entries.map { try r.read($0) }, ["hello\n", "hi\n", "z\n", "y\n"].map { Data($0.utf8) })
                XCTAssertEqual(r.entries.map { $0.formatSpecific["headerOffset"] }, ["8", "94", "174", "236"])
            case "ar-symtab":
                XCTAssertEqual(r.entries.map { $0.formatSpecific["headerOffset"] }, ["8", "128", "712"])
                XCTAssertEqual(try r.entries.map { sha(try r.read($0)) }, ["c00aa5904444d2a1eaa4a1f8085722720727b5aa9beabe612db1a60d4a42c4ad", "3df65c0758b77b028fb12ed9945f456137c19465764ecdd3d9ef49a8dc9e2bbb", "aeacbdb7d373f60cc34a23c5c570ff151291aed75cdfb8a9710a8e46bcda98ca"])
            case "ar-deb":
                XCTAssertEqual(try r.read(r.entries[0]), Data("2.0\n".utf8))
                XCTAssertEqual(sha(try r.read(r.entries[2])), "89a61e871bd91f64ef247ebc81b9aa055b580968582d2d7d81672db88bbdd407")
                XCTAssertEqual(try ArchiveReader.open(data: r.read(r.entries[2])).format, .gzip)
            case "ar-tailpad":
                XCTAssertEqual(data.count, 136)
                XCTAssertEqual(try r.entries.map { try r.read($0) }, [Data("odd\n".utf8), Data("abc".utf8)])
                let noPad = try ArchiveReader.open(data: Data(data.dropLast()))
                XCTAssertEqual(noPad.entries, r.entries)
                XCTAssertEqual(try noPad.read(noPad.entries[1]), Data("abc".utf8))
            case "ar-sysv":
                XCTAssertEqual(r.entries[3].pathComponents, ["sub", "deep", "long-member-name.o"])
                XCTAssertEqual(try r.entries.map { try r.read($0) }, [Data([0, 0, 0, 0])] + ["long\n", "16\n", "path\n", "x"].map { Data($0.utf8) })
            default: break
            }
        }
    }

    func testDetectionEmptyThinDamagedAndForeignMagic() throws {
        let empty = try ArchiveReader.open(data: B().data)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(try empty.reopen().entries, [])
        var b = B(); b.member(payload: [1, 2, 3])
        for count in 9..<68 {
            assertError("format") { _ = try FormatDetector.detect(data: Data(b.bytes.prefix(count))) }
        }
        var bad = b; bad.bytes[66] = 0
        assertError("format") { _ = try ArchiveReader.open(data: bad.data) }
        assertError("malformed") { _ = try direct(bad) }
        for tail in [[], Array(b.bytes.dropFirst(8))] {
            let data = Data(Array("!<thin>\n".utf8) + tail)
            XCTAssertEqual(try FormatDetector.detect(data: data), .ar)
            for recover in [false, true] {
                assertError("thin ar archive") { _ = try ArchiveReader.open(data: data, options: ReaderOptions(recoverDamagedArchives: recover)) }
            }
        }
        for magic in [Array("<bigaf>\n".utf8), Array("<aiaff>\n".utf8), [0xCA, 0xFE, 0xBA, 0xBE] + Array(repeating: UInt8(0), count: 28)] {
            assertError("format") { _ = try ArchiveReader.open(data: Data(magic + b.bytes)) }
        }
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        for ext in ["tar", "Z", "lzma"] {
            let url = temp.appendingPathComponent("archive.\(ext)")
            try b.data.write(to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .ar)
        }
    }

    func testMixedNamesSymbolsAndZeroSizeProgress() throws {
        var b = B()
        for name in ["/", "/SYM64/", "__.SYMDEF", "__.SYMDEF_64", "__.SYMDEF SORTED"] {
            b.member(name, payload: [1, 2], date: "", uid: "", gid: "", mode: "")
        }
        b.extended("__.SYMDEF SORTED", payload: [1, 2], padding: 4)
        b.extended("__.SYMDEF_64 SORTED", payload: [1, 2])
        b.member("zero")
        b.extended("empty", padding: 7)
        b.extended("freebsd-long-name.o", payload: [3])
        b.member("exactly16chars.o", payload: [4, 5, 6])
        b.member("foo/", payload: [7]); b.member("foo", payload: [8])
        let r = try ArchiveReader.open(data: b.data)
        let symbols = ["/", "/SYM64/", "__.SYMDEF", "__.SYMDEF_64", "__.SYMDEF SORTED", "__.SYMDEF SORTED", "__.SYMDEF_64 SORTED"]
        XCTAssertEqual(r.entries.map(\.name), symbols + ["zero", "empty", "freebsd-long-name.o", "exactly16chars.o", "foo", "foo"])
        XCTAssertEqual(try r.entries.map { try r.read($0) }, Array(repeating: Data([1, 2]), count: 7) + [Data(), Data(), Data([3]), Data([4, 5, 6]), Data([7]), Data([8])])
        XCTAssertEqual(r.entries.map(\.index), Array(0..<13))
        let foreign = try ArchiveReader.open(data: fixture("lib"))
        assertError("notFound") { _ = try direct(b).stream(for: foreign.entries[0], limits: ReadLimits()) }
    }

    func testSymbolPayloadsPublishedAndOnlyStringTableHidden() throws {
        var b = B()
        b.member("/", payload: [0, 1, 2])
        b.member("//", payload: Array("sub/member.o/\n".utf8))
        b.member("/SYM64/", payload: [3, 4])
        b.extended("__.SYMDEF SORTED", payload: [5, 6, 7], padding: 4)
        b.member("/0", payload: [8])
        let r = try ArchiveReader.open(data: b.data)
        XCTAssertEqual(r.entries.map(\.name), ["/", "/SYM64/", "__.SYMDEF SORTED", "sub/member.o"])
        XCTAssertEqual(r.entries.map(\.uncompressedSize), [3, 2, 3, 1])
        XCTAssertEqual(r.entries.map(\.kind), Array(repeating: .file, count: 4))
        XCTAssertEqual(r.entries.map(\.index), Array(0..<4))
        XCTAssertEqual(r.entries[2].formatSpecific["nameForm"], "bsd-extended")
        XCTAssertEqual(try r.entries.map { try r.read($0) }, [Data([0, 1, 2]), Data([3, 4]), Data([5, 6, 7]), Data([8])])
        XCTAssertEqual(try r.reopen().entries, r.entries)
        // 公開した symbol も entry 数・合計サイズの上限に含める。
        assertError("limit") { _ = try direct(b, limits: ReadLimits(maxEntryCount: 3)) }
        assertError("limit") { _ = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 8))) }
    }

    func testSysVTerminatorPathsOffsetsAndOptionalSlash() throws {
        for terminator in ["/\n", "\0", ""] {
            var b = B()
            let first = "sub/deep/name.o"
            let second = "exactly16chars.o"
            let table = Array((first + "/\n" + second + terminator).utf8)
            b.member("//", payload: table, date: "", uid: "", gid: "", mode: "")
            b.member("/0", payload: [1]); b.member("/\(first.utf8.count + 2)", payload: [2])
            b.member("debian-binary/", payload: Array("2.0\n".utf8))
            let r = try ArchiveReader.open(data: b.data)
            XCTAssertEqual(r.entries.map(\.name), [first, second, "debian-binary"])
            XCTAssertEqual(r.entries[0].pathComponents, ["sub", "deep", "name.o"])
            XCTAssertEqual(r.entries[1].formatSpecific["nameForm"], "string-table")
            XCTAssertEqual(try r.read(r.entries[1]), Data([2]))
        }
        var b = B(); b.member("//", payload: Array("dir/name//\n".utf8)); b.member("/0")
        XCTAssertEqual(try direct(b).entries[0].name, "dir/name/") // strip exactly one slash
    }

    func testHeaderNumbersAndModes() throws {
        for field in ["", "12x4", "1 2", "-1", "1\0", "999999999x"] {
            var b = B(); b.member(size: field)
            assertError("malformed") { _ = try direct(b) }
        }
        for mode in ["644", "100644"] {
            var b = B(); b.member(mode: mode)
            let entry = try direct(b).entries[0]
            XCTAssertEqual(entry.posixPermissions, 0o644)
            XCTAssertEqual(entry.modificationDate?.timeIntervalSince1970, 0)
            XCTAssertEqual(entry.formatSpecific["uid"], "12")
            XCTAssertEqual(entry.formatSpecific["gid"], "34")
        }
        var b = B(); b.member(size: " 0", date: "", uid: "", gid: "", mode: "")
        let entry = try direct(b).entries[0]
        XCTAssertNil(entry.modificationDate); XCTAssertNil(entry.posixPermissions)
        XCTAssertNil(entry.formatSpecific["uid"]); XCTAssertNil(entry.formatSpecific["gid"])
        for offset in [16, 28, 34, 40] {
            var bad = b; bad.bytes[8 + offset] = 56 // 8 is invalid only in mode
            if offset != 40 { bad.bytes[8 + offset] = 120 }
            assertError("malformed") { _ = try direct(bad) }
        }
        b = B(); b.member(); let second = b.member(); b.bytes[second + 59] = 0
        for recover in [false, true] { assertError("malformed") { _ = try direct(b, recover: recover) } }
    }

    func testMalformedNamesAndTables() throws {
        for name in ["#1/0", "#1/999", "#1/", "#1/x", "#1/1 2", ""] {
            var b = B(); b.member(name, payload: Array(repeating: 1, count: 10))
            assertError("malformed") { _ = try direct(b) }
        }
        for name in [Array(repeating: UInt8(0), count: 8), Array("a\0b.o\0\0\0".utf8)] {
            var b = B(); b.member("#1/8", payload: name)
            assertError("malformed") { _ = try direct(b) }
        }
        var b = B(); b.member("a\0b")
        assertError("malformed") { _ = try direct(b) }
        b = B(); b.member("/0")
        assertError("malformed") { _ = try direct(b) }
        for ref in ["/10", "/999", "/999999999999999"] {
            b = B(); b.member("//", payload: Array("longname/\n".utf8)); b.member(ref)
            assertError("malformed") { _ = try direct(b) }
        }
        b = B(); b.member("//"); b.member("//")
        assertError("malformed") { _ = try direct(b) }
        b = B(); b.member("//", payload: [1, 2], size: "10")
        for recover in [false, true] { assertError("truncated") { _ = try direct(b, recover: recover) } }
        b = B(); b.member("//", payload: [10]); b.member("/0")
        assertError("malformed") { _ = try direct(b) }
    }

    func testLimitsAndBoundedNameScan() throws {
        var b = B(); b.member("a/b", payload: [1, 2]); b.member("second")
        for limits in [ReadLimits(maxEntrySize: 1), ReadLimits(maxEntryCount: 1), ReadLimits(maxMetadataSize: 2),
                       ReadLimits(maxPathComponentCount: 1), ReadLimits(maxTotalMetadataSize: 1)] {
            assertError("limit") { _ = try direct(b, limits: limits) }
        }
        assertError("limit") { _ = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 1))) }
        let r = try ArchiveReader.open(data: b.data, options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 1)))
        assertError("limit") { _ = try r.read(r.entries[0]) }
        for (size, error) in [("4000000000", "truncated"), ("9999999999", "limit")] {
            b = B(); b.member(size: size)
            assertError(error) { _ = try direct(b) }
        }
        b = B(); b.member(size: "64")
        assertError("limit") { _ = try direct(b, limits: ReadLimits(maxEntrySize: 32)) }
        b = B(); b.member("#1/70000", size: "70000")
        assertError("limit") { _ = try direct(b) }
        b = B(); b.member("//", size: "33554432")
        assertError("limit") { _ = try direct(b) }
        b = B(); b.member("//", payload: Array(repeating: 97, count: 65_537)); b.member("/0")
        assertError("limit") { _ = try direct(b) }
        b = B(); b.member("//", payload: Array(repeating: 97, count: 65_536) + [47, 10]); b.member("/0")
        XCTAssertEqual(try direct(b).entries[0].rawName.bytes.count, 65_536)
        b = B(); b.member("//", payload: Array(repeating: 97, count: 100))
        assertError("limit") { _ = try direct(b, limits: ReadLimits(maxTotalMetadataSize: 99)) }
    }

    func testRecoveryEveryCutAndOddPadding() throws {
        var b = B(); b.member("first", payload: [1, 2, 3])
        let second = b.extended("has space.txt", payload: [4, 5, 6, 7], padding: 3)
        XCTAssertEqual(second, 72)
        let full = b.bytes
        for cut in second + 1..<full.count {
            b.bytes = Array(full.prefix(cut))
            assertError("truncated") { _ = try direct(b) }
            let r = try direct(b, recover: true)
            XCTAssertEqual(r.entries.first?.name, "first")
            if cut < second + 76 { XCTAssertEqual(r.entries.count, 1) }
            else {
                XCTAssertEqual(r.entries.count, 2)
                XCTAssertTrue(r.entries[1].isIncomplete)
                XCTAssertEqual(try r.stream(for: r.entries[1], limits: ReadLimits()).readAll(), Data([4, 5, 6, 7].prefix(cut - second - 76)))
            }
        }
        b.bytes = full + Array(repeating: 42, count: 30)
        assertError("truncated") { _ = try direct(b) }
        XCTAssertEqual(try direct(b, recover: true).entries.count, 2)
    }

    func testUnsafeNamesListedButExtractionRejectsAndEncodingPolicy() throws {
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        for name in ["../../etc/evil.conf", "/absolute/file"] {
            var b = B(); b.extended(name, payload: [1])
            let r = try ArchiveReader.open(data: b.data)
            XCTAssertEqual(r.entries[0].name, name)
            XCTAssertEqual(r.entries[0].pathComponents, name.split(separator: "/").map(String.init))
            assertError("malformed") { _ = try r.extract(r.entries[0], to: temp) }
        }
        var b = B(); b.member("#1/6", payload: [0x93, 0xFA, 0x96, 0x7B, 0, 0, 1, 2])
        let r = try ArchiveReader.open(data: b.data, options: ReaderOptions(encodingPolicy: .fixed(.shiftJIS)))
        XCTAssertEqual(r.entries[0].name, "日本")
        XCTAssertEqual(try r.read(r.entries[0]), Data([1, 2]))
    }

    func testDeterministicHeaderMutationsDoNotCrash() throws {
        var seed = B(); seed.member("//", payload: Array("sub/long-name.o/\n".utf8)); seed.member("/0", payload: [1, 2, 3])
        seed.extended("has space.txt", payload: [4], padding: 3)
        for index in seed.bytes.indices {
            for byte: UInt8 in [0, 10, 47, 57, 255] {
                var b = seed; b.bytes[index] = byte
                for recover in [false, true] {
                    do {
                        let r = try direct(b, limits: ReadLimits(maxEntrySize: 1 << 20, maxMetadataSize: 1 << 16), recover: recover)
                        for entry in r.entries { _ = try r.stream(for: entry, limits: ReadLimits()).readAll() }
                    } catch is KaitoError { } catch { XCTFail("Unexpected error: \(error)") }
                }
            }
        }
    }

    func testExternalOracleAcceptanceWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_AR_ORACLE"] else {
            throw XCTSkip("set KAITOKIT_AR_ORACLE to the supplied ar fixture directory")
        }
        let root = URL(fileURLWithPath: path)
        var baseline: [String: String] = [:]
        for fixture in ["bsd.a", "gnu.a", "sysv.a", "test.deb"] {
            let r = try ArchiveReader.open(url: root.appendingPathComponent(fixture))
            let expectedNames = fixture == "test.deb" ? ["debian-binary", "control.tar.gz", "data.tar.xz"] :
                ["a.txt", "b.txt", "a-very-long-member-name-exceeding-sixteen-chars.txt", "exactly16chars.o", "data.bin"]
            XCTAssertEqual(r.entries.map(\.name), expectedNames)
            XCTAssertEqual(try r.reopen().entries, r.entries)
            var digests = "", byName: [String: String] = [:]
            for entry in r.entries {
                let bytes = try r.read(entry), hash = sha(bytes)
                digests += hash; byName[entry.name] = "\(bytes.count):\(hash)"
            }
            let total = sha(Data(digests.utf8))
            if fixture == "test.deb" { XCTAssertTrue(total.hasPrefix("d85102e0bfb1c4efee731a")) }
            else {
                XCTAssertEqual(total, "80d5caebef36838bf8dc8aedbb55f80b147b12d7e306013c475b06cf73f487be")
                if fixture == "bsd.a" { baseline = byName } else { XCTAssertEqual(byName, baseline) }
            }
            print("AR_ACCEPT \(fixture) entries=\(r.entries.count) sha256=\(total) names=\(r.entries.map(\.name))")
        }
        let symbols = try ArchiveReader.open(url: root.appendingPathComponent("withsym.a"))
        XCTAssertEqual(symbols.entries.map(\.name), ["__.SYMDEF SORTED", "alpha.o", "beta.o"])
        XCTAssertEqual(symbols.entries.map(\.uncompressedSize), [40, 512, 512])
        let symbolDigests = try symbols.entries.map { sha(try symbols.read($0)) }.joined()
        let symbolTotal = sha(Data(symbolDigests.utf8))
        // XADMaster executable の black-box 出力（2026-09-09）。実装 source は不参照。
        XCTAssertEqual(symbolTotal, "a08c54571638be4ee3b5a35cac49af77a2fe3d115d5f09971a6bf7f236c67ff7")
        print("AR_ACCEPT withsym.a entries=3 sha256=\(symbolTotal)")
        let url = root.appendingPathComponent("gnu-thin.a")
        XCTAssertEqual(try FormatDetector.detect(url: url), .ar)
        assertError("thin ar archive") { _ = try ArchiveReader.open(url: url) }
        print("AR_ACCEPT gnu-thin.a rejected=unsupportedMethod(thin ar archive)")
    }
}
