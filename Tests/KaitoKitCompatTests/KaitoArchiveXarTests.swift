// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表と固定 fixture に基づく検証。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。
import CryptoKit
import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveXarTests: XCTestCase {
    func testSingleEntryExtractionFollowsForwardReferencesAndChains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temporary = root.deletingLastPathComponent().appendingPathComponent(".build/xar-compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (name, indices, expected) in [
            ("xar-plain.xar", [1], "1ddc234bae1b3930239b3d8625224117828d8a576bb8951087cbe6097387fb1e"),
            ("xar-links.xar", [1, 2], "86d7bb82c5856157d89466dc8fc8d52b8e14742702359f500dd09f0f912bb77c")
        ] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).b64"), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            let archive = try XCTUnwrap(KaitoArchive(data: bytes))
            for index in indices {
                let output = temporary.appendingPathComponent("\(name)-\(index)")
                XCTAssertTrue(archive.extractEntry(Int32(index), to: output.path), "\(String(describing: archive.lastError))")
                let fileName = name == "xar-plain.xar" ? "a.txt" : "l\(index).txt"
                let data = try Data(contentsOf: output.appendingPathComponent(fileName))
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected)
            }
        }
    }

    func testStableFormatNameForEveryFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (name, count) in [("xar-plain.xar", 10), ("xar-stored.xar", 10), ("xar-bzip2.xar", 10),
                              ("xar-sha512.xar", 10), ("xar-lzma.xar", 1), ("xar-xz.xar", 1),
                              ("xar-links.xar", 5), ("xar-subdoc.xar", 2), ("xar-pkg.pkg", 3)] {
            let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/\(name).b64"), encoding: .utf8)
            let bytes = try XCTUnwrap(Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            let archive = try XCTUnwrap(KaitoArchive(data: bytes))
            XCTAssertEqual(archive.formatName(), "XAR", name)
            XCTAssertEqual(archive.numberOfEntries(), Int32(count), name)
        }
    }
}
