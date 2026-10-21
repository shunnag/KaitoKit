import Foundation
import XCTest
@testable import KaitoKit

final class RAR4HeaderWalkReadTests: RAR4BuilderTestCase {
    private func archive(sizes: [Int]) -> Data {
        makeArchive(files: sizes.enumerated().map { FileFixture(name: Array("entry-\($0).bin".utf8), contents: Data(repeating: UInt8(truncatingIfNeeded: $0), count: $1)) })
    }
    func testUnencryptedHeadersCostOneBaseReadEachOnLocalSource() throws {
        let source = CallCountingByteSource(DataByteSource(archive(sizes: Array(repeating: 40000, count: 50))))
        let reader = try RAR4Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 50)
        XCTAssertLessThanOrEqual(source.readCount, 52 + 2)
    }
    func testSmallMembersCoalesceOnNonLocalSource() throws {
        let source = CallCountingByteSource(DataByteSource(archive(sizes: Array(repeating: 4096, count: 200))), reportsNonLocalVolume: true)
        let reader = try RAR4Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 200)
        XCTAssertLessThanOrEqual(source.readCount, 8)
    }
    func testLargeMembersStayInHopMode() throws {
        let source = CallCountingByteSource(DataByteSource(archive(sizes: Array(repeating: 600 << 10, count: 40))), reportsNonLocalVolume: true)
        let reader = try RAR4Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 40)
        XCTAssertLessThanOrEqual(source.readCount, 44)
        XCTAssertLessThanOrEqual(source.readBytes, 40 * (16 << 10) + (1 << 20))
    }
    func testMixedSpacingRunsBoundWastedBytes() throws {
        let sizes = Array(repeating: 4096, count: 60) + Array(repeating: 600 << 10, count: 10) + Array(repeating: 4096, count: 60)
        let bytes = archive(sizes: sizes)
        let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
        let reader = try RAR4Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, sizes.count)
        XCTAssertLessThanOrEqual(source.readBytes, 120 * 4096 + 10 * (16 << 10) + 3 * (1 << 20))
        for index in [0, 60, 129] {
            XCTAssertEqual(try reader.stream(for: reader.entries[index], limits: ReadLimits()).readAll(), Data(repeating: UInt8(truncatingIfNeeded: index), count: sizes[index]))
        }
    }
    func testHeaderEncryptedFixturesListIdenticallyThroughWindow() throws {
        for suffix in ["ascii28-hp", "ascii64-hp"] {
            let count = suffix == "ascii28-hp" ? 28 : 64
            let bytes = try ZipTestSupport.checkedInFixture("rar4/kaito-password-\(suffix).rar")
            var expected: [ArchiveEntry] = []
            for high in [false, true] {
                let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: high)
                let reader = try RAR4Reader(source: source, options: ReaderOptions(password: String(repeating: count == 28 ? "a" : "b", count: count)))
                if !high { expected = reader.entries }
                else { XCTAssertEqual(reader.entries, expected) }
                XCTAssertLessThanOrEqual(source.readCount, 4)
            }
        }
    }
    func testPackedSegmentsReferenceBaseSourceNotWindow() throws {
        let source = CallCountingByteSource(DataByteSource(archive(sizes: [4000, 4000])))
        var password: String?
        let parsed = try RAR4VolumeParser.parseVolume(source: source, limits: ReadLimits(), password: &password,
            passwordProvider: nil, headerKeyCache: RAR3KeyCache(), passwordEncodings: RAR4Reader.PasswordEncodingSelection(), signatureOffset: 0, inputLatency: .high)
        for record in parsed.records {
            for segment in record.packedSegments { XCTAssertTrue((segment.source as AnyObject) === source) }
        }
    }
}
