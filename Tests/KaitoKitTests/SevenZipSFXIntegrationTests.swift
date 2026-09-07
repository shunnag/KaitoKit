import Foundation
import KaitoKit
import XCTest

final class SevenZipSFXIntegrationTests: XCTestCase {
    func testPEPrefixedSevenZipOpensFromURLAndOptInData() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-sfx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let expected = Data(
            (0..<32_768).map { UInt8(truncatingIfNeeded: $0 * 37) }
        ) + Data("embedded 7z fixture 日本語\n".utf8)
        _ = try SevenZipTestSupport.write(
            expected,
            relativePath: "payload.bin",
            below: sourceDirectory
        )

        let nativeURL = temporary.appendingPathComponent("native.7z")
        try SevenZipTestSupport.makeArchive(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: nativeURL,
            options: ["-m0=LZMA2", "-ms=off"]
        )
        let nativeData = try Data(contentsOf: nativeURL)
        let nativeReader = try ArchiveReader.open(data: nativeData)
        XCTAssertEqual(
            try nativeReader.read(try XCTUnwrap(nativeReader.entries.first)),
            expected
        )

        var prefixedData = makePEPrefix(markerOffset: 192)
        prefixedData.append(nativeData)
        let executableURL = temporary.appendingPathComponent("fixture.exe")
        try prefixedData.write(to: executableURL)

        let fileReader = try ArchiveReader.open(url: executableURL)
        XCTAssertEqual(fileReader.format, .sevenZip)
        XCTAssertEqual(fileReader.entries.map(\.name), ["payload.bin"])
        XCTAssertEqual(try fileReader.read(fileReader.entries[0]), expected)
        let reopenedFile = try fileReader.reopen()
        XCTAssertEqual(
            try reopenedFile.read(reopenedFile.entries[0]),
            expected
        )

        XCTAssertThrowsError(try ArchiveReader.open(data: prefixedData)) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedFormat)
        }
        let dataReader = try ArchiveReader.open(
            data: prefixedData,
            options: ReaderOptions(scanForSFXInData: true)
        )
        XCTAssertEqual(dataReader.format, .sevenZip)
        XCTAssertEqual(dataReader.entries.map(\.name), ["payload.bin"])
        XCTAssertEqual(try dataReader.read(dataReader.entries[0]), expected)
        let reopenedData = try dataReader.reopen()
        XCTAssertEqual(
            try reopenedData.read(reopenedData.entries[0]),
            expected
        )
    }

    private func makePEPrefix(markerOffset: Int) -> Data {
        precondition(markerOffset >= 0x44)
        var bytes = [UInt8](repeating: 0x90, count: markerOffset)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        bytes[0x3c] = 0x40
        bytes[0x3d] = 0
        bytes[0x3e] = 0
        bytes[0x3f] = 0
        bytes[0x40] = 0x50
        bytes[0x41] = 0x45
        bytes[0x42] = 0
        bytes[0x43] = 0
        return Data(bytes)
    }
}
