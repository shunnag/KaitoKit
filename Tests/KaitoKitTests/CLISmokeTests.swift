import CryptoKit
import CoreFoundation
import Foundation
import KaitoKit
import XCTest

final class CLISmokeTests: XCTestCase {
    func testDetectEncodingIANARoundTripsForAllCorpusEncodings() throws {
        let samples = [
            ("windows-1250", "a3f3649f", "Łódź"),
            ("windows-1251", "d3eaf0e0bfede0", "Україна"),
            ("windows-1252", "45737061f161", "España"),
            ("windows-1253", "c5ebebdce4e1", "Ελλάδα"),
            ("windows-1254", "54fc726be765", "Türkçe"),
            ("windows-1258", "eaec", "ê\u{0301}"),
            ("iso-8859-2", "a3f364bc", "Łódź"),
            ("iso-8859-5", "c0dee1e1d8ef", "Россия"),
            ("iso-8859-15", "63bd7572", "cœur"),
            ("koi8-r", "f2cfd3d3c9d1", "Россия"),
            ("koi8-u", "f5cbd2c1a7cec1", "Україна"),
            ("cp866", "90aee1e1a8ef", "Россия"),
            ("cp850", "477294e165", "Größe"),
            ("macintosh", "4672616e8d616973", "Français"),
            ("x-mac-cyrillic", "90eef1f1e8df", "Россия"),
            ("x-mac-centraleurroman", "fc976490", "Łódź"),
            ("cp874", "c0d2c9d2e4b7c2", "ภาษาไทย"),
            ("cp932", "93fa967b8cea", "日本語"),
            ("euc-jp", "a4d2a4e9a4aca4ca", "ひらがな"),
            ("gb18030", "babad3ef", "汉语"),
            ("cp950", "ba7ebb79", "漢語"),
            ("big5-hkscs", "adbbb4e4", "香港"),
            ("cp949", "c7d1b1db", "한글"),
            ("windows-1255", "f9ece5ed", "שלום"),
            ("windows-1256", "dfcac7c8", "كتاب"),
            ("windows-1257", "52ee6761", "Rīga"),
            ("iso-8859-8", "f9ece5ed", "שלום"),
            ("cp862", "998c858d", "שלום"),
            ("iso-8859-6", "e3cac7c8", "كتاب"),
            ("cp864", "a9aa", "ﺏﺕ"),
            ("x-mac-arabic", "e3cac7c8", "كتاب"),
            ("x-mac-farsi", "e3cac7c8", "كتاب"),
            ("iso-8859-4", "52ef6761", "Rīga"),
            ("iso-8859-13", "52ee6761", "Rīga"),
            ("cp775", "528c6761", "Rīga"),
            ("cp865", "529b64", "Rød"),
            ("cp861", "99", "Ö"),
            ("x-mac-icelandic", "ea736c616e64", "Ísland"),
            ("iso-8859-10", "cd736c616e64", "Ísland"),
            ("cp437", "477294e165", "Größe"),
            ("iso-8859-16", "bafe", "șț"),
            ("x-mac-romanian", "bfdf", "șț"),
            ("cp852", "ac65e774696e61", "Čeština"),
            ("x-mac-croatian", "e8e6f0", "čćđ"),
            ("cp855", "a39ed0aca0e1b7de", "България"),
            ("iso-8859-7", "c5ebebdce4e1", "Ελλάδα"),
            ("cp737", "84a2a2e19b98", "Ελλάδα"),
            ("cp869", "a8e5e59bddd6", "Ελλάδα"),
            ("x-mac-greek", "b6ececc0e4e1", "Ελλάδα"),
            ("iso-8859-9", "54fc726be765", "Türkçe"),
            ("cp857", "5481726b8765", "Türkçe"),
            ("x-mac-turkish", "549f726b8d65", "Türkçe"),
            // VISCII は CF の IANA 往復だけを検証。拡張134文字は Python 側で RFC と照合する。
            ("viscii", "566965746e616d", "Vietnam"),
            ("x-mac-hebrew", "f9ece5ed", "שלום"),
            ("x-mac-ukrainian", "90eef1f1e8df", "Россия"),
            ("x-mac-thai", "c0d2c9d2e4b7c2", "ภาษาไทย"),
        ]
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = try findKaitoExecutable()
        for (iana, hex, text) in samples {
            let file = temporary.appendingPathComponent("\(iana).tsv")
            try "sample\tfixture\t\(iana)\t\(hex)\t\(text)\n"
                .write(to: file, atomically: true, encoding: .utf8)
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(iana as CFString)
            XCTAssertNotEqual(cfEncoding, kCFStringEncodingInvalidId, iana)
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            let canonical = try XCTUnwrap(CFStringConvertEncodingToIANACharSetName(
                CFStringConvertNSStringEncodingToEncoding(nsEncoding)
            )) as String
            // 指定名と CoreFoundation が返す名前の両方で、同じ厳密復号結果になることを確かめる。
            for name in Set([iana, canonical]) {
                let output = try runKaito(executable, arguments: ["detect-encoding", "--decode", name, file.path])
                XCTAssertEqual(output, "sample\tOK\t\(text)\n", "\(iana) / \(name)")
            }
        }
    }

