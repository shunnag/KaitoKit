import Foundation
@testable import KaitoKit
import XCTest

final class StuffItJapaneseNameTests: XCTestCase {
    func testJapaneseFixturesResolveEveryEntryNameAndPath() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/stuffit")
        for fixture in ["jp-sjis.sit", "jp-macjp.sit", "jp-euc.sit"] {
            let reader = try ArchiveReader.open(url: fixtureRoot.appendingPathComponent(fixture))
            let euc = fixture == "jp-euc.sit"
            XCTAssertEqual(reader.nameEncoding, euc ? .japaneseEUC : .shiftJIS, fixture)
            var paths = [
                ["写真.jpg"], ["第１巻"], ["第１巻", "ページ０１.jpg"], ["第１巻", "ページ０２.jpg"],
                [euc ? "〜テスト〜.txt" : "～テスト～.txt"], ["Vol.1 表紙.png"],
                ["アイコン付き.jpg", "..namedfork", "rsrc"], ["アイコン付き.jpg"],
            ]
            if fixture == "jp-macjp.sit" { paths += [["メモ….txt"], ["©メモ.txt"]] }
            XCTAssertEqual(reader.entries.map(\.pathComponents), paths, fixture)
            let names = paths.map { $0.joined(separator: "/") }
            XCTAssertEqual(reader.entries.map(\.name), names, fixture)
            for entry in reader.entries {
                XCTAssertEqual(entry.kind, entry.index == 1 ? .directory : .file)
                if entry.kind == .file {
                    XCTAssertEqual(entry.formatSpecific["fork"], entry.index == 6 ? "resource" : "data")
                }
                XCTAssertEqual(UInt64(try reader.read(entry).count), entry.uncompressedSize)
            }
        }
    }

    func testMacJapaneseSpecificBytesRetryInClassicAndSIT5() throws {
        let memo = Array("メモ".data(using: .shiftJIS)!)
        let characters: [(UInt8, String)] = [
            (0x80, "\\"), (0xA0, "\u{00A0}"), (0xFD, "©"), (0xFE, "™"), (0xFF, "…"),
        ]
        for (byte, character) in characters {
            let bytes = memo + [byte] + Array(".txt".utf8)
            XCTAssertNil(EncodingDetector.decode(bytes: bytes, as: .shiftJIS))
            for sit5 in [false, true] {
                let reader = try ArchiveReader.open(data: namedArchive(bytes, sit5: sit5),
                    options: ReaderOptions(encodingPolicy: .fixed(.shiftJIS)))
                XCTAssertEqual(reader.nameEncoding, .shiftJIS)
                XCTAssertEqual(reader.entries[0].name, "メモ\(character).txt", "\(byte), SIT5=\(sit5)")
                XCTAssertEqual(reader.entries[0].rawName.bytes, bytes)
                XCTAssertEqual(try reader.read(reader.entries[0]), Data([65, 66]))
            }
        }
    }

    func testAutomaticShiftJISPreservesStrictUTF8AndCP932Names() throws {
        let legacy = Array("～テスト～.txt".data(using: .shiftJIS)!)
        let utf8 = Array("混在.txt".utf8)
        var archive = namedArchive(legacy, sit5: false) + namedArchive(utf8, sit5: false).dropFirst(22)
        var bytes = Array(archive)
        StuffItContainerTests.put(UInt64(bytes.count), 4, 6, &bytes)
        archive = Data(bytes)
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.nameEncoding, .shiftJIS)
        XCTAssertEqual(reader.entries.map(\.name), ["～テスト～.txt", "混在.txt"])
    }

    func testOtherPoliciesAndUndecodableNamesKeepTheirFallback() throws {
        let bytes: [UInt8] = [0xFD, 0x83, 0x81, 0x83, 0x82]
        for policy in [EncodingPolicy.fixed(.macOSRoman), .fixed(.japaneseEUC), .utf8Only] {
            let expected = EncodingDetector.detect(bytes: bytes, policy: policy).string
            let reader = try ArchiveReader.open(data: namedArchive(bytes, sit5: false),
                options: ReaderOptions(encodingPolicy: policy))
            XCTAssertEqual(reader.entries[0].name, expected)
        }
        XCTAssertNil(EncodingDetector.decodeMacJapanese(bytes: [0x81]))
        let reader = try ArchiveReader.open(data: namedArchive([0x81], sit5: true),
            options: ReaderOptions(encodingPolicy: .fixed(.shiftJIS)))
        XCTAssertEqual(reader.entries[0].name,
            EncodingDetector.detect(bytes: [0x81], policy: .fixed(.shiftJIS)).string)
        let sitx = try ArchiveReader.open(data: StuffItXReaderTests.archive())
        XCTAssertEqual(sitx.entries[0].pathComponents, ["folder", "日本語"])
    }

    private func namedArchive(_ name: [UInt8], sit5: Bool) -> Data {
        if !sit5 {
            var bytes = Array(StuffItContainerTests.classic())
            bytes[24] = UInt8(name.count)
            bytes.replaceSubrange(25..<(25 + name.count), with: name)
            StuffItContainerTests.put(UInt64(CRC16.checksum(Array(bytes[22..<132]))), 2, 132, &bytes)
            return Data(bytes)
        }
        var bytes = Array(StuffItContainerTests.sit5())
        bytes.replaceSubrange(148..<149, with: name)
        StuffItContainerTests.put(UInt64(bytes.count), 4, 84, &bytes)
        StuffItContainerTests.put(UInt64(48 + name.count), 2, 106, &bytes)
        StuffItContainerTests.put(UInt64(name.count), 2, 130, &bytes)
        bytes[132] = 0; bytes[133] = 0
        StuffItContainerTests.put(UInt64(CRC16.checksum(Array(bytes[100..<(148 + name.count)]))), 2, 132, &bytes)
        bytes[98] = 0; bytes[99] = 0
        StuffItContainerTests.put(UInt64(CRC16.checksum(Array(bytes[..<100]))), 2, 98, &bytes)
        return Data(bytes)
    }
}
