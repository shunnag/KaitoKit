import Foundation
@testable import KaitoKit
import XCTest

final class FormatDetectorM5Tests: XCTestCase {
    private let zip = [UInt8]([0x50, 0x4B, 0x03, 0x04])
    private let rar5 = [UInt8]([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
    private let sevenZip = [UInt8]([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])

    func testDirectSignatureTable() throws {
        let cases: [(ArchiveFormat, [UInt8])] = [
            (.zip, zip),
            (.rar, rar5),
            (.sevenZip, sevenZip),
            (.xz, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
            (.gzip, [0x1F, 0x8B]),
            (.bzip2, [0x42, 0x5A, 0x68, 0x31]),
            (.compress, [0x1F, 0x9D]),
        ]

        for (expected, signature) in cases {
            XCTAssertEqual(
                try FormatDetector.detect(data: Data(signature)),
                expected,
                "signature: \(signature)"
            )
        }
    }

    func testStructurallyPlausibleLHAWinsOverTwoByteGzipMarker() throws {
        var header = [UInt8](repeating: 0, count: 40)
        header[0] = 0x1F
        header[1] = 0x8B
        header.replaceSubrange(2..<7, with: Array("-lh5-".utf8))
        header[20] = 0

        XCTAssertEqual(try FormatDetector.detect(data: Data(header)), .lha)
    }

    func testSFXDataRequiresOptInAndARecognizedExecutablePrefix() throws {
        let archive = makePE(marker: zip, at: 192)

        assertUnsupported(archive)
        XCTAssertEqual(
            try FormatDetector.detect(
                data: archive,
                options: ReaderOptions(scanForSFXInData: true)
            ),
            .zip
        )

        var arbitrary = archive
        arbitrary[0] = 0
        arbitrary[1] = 0
        assertUnsupported(
            arbitrary,
            options: ReaderOptions(scanForSFXInData: true)
        )
    }

    func testPEAndMachOSFXSignatureTable() throws {
        let cases: [(ArchiveFormat, [UInt8])] = [
            (.zip, zip),
            (.rar, rar5),
            (.sevenZip, sevenZip),
        ]
        let options = ReaderOptions(scanForSFXInData: true)

        for (expected, marker) in cases {
            XCTAssertEqual(
                try FormatDetector.detect(
                    data: makePE(marker: marker, at: 192),
                    options: options
                ),
                expected
            )
            XCTAssertEqual(
                try FormatDetector.detect(
                    data: makeMachO(marker: marker, at: 96),
                    options: options
                ),
                expected
            )
        }
    }

    func testSFXUsesEarliestOffsetBeforeFormatOrder() throws {
        var executable = makePE(marker: zip, at: 224)
        executable.replaceSubrange(176..<(176 + rar5.count), with: rar5)
        executable.replaceSubrange(128..<(128 + sevenZip.count), with: sevenZip)

        let match = try XCTUnwrap(
            FormatDetector.findSFXSignature(
                source: DataByteSource(data: executable),
                maximumScanSize: 256
            )
        )
        XCTAssertEqual(match.offset, 128)
        XCTAssertEqual(match.format, .sevenZip)
    }

    func testSFXScanSizeIsConfigurableAndClamped() throws {
        let markerOffset = 320
        let executable = makePE(marker: zip, at: markerOffset)

        assertUnsupported(
            executable,
            options: ReaderOptions(
                maximumSFXScanSize: UInt64(markerOffset - 1),
                scanForSFXInData: true
            )
        )
        XCTAssertEqual(
            try FormatDetector.detect(
                data: executable,
                options: ReaderOptions(
                    maximumSFXScanSize: UInt64(markerOffset),
                    scanForSFXInData: true
                )
            ),
            .zip
        )

        let clamped = ReaderOptions(maximumSFXScanSize: UInt64.max)
        XCTAssertEqual(clamped.maximumSFXScanSize, 1 * 1_024 * 1_024)

        let beyondMaximum = makePE(
            marker: zip,
            at: Int(FormatDetector.maximumSFXScanSize) + 1
        )
        assertUnsupported(
            beyondMaximum,
            options: ReaderOptions(
                maximumSFXScanSize: UInt64.max,
                scanForSFXInData: true
            )
        )
    }

    func testURLDetectionUsesSFXAndExtensionHints() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-FormatDetector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sfxURL = directory.appendingPathComponent("reader.exe")
        try makePE(marker: rar5, at: 192).write(to: sfxURL)
        XCTAssertEqual(try FormatDetector.detect(url: sfxURL), .rar)

        let tarURL = directory.appendingPathComponent("legacy.TAR")
        try Data([0x01]).write(to: tarURL)
        XCTAssertEqual(try FormatDetector.detect(url: tarURL), .tar)

        let compressURL = directory.appendingPathComponent("legacy.Z")
        try Data([0x01]).write(to: compressURL)
        XCTAssertEqual(try FormatDetector.detect(url: compressURL), .compress)

        let contentWinsURL = directory.appendingPathComponent("content.tar")
        try Data([0x1F, 0x8B]).write(to: contentWinsURL)
        XCTAssertEqual(try FormatDetector.detect(url: contentWinsURL), .gzip)
    }

    func testAtLeast200DeterministicSignatureMutantsAreRejected() throws {
        let markers = [zip, rar5, sevenZip]
        let options = ReaderOptions(scanForSFXInData: true)
        var exercised = 0

        for marker in markers {
            for index in marker.indices {
                for variant in UInt8(0)..<UInt8(16) {
                    var mutant = marker
                    mutant[index] ^= 0x80 | variant
                    assertUnsupported(
                        makePE(marker: mutant, at: 192),
                        options: options
                    )
                    exercised += 1
                }
            }
        }

        for index in 0..<2 {
            for variant in UInt8(0)..<UInt8(32) {
                var mutant: [UInt8] = [0x1F, 0x9D]
                mutant[index] ^= 0x40 | variant
                assertUnsupported(Data(mutant))
                exercised += 1
            }
        }

        XCTAssertGreaterThanOrEqual(exercised, 200)
    }

    private func makePE(marker: [UInt8], at markerOffset: Int) -> Data {
        precondition(markerOffset >= 128)
        var bytes = [UInt8](
            repeating: 0x90,
            count: max(256, markerOffset + marker.count)
        )
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[0x3C] = 0x40
        bytes[0x3D] = 0
        bytes[0x3E] = 0
        bytes[0x3F] = 0
        bytes.replaceSubrange(0x40..<0x44, with: [0x50, 0x45, 0, 0])
        bytes.replaceSubrange(
            markerOffset..<(markerOffset + marker.count),
            with: marker
        )
        return Data(bytes)
    }

    private func makeMachO(marker: [UInt8], at markerOffset: Int) -> Data {
        precondition(markerOffset >= 4)
        var bytes = [UInt8](
            repeating: 0,
            count: markerOffset + marker.count
        )
        bytes.replaceSubrange(0..<4, with: [0xCF, 0xFA, 0xED, 0xFE])
        bytes.replaceSubrange(
            markerOffset..<(markerOffset + marker.count),
            with: marker
        )
        return Data(bytes)
    }

    private func assertUnsupported(
        _ data: Data,
        options: ReaderOptions = ReaderOptions(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FormatDetector.detect(data: data, options: options),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedFormat,
                file: file,
                line: line
            )
        }
    }
}
