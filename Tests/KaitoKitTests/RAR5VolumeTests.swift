import Foundation
@testable import KaitoKit
import XCTest

final class RAR5VolumeTests: XCTestCase {
    func testNonzeroFirstVolumeNumberIsRejectedForDataAndArbitrarySource() throws {
        let archive = RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 1,
            blocks: []
        )
        let expected = KaitoError.malformed(
            "RAR5 volume number 1 does not match expected 0"
        )

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(source: RAR5VolumeByteSource(archive))
        ) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }
    }

    func testExplicitZeroFirstVolumeNumberIsRejectedByParserAndLocator() throws {
        let archive = RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 0,
            blocks: []
        )
        let expected = KaitoError.malformed(
            "RAR5 first volume has an explicit volume number"
        )

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }

        let directory = try ZipTestSupport.temporaryDirectory(
            label: "rar5-explicit-first-number"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("explicit.part1.rar")
        try archive.write(to: first)
        XCTAssertThrowsError(
            try RARVolumeLocator(firstVolumeURL: first, naming: .rar5)
        ) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }
    }

    func testPartOneSplitReadFromDataKeepsExactUnsupportedError() throws {
        let archive = RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: [RAR5TestSupport.storedFile(
                name: "split.bin",
                contents: Data("first fragment".utf8),
                headerFlags: 0x0010
            )]
        )

        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("multi-volume from Data")
            )
        }
    }

    func testConfiguredVolumeCapStopsBeforeOpeningAnotherSibling() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar5-volume-cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("cap.part1.rar")
        let second = directory.appendingPathComponent("cap.part2.rar")
        try RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: []
        ).write(to: first)
        try RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 1,
            endFlags: 0x0001,
            blocks: []
        ).write(to: second)

        var limits = ReadLimits()
        limits.maxVolumeCount = 2
        XCTAssertThrowsError(
            try ArchiveReader.open(url: first, options: ReaderOptions(limits: limits))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .limitExceeded("RAR5 volume count"))
        }
    }

    func testMixedCasePartMarkerAndExtensionArePreserved() throws {
        let directory = try ZipTestSupport.temporaryDirectory(
            label: "rar5-volume-case"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("Mixed.PaRt1.RAR")
        let second = directory.appendingPathComponent("Mixed.PaRt2.RAR")
        try RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: []
        ).write(to: first)
        try RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 1,
            blocks: []
        ).write(to: second)
        let locator = try RARVolumeLocator(
            firstVolumeURL: first,
            naming: .rar5
        )
        XCTAssertEqual(
            try locator.locate(volumeNumber: 1).url?.lastPathComponent,
            second.lastPathComponent
        )

        let reader = try ArchiveReader.open(url: first)
        XCTAssertTrue(reader.entries.isEmpty)
        XCTAssertTrue(try reader.reopen().entries.isEmpty)
    }

    func testGeneratedStoredMultiVolumeChainRoundTripsBytePerfectly() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-volume-stored")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let payload = RAR5TestSupport.deterministicPayload(
            count: 2 * 1_024 * 1_024 + 123_457,
            seed: 0x52_41_52_35_56_4f_4c
        )
        let laterPayload = Data("entry wholly contained in a later volume\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "stored.bin", below: source)
        _ = try ZipTestSupport.write(
            laterPayload,
            relativePath: "later.txt",
            below: source
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["stored.bin", "later.txt"],
            archiveURL: temporary.appendingPathComponent("stored.rar"),
            options: ["-m0", "-s-", "-v1m"]
        )

        let firstVolume = temporary.appendingPathComponent("stored.part1.rar")
        let reader = try ArchiveReader.open(url: firstVolume)
        XCTAssertEqual(reader.entries.map(\.name), ["stored.bin", "later.txt"])
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "stored.bin")
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(entry.compressedSize, UInt64(payload.count))
        XCTAssertEqual(entry.formatSpecific["multiVolume"], "true")
        XCTAssertGreaterThan(Int(entry.formatSpecific["volumeSegmentCount"] ?? "0") ?? 0, 1)
        XCTAssertEqual(entry.formatSpecific["splitBefore"], "false")
        XCTAssertEqual(entry.formatSpecific["splitAfter"], "false")
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(try reader.reopen().read(entry), payload)
        let later = try XCTUnwrap(reader.entries.last)
        XCTAssertEqual(later.formatSpecific["multiVolume"], "false")
        XCTAssertEqual(try reader.read(later), laterPayload)

        // Both the original and a later reopen must keep using the exact file
        // descriptors authenticated at open time, even after every path is gone.
        let volumeURLs = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "rar" }
        XCTAssertGreaterThan(volumeURLs.count, 1)
        for volumeURL in volumeURLs {
            try FileManager.default.removeItem(at: volumeURL)
        }
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(try reader.read(later), laterPayload)
        let pathIndependentReader = try reader.reopen()
        XCTAssertEqual(
            try pathIndependentReader.read(pathIndependentReader.entries[0]),
            payload
        )
        XCTAssertEqual(
            try pathIndependentReader.read(pathIndependentReader.entries[1]),
            laterPayload
        )
    }

    func testGeneratedCompressedMultiVolumeChainRoundTripsBytePerfectly() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-volume-compressed")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let payload = RAR5TestSupport.deterministicPayload(
            count: 2 * 1_024 * 1_024 + 321_987,
            seed: 0x43_4f_4d_50_56_4f_4c
        )
        _ = try ZipTestSupport.write(payload, relativePath: "compressed.bin", below: source)
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["compressed.bin"],
            archiveURL: temporary.appendingPathComponent("compressed.rar"),
            options: ["-m5", "-s-", "-md1m", "-v1m"]
        )

        let reader = try ArchiveReader.open(
            url: temporary.appendingPathComponent("compressed.part1.rar")
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(entry.name, "compressed.bin")
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(entry.formatSpecific["method"], "5")
        XCTAssertEqual(entry.formatSpecific["multiVolume"], "true")
        XCTAssertGreaterThan(Int(entry.formatSpecific["volumeSegmentCount"] ?? "0") ?? 0, 1)
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testNonfinalPackedCRCIsVerifiedBeforeStreaming() throws {
        let directory = try ZipTestSupport.temporaryDirectory(
            label: "rar5-volume-packed-crc"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstPayload = Data("packed bytes from volume one".utf8)
        let lastPayload = Data(" and volume two".utf8)
        let fullPayload = firstPayload + lastPayload
        var firstVolume = RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: [RAR5TestSupport.storedFile(
                name: "split.bin",
                contents: firstPayload,
                fileFlags: 0x0008,
                headerFlags: 0x0010
            )]
        )
        try corruptFirstDataArea(&firstVolume)
        let lastVolume = RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 1,
            blocks: [RAR5TestSupport.storedFile(
                name: "split.bin",
                contents: lastPayload,
                unpackedSize: UInt64(fullPayload.count),
                dataCRC32: CRC32.checksum(fullPayload),
                headerFlags: 0x0008
            )]
        )
        let firstURL = directory.appendingPathComponent("crc.part1.rar")
        try firstVolume.write(to: firstURL)
        try lastVolume.write(to: directory.appendingPathComponent("crc.part2.rar"))

        let reader = try ArchiveReader.open(url: firstURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.stream(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testNonfinalPackedBlake2spIsVerifiedBeforeStreaming() throws {
        let directory = try ZipTestSupport.temporaryDirectory(
            label: "rar5-volume-packed-blake"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstPayload = Data("BLAKE2sp bytes from volume one".utf8)
        let lastPayload = Data(" and volume two".utf8)
        let fullPayload = firstPayload + lastPayload
        let firstHash = RAR5TestSupport.extraRecord(
            type: 0x02,
            payload: RAR5TestSupport.vint(0) + Array(Blake2sp.checksum(firstPayload))
        )
        let finalHash = RAR5TestSupport.extraRecord(
            type: 0x02,
            payload: RAR5TestSupport.vint(0) + Array(Blake2sp.checksum(fullPayload))
        )
        var firstVolume = RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: [RAR5TestSupport.storedFile(
                name: "split.bin",
                contents: firstPayload,
                includeCRC32: false,
                fileFlags: 0x0008,
                extra: firstHash,
                headerFlags: 0x0010
            )]
        )
        try corruptFirstDataArea(&firstVolume)
        let lastVolume = RAR5TestSupport.archive(
            mainFlags: 0x0003,
            mainVolumeNumber: 1,
            blocks: [RAR5TestSupport.storedFile(
                name: "split.bin",
                contents: lastPayload,
                unpackedSize: UInt64(fullPayload.count),
                includeCRC32: false,
                extra: finalHash,
                headerFlags: 0x0008
            )]
        )
        let firstURL = directory.appendingPathComponent("blake.part1.rar")
        try firstVolume.write(to: firstURL)
        try lastVolume.write(to: directory.appendingPathComponent("blake.part2.rar"))

        let reader = try ArchiveReader.open(url: firstURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.stream(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testMissingContinuationVolumeIsTruncated() throws {
        let fixture = try makeSmallGeneratedChain(label: "missing")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.volumes[1])

        XCTAssertThrowsError(try ArchiveReader.open(url: fixture.volumes[0])) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testWrongNumberedContinuationAndNonFirstInputAreRejected() throws {
        let fixture = try makeSmallGeneratedChain(label: "number")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertGreaterThan(fixture.volumes.count, 2)

        XCTAssertThrowsError(try ArchiveReader.open(url: fixture.volumes[1])) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 volume number 1 does not match expected 0")
            )
        }

        try Data(contentsOf: fixture.volumes[2]).write(to: fixture.volumes[1])
        XCTAssertThrowsError(try ArchiveReader.open(url: fixture.volumes[0])) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 volume number 2 does not match expected 1")
            )
        }
    }

    func testSameNumberVolumeWithDifferentFileMetadataIsRejected() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-volume-mismatch")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try ZipTestSupport.write(
            RAR5TestSupport.deterministicPayload(count: 8 * 1_024, seed: 0x41),
            relativePath: "alpha.bin",
            below: source
        )
        _ = try ZipTestSupport.write(
            RAR5TestSupport.deterministicPayload(count: 8 * 1_024, seed: 0x42),
            relativePath: "beta.bin",
            below: source
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["alpha.bin"],
            archiveURL: temporary.appendingPathComponent("alpha.rar"),
            options: ["-m0", "-s-", "-v1k"]
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["beta.bin"],
            archiveURL: temporary.appendingPathComponent("beta.rar"),
            options: ["-m0", "-s-", "-v1k"]
        )

        let volumeURLs = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        )
        let alphaFirst = try XCTUnwrap(volumeURLs.first {
            $0.lastPathComponent.hasPrefix("alpha.part") && partNumber($0) == 1
        })
        let alphaSecond = try XCTUnwrap(volumeURLs.first {
            $0.lastPathComponent.hasPrefix("alpha.part") && partNumber($0) == 2
        })
        let betaSecond = try XCTUnwrap(volumeURLs.first {
            $0.lastPathComponent.hasPrefix("beta.part") && partNumber($0) == 2
        })
        try Data(contentsOf: betaSecond).write(to: alphaSecond)
        XCTAssertThrowsError(
            try ArchiveReader.open(url: alphaFirst)
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 split file metadata changes between volumes")
            )
        }
    }

    func testSolidGroupingSkipsDirectoryHeaders() throws {
        let archive = RAR5TestSupport.archive(mainFlags: 0x0004, blocks: [
            RAR5TestSupport.storedFile(
                name: "first.txt",
                contents: Data("first".utf8)
            ),
            RAR5TestSupport.storedFile(
                name: "folder",
                contents: Data(),
                fileFlags: 0x0001
            ),
            RAR5TestSupport.storedFile(
                name: "second.txt",
                contents: Data("second".utf8),
                compressionInfo: 0x0040
            ),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["first.txt", "folder", "second.txt"])
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, 0])
    }

    func testOutOfRangeNanosecondsAreRejected() throws {
        var timePayload = RAR5TestSupport.vint(0x0013)
        appendLittle(1, to: &timePayload)
        appendLittle(1_000_000_000, to: &timePayload)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "time.txt",
                contents: Data(),
                extra: RAR5TestSupport.extraRecord(type: 0x03, payload: timePayload)
            ),
        ])

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 nanosecond field is out of range")
            )
        }
    }

    func testDuplicateSingletonFileExtrasAreRejected() throws {
        let records: [(UInt64, [UInt8])] = [
            (0x01, RAR5TestSupport.vint(0) + RAR5TestSupport.vint(0)
                + [0] + [UInt8](repeating: 0, count: 32)),
            (0x02, RAR5TestSupport.vint(0) + [UInt8](repeating: 0, count: 32)),
            (0x03, RAR5TestSupport.vint(0)),
            (0x04, RAR5TestSupport.vint(0) + RAR5TestSupport.vint(1)),
            (0x05, RAR5TestSupport.vint(1) + RAR5TestSupport.vint(0)
                + RAR5TestSupport.vint(1) + [0x78]),
            (0x06, RAR5TestSupport.vint(0)),
        ]

        for (type, payload) in records {
            let record = RAR5TestSupport.extraRecord(type: type, payload: payload)
            let archive = RAR5TestSupport.archive(blocks: [
                RAR5TestSupport.storedFile(
                    name: "duplicate-\(type).bin",
                    contents: Data(),
                    extra: record + record
                ),
            ])
            XCTAssertThrowsError(try ArchiveReader.open(data: archive), "type \(type)") {
                error in
                XCTAssertEqual(
                    error as? KaitoError,
                    .malformed("duplicate RAR5 file extra record type \(type)")
                )
            }
        }
    }

    private func makeSmallGeneratedChain(
        label: String
    ) throws -> (directory: URL, volumes: [URL]) {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-volume-\(label)")
        do {
            let source = temporary.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: false
            )
            let payload = RAR5TestSupport.deterministicPayload(
                count: 8 * 1_024,
                seed: 0x53_41_46_45_56_4f_4c
            )
            _ = try ZipTestSupport.write(payload, relativePath: "split.bin", below: source)
            try RAR5TestSupport.makeGeneratedArchive(
                sourceDirectory: source,
                paths: ["split.bin"],
                archiveURL: temporary.appendingPathComponent("chain.rar"),
                options: ["-m0", "-s-", "-v1k"]
            )
            let volumes = try FileManager.default.contentsOfDirectory(
                at: temporary,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("chain.part") && $0.pathExtension == "rar"
            }.sorted {
                (partNumber($0) ?? Int.max) < (partNumber($1) ?? Int.max)
            }
            guard volumes.count > 2 else {
                throw KaitoError.malformed("RAR did not generate enough test volumes")
            }
            return (temporary, volumes)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func partNumber(_ url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: ".part", options: .backwards) else {
            return nil
        }
        return Int(stem[range.upperBound...])
    }

    private func corruptFirstDataArea(_ archive: inout Data) throws {
        var bytes = [UInt8](archive)
        let dataRange = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: bytes).first(where: { !$0.data.isEmpty })?.data
        )
        bytes[dataRange.lowerBound] ^= 0x80
        archive = Data(bytes)
    }

    private func appendLittle(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

private final class RAR5VolumeByteSource: ByteSource {
    private let source: DataByteSource

    var length: UInt64 { source.length }

    init(_ data: Data) {
        source = DataByteSource(data: data)
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        try source.read(into: buffer, at: offset)
    }
}
