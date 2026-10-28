import Foundation
@testable import KaitoKit
import XCTest

/// RAR 6.24 の黒箱出力を原本の SHA-256 と照合し、実際に復号した filter / PPMd を検査する。
final class RAR4FilterFixtureTests: XCTestCase {
    private struct Manifest: Decodable {
        let archives: [Fixture]
    }

    private struct Fixture: Decodable {
        struct Entry: Decodable {
            let path: String
            let size: Int
            let sha256: String
        }

        let path: String
        let kind: String
        let entries: [Entry]
    }

    func testRGBFixtureContainsRGBFilterAndMatchesInputSHA256() throws {
        try verify("rgb", filter: .rgb)
    }

    func testDeltaFixtureContainsDeltaFilterAndMatchesInputSHA256() throws {
        try verify("delta", filter: .delta)
    }

    func testE8FixtureContainsE8FilterAndMatchesInputSHA256() throws {
        try verify("e8", filter: .e8)
    }

    func testAudioFixtureContainsAudioFilterAndMatchesInputSHA256() throws {
        try verify("audio", filter: .audio)
    }

    func testSolidPPMdFixtureContinuesModelAndMatchesEveryInputSHA256() throws {
        try verify("ppmd-solid", filter: nil)
    }

    private func verify(_ kind: String, filter: RARStandardFilterKind?) throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: TestFixtures.url("rar4/r0-manifest.json"))
        )
        let fixture = try XCTUnwrap(manifest.archives.first { $0.kind == kind })
        let data = try TestFixtures.base64("rar4/" + fixture.path)
        XCTAssertLessThanOrEqual(data.count, 64 * 1024)
        let reader = try ArchiveReader.open(data: data)
        XCTAssertEqual(reader.entries.map(\.name), fixture.entries.map(\.path))
        XCTAssertEqual(reader.entries.count, filter == nil ? 2 : 1)
        for (entry, expected) in zip(reader.entries, fixture.entries) {
            let decoded = try reader.read(entry)
            XCTAssertEqual(decoded.count, expected.size, entry.name)
            XCTAssertEqual(decoded.sha256Hex, expected.sha256, entry.name)
        }
        if filter == nil {
            XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0])
            // 後方 seek と再 open でも先行 member の PPMd model を復元できる。
            for index in [1, 0, 1] {
                XCTAssertEqual(try reader.read(reader.entries[index]).sha256Hex,
                               fixture.entries[index].sha256)
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(try reopened.read(reopened.entries[1]).sha256Hex, fixture.entries[1].sha256)
        }

        let source = DataByteSource(data: data)
        var password: String?
        let parsed = try RAR4VolumeParser.parseVolume(
            source: source, limits: ReadLimits(), password: &password,
            passwordProvider: nil, headerKeyCache: RAR3KeyCache(),
            passwordEncodings: RAR4Reader.PasswordEncodingSelection(), signatureOffset: 0
        )
        XCTAssertEqual(parsed.records.count, fixture.entries.count)
        let first = try XCTUnwrap(parsed.records.first)
        let state = try RAR29Decoder.SolidState(dictionarySize: first.dictionarySize)
        for (index, record) in parsed.records.enumerated() {
            XCTAssertEqual(record.unpackVersion, 29)
            XCTAssertEqual(record.packedSegments.count, 1)
            let segment = try XCTUnwrap(record.packedSegments.first)
            if filter == nil {
                let header = try XCTUnwrap(readByteRange(source: source, offset: segment.offset, count: 1).first)
                XCTAssertNotEqual(header & 0x80, 0, "member must start in PPMd mode")
                XCTAssertEqual(header & 0x20 != 0, index == 0, "only the first member resets the PPMd model")
                XCTAssertEqual(record.firstFlags & RAR4FileFlag.solid != 0, index > 0)
            }
            let decoder = try RAR29Decoder(
                source: source, offset: segment.offset, compressedSize: record.packedSize,
                expectedSize: record.unpackedSize, unpackVersion: record.unpackVersion,
                method: record.method, dictionarySize: record.dictionarySize,
                isSolid: record.firstFlags & RAR4FileFlag.solid != 0,
                limits: ReadLimits(), solidState: state
            )
            var decoded = Data()
            var buffer = [UInt8](repeating: 0, count: 257)
            while !decoder.isFinished {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                XCTAssertTrue(count > 0 || decoder.isFinished)
                decoded.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(decoded.sha256Hex, fixture.entries[index].sha256)
        }
        // RAR3FilterToken.parse が認識して decoder が登録した table を読む。
        // 本体に計測用 API を追加せず、private field の改名・型変更も明示的な失敗にする。
        let programs = try XCTUnwrap(Mirror(reflecting: state).children.first {
            $0.label == "filterPrograms"
        }?.value as? [RAR29Decoder.StoredFilterProgram])
        if let filter {
            XCTAssertEqual(programs.map(\.kind), [filter], "intended filter must be decoded from the fixture")
        } else {
            XCTAssertTrue(programs.isEmpty)
        }
    }
}
