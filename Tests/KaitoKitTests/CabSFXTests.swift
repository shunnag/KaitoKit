import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// PE / Mach-O 実行形式の後ろに置かれた CAB（IExpress や hotfix の self-extractor）。
/// 既存の 7z / RAR / ZIP と同じ上限付き署名走査で `MSCF` を見つけ、header を検証してから開く。
final class CabSFXTests: XCTestCase {
    private func fixture(_ variant: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Fixtures/container/cab-\(variant).cab.b64"), encoding: .utf8)
        return try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
    }

    private func digests(_ reader: ArchiveReader) throws -> [String] {
        try reader.entries.map { entry in
            entry.name + " " + SHA256.hash(data: try reader.read(entry)).map { String(format: "%02x", $0) }.joined()
        }
    }

    func testCabinetBehindExecutablePrefixIsDetectedListedAndReopened() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for variant in ["stored", "mszip", "multiblock"] {
            let cabinet = try fixture(variant)
            let expected = try digests(try ArchiveReader.open(data: cabinet))
            for prefixSize in [68, 1_024, 40_000] {
                var prefixed = ZipTestSupport.makePEPrefix(count: prefixSize)
                prefixed.append(cabinet)
                let url = temporary.appendingPathComponent("\(variant)-\(prefixSize).exe")
                try prefixed.write(to: url)
                XCTAssertEqual(try FormatDetector.detect(url: url), .cab, "\(variant) \(prefixSize)")
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(reader.format, .cab, "\(variant) \(prefixSize)")
                XCTAssertEqual(try digests(reader), expected, "\(variant) \(prefixSize)")
                try FileManager.default.removeItem(at: url)
                XCTAssertEqual(try digests(try reader.reopen()), expected, "\(variant) \(prefixSize)")

                // Data からは既定で走査しない。scanForSFXInData で同じ結果になる。
                XCTAssertThrowsError(try ArchiveReader.open(data: prefixed)) {
                    XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
                }
                let fromData = try ArchiveReader.open(data: prefixed, options: ReaderOptions(scanForSFXInData: true))
                XCTAssertEqual(try digests(fromData), expected, "\(variant) \(prefixSize) data")
            }
        }
    }

    func testFalseCabinetSignaturesInsideThePrefixAreSkippedAndScanIsBounded() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cabinet = try fixture("stored")
        let expected = try digests(try ArchiveReader.open(data: cabinet))

        // 実行形式の中に "MSCF" だけが現れても、CFHEADER の version / reserved が合わなければ飛ばして
        // 本物の cabinet を見つける。
        var prefix = ZipTestSupport.makePEPrefix(count: 4_096)
        prefix.replaceSubrange(300..<304, with: "MSCF".utf8)
        prefix.replaceSubrange(2_000..<2_004, with: "MSCF".utf8)
        var decoy = prefix
        decoy.append(cabinet)
        let url = temporary.appendingPathComponent("decoy.exe")
        try decoy.write(to: url)
        XCTAssertEqual(try FormatDetector.detect(url: url), .cab)
        XCTAssertEqual(try digests(try ArchiveReader.open(url: url)), expected)

        // 走査上限（1 MiB、それ以上の指定は 1 MiB に丸める）の外にある cabinet は見つけない。
        var far = ZipTestSupport.makePEPrefix(count: 1_048_576 + 4_096)
        far.append(cabinet)
        let farURL = temporary.appendingPathComponent("far.exe")
        try far.write(to: farURL)
        XCTAssertThrowsError(try ArchiveReader.open(url: farURL))
        XCTAssertThrowsError(try FormatDetector.detect(url: farURL, options: ReaderOptions(maximumSFXScanSize: 1_048_576 + 8_192)))
        // 上限内ならその近くでも見つかる。
        var near = ZipTestSupport.makePEPrefix(count: 1_048_576 - 512)
        near.append(cabinet)
        let nearURL = temporary.appendingPathComponent("near.exe")
        try near.write(to: nearURL)
        XCTAssertEqual(try FormatDetector.detect(url: nearURL), .cab)
        XCTAssertEqual(try digests(try ArchiveReader.open(url: nearURL)), expected)

        // 署名の直後で切れた cabinet は truncated。
        var cut = ZipTestSupport.makePEPrefix(count: 512)
        cut.append(cabinet.prefix(60))
        let cutURL = temporary.appendingPathComponent("cut.exe")
        try cut.write(to: cutURL)
        XCTAssertThrowsError(try ArchiveReader.open(url: cutURL))
    }
}
