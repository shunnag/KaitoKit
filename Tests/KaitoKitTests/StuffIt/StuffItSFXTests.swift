// stub は実行せず、署名候補の検証・起点・scan bound だけを検査する。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItSFXTests: XCTestCase {
    func testStuffIt5SFXCandidateValidationHasACumulativeByteBudget() throws {
        let scanSize = 16_384, first = 8_192
        var block = Array(StuffItContainerTests.sit5().prefix(100))
        StuffItContainerTests.put(UInt64(first), 4, 84, &block)
        StuffItContainerTests.put(UInt64(first), 4, 94, &block)
        block[98] = 0; block[99] = 0
        let offsets = Array(stride(from: 2, through: scanSize, by: 100))
        var bytes = [UInt8](repeating: 0, count: offsets.last! + first)
        bytes[0] = 0x4d; bytes[1] = 0x5a
        for offset in offsets { bytes.replaceSubrange(offset..<offset + 100, with: block) }
        // Later candidates lie inside earlier headers. Work backwards so every
        // recorded CRC is wrong even after all overlapping fields are final.
        for offset in offsets.reversed() {
            let header = Array(bytes[offset..<offset + first])
            StuffItContainerTests.put(UInt64(CRC16.checksum(header) ^ 1), 2, offset + 98, &bytes)
        }
        let source = CountingByteSource(DataByteSource(Data(bytes)))
        XCTAssertThrowsError(try ArchiveReader.open(source: source, options: ReaderOptions(
            limits: ReadLimits(maxMetadataSize: 32_768), maximumSFXScanSize: UInt64(scanSize),
            scanForSFXInData: true))) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt SFX scan"))
        }
        XCTAssertLessThan(source.bytesRead, 128 * 1_024,
                          "StuffIt SFX candidate validation must have a cumulative byte budget")
    }

    func testLargeStuffIt5SFXHeaderIsValidatedOnceByParser() throws {
        let original = Array(StuffItContainerTests.sit5())
        let first = 100 + 4 + 2 * 65_535
        var header = Array(original.prefix(100)) + [UInt8](repeating: 0x63, count: first - 100)
        header[83] |= 0x20 // Comment and auxiliary lengths each fit their 16-bit fields.
        StuffItContainerTests.put(65_535, 2, 100, &header)
        StuffItContainerTests.put(65_535, 2, 102, &header)
        StuffItContainerTests.put(UInt64(first + original.count - 100), 4, 84, &header)
        StuffItContainerTests.put(UInt64(first), 4, 94, &header)
        header[98] = 0; header[99] = 0
        StuffItContainerTests.put(UInt64(CRC16.checksum(header)), 2, 98, &header)
        let stub = Data([0x4d, 0x5a]) + Data(repeating: 0, count: 126)
        let wrapped = stub + Data(header + original.dropFirst(100))
        let source = CountingByteSource(DataByteSource(wrapped))
        XCTAssertEqual(try StuffItSFX.find(source: source, maximumScanSize: 128, limits: ReadLimits()), 128)
        XCTAssertLessThan(source.bytesRead, 64 * 1_024,
                          "SFX scanning must defer large StuffIt 5 header CRCs to the parser")
        let options = ReaderOptions(maximumSFXScanSize: 128, scanForSFXInData: true)
        let reader = try ArchiveReader.open(source: source, options: options)
        XCTAssertEqual(reader.entries.map(\.name), ["A"])
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("AB".utf8))
        var corrupt = wrapped; corrupt[stub.count + first - 1] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(data: corrupt, options: options)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("StuffIt 5 archive header CRC"))
        }
    }

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
