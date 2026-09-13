// stub は実行せず、署名候補の検証・起点・scan bound だけを検査する。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItSFXTests: XCTestCase {
    func testInvalidCandidatesAreSkippedForAllThreeContainers() throws {
        let classic = StuffItContainerTests.classic(), sit5 = StuffItContainerTests.sit5()
        let sitx = StuffItXReaderTests.archive()
        var badClassic = classic; badClassic[132] ^= 1
        var bad5 = sit5; bad5[98] ^= 1
        let badX = Data("StuffIt!".utf8) + Data(repeating: 0xff, count: 40)
        for archive in [classic, sit5, sitx] {
            var stub = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 61)
            stub += badClassic + bad5 + badX
            let offset = UInt64(stub.count), wrapped = stub + archive
            XCTAssertEqual(try StuffItSFX.find(source: DataByteSource(wrapped), maximumScanSize: 1_048_576, limits: ReadLimits()), offset)
            let options = ReaderOptions(scanForSFXInData: true)
            let reader = try ArchiveReader.open(data: wrapped, options: options)
            let plain = try ArchiveReader.open(data: archive)
            XCTAssertEqual(try FormatDetector.detect(data: wrapped, options: options), plain.format)
            XCTAssertEqual(reader.entries, plain.entries)
            for entry in reader.entries { XCTAssertEqual(try reader.read(entry), try plain.read(plain.entries[entry.index])) }
            XCTAssertThrowsError(try ArchiveReader.open(data: wrapped))
        }
    }

    func testFirstValidCandidateWinsAndLimitsAreInclusive() throws {
        let classic = StuffItContainerTests.classic(), sit5 = StuffItContainerTests.sit5()
        let stub = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 126)
        let source = DataByteSource(stub + classic + sit5)
        for bound: UInt64 in [0, 127] { XCTAssertNil(try StuffItSFX.find(source: source, maximumScanSize: bound, limits: ReadLimits())) }
        XCTAssertEqual(try StuffItSFX.find(source: source, maximumScanSize: 128, limits: ReadLimits()), 128)
        let reader = try ArchiveReader.open(source: source, options: ReaderOptions(maximumSFXScanSize: 128, scanForSFXInData: true))
        XCTAssertEqual(reader.entries[0].formatSpecific["container"], "classic")
        let outside = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 1_048_575) + classic
        XCTAssertNil(try StuffItSFX.find(source: DataByteSource(outside), maximumScanSize: .max, limits: ReadLimits()))
        XCTAssertNil(try StuffItSFX.find(source: DataByteSource(Data([0, 0]) + classic), maximumScanSize: 1_024, limits: ReadLimits()))
    }

    func testEncryptedClassicSFXNeedsResourceAndEncryptedCatalogUsesProvider() throws {
        let stub = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 70)
        let options = ReaderOptions(scanForSFXInData: true)
        let classic = try ArchiveReader.open(data: stub + StuffItContainerTests.classic(method: 0x80), options: options)
        XCTAssertTrue(classic.entries[0].isEncrypted)
        XCTAssertThrowsError(try classic.stream(classic.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt encryption without archive resource fork"))
        }
        let encrypted = stub + (try StuffItXCryptoTests.archive(encryptedCatalog: true))
        XCTAssertEqual(try FormatDetector.detect(data: encrypted, options: options), .stuffItX)
        XCTAssertThrowsError(try ArchiveReader.open(data: encrypted, options: options)) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        let provider = StuffItXCryptoTests.Provider("password")
        let reader = try ArchiveReader.open(data: encrypted, options: ReaderOptions(passwordProvider: provider, scanForSFXInData: true))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("ABC".utf8))
    }
}