    func testDetectEncodingNamesArchivesAndStrictDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Fixtures/encoding/names-smoke.tsv")
        let rows = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        XCTAssertEqual(rows.count, 41)
        XCTAssertEqual(Set(rows.map { $0[1] }).count, 39)
        let executable = try findKaitoExecutable()
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for options in [[], ["--language", "ja"], ["--no-language", "--from-windows"]] {
            let output = try runKaito(executable, arguments: ["detect-encoding"] + options + [fixture.path])
            let detected = output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            XCTAssertEqual(detected.count, rows.count)
            for (row, result) in zip(rows, detected) {
                XCTAssertEqual(result.count, 4)
                guard result.count == 4 else { continue }
                XCTAssertEqual(String(result[0]), row[0])
                XCTAssertFalse(result[1].isEmpty)
                let confidence = try XCTUnwrap(Double(result[2]))
                XCTAssertTrue((0...1).contains(confidence))
                XCTAssertEqual(result[2].split(separator: ".").last?.count, 3)
            }
            XCTAssertEqual(detected[0][1], "cp932")
            XCTAssertEqual(String(detected[0][3]), rows[0][4])
            XCTAssertEqual(detected[1][1], "euc-jp")
            XCTAssertEqual(String(detected[1][3]), rows[1][4])
        }
        for (encoding, group) in Dictionary(grouping: rows, by: { $0[2] }) {
            let file = temporary.appendingPathComponent("decode.tsv")
            try (group.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            let decoded = try runKaito(executable, arguments: ["detect-encoding", "--decode", encoding, file.path])
            XCTAssertEqual(decoded, group.map { "\($0[0])\tOK\t\($0[4])\n" }.joined())
        }
        let archive = temporary.appendingPathComponent("archives.tsv")
        let ascii = "636f7665722e6a7067"
        try "group\tlang\ttruth_iana\tk\thex1,hex2,...\ng1\tja\tcp932\t1\t\(rows[0][3]),\(ascii)\ng2\tja\teuc-jp\t1\t\(rows[1][3])\ng3\ten\tutf-8\t1\t\(ascii)\n"
            .write(to: archive, atomically: true, encoding: .utf8)
        for options in [["--language", "ja"], ["--no-language"]] {
            let output = try runKaito(executable, arguments: ["detect-encoding", "--archive"] + options + [archive.path])
            XCTAssertEqual(output, "g1\tcp932\t0\t日本語の本|cover.jpg\ng2\teuc-jp\t0\tひらがな\ng3\tutf-8\t0\tcover.jpg\n")
        }
        // 誤った正解欄、厳密復号の失敗、制御文字・区切り・正準等価の扱いを確かめる。
        let edge = temporary.appendingPathComponent("edge.tsv")
        try "ok\ten\tutf-8\t61\ta\nmismatch\ten\tutf-8\t61\tb\nfail\ten\tutf-8\tff\tx\nescape\ten\tutf-8\t615c7c090a0d\tx\ncanonical\ten\tutf-8\t65cc81\té\n"
            .write(to: edge, atomically: true, encoding: .utf8)
        let decoded = try runKaito(executable, arguments: ["detect-encoding", "--decode", "utf-8", edge.path])
        XCTAssertEqual(decoded, "ok\tOK\ta\nmismatch\tMISMATCH\ta\nfail\tFAIL\t\nescape\tMISMATCH\ta\\\\\\|\\t\\n\\r\ncanonical\tMISMATCH\te\u{0301}\n")
    }

