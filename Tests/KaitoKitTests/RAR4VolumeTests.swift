import Foundation
@testable import KaitoKit
import XCTest

final class RAR4VolumeTests: XCTestCase {
    private static let stem = "test_read_format_rar_multivolume"

    func testOldRarR00NumberingMergesSplitStoredEntry() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar4-old-volume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPayload = Data("old-numbered ".utf8)
        let secondPayload = Data("RAR4 volume".utf8)
        let complete = firstPayload + secondPayload
        let first = makeStoredVolume(
            payload: firstPayload,
            unpackedSize: complete.count,
            fileCRC: CRC32.checksum(firstPayload),
            mainFlags: 0x0001 | 0x0100,
            fileFlags: 0x0002,
            requestsNextVolume: true
        )
        let second = makeStoredVolume(
            payload: secondPayload,
            unpackedSize: complete.count,
            fileCRC: CRC32.checksum(complete),
            mainFlags: 0x0001,
            fileFlags: 0x0001,
            requestsNextVolume: false
        )
        let firstURL = directory.appendingPathComponent("legacy.rar")
        try first.write(to: firstURL)
        try second.write(to: directory.appendingPathComponent("legacy.r00"))

        let reader = try ArchiveReader.open(url: firstURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "joined.txt")
        XCTAssertEqual(entry.formatSpecific["volumeSegmentCount"], "2")
        XCTAssertEqual(try reader.read(entry), complete)
        XCTAssertEqual(try reader.reopen().read(entry), complete)
    }

    func testNewNumberingPreservesPartMarkerAndExtensionSpelling() throws {
        let directory = try ZipTestSupport.temporaryDirectory(
            label: "rar4-new-volume-case"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPayload = Data("mixed-case ".utf8)
        let secondPayload = Data("RAR4 volume name".utf8)
        let complete = firstPayload + secondPayload
        let first = makeStoredVolume(
            payload: firstPayload,
            unpackedSize: complete.count,
            fileCRC: CRC32.checksum(firstPayload),
            mainFlags: 0x0001 | 0x0010 | 0x0100,
            fileFlags: 0x0002,
            requestsNextVolume: true
        )
        let second = makeStoredVolume(
            payload: secondPayload,
            unpackedSize: complete.count,
            fileCRC: CRC32.checksum(complete),
            mainFlags: 0x0001 | 0x0010,
            fileFlags: 0x0001,
            requestsNextVolume: false
        )
        let firstURL = directory.appendingPathComponent("Mixed.PaRt0001.RAR")
        let secondURL = directory.appendingPathComponent("Mixed.PaRt0002.RAR")
        try first.write(to: firstURL)
        try second.write(to: secondURL)
        let locator = try RARVolumeLocator(
            firstVolumeURL: firstURL,
            naming: .rar4New
        )
        XCTAssertEqual(
            try locator.locate(volumeNumber: 1).url?.lastPathComponent,
            secondURL.lastPathComponent
        )

        let reader = try ArchiveReader.open(url: firstURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.formatSpecific["volumeSegmentCount"], "2")
        XCTAssertEqual(try reader.read(entry), complete)
        XCTAssertEqual(try reader.reopen().read(entry), complete)
    }

    func testRealNewNumberedVolumesAreMergedAndReopenRetainsSources() throws {
        guard let corpus = RAR4TestSupport.corpusDirectory else {
            throw XCTSkip("KAITOKIT_RAR4_CORPUS is not configured")
        }
        let first = corpus.appendingPathComponent("\(Self.stem).part0001.rar")
        guard FileManager.default.fileExists(atPath: first.path) else {
            throw XCTSkip("RAR4 multi-volume corpus is absent")
        }

        let reader = try ArchiveReader.open(url: first)
        XCTAssertEqual(reader.entries.count, 7)
        XCTAssertEqual(reader.entries[0].name, "ppmd_lzss_conversion_test.txt")
        XCTAssertEqual(reader.entries[0].compressedSize, 59_889 + 59_889 + 56_824)
        XCTAssertEqual(reader.entries[0].formatSpecific["volumeSegmentCount"], "3")
        XCTAssertEqual(reader.entries[0].formatSpecific["splitBefore"], "false")
        XCTAssertEqual(reader.entries[0].formatSpecific["splitAfter"], "false")
        XCTAssertEqual(reader.entries[1].formatSpecific["volumeSegmentCount"], "2")

        // This stored symlink body lives only in part 4. It proves that both the
        // original reader and its path-independent reopen retain later handles.
        let link = reader.entries[2]
        let expected = Data("LibarchiveAddingTest.html".utf8)
        XCTAssertEqual(try reader.read(link), expected)
        XCTAssertEqual(try reader.reopen().read(link), expected)
    }

    func testNonfinalPackedPartCRCIsCheckedBeforeDecoding() throws {
        guard let corpus = RAR4TestSupport.corpusDirectory else {
            throw XCTSkip("KAITOKIT_RAR4_CORPUS is not configured")
        }
        let original = corpus.appendingPathComponent("\(Self.stem).part0001.rar")
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw XCTSkip("RAR4 multi-volume corpus is absent")
        }
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar4-volume-crc")
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 1...4 {
            let name = String(format: "%@.part%04d.rar", Self.stem, number)
            try FileManager.default.copyItem(
                at: corpus.appendingPathComponent(name),
                to: directory.appendingPathComponent(name)
            )
        }

        let first = directory.appendingPathComponent("\(Self.stem).part0001.rar")
        var bytes = try Data(contentsOf: first)
        // Marker (7) + main header (13) + first file header (71).
        bytes[91] ^= 0x01
        try bytes.write(to: first)

        let reader = try ArchiveReader.open(url: first)
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testVolumeCountLimitStopsBeforeOpeningUnboundedContinuations() throws {
        guard let corpus = RAR4TestSupport.corpusDirectory else {
            throw XCTSkip("KAITOKIT_RAR4_CORPUS is not configured")
        }
        let first = corpus.appendingPathComponent("\(Self.stem).part0001.rar")
        guard FileManager.default.fileExists(atPath: first.path) else {
            throw XCTSkip("RAR4 multi-volume corpus is absent")
        }
        var limits = ReadLimits()
        limits.maxVolumeCount = 3
        XCTAssertThrowsError(
            try ArchiveReader.open(url: first, options: ReaderOptions(limits: limits))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .limitExceeded("RAR4 volume count"))
        }
    }

    func testAggregateMetadataLimitCountsCompletedEntriesAcrossVolumes() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar4-volume-metadata")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Data("kept".utf8)
        let firstPart = Data("split ".utf8)
        let lastPart = Data("entry".utf8)
        let joined = firstPart + lastPart
        let first = makeStoredVolume(
            files: [
                ("kept.txt", kept, kept.count, CRC32.checksum(kept), 0),
                ("joined.txt", firstPart, joined.count, CRC32.checksum(firstPart), 0x0002),
            ],
            mainFlags: 0x0001 | 0x0010 | 0x0100,
            requestsNextVolume: true
        )
        let second = makeStoredVolume(
            files: [
                ("joined.txt", lastPart, joined.count, CRC32.checksum(joined), 0x0001),
            ],
            mainFlags: 0x0001 | 0x0010,
            requestsNextVolume: false
        )
        let firstURL = directory.appendingPathComponent("metadata.part0001.rar")
        try first.write(to: firstURL)
        try second.write(to: directory.appendingPathComponent("metadata.part0002.rar"))

        let entries = try ArchiveReader.open(url: firstURL).entries
        XCTAssertEqual(entries.map(\.name), ["kept.txt", "joined.txt"])
        let exactCost = entries.reduce(UInt64(0)) { total, entry in
            total + 256 + UInt64(entry.rawName.bytes.count * 2) +
                entry.formatSpecific.reduce(UInt64(0)) { subtotal, field in
                    field.key == "nameSource"
                        ? subtotal
                        : subtotal + UInt64(field.key.utf8.count + field.value.utf8.count)
                }
        }

        var limits = ReadLimits()
        limits.maxTotalMetadataSize = exactCost
        XCTAssertEqual(
            try ArchiveReader.open(
                url: firstURL,
                options: ReaderOptions(limits: limits)
            ).entries.count,
            2
        )

        limits.maxTotalMetadataSize = exactCost - 1
        XCTAssertThrowsError(try ArchiveReader.open(
            url: firstURL,
            options: ReaderOptions(limits: limits)
        )) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("size \(exactCost) exceeds limit \(exactCost - 1)")
            )
        }
    }

    private func makeStoredVolume(
        payload: Data,
        unpackedSize: Int,
        fileCRC: UInt32,
        mainFlags: UInt16,
        fileFlags: UInt16,
        requestsNextVolume: Bool
    ) -> Data {
        makeStoredVolume(
            files: [("joined.txt", payload, unpackedSize, fileCRC, fileFlags)],
            mainFlags: mainFlags,
            requestsNextVolume: requestsNextVolume
        )
    }

    private func makeStoredVolume(
        files: [(String, Data, Int, UInt32, UInt16)],
        mainFlags: UInt16,
        requestsNextVolume: Bool
    ) -> Data {
        var archive = Data(RAR4Reader.signature)
        archive.append(contentsOf: makeHeader(
            type: 0x73,
            flags: mainFlags,
            fields: [0, 0, 0, 0, 0, 0]
        ))
        for (name, payload, unpackedSize, fileCRC, fileFlags) in files {
            var fields: [UInt8] = []
            appendLittle(UInt32(payload.count), to: &fields)
            appendLittle(UInt32(unpackedSize), to: &fields)
            fields.append(2)
            appendLittle(fileCRC, to: &fields)
            appendLittle(UInt32(0), to: &fields)
            fields.append(29)
            fields.append(0x30)
            appendLittle(UInt16(name.utf8.count), to: &fields)
            appendLittle(UInt32(0x20), to: &fields)
            fields.append(contentsOf: name.utf8)
            archive.append(contentsOf: makeHeader(
                type: 0x74,
                flags: fileFlags | 0x8000,
                fields: fields
            ))
            archive.append(payload)
        }
        archive.append(contentsOf: makeHeader(
            type: 0x7b,
            flags: requestsNextVolume ? 0x0001 : 0,
            fields: []
        ))
        return archive
    }

    private func makeHeader(type: UInt8, flags: UInt16, fields: [UInt8]) -> [UInt8] {
        var body = [type]
        appendLittle(flags, to: &body)
        appendLittle(UInt16(7 + fields.count), to: &body)
        body.append(contentsOf: fields)
        var header: [UInt8] = []
        appendLittle(UInt16(truncatingIfNeeded: CRC32.checksum(body)), to: &header)
        header.append(contentsOf: body)
        return header
    }

    private func appendLittle<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
}
