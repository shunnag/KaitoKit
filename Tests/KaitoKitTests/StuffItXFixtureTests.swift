// CC0 実書庫と支給 SHA-256。Brimstone catalog と対応済みデータ層の結果を区別する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXFixtureTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stuffit")
    private func fixture(_ name: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Data(contentsOf: root.appendingPathComponent(name + ".b64")), options: .ignoreUnknownCharacters))
    }
    func testTenHistoricalFixturesAndCatalogDependency() throws {
        struct Item: Decodable { let file: String; let size: Int; let sha256: String }
        let manifest = try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent("slice3-manifest.json")))
        XCTAssertEqual(manifest.count, 10)
        for item in manifest {
            let data = try fixture(item.file)
            XCTAssertEqual(data.count, item.size); XCTAssertLessThanOrEqual(data.count, 40 * 1024)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), item.sha256)
            XCTAssertEqual(try FormatDetector.detect(data: data), .stuffItX)
            XCTAssertThrowsError(try ArchiveReader.open(data: data)) {
                guard case KaitoError.unsupportedMethod(let detail) = $0 else { return XCTFail("\(item.file): \($0)") }
                XCTAssertEqual(detail, item.file.contains("recoverability") ? "StuffIt X Root algorithms 5:0" : "StuffIt X compression 0")
            }
        }
    }
    func testHistoricalCyanideAndAuxiliarySHA256() throws {
        struct Stream: Decodable { let id: UInt64; let output: UInt64; let sha256: String? }
        struct Expected: Decodable { let file: String; let streams: [Stream] }
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: root.appendingPathComponent("slice3-verified-forks.json")))
        var matches = 0, fullTailCounts = 0
        for archive in expected where ["testfile.stuffit7_dlx.mac9.sitx", "testfile.stuffit7_dlx.mac9.comment.sitx", "testfile.stuffit_deluxe_2009.win.sitx"].contains(archive.file) {
            let source = DataByteSource(try fixture(archive.file))
            let elements = try StuffItXElementParser(source: source, limits: ReadLimits()).parse()
            for element in elements where element.type == 1 && [1,5].contains(element.compression) {
                let stream = try XCTUnwrap(archive.streams.first { $0.id == element.attributes[1] })
                let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: stream.output, limits: ReadLimits())
                if element.compression == 1 {
                    let framed = try StuffItXFramedInput(source: source, ranges: element.data)
                    XCTAssertEqual(try readByteRange(source: framed, offset: 10, count: 1), [255])
                    fullTailCounts += 1
                }
                let bytes = try StuffItXCodecTests.collect(coordinator.stream(offset: 0, length: stream.output), chunk: 7)
                XCTAssertEqual(UInt64(bytes.count), stream.output)
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), stream.sha256)
                matches += 1
            }
        }
        XCTAssertEqual(matches, 11); XCTAssertEqual(fullTailCounts, 10)
    }
}
