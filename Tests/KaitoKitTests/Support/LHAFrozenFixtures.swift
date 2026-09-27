import CryptoKit
import Foundation
import XCTest

enum LHAFrozenFixtures {
    struct Fixture: Decodable {
        let name: String
        let file: String
        let golden: String
        let storage: String
        let logicalSize: UInt64
        let size: Int
        let sha256: String
    }

    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lha-raw-layout", isDirectory: true)
    }

    static func all() throws -> [Fixture] {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            .fixtures
    }

    static func named(_ name: String) throws -> Fixture {
        try XCTUnwrap(all().first { $0.name == name }, name)
    }

    static func bytes(_ fixture: Fixture) throws -> Data {
        let encoded = try Data(contentsOf: root.appendingPathComponent(fixture.file))
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        XCTAssertEqual(data.count, fixture.size, fixture.name)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       fixture.sha256, fixture.name)
        return data
    }

    static func materialize(_ fixture: Fixture, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fixture.name + ".lzh")
        try bytes(fixture).write(to: url)
        if fixture.storage == "sparse-prefix" {
            // L9 は header だけを保存し、4 GiB の payload と終端は疎な領域で作る。
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.truncate(atOffset: fixture.logicalSize)
        } else {
            XCTAssertEqual(fixture.storage, "archive")
            XCTAssertEqual(UInt64(fixture.size), fixture.logicalSize)
        }
        return url
    }
}