    func testStuffItExtractionDefersResourcesAndPreservesParentPaths() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/stuffit")
        let executable = try findKaitoExecutable()
        for fixture in ["jp-sjis.sit", "jp-macjp.sit", "jp-euc.sit"] {
            let source = fixtureRoot.appendingPathComponent(fixture)
            let reader = try ArchiveReader.open(url: source)
            let listing = try runKaito(executable, arguments: ["list", source.path])
            XCTAssertTrue(listing.contains("\t第１巻/ページ０１.jpg\t"), listing)
            let output = temporary.appendingPathComponent(fixture)
            _ = try runKaito(executable, arguments: ["extract", source.path, "-o", output.path])
            for entry in reader.entries where entry.kind == .file {
                let path = output.appendingPathComponent(entry.pathComponents.joined(separator: "/"))
                XCTAssertEqual(try Data(contentsOf: path), try reader.read(entry), entry.name)
            }
        }
    }

    func testResourceForkRunsAfterHardLinksAndBeforeDirectoryMetadata() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        let output = temporary.appendingPathComponent("out")
        let folder = output.appendingPathComponent("folder")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: temporary)
        }
        let archive = temporary.appendingPathComponent("fork-and-link.tar")
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "folder/", type: 0x35, mode: 0o500),
            HandTarEntry(name: "folder/alias/..namedfork/rsrc", contents: Data([3, 4])),
            HandTarEntry(name: "folder/image", contents: Data([1, 2])),
            HandTarEntry(name: "folder/alias", type: 0x31, linkName: "folder/image"),
        ]).write(to: archive)
        _ = try runKaito(findKaitoExecutable(), arguments: ["extract", archive.path, "-o", output.path])
        for name in ["image", "alias"] {
            let file = folder.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: file), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: file.appendingPathComponent("..namedfork/rsrc")), Data([3, 4]))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, 1_700_000_000)
    }

    func testSplitSevenZipListAndSHAMatchWholeArchive() throws {
        let bytes = try ZipTestSupport.checkedInFixture("sevenzip/chain-lzma-lzma-lzma2-bcj2.7z")
        let directory = try ZipTestSupport.temporaryDirectory(label: "cli-split-7z")
        defer { try? FileManager.default.removeItem(at: directory) }
        let whole = try ZipTestSupport.write(bytes, relativePath: "whole.7z", below: directory)
        // 署名自体が巻をまたぐケースを CLI の detect / list / sha まで通す。
        let first = try ZipTestSupport.write(Data(bytes.prefix(5)), relativePath: "split.7z.001", below: directory)
        try ZipTestSupport.write(Data(bytes.dropFirst(5)), relativePath: "split.7z.002", below: directory)
        let executable = try findKaitoExecutable()
        for command in ["detect", "list", "sha"] {
            XCTAssertEqual(try runKaito(executable, arguments: [command, first.path]),
                           try runKaito(executable, arguments: [command, whole.path]))
        }
    }

    func testXarExtractionDefersForwardLinksAndReportsTargetFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = try findKaitoExecutable()
        for name in ["xar-plain.xar", "xar-links.xar"] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).b64"), encoding: .utf8)
            let archive = temporary.appendingPathComponent(name)
            try XCTUnwrap(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))).write(to: archive)
            for failedTarget in (name == "xar-plain.xar" ? [false, true] : [false]) {
                let output = temporary.appendingPathComponent("\(name)-\(failedTarget)")
                if failedTarget {
                    // 実体の公開を失敗させ、同名の既存 object を link が信用しないことを検査する。
                    try FileManager.default.createDirectory(at: output.appendingPathComponent("hard.txt"), withIntermediateDirectories: true)
                }
                let process = Process()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = ["extract", archive.path, "-o", output.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                try process.run()
                process.waitUntilExit()
                let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationReason, .exit)
                if failedTarget {
                    XCTAssertEqual(process.terminationStatus, 1)
                    XCTAssertTrue(errors.contains("failed entry 7 (hard.txt)"), errors)
                    XCTAssertTrue(errors.contains("failed entry 1 (a.txt)"), errors)
                    XCTAssertTrue(errors.contains("hard-link target was not materialized by this archive reader"), errors)
                    XCTAssertTrue(errors.contains("2 archive entries failed"), errors)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("a.txt").path))
                    continue
                }
                XCTAssertEqual(process.terminationStatus, name == "xar-links.xar" ? 1 : 0, errors)
                if name == "xar-links.xar" {
                    XCTAssertTrue(errors.contains("failed entry 3 (dangling.txt)"), errors)
                    XCTAssertTrue(errors.contains("1 archive entries failed"), errors)
                } else { XCTAssertEqual(errors, "") }
                let members = name == "xar-plain.xar" ? ["a.txt", "hard.txt"] : ["orig.txt", "l1.txt", "l2.txt"]
                let expected = name == "xar-plain.xar"
                    ? "1ddc234bae1b3930239b3d8625224117828d8a576bb8951087cbe6097387fb1e"
                    : "86d7bb82c5856157d89466dc8fc8d52b8e14742702359f500dd09f0f912bb77c"
                var inode: NSNumber?
                for member in members {
                    let url = output.appendingPathComponent(member)
                    let data = try Data(contentsOf: url)
                    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected)
                    let actual = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
                    if let inode { XCTAssertEqual(actual, inode) } else { inode = actual }
                }
            }
        }
    }

    func testArListAndSHA() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/lib.a.b64"), encoding: .utf8)
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("lib.a")
        try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
        let executable = try findKaitoExecutable()
        let output = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertEqual(output.split(separator: "\n").count, 2)
        XCTAssertTrue(output.contains("ar (stored)\tplain\ta.txt"))
        let hashes = try runKaito(executable, arguments: ["sha", url.path])
        XCTAssertTrue(hashes.contains("70bf6ca40d63eeb669f684aafbf02a896c396de1b3aab3b0efe107d66279c202"))
        XCTAssertTrue(hashes.contains("e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c"))
    }

    /// 2026-09-20 に追加した単一 stream 形式の `detect` 名と `list` の method 名。
    func testDetectAndListNameTheNewSingleFileFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        for (fixture, name, detected, method) in [
            ("lzip/one.lz.b64", "one.lz", "lzip", "LZMA (lzip)"),
            ("brotli/one.br.b64", "one.br", "brotli", "Brotli"),
            ("pbzx/text.pbzx.b64", "text.pbzx", "pbzx", "XZ (pbzx)"),
        ] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/\(fixture)"), encoding: .utf8)
            let url = temp.appendingPathComponent(name)
            try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
            XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), detected, name)
            let listing = try runKaito(executable, arguments: ["list", url.path])
            XCTAssertEqual(listing.split(separator: "\n").count, 1, name)
            XCTAssertTrue(listing.contains("\t\(method)\tplain\t"), "\(name): \(listing)")
        }
    }

    /// UDF 専用 image は `udf`、hybrid は `iso` と検出し、どちらも UDF の木を `UDF (stored)` で一覧する。
    func testDetectAndListUDFImages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        for (fixture, detected) in [("udf201-512.img", "udf"), ("hybrid102.iso", "iso")] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/udf/\(fixture).gz.b64"), encoding: .utf8)
            let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
            let url = temp.appendingPathComponent(fixture)
            try gzip.read(gzip.entries[0]).write(to: url)
            XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), detected, fixture)
            let listing = try runKaito(executable, arguments: ["list", url.path])
            XCTAssertTrue(listing.contains("\t2880\tfile\tUDF (stored)\tplain\treadme.txt"), "\(fixture): \(listing)")
            XCTAssertTrue(listing.contains("\tsymlink\tUDF (stored)\tplain\tlink-to-readme"), fixture)
            if fixture == "udf201-512.img" {
                XCTAssertTrue(listing.contains("\tforked.txt/..namedfork/rsrc\tfork=resource"), listing)
            }
            let hashes = try runKaito(executable, arguments: ["sha", url.path])
            XCTAssertTrue(hashes.contains("efe110a6cc29d1711091a93ff160466004e53f7a835209094e1131983276f25e\treadme.txt"), fixture)
        }
    }

    /// WIM は `wim` と検出し、LZX resource を `WIM LZX` で一覧、SHA-1 検証付きで読む。
    func testDetectAndListWIM() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/wim/lzx.wim.b64"), encoding: .utf8)
        let url = temp.appendingPathComponent("lzx.wim")
        try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
        XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "wim")
        let listing = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertTrue(listing.contains("\t56270\tfile\tWIM LZX\tplain\ttext.txt"), listing)
        let hashes = try runKaito(executable, arguments: ["sha", url.path])
        XCTAssertTrue(hashes.contains("\ttext.txt"), hashes)
        XCTAssertFalse(hashes.contains("ERROR"), hashes)
    }

    /// MacBinary / AppleSingle / BinHex の単体は wrapper 名で検出し、data / resource の 2 fork を一覧する。
    func testDetectAndListMacWrappers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        for (fixture, detected, method) in [("readme.txt.bin", "macbinary", "MacBinary (stored)"),
                                            ("readme.txt.as", "applesingle", "AppleSingle (stored)"),
                                            ("readme.txt.hqx", "binhex", "BinHex 4.0 (RLE90)")] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/macwrappers/\(fixture).b64"), encoding: .utf8)
            let url = temp.appendingPathComponent(fixture)
            try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
            XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), detected, fixture)
            let listing = try runKaito(executable, arguments: ["list", url.path])
            XCTAssertTrue(listing.contains("\t823\tfile\t\(method)\tplain\treadme.txt\tfork=data"), "\(fixture): \(listing)")
            XCTAssertTrue(listing.contains("\t416\tfile\t\(method)\tplain\treadme.txt/..namedfork/rsrc\tfork=resource"), fixture)
        }
    }

    /// PKZIP 1.x の旧 method は shrink / reduceN / implode の名前で一覧され、sha が通る。
    func testListLegacyZipMethods() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        for (fixture, method) in [("shrink.zip", "shrink"), ("reduce4.zip", "reduce4"), ("implode-8k-3trees.zip", "implode")] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/zip-legacy/\(fixture).b64"), encoding: .utf8)
            let url = temp.appendingPathComponent(fixture)
            try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
            let listing = try runKaito(executable, arguments: ["list", url.path])
            XCTAssertTrue(listing.contains("\t31680\tfile\t\(method)\tplain\ttext.txt"), "\(fixture): \(listing)")
            let hashes = try runKaito(executable, arguments: ["sha", url.path])
            XCTAssertTrue(hashes.contains("5a3bb49b57d40193fbe5ad5869b029c01f2bdfe046f8a4368438178b923f1c10\ttext.txt"), "\(fixture): \(hashes)")
            XCTAssertFalse(hashes.contains("ERROR"), hashes)
        }
    }

    /// BIN/CUE の生 sector image は `iso` と検出され、`.cue` からも同じ一覧になる。
    func testDetectAndListRawSectorImageAndCueSheet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/bincue/mode1.bin.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let bin = temp.appendingPathComponent("mode1.bin")
        try gzip.read(gzip.entries[0]).write(to: bin)
        let cue = temp.appendingPathComponent("mode1.cue")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Fixtures/bincue/mode1.cue"), to: cue)
        for url in [bin, cue] {
            XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "iso", url.lastPathComponent)
            let hashes = try runKaito(executable, arguments: ["sha", url.path])
            XCTAssertTrue(hashes.contains("e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c\tdata.bin"), "\(url.lastPathComponent): \(hashes)")
            XCTAssertFalse(hashes.contains("ERROR"), hashes)
        }
    }

    /// compound file は `cfb` と検出し、storage を directory、stream を stored file として一覧する。
    func testDetectAndListCompoundFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/cfb/v4.cfb.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let url = temp.appendingPathComponent("v4.cfb")
        try gzip.read(gzip.entries[0]).write(to: url)
        XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "cfb")
        let listing = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertTrue(listing.contains("\t0\tdirectory\tstored\tplain\tStorage One/Deeper"), listing)
        XCTAssertTrue(listing.contains("\t20000\tfile\tstored\tplain\tlarge-a.bin"), listing)
        XCTAssertTrue(listing.contains("\t100\tfile\tstored\tplain\t[5]SummaryInformation"), listing)
        let hashes = try runKaito(executable, arguments: ["sha", url.path])
        XCTAssertFalse(hashes.contains("ERROR"), hashes)
    }

    /// CHM は `chm` と検出し、LZX section の file を `LZX`、section 0 の file を `stored` として一覧する。
    func testDetectAndListCHM() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/chm/basic.chm.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let url = temp.appendingPathComponent("basic.chm")
        try gzip.read(gzip.entries[0]).write(to: url)
        XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "chm")
        let listing = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertTrue(listing.contains("\t70000\tfile\tLZX\tplain\timages/logo.bin"), listing)
        XCTAssertTrue(listing.contains("\t68\tfile\tstored\tplain\t#SYSTEM"), listing)
        XCTAssertTrue(listing.contains("\t0\tdirectory\tstored\tplain\ttopics/sub"), listing)
        let hashes = try runKaito(executable, arguments: ["sha", url.path])
        XCTAssertFalse(hashes.contains("ERROR"), hashes)
    }

    /// ARJ（素の書庫と DOS SFX）は `arj` と検出し、method 名で一覧する。
    func testDetectAndListARJ() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        for fixture in ["basic.arj", "sfx.exe"] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/arj/\(fixture).b64"), encoding: .utf8)
            let url = temp.appendingPathComponent(fixture)
            try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
            XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "arj", fixture)
            let listing = try runKaito(executable, arguments: ["list", url.path])
            XCTAssertTrue(listing.contains("\t26400\tfile\tcompressed most\tplain\tREADME.TXT"), "\(fixture): \(listing)")
            XCTAssertTrue(listing.contains("\t768\tfile\tstored\tplain\tSTORED.BIN"), fixture)
            XCTAssertTrue(listing.contains("\t1400\tfile\tcompressed most\tplain\t日本語.TXT"), fixture)
            let hashes = try runKaito(executable, arguments: ["sha", url.path])
            XCTAssertTrue(hashes.contains("8d1126c536d13946d9fd277a295e1fe7ff3941edb04f94b99c2b3fb5999a029a\tREADME.TXT"), "\(fixture): \(hashes)")
            XCTAssertFalse(hashes.contains("ERROR"), hashes)
        }
    }

    /// DMG は `dmg` と検出し、HFS+ volume の file を `HFS+ (stored)`、fork と decmpfs を含めて一覧する。
    func testDetectAndListDMG() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let executable = try findKaitoExecutable()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/dmg/hfs-lzfse.dmg.gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)))
        let url = temp.appendingPathComponent("hfs-lzfse.dmg")
        try gzip.read(gzip.entries[0]).write(to: url)
        XCTAssertEqual(try runKaito(executable, arguments: ["detect", url.path]).trimmingCharacters(in: .whitespacesAndNewlines), "dmg")
        let listing = try runKaito(executable, arguments: ["list", url.path])
        XCTAssertTrue(listing.contains("\t200000\tfile\tHFS+ (stored)\tplain\tfragmented.bin"), listing)
        XCTAssertTrue(listing.contains("\t20\tfile\tHFS+ (stored)\tplain\treadme.txt/..namedfork/rsrc\tfork=resource"), listing)
        XCTAssertTrue(listing.contains("\tsymlink\tHFS+ (stored)\tplain\tlink-to-nested"), listing)
        XCTAssertTrue(listing.contains("\tfile\tHFS+ compressed (decmpfs)\tplain\tcompressed.txt"), listing)
        // decmpfs の file は `sha` で失敗として数えられる（終了コード非 0）ので、その file を持たない raw image で確かめる。
        let rawText = try String(contentsOf: root.appendingPathComponent("Fixtures/dmg/hfs-raw.dmg.gz.b64"), encoding: .utf8)
        let rawGzip = try ArchiveReader.open(data: try XCTUnwrap(Data(base64Encoded: rawText, options: .ignoreUnknownCharacters)))
        let rawURL = temp.appendingPathComponent("hfs-raw.dmg")
        try rawGzip.read(rawGzip.entries[0]).write(to: rawURL)
        let hashes = try runKaito(executable, arguments: ["sha", rawURL.path])
        XCTAssertTrue(hashes.contains("c6ced9f772ab08b591a1d3a1057bf4fd267ab64b1536d170f61722afb16677de\treadme.txt"), hashes)
        XCTAssertFalse(hashes.contains("ERROR"), hashes)
    }

    func testListCpioFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/newc.cpio.b64"), encoding: .utf8)
        let temp = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("newc.cpio")
        try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters)).write(to: url)
        let output = try runKaito(findKaitoExecutable(), arguments: ["list", url.path])
        XCTAssertEqual(output.split(separator: "\n").count, 5)
        XCTAssertTrue(output.contains("cpio (stored)\tplain\t./a.txt"))
    }

    func testListShowsMethodEncryptionAndOptionalRawName() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-list.tar")
        let name = "page.txt"
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: name, contents: Data("payload".utf8)),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let ordinary = try runKaito(executable, arguments: ["list", archive.path])
        let raw = try runKaito(executable, arguments: ["list", archive.path, "--raw"])
        let expectedRawName = name.utf8.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            ordinary.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "7", "file", "tar (stored)", "plain", "page.txt"]
        )
        XCTAssertEqual(
            raw.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "7", "file", "tar (stored)", "plain", "page.txt", expectedRawName]
        )
    }

    func testListNamesTheZIPEncryptionMethod() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "cli-list-encryption")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try ZipTestSupport.write(
            Data("encrypted list payload".utf8),
            relativePath: "secret.txt",
            below: source
        )
        let archive = temporary.appendingPathComponent("encrypted.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["secret.txt"],
            archiveURL: archive,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let output = try runKaito(
            findKaitoExecutable(),
            arguments: ["list", archive.path]
        )
        XCTAssertEqual(
            output.trimmingCharacters(in: .newlines).components(separatedBy: "\t"),
            ["0", "22", "file", "stored", "ZipCrypto", "secret.txt"]
        )
    }

    func testSHAOutputIsStableAcrossRuns() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli.tar")
        let contents = Data("stable cli payload".utf8)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "日本語.txt", contents: contents),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let first = try runKaito(executable, arguments: ["sha", archive.path])
        let second = try runKaito(executable, arguments: ["sha", archive.path])
        XCTAssertEqual(first, second)

        let lines = first.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("0\t\(contents.count)\t"))
        XCTAssertTrue(lines[0].hasSuffix("\t日本語.txt"))
        XCTAssertTrue(lines[1].hasPrefix("total\t1\t"))
    }

    func testSHAStreamsAcrossReusableBufferBoundary() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-sha-large.tar")
        let contents = Data(repeating: 0xA5, count: 4 * 1_024 * 1_024 + 17)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "large.bin", contents: contents),
        ]).write(to: archive)

        let output = try runKaito(
            findKaitoExecutable(),
            arguments: ["sha", archive.path]
        )
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let digest = SHA256.hash(data: contents)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(lines[0], "0\t\(contents.count)\t\(digest)\tlarge.bin")
    }

    func testBenchSupportsMappedDataAndLegacyArgumentOrder() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-bench.tar")
        let contents = Data("mapped benchmark payload".utf8)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "page.txt", contents: contents),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let outputs = try [
            runKaito(executable, arguments: ["bench", archive.path, "1"]),
            runKaito(executable, arguments: ["bench", "--data", archive.path, "1"]),
            runKaito(executable, arguments: ["bench", archive.path, "1", "--data"]),
            runKaito(executable, arguments: ["bench", "--random", archive.path, "1"]),
            runKaito(
                executable,
                arguments: ["bench", archive.path, "1", "--random", "--data"]
            ),
        ]

        for output in outputs {
            let lines = output.split(separator: "\n")
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines[0], "reps\t1")
            XCTAssertTrue(lines[1].hasPrefix("open-median-ms\t"))
            XCTAssertNotNil(Double(lines[1].dropFirst("open-median-ms\t".count)))
            XCTAssertTrue(lines[2].hasPrefix("extract-median-ms\t"))
            XCTAssertEqual(lines[3], "bytes\t\(contents.count)")
        }
    }

    func testBenchRandomReadsAtMostTwentyNonDirectoryEntries() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("cli-bench-random.tar")
        var entries = [HandTarEntry(name: "folder/", type: 0x35)]
        entries.append(contentsOf: (0..<25).map { index in
            HandTarEntry(
                name: String(format: "folder/page-%02d.bin", index),
                contents: Data(repeating: UInt8(index), count: 1_000 + index)
            )
        })
        try TarTestSupport.makeTar(entries: entries).write(to: archive)

        let executable = try findKaitoExecutable()
        let outputs = try (0..<2).map { _ in
            try runKaito(
                executable,
                arguments: ["bench", "--random", archive.path, "1"]
            )
        }
        let lines = outputs.map { $0.split(separator: "\n") }
        guard lines.allSatisfy({ $0.count == 4 }) else {
            return XCTFail("bench output must keep its four-line format")
        }
        XCTAssertTrue(lines.allSatisfy { $0[0] == "reps\t1" })
        XCTAssertTrue(lines.allSatisfy { $0[2].hasPrefix("extract-median-ms\t") })
        XCTAssertEqual(lines[0][3], lines[1][3], "the fixed sample must be reproducible")
        let byteCount = try XCTUnwrap(Int(lines[0][3].dropFirst("bytes\t".count)))
        XCTAssertTrue((20_000..<21_000).contains(byteCount), "exactly 20 files are read")
    }

    func testBenchRandomReadsTwentyEntriesFromSolidSevenZip() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "cli-7z-random")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        var paths: [String] = []
        for index in 0..<25 {
            let name = String(format: "page-%02d.bin", index)
            paths.append(name)
            _ = try SevenZipTestSupport.write(
                Data(repeating: UInt8(index), count: 1_000 + index),
                relativePath: name,
                below: source
            )
        }
        let archive = temporary.appendingPathComponent("solid.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: paths,
            archiveURL: archive,
            options: ["-m0=LZMA2", "-ms=on"]
        )

        let executable = try findKaitoExecutable()
        XCTAssertEqual(
            try runKaito(executable, arguments: ["detect", archive.path])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "7z"
        )
        let listed = try runKaito(executable, arguments: ["list", archive.path])
            .split(separator: "\n")
        XCTAssertEqual(listed.count, paths.count)
        XCTAssertTrue(listed.allSatisfy { $0.contains("\tLZMA2\t") })
        let hashes = try runKaito(executable, arguments: ["sha", archive.path])
            .split(separator: "\n")
        XCTAssertEqual(hashes.count, paths.count + 1)
        XCTAssertTrue(hashes.last?.hasPrefix("total\t25\t") == true)

        let output = try runKaito(
            executable,
            arguments: ["bench", "--random", archive.path, "1"]
        )
        let lines = output.split(separator: "\n")
        guard lines.count == 4 else {
            return XCTFail("bench output must keep its four-line format")
        }
        let byteCount = try XCTUnwrap(Int(lines[3].dropFirst("bytes\t".count)))
        XCTAssertTrue((20_000..<21_000).contains(byteCount), "exactly 20 files are read")
    }

    func testListSHAAndBenchPassPasswordToHeaderEncryptedSevenZip() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "cli-7z-password")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let name = "secret.txt"
        let contents = Data("header-encrypted CLI payload".utf8)
        let password = "cli-fixed-password"
        _ = try SevenZipTestSupport.write(contents, relativePath: name, below: source)
        let archive = temporary.appendingPathComponent("encrypted.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: source,
            paths: [name],
            archiveURL: archive,
            options: ["-m0=Copy", "-ms=off", "-p\(password)", "-mhe=on"]
        )

        let executable = try findKaitoExecutable()
        let listed = try runKaito(
            executable,
            arguments: ["list", "--raw", "-p", password, archive.path]
        ).trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        XCTAssertEqual(listed.count, 7)
        XCTAssertEqual(listed[1], String(contents.count))
        XCTAssertEqual(listed[4], "7zAES-256")
        XCTAssertEqual(listed[5], name)

        let hashes = try runKaito(
            executable,
            arguments: ["sha", archive.path, "-p", password]
        ).split(separator: "\n")
        XCTAssertEqual(hashes.count, 2)
        XCTAssertTrue(hashes[0].hasPrefix("0\t\(contents.count)\t"))
        XCTAssertTrue(hashes[0].hasSuffix("\t\(name)"))
        XCTAssertTrue(hashes[1].hasPrefix("total\t1\t"))

        let benchmark = try runKaito(
            executable,
            arguments: ["bench", "-p", password, "--data", archive.path, "1"]
        ).split(separator: "\n")
        XCTAssertEqual(benchmark.count, 4)
        XCTAssertEqual(benchmark[0], "reps\t1")
        XCTAssertEqual(benchmark[3], "bytes\t\(contents.count)")
    }

    func testExtractDefersRestrictiveDirectoryMetadataUntilAfterChildren() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let restrictedDirectory = output.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: restrictedDirectory.path
            )
            try? FileManager.default.removeItem(at: temporary)
        }

        let archive = temporary.appendingPathComponent("restrictive-directory.tar")
        let payload = Data("created before final directory metadata".utf8)
        let expectedTime = Date(timeIntervalSince1970: 1_650_000_123)
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(
                name: "locked/",
                type: 0x35,
                mode: 0o500,
                modificationTime: 1_650_000_123
            ),
            HandTarEntry(name: "locked/child.txt", contents: payload),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        _ = try runKaito(
            executable,
            arguments: ["extract", archive.path, "-o", output.path]
        )

        XCTAssertEqual(
            try Data(contentsOf: restrictedDirectory.appendingPathComponent("child.txt")),
            payload
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: restrictedDirectory.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value & 0o7777, 0o500)
        XCTAssertEqual(
            try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970,
            expectedTime.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testListAndSHAEscapeTerminalControlCharactersInNames() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("controls.tar")
        let name = "safe\u{1b}[2J\u{7f}\u{85}\u{2028}spoof.txt"
        try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: name, contents: Data("payload".utf8)),
        ]).write(to: archive)

        let executable = try findKaitoExecutable()
        let list = try runKaito(executable, arguments: ["list", archive.path])
        let sha = try runKaito(executable, arguments: ["sha", archive.path])
        let visibleName = "safe\\u{1b}[2J\\u{7f}\\u{85}\\u{2028}spoof.txt"

        XCTAssertTrue(list.contains(visibleName))
        XCTAssertTrue(sha.contains(visibleName))
        for output in [list, sha] {
            XCTAssertFalse(output.unicodeScalars.contains { scalar in
                scalar.value == 0x1b || scalar.value == 0x7f ||
                    (0x80...0x9f).contains(scalar.value) ||
                    scalar.value == 0x2028 || scalar.value == 0x2029
            })
        }
    }

    func testPerEntryFailureContinuesSHAAndExtractionButReturnsFailure() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("partial.lzh")
        let payload = Data("after unsupported entry".utf8)
        try LHATestSupport.makeArchive(entries: [
            HandLHAEntry(name: "unreadable", method: "-pm2-", headerLevel: 2),
            HandLHAEntry(name: "dir/good.txt", contents: payload, headerLevel: 2),
            HandLHAEntry(name: "dir", method: "-lhd-", headerLevel: 2, permissions: 0o500),
        ]).write(to: archive)
        let output = temporary.appendingPathComponent("output")
        for arguments in [["sha", archive.path], ["extract", archive.path, "-o", output.path]] {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = try findKaitoExecutable()
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 1)
            XCTAssertTrue(errors.contains("entry 0 (unreadable)"))
            XCTAssertTrue(errors.contains("1 archive entries failed"))
            if arguments[0] == "sha" {
                XCTAssertTrue(text.contains("\tdir/good.txt\n"))
                XCTAssertTrue(text.contains("partial\t2\t"))
                XCTAssertTrue(text.contains("0\tERROR\t"))
                XCTAssertFalse(text.contains("total\t"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("dir/good.txt")), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent("dir").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970, Double(LHATestSupport.unixTimestamp))
    }

    func testSolidCRCFailureLabelsFailedEntryAndSourceMember() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixture = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/solid_lz_rar300.rar.b64")
        let encoded = try String(contentsOf: fixture, encoding: .utf8)
        var bytes = Array(try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)))
        var offset = 7
        while bytes[offset + 2] != 0x74 {
            offset += Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        }
        let size = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
        bytes[offset + 16] ^= 1 // Wrong member CRC; leave the solid compressed stream intact.
        let headerCRC = CRC32.checksum(Array(bytes[(offset + 2)..<(offset + size)]))
        bytes[offset] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let archive = temporary.appendingPathComponent("bad-solid.rar")
        try Data(bytes).write(to: archive)
        for arguments in [["sha", archive.path], ["extract", archive.path, "-o", temporary.appendingPathComponent("out").path]] {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = try findKaitoExecutable()
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 1)
            XCTAssertTrue(errors.contains("error: failed entry 1 ("), errors)
            XCTAssertTrue(errors.contains("Checksum mismatch (source member 0)"), errors)
            XCTAssertFalse(errors.contains("Checksum mismatch for entry"), errors)
            if arguments[0] == "sha" {
                XCTAssertTrue(output.contains("1\tERROR\tfailed entry 1: Checksum mismatch (source member 0)\t"), output)
            }
        }
    }

    private func runKaito(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errors = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TarTestSupportError.commandFailed(
                String(decoding: errors, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func findKaitoExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["KAITO_EXECUTABLE"] {
            let candidate = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("kaito"))
        var ancestor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(ancestor.appendingPathComponent("kaito"))
            ancestor.deleteLastPathComponent()
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repository.appendingPathComponent(".build/debug/kaito"))
        candidates.append(repository.appendingPathComponent(".build/out/Products/Debug/kaito"))
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let buildDirectory = repository.appendingPathComponent(".build", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        ) {
            for case let candidate as URL in enumerator where candidate.lastPathComponent == "kaito" {
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw TarTestSupportError.commandFailed("built kaito executable was not found")
    }
}
