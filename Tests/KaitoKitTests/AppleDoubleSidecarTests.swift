import Foundation
@testable import KaitoKit
import XCTest

/// `__MACOSX/._name`（Finder / ditto の ZIP）と `._name`（macOS tar）の AppleDouble sidecar の方針。
/// fixture は Tests/Fixtures/appledouble（ditto と bsdtar が書いたもの）。
final class AppleDoubleSidecarTests: XCTestCase {
    func testR6HardLinkIndicesFollowSidecarRemovalAndForkInsertion() throws {
        var metadata = Data(repeating: 0, count: 26)
        metadata.replaceSubrange(0..<8, with: [0, 5, 0x16, 7, 0, 2, 0, 0])
        for policy in [AppleDoublePolicy.merge, .hide] {
            for withFork in [false, true] {
                let sidecar = withFork ? resourceSidecar() : metadata
                let bytes = try TarTestSupport.makeTar(entries: [
                    HandTarEntry(name: "._foo", contents: sidecar),
                    HandTarEntry(name: "foo", contents: Data("payload".utf8)),
                    HandTarEntry(name: "link", type: 0x31, linkName: "foo"),
                    HandTarEntry(name: "chained", type: 0x31, linkName: "link"),
                ])
                let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(appleDoublePolicy: policy))
                let target = try XCTUnwrap(reader.entries.first { $0.name == "foo" })
                let link = try XCTUnwrap(reader.entries.first { $0.name == "link" })
                let chained = try XCTUnwrap(reader.entries.first { $0.name == "chained" })
                XCTAssertEqual(link.formatSpecific["hardLinkTargetIndex"], String(target.index))
                XCTAssertEqual(chained.formatSpecific["hardLinkTargetIndex"], String(link.index))
                // tar の hardlink 自身の本文は従来どおり空。展開側が公開 index から参照を辿る。
                XCTAssertEqual(try reader.read(link), Data())
                XCTAssertEqual(try reader.reopen().entries, reader.entries)
                let directory = try TarTestSupport.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                _ = try reader.extract(target, to: directory)
                _ = try reader.extract(link, to: directory)
                _ = try reader.extract(chained, to: directory)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("chained")), Data("payload".utf8))
            }
        }
    }

    func testR7UnreadableSidecarCandidatesRemainVisible() throws {
        for candidate in ["._ordinary", "__MACOSX/._ordinary"] {
            for hasTarget in [false, true] {
                var entries = [HandZipEntry(name: candidate, uncompressedData: Data(repeating: 65, count: 1000), method: 7),
                               HandZipEntry(name: "good", uncompressedData: Data("readable".utf8))]
                if hasTarget { entries.append(HandZipEntry(name: "ordinary", uncompressedData: Data("target".utf8))) }
                let bytes = try ZipTestSupport.makeArchive(entries: entries)
                for policy in [AppleDoublePolicy.merge, .hide, .expose] {
                    let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(appleDoublePolicy: policy))
                    XCTAssertEqual(reader.entries.map(\.name), entries.map { String(decoding: $0.rawName, as: UTF8.self) })
                    XCTAssertEqual(try reader.read(reader.entries[1]), Data("readable".utf8))
                    XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                        guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("予期しないエラー: \($0)") }
                    }
                }
            }
        }
    }

    private func resourceSidecar() -> Data {
        var bytes = Data(repeating: 0, count: 1000)
        bytes.replaceSubrange(0..<8, with: [0, 5, 0x16, 7, 0, 2, 0, 0])
        bytes[25] = 1
        bytes.replaceSubrange(26..<38, with: [0, 0, 0, 2, 0, 0, 0, 38, 0, 0, 0, 4])
        bytes.replaceSubrange(38..<42, with: "RSRC".utf8)
        return bytes
    }

    func testR8ResourceForkCompletionChecksTheWholeSidecarCRC() throws {
        let intact = resourceSidecar()
        for flip in [38, 999] {
            var corrupt = intact; corrupt[flip] ^= 1
            let bytes = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(name: "foo", uncompressedData: Data("data".utf8)),
                HandZipEntry(name: "._foo", uncompressedData: intact, compressedData: corrupt),
            ])
            let exposed = try ArchiveReader.open(data: bytes, options: ReaderOptions(appleDoublePolicy: .expose))
            XCTAssertThrowsError(try exposed.read(exposed.entries[1])) {
                XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 1))
            }
            let merged = try ArchiveReader.open(data: bytes)
            let fork = try XCTUnwrap(merged.entries.first { $0.formatSpecific["fork"] == "resource" })
            XCTAssertThrowsError(try merged.read(fork)) {
                XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 1))
            }
            // 最後の 1 byte を返す前に検証し、再読でも同じ終端エラーを維持する。
            let stream = try merged.stream(fork)
            var byte: UInt8 = 0
            for _ in 0..<3 { XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try stream.read(into: $0) }, 1) }
            for _ in 0..<2 {
                XCTAssertThrowsError(try withUnsafeMutableBytes(of: &byte) { try stream.read(into: $0) }) {
                    XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 1))
                }
            }
        }
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/appledouble/\(name).b64")
        return try XCTUnwrap(Data(base64Encoded: try String(contentsOf: url, encoding: .utf8), options: .ignoreUnknownCharacters))
    }

    private func names(_ reader: ArchiveReader) -> [String] { reader.entries.map(\.name) }

    func testMergePublishesResourceForksAndDropsSidecarsInZipAndTar() throws {
        for (name, format) in [("finder.zip", ArchiveFormat.zip), ("mac.tar", .tar)] {
            let data = try Self.fixture(name)
            let reader = try ArchiveReader.open(data: data)      // 既定は .merge
            XCTAssertEqual(reader.format, format, name)
            XCTAssertEqual(Set(names(reader)), [
                "folder/", "folder/rsrc.txt", "folder/rsrc.txt/..namedfork/rsrc", "folder/sub/",
                "folder/sub/deep.txt", "folder/sub/deep.txt/..namedfork/rsrc", "folder/plain.txt",
            ], name)
            XCTAssertEqual(reader.entries.map(\.index), Array(0..<reader.entries.count), name)
            let fork = try XCTUnwrap(reader.entries.first { $0.name == "folder/rsrc.txt/..namedfork/rsrc" }, name)
            XCTAssertEqual(fork.kind, .file, name)
            XCTAssertEqual(fork.uncompressedSize, 15, name)
            XCTAssertEqual(fork.formatSpecific["fork"], "resource", name)
            XCTAssertEqual(fork.formatSpecific["appleDoubleSidecar"], format == .zip ? "__MACOSX/folder/._rsrc.txt" : "folder/._rsrc.txt", name)
            XCTAssertEqual(try reader.read(fork), Data("RSRC-DATA-1234\n".utf8), name)
            // fork entry は data file の直後。
            let dataIndex = try XCTUnwrap(reader.entries.firstIndex { $0.name == "folder/rsrc.txt" })
            XCTAssertEqual(reader.entries[dataIndex + 1].name, "folder/rsrc.txt/..namedfork/rsrc", name)
            let deep = try XCTUnwrap(reader.entries.first { $0.name == "folder/sub/deep.txt/..namedfork/rsrc" }, name)
            XCTAssertEqual(try reader.read(deep), Data("DEEP-RSRC".utf8), name)
            // chunk 読みでも同じ。
            let stream = try reader.stream(fork)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 4)
            while stream.remaining > 0 {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                guard count > 0 else { break }
                output.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(output, Data("RSRC-DATA-1234\n".utf8), name)
            // 通常 entry はそのまま読める。rawRecord は通常 entry だけ。
            let plain = try XCTUnwrap(reader.entries.first { $0.name == "folder/plain.txt" })
            XCTAssertEqual(try reader.read(plain), Data("plain\n".utf8), name)
            if format == .zip {
                XCTAssertNotNil(try reader.rawRecord(of: plain), name)
                XCTAssertNil(try reader.rawRecord(of: fork), name)
            }
            // reopen は同じ写像を保つ。
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, name)
            XCTAssertEqual(try reopened.read(reopened.entries[fork.index]), Data("RSRC-DATA-1234\n".utf8), name)
        }
    }

    func testHideAndExposePolicies() throws {
        let data = try Self.fixture("finder.zip")
        let hidden = try ArchiveReader.open(data: data, options: ReaderOptions(appleDoublePolicy: .hide))
        XCTAssertEqual(Set(names(hidden)), ["folder/", "folder/rsrc.txt", "folder/sub/", "folder/sub/deep.txt", "folder/plain.txt"])
        XCTAssertFalse(hidden.entries.contains { $0.formatSpecific["fork"] != nil })
        let exposed = try ArchiveReader.open(data: data, options: ReaderOptions(appleDoublePolicy: .expose))
        // folder/sub の xattr が directory 用の sidecar `__MACOSX/folder/._sub` を作る（ditto --keepParent は
        // 最上位 folder 自身の sidecar を書かない）。merge ではこれも消える（上のテスト）。
        XCTAssertEqual(exposed.entries.count, 12)
        XCTAssertTrue(names(exposed).contains("__MACOSX/folder/._rsrc.txt"))
        XCTAssertTrue(names(exposed).contains("__MACOSX/folder/._sub"))
        XCTAssertTrue(names(exposed).contains("__MACOSX/"))
        let sidecar = try XCTUnwrap(exposed.entries.first { $0.name == "__MACOSX/folder/._rsrc.txt" })
        XCTAssertEqual(try exposed.read(sidecar).count, 135)
        // tar でも同じ。
        let tar = try ArchiveReader.open(data: try Self.fixture("mac.tar"), options: ReaderOptions(appleDoublePolicy: .expose))
        XCTAssertEqual(tar.entries.count, 10)
        XCTAssertTrue(names(tar).contains("folder/._plain.txt"))
        XCTAssertTrue(names(tar).contains("._folder"))
        XCTAssertTrue(names(tar).contains("folder/._sub"))
    }

    func testExtractionRestoresTheResourceForkWithoutAMACOSXFolder() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: try Self.fixture("finder.zip"))
        for entry in reader.entries { _ = try reader.extract(entry, to: temporary) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("__MACOSX").path))
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("folder/rsrc.txt")), Data("with rsrc\n".utf8))
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("folder/rsrc.txt/..namedfork/rsrc")), Data("RSRC-DATA-1234\n".utf8))
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("folder/sub/deep.txt/..namedfork/rsrc")), Data("DEEP-RSRC".utf8))
    }

    func testOrphanNonAppleDoubleAndEncryptedSidecarsAreLeftAlone() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        // 参照先の無い sidecar、AppleDouble でない `._` file、`__MACOSX` 配下の普通の file を持つ tar を手組みする。
        let exposed = try ArchiveReader.open(data: try Self.fixture("finder.zip"), options: ReaderOptions(appleDoublePolicy: .expose))
        let appleDouble = try exposed.read(try XCTUnwrap(exposed.entries.first { $0.name == "__MACOSX/folder/._rsrc.txt" }))
        let entries: [HandTarEntry] = [
            HandTarEntry(name: "a.txt", contents: Data("A".utf8)),
            HandTarEntry(name: "._a.txt", contents: appleDouble),               // resource fork → fork entry
            HandTarEntry(name: "._orphan.txt", contents: appleDouble),          // 参照先が無い → そのまま
            HandTarEntry(name: "._notdouble", contents: Data("just a file".utf8)),
            HandTarEntry(name: "notdouble", contents: Data("x".utf8)),
            HandTarEntry(name: "__MACOSX/readme.txt", contents: Data("kept".utf8)),
        ]
        let tar = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: entries))
        XCTAssertEqual(names(tar), ["a.txt", "a.txt/..namedfork/rsrc", "._orphan.txt", "._notdouble", "notdouble", "__MACOSX/readme.txt"])
        XCTAssertEqual(try tar.read(tar.entries[1]), Data("RSRC-DATA-1234\n".utf8))
        // hide は AppleDouble と確かめたものだけ隠し、`__MACOSX` 配下の普通の file は残す。
        let hidden = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: entries), options: ReaderOptions(appleDoublePolicy: .hide))
        XCTAssertEqual(names(hidden), ["a.txt", "._notdouble", "notdouble", "__MACOSX/readme.txt"])

        // 暗号化 ZIP の sidecar は中身を確かめられない: merge では残り、hide では `__MACOSX` 配下だけ名前で隠す。
        let zipPath = "/usr/bin/zip"
        try ZipTestSupport.requireExecutable(zipPath, reason: "zip is unavailable; encrypted sidecar case skipped")
        let root = temporary.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("__MACOSX/folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("with rsrc\n".utf8).write(to: root.appendingPathComponent("folder/rsrc.txt"))
        try appleDouble.write(to: root.appendingPathComponent("__MACOSX/folder/._rsrc.txt"))
        try ZipTestSupport.checkedRun(zipPath, arguments: ["-q", "-r", "-P", "secret", "../enc.zip", "folder", "__MACOSX"], currentDirectory: root)
        let encrypted = temporary.appendingPathComponent("enc.zip")
        let merged = try ArchiveReader.open(url: encrypted)
        XCTAssertTrue(names(merged).contains("__MACOSX/folder/._rsrc.txt"))
        XCTAssertFalse(names(merged).contains { $0.hasSuffix("..namedfork/rsrc") })
        let hiddenEncrypted = try ArchiveReader.open(url: encrypted, options: ReaderOptions(appleDoublePolicy: .hide))
        XCTAssertFalse(names(hiddenEncrypted).contains { $0.hasPrefix("__MACOSX") })
        // 暗号化は entry の flag で分かるので、password を渡しても open 時には中身を読まず sidecar は残る。
        let withPassword = try ArchiveReader.open(url: encrypted, options: ReaderOptions(password: "secret"))
        XCTAssertTrue(names(withPassword).contains("__MACOSX/folder/._rsrc.txt"))
    }

    func testAppleDoubleHeaderParsing() throws {
        var header = [UInt8](repeating: 0, count: 26 + 24)
        header[0...3] = [0, 5, 0x16, 7]; header[4...7] = [0, 2, 0, 0]; header[25] = 2
        header[26...37] = [0, 0, 0, 9, 0, 0, 0, 50, 0, 0, 0, 32]     // Finder info
        header[38...49] = [0, 0, 0, 2, 0, 0, 0, 82, 0, 0, 0, 15]     // resource fork
        let parsed = try XCTUnwrap(try AppleDoubleHeader(header, totalLength: 97))
        XCTAssertEqual(parsed.resourceFork?.offset, 82)
        XCTAssertEqual(parsed.resourceFork?.length, 15)
        XCTAssertThrowsError(try AppleDoubleHeader(header, totalLength: 96)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        header[25] = 40
        XCTAssertThrowsError(try AppleDoubleHeader(header, totalLength: nil))
        header[25] = 2; header[0] = 1
        XCTAssertNil(try AppleDoubleHeader(header, totalLength: nil))
        XCTAssertNil(try AppleDoubleHeader([0, 5, 0x16, 7], totalLength: nil))
    }
}
