import CryptoKit
import Foundation
import KaitoKit
import XCTest

final class LHAPublicValueGoldenTests: XCTestCase {
    func testFrozenStepZeroPublicValues() throws {
        try requireTokyo()
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try LHAFrozenFixtures.all()
        XCTAssertEqual(fixtures.count, 31)
        for fixture in fixtures {
            let url = try LHAFrozenFixtures.materialize(fixture, in: directory)
            try assertGolden(url: url, golden: fixture.golden)
        }
        print("LHA-GOLDEN Step0=31 TZ=Asia/Tokyo")
    }

    func testExistingLHAFixturePublicValues() throws {
        try requireTokyo()
        let root = LHAFrozenFixtures.root.deletingLastPathComponent().appendingPathComponent("lha")
        let archives = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".lzh.b64") }.sorted { $0.path < $1.path }
        XCTAssertEqual(archives.count, 3)
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for archive in archives {
            let name = archive.lastPathComponent.replacingOccurrences(of: ".lzh.b64", with: "")
            let fixture = try LHAFrozenFixtures.named(name)
            let data = try XCTUnwrap(Data(base64Encoded: Data(contentsOf: archive), options: .ignoreUnknownCharacters))
            XCTAssertEqual(data, try LHAFrozenFixtures.bytes(fixture), name)
            let url = directory.appendingPathComponent(name + ".lzh")
            try data.write(to: url)
            try assertGolden(url: url, golden: fixture.golden)
        }
        print("LHA-GOLDEN existing=3 TZ=Asia/Tokyo")
    }

    private func requireTokyo() throws {
        try XCTSkipUnless(TimeZone.current.identifier == "Asia/Tokyo", "Run with TZ=Asia/Tokyo for frozen LHA dates")
    }

    private func assertGolden(url: URL, golden: String) throws {
        let actual = try LHAPublicValueDump.data(url: url)
        let expected = try Data(contentsOf: LHAFrozenFixtures.root.appendingPathComponent(golden))
        if actual != expected {
            let path = url.deletingPathExtension().appendingPathExtension("actual.json")
            try actual.write(to: path)
            XCTFail("LHA public values differ: \(golden)\n\(String(decoding: actual, as: UTF8.self))")
        }
    }
}

// Step 0 の lhadump と同じ項目・JSON 書式。エラーも golden の一部として比べる。
private enum LHAPublicValueDump {
    static func nullable<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    static func errorJSON(_ error: any Error) -> [String: Any] {
        ["type": String(reflecting: type(of: error)), "message": String(describing: error)]
    }

    static func contentJSON(reader: ArchiveReader, entry: ArchiveEntry) -> [String: Any] {
        do {
            let stream = try reader.stream(entry)
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                hash.update(data: Data(buffer.prefix(count)))
            }
            return ["sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()]
        } catch {
            return ["error": errorJSON(error)]
        }
    }

    static func dump(url: URL) -> [String: Any] {
        do {
            let reader = try ArchiveReader.open(url: url)
            let entries: [[String: Any]] = reader.entries.map { entry in
                [
                    "index": entry.index,
                    "rawName": [
                        "bytes": entry.rawName.bytes,
                        "declaredEncoding": nullable(entry.rawName.declaredEncoding?.rawValue),
                        "isDirectoryHint": entry.rawName.isDirectoryHint,
                    ],
                    "name": entry.name,
                    "pathComponents": entry.pathComponents,
                    "kind": entry.kind.rawValue,
                    "uncompressedSize": nullable(entry.uncompressedSize),
                    "compressedSize": nullable(entry.compressedSize),
                    "modificationDate": nullable(entry.modificationDate?.timeIntervalSince1970),
                    "posixPermissions": nullable(entry.posixPermissions),
                    "isEncrypted": entry.isEncrypted,
                    "solidGroup": entry.solidGroup,
                    "crc32": nullable(entry.crc32),
                    "methodDescription": entry.methodDescription,
                    "formatSpecific": entry.formatSpecific,
                    "isIncomplete": entry.isIncomplete,
                    "content": contentJSON(reader: reader, entry: entry),
                ]
            }
            return [
                "format": reader.format.rawValue,
                "nameEncoding": nullable(reader.nameEncoding?.rawValue),
                "entries": entries,
            ]
        } catch {
            return ["error": errorJSON(error)]
        }
    }

    static func data(url: URL) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: dump(url: url),
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
}
