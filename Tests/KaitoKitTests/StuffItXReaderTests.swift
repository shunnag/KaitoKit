// 未圧縮の人工 catalog により、後続 slice の codec に依存せず容器を検証する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXReaderTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer
    static func checksum(_ data: Data) -> Data {
        let value = CRC32.checksum(data)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) })
    }
    static func archive(corruptData: Bool = false, corruptCatalog: Bool = false, method: UInt64? = nil,
                        digest: UInt64 = 0, key: UInt64 = 2) -> Data {
        var w = Writer(data: Data("StuffIt!".utf8))
        w.element(7, extra: 5)
        w.element(2, [(1,2),(2,1),(7,0)]); w.element(4, [(1,1),(2,0),(7,1)])
        w.element(2, [(1,3),(2,1),(7,2)]); w.element(2, [(1,4),(2,0),(7,3)])
        var catalog = Writer()
        for name in ["日本語", "folder", "alias", "empty"] {
            catalog.p2(1); catalog.string(Data(name.utf8)); catalog.p2(10); catalog.p2(1); catalog.align()
            catalog.string(Data(name.utf8)); catalog.p2(0); catalog.align()
        }
        w.element(5, [(1,1),(5,UInt64(catalog.data.count))], [(2,0,nil)])
        w.frames([catalog.data]); var crc = checksum(catalog.data); if corruptCatalog { crc[0] ^= 1 }; w.frames([crc])
        let data = Data("ABCDE".utf8)
        var algorithms: [(UInt64, UInt64, UInt64?)] = [(key,digest,nil)]
        if let method { algorithms.append((1,method,nil)) }
        w.element(1, [(1,10),(5,5)], algorithms)
        w.frames([data.prefix(1), data.dropFirst(1)])
        var expected = digest == 0 ? checksum(data) : Data(Insecure.MD5.hash(data: data))
        if corruptData { expected[0] ^= 1 }
        w.frames(digest == 1 ? [expected.prefix(3), expected.dropFirst(3)] : [expected])
        // Data より後の宣言、slot の逆順、同一 slot の複数 owner を含める。
        w.element(3, [(2,2),(3,10),(4,1),(5,2)], extra: 1)
        w.element(3, [(2,2),(3,10),(4,0),(5,3)], extra: 0)
        w.element(3, [(2,3),(3,10),(4,0),(5,3)], extra: 0)
        var comment = Writer(); comment.p2(9); comment.string(Data("Test Comment".utf8)); comment.p2(0); comment.align()
        w.element(9, [(6,15),(7,0)])
        w.element(5, [(1,15),(5,UInt64(comment.data.count))], [(6,1,nil)])
        w.frames([comment.data]); w.frames([Data(Insecure.MD5.hash(data: comment.data))]); w.element(0)
        return w.data
    }
    func testStoredSolidSharedSlotsPathsCommentsAndWrappers() throws {
        let data = Self.archive(), reader = try ArchiveReader.open(data: data)
        XCTAssertEqual(reader.format, .stuffItX)
        XCTAssertEqual(reader.entries.count, 5)
        let entries = reader.entries
        XCTAssertEqual(entries[0].pathComponents, ["folder", "日本語"])
        XCTAssertEqual(entries[1].pathComponents, ["folder", "alias"])
        XCTAssertEqual(entries[2].pathComponents, ["folder", "日本語", "..namedfork", "rsrc"])
        XCTAssertEqual(entries.map(\.solidGroup), [10,10,10,-1,-1])
        XCTAssertEqual(entries[0].formatSpecific["catalogPath"], "日本語")
        XCTAssertEqual(entries[0].formatSpecific["archiveComment"], "Test Comment")
        for index in [2,0,1,2,0] {
            XCTAssertEqual(try reader.read(entries[index]), Data((index == 2 ? "DE" : "ABC").utf8))
        }
        XCTAssertEqual(try reader.read(entries[4]), Data())
        XCTAssertEqual(try FormatDetector.detect(data: data), .stuffItX)
        XCTAssertThrowsError(try FormatDetector.detect(data: Data("StuffIt?base64\n".utf8))) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
    }
    func testCRCAndMD5DataAndCatalog() throws {
        for digest: UInt64 in [0,1] {
            for key: UInt64 in [2,6] {
                let reader = try ArchiveReader.open(data: Self.archive(digest: digest, key: key))
                XCTAssertEqual(try reader.read(reader.entries[2]), Data("DE".utf8))
                let bad = try ArchiveReader.open(data: Self.archive(corruptData: true, digest: digest, key: key))
                for _ in 0..<2 {
                    XCTAssertThrowsError(try bad.read(bad.entries[2])) { XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1)) }
                }
            }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: Self.archive(corruptCatalog: true))) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1))
        }
    }
    func testUnsupportedPayloadIsAnEntryFailure() throws {
        for method: UInt64 in [0,6,7] {
            let reader = try ArchiveReader.open(data: Self.archive(method: method))
            XCTAssertEqual(reader.entries.count, 5)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) {
                guard case KaitoError.unsupportedMethod = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try reader.read(reader.entries[4]), Data())
        }
    }
    func testCoordinatorRetainsStateAndInvalidatesOldRanges() throws {
        let source = DataByteSource(Self.archive())
        let element = try XCTUnwrap(StuffItXElementParser(source: source, limits: ReadLimits()).parse().first { $0.type == 1 })
        let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: 5, limits: ReadLimits())
        let old = try coordinator.stream(offset: 0, length: 3)
        XCTAssertTrue(coordinator.hasRetainedDecoderState)
        let next = try coordinator.stream(offset: 3, length: 2)
        XCTAssertThrowsError(try StuffItXCodecTests.collect(old, chunk: 1))
        XCTAssertEqual(try StuffItXCodecTests.collect(next, chunk: 1), Data("DE".utf8))
        XCTAssertFalse(coordinator.hasRetainedDecoderState)
        XCTAssertEqual(try StuffItXCodecTests.collect(coordinator.stream(offset: 0, length: 5), chunk: 1), Data("ABCDE".utf8))
    }
    func testPackedCatalogFieldsAndLinkMarker() throws {
        var w = Writer()
        func packed(_ value: UInt64, _ count: Int, _ writer: inout Writer) {
            for i in (0..<count).reversed() { writer.bits((value >> (8 * i)) & 255, 8) }
        }
        w.p2(2); packed(116_444_736_000_000_000, 8, &w)
        w.p2(8); packed(116_444_736_010_000_000, 8, &w)
        w.p2(3); packed(0x12345678, 4, &w)
        w.p2(6); w.bits(2,8); packed(0o100755,4,&w); packed(501,4,&w); packed(20,4,&w)
        w.p2(4); for b in Array("slnkrhap".utf8) + [UInt8](repeating: 0, count: 24) { w.bits(UInt64(b),8) }
        w.p2(7); w.p2(9); w.p2(11); w.string(Data()); w.p2(12); w.string(Data("x".utf8)); w.p2(0); w.align()
        let record = try StuffItXCatalog.parse(w.data, count: 1, limits: ReadLimits())[0]
        XCTAssertEqual(record.modified, Date(timeIntervalSince1970: 0)); XCTAssertTrue(record.link)
        XCTAssertEqual(record.permissions, 0o755); XCTAssertEqual(record.metadata["uid"], "501")
        XCTAssertEqual(record.metadata["gid"], "20"); XCTAssertEqual(record.metadata["catalog3"], "305419896")
        var bad = Writer(); bad.p2(13); bad.align()
        XCTAssertThrowsError(try StuffItXCatalog.parse(bad.data, count: 1, limits: ReadLimits()))
        XCTAssertThrowsError(try StuffItXCatalog.parse(w.data + [0], count: 1, limits: ReadLimits()))
    }
    func testAuxiliaryUsesDeclaredStreamLengthAndIsNotPublished() throws {
        var w = Writer(data: Data("StuffIt!".utf8))
        w.element(2,[(1,2),(2,0)])
        var catalog = Writer(); catalog.p2(1); catalog.string(Data("image".utf8)); catalog.p2(0); catalog.align()
        w.element(5,[(5,UInt64(catalog.data.count))]); w.frames([catalog.data]); w.frames([])
        w.element(3,[(2,2),(3,10),(4,0),(5,2)],extra:3)
        w.element(1,[(1,10),(5,5)],[(2,0,nil)]); w.frames([Data("ABCDE".utf8)]); w.frames([Self.checksum(Data("ABCDE".utf8))])
        w.element(0)
        let reader = try ArchiveReader.open(data:w.data)
        XCTAssertEqual(reader.entries.count,1); XCTAssertEqual(reader.entries[0].uncompressedSize,0)
        XCTAssertTrue(reader.entries[0].formatSpecific["auxiliaryForks"]!.contains("streamLength=5"))
        XCTAssertEqual(try reader.read(reader.entries[0]),Data())
        var corrupt = w.data; corrupt[corrupt.count - 6] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(data:corrupt))
    }
    func testObjectAndResourceLimits() throws {
        for limits in [ReadLimits(maxEntryCount: 2), ReadLimits(maxMetadataSize: 1),
                       ReadLimits(maxPathComponentCount: 1), ReadLimits(maxTotalMetadataSize: 64),
                       ReadLimits(maxMetadataRecordCount: 2), ReadLimits(maxTotalUncompressedSize: 4)] {
            XCTAssertThrowsError(try ArchiveReader.open(data:Self.archive(),options:ReaderOptions(limits:limits))) {
                guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
            }
        }
        let fixed = try ArchiveReader.open(data:Self.archive(),options:ReaderOptions(encodingPolicy:.fixed(.macOSRoman)))
        XCTAssertEqual(fixed.entries[0].pathComponents[1],String(bytes:Array("日本語".utf8),encoding:.macOSRoman))
    }
}
