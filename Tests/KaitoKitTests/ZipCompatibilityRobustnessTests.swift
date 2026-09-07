import Foundation
@testable import KaitoKit
import XCTest

final class ZipCompatibilityRobustnessTests: XCTestCase {
    func testNewestEmptyArchiveAtEOFWinsBeyondStandardSearchWindow() throws {
        let older = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "older.bin",
                uncompressedData: Data(repeating: 0x4B, count: 70_000)
            ),
        ])
        let newer = try ZipTestSupport.makeArchive(entries: [])
        var concatenated = older
        concatenated.append(newer)

        XCTAssertGreaterThan(concatenated.count, 65_557)
        let reader = try ArchiveReader.open(data: concatenated)
        XCTAssertTrue(reader.entries.isEmpty)
    }

    func testMarkerlessZIP64EndLayoutsOpenAndRead() throws {
        let fixtures = [
            HandZipEntry(
                name: "bsdtar-zip64.txt",
                uncompressedData: Data("bsdtar zip:zip64 layout\n".utf8)
            ),
            HandZipEntry(
                rawName: Array("-".utf8),
                uncompressedData: Data("Info-ZIP stdin layout\n".utf8),
                hasDataDescriptor: true
            ),
        ]

        for fixture in fixtures {
            var archive = try ZipTestSupport.makeArchive(
                entries: [fixture],
                forceZIP64End: true
            )
            let layout = try ZipTestSupport.layout(of: archive)
            try replaceZIP64EndSentinelsWithZIP32Values(
                in: &archive,
                layout: layout,
                entryCount: 1
            )

            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(reader.entries.map(\.name), [String(decoding: fixture.rawName, as: UTF8.self)])
            XCTAssertEqual(try reader.read(reader.entries[0]), fixture.uncompressedData)
        }
    }

    func testZIP32EntryCommentBeginningWithLocatorSignatureIsNotZIP64() throws {
        let payload = Data("ordinary ZIP32 payload\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "page.txt", uncompressedData: payload),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let locatorShapedComment = Data([0x50, 0x4B, 0x06, 0x07])
            + Data(repeating: 0, count: 16)

        try ZipTestSupport.writeUInt16(
            UInt16(locatorShapedComment.count),
            to: &archive,
            at: layout.centralEntryOffsets[0] + 32
        )
        try ZipTestSupport.writeUInt32(
            UInt32(layout.centralDirectorySize + locatorShapedComment.count),
            to: &archive,
            at: layout.endRecordOffset + 12
        )
        archive.replaceSubrange(
            layout.endRecordOffset..<layout.endRecordOffset,
            with: locatorShapedComment
        )

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testZIP32LocatorShapedCommentFallsBackAfterZIP64ParseFailure() throws {
        let payload = Data(repeating: 0x41, count: 128)
        var archive = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "page.txt", uncompressedData: payload)],
            prefix: ZipTestSupport.makePEPrefix(count: 128, fill: 0x53)
        )
        let layout = try ZipTestSupport.layout(of: archive)
        let falseZIP64Size = 56
        let locatorSize = 20
        let insertedCommentSize = falseZIP64Size + locatorSize
        let finalDirectorySize = layout.centralDirectorySize + insertedCommentSize
        let relativeDirectoryOffset = layout.centralDirectoryOffset - layout.archiveBase
        let shiftedArchiveBase = layout.archiveBase - insertedCommentSize
        guard shiftedArchiveBase >= 0 else {
            throw ZipTestSupportError.fixture("SFX prefix is too short for shifted ZIP64 base")
        }

        // Make the last 76 bytes of the legal ZIP32 entry comment look like a
        // complete ZIP64 end record and locator. The false ZIP64 location is
        // internally consistent, but shifts the archive base so its selected
        // central directory fails to parse. The ZIP32 interpretation remains
        // coherent and must therefore be used as the fallback.
        var comment = Data([0x50, 0x4B, 0x06, 0x06])
        appendUInt64(44, to: &comment)
        appendUInt16(45, to: &comment)
        appendUInt16(45, to: &comment)
        appendUInt32(0, to: &comment)
        appendUInt32(0, to: &comment)
        appendUInt64(1, to: &comment)
        appendUInt64(1, to: &comment)
        appendUInt64(UInt64(finalDirectorySize), to: &comment)
        appendUInt64(UInt64(relativeDirectoryOffset), to: &comment)
        XCTAssertEqual(comment.count, falseZIP64Size)

        comment.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])
        appendUInt32(0, to: &comment)
        appendUInt64(
            UInt64(layout.endRecordOffset - shiftedArchiveBase),
            to: &comment
        )
        appendUInt32(1, to: &comment)
        XCTAssertEqual(comment.count, insertedCommentSize)

        try ZipTestSupport.writeUInt16(
            UInt16(insertedCommentSize),
            to: &archive,
            at: layout.centralEntryOffsets[0] + 32
        )
        try ZipTestSupport.writeUInt32(
            UInt32(finalDirectorySize),
            to: &archive,
            at: layout.endRecordOffset + 12
        )
        archive.replaceSubrange(
            layout.endRecordOffset..<layout.endRecordOffset,
            with: comment
        )

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(scanForSFXInData: true)
        )
        XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testIncoherentZIP64LocatorAndSentinelEOCDDoNotHideArchive() throws {
        let payload = Data("visible before false ZIP64 trailer\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])

        var trailer = Data(repeating: 0xA5, count: 56)
        trailer.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])
        appendUInt32(0, to: &trailer)
        appendUInt64(0, to: &trailer)
        appendUInt32(2, to: &trailer)
        trailer.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt32(UInt32.max, to: &trailer)
        appendUInt32(UInt32.max, to: &trailer)
        appendUInt16(0, to: &trailer)
        XCTAssertEqual(trailer.count, 98)
        archive.append(trailer)

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(
                    limits: ReadLimits(maxMetadataSize: 16)
                )
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected the older archive's limit, got \(error)")
            }
        }
    }

    func testImpossibleZIP64EntryCountDoesNotHideArchive() throws {
        let payload = Data("visible before impossible ZIP64 count\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])

        var trailer = Data([0x50, 0x4B, 0x06, 0x06])
        appendUInt64(44, to: &trailer)
        appendUInt16(45, to: &trailer)
        appendUInt16(45, to: &trailer)
        appendUInt32(0, to: &trailer)
        appendUInt32(0, to: &trailer)
        appendUInt64(UInt64.max, to: &trailer)
        appendUInt64(UInt64.max, to: &trailer)
        appendUInt64(0, to: &trailer)
        appendUInt64(0, to: &trailer)
        trailer.append(contentsOf: [0x50, 0x4B, 0x06, 0x07])
        appendUInt32(0, to: &trailer)
        appendUInt64(0, to: &trailer)
        appendUInt32(1, to: &trailer)
        trailer.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt16(UInt16.max, to: &trailer)
        appendUInt32(UInt32.max, to: &trailer)
        appendUInt32(UInt32.max, to: &trailer)
        appendUInt16(0, to: &trailer)
        XCTAssertEqual(trailer.count, 98)
        archive.append(trailer)

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testNewestCoherentZIP64SpannedCandidateIsNotMasked() throws {
        let older = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "older.txt"),
        ])
        for markerless in [false, true] {
            var newer = try ZipTestSupport.makeArchive(
                entries: [HandZipEntry(name: "newer.txt")],
                forceZIP64End: true
            )
            let newerLayout = try ZipTestSupport.layout(of: newer)
            if markerless {
                try replaceZIP64EndSentinelsWithZIP32Values(
                    in: &newer,
                    layout: newerLayout,
                    entryCount: 1
                )
            }
            let locatorOffset = try XCTUnwrap(newerLayout.zip64LocatorOffset)
            try ZipTestSupport.writeUInt32(2, to: &newer, at: locatorOffset + 16)
            var concatenated = older
            concatenated.append(newer)

            XCTAssertThrowsError(try ArchiveReader.open(data: concatenated)) { error in
                guard case KaitoError.unsupportedMethod("spanned") = error else {
                    return XCTFail(
                        "expected newest ZIP64 spanned error (markerless: "
                            + "\(markerless)), got \(error)"
                    )
                }
            }
        }
    }

    func testNewestCoherentZIP64EntryLimitIsNotMasked() throws {
        let older = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "older.txt"),
        ])
        let newer = try ZipTestSupport.makeArchive(
            entries: [
                HandZipEntry(name: "newer-1.txt"),
                HandZipEntry(name: "newer-2.txt"),
            ],
            forceZIP64End: true
        )
        var concatenated = older
        concatenated.append(newer)

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: concatenated,
                options: ReaderOptions(limits: ReadLimits(maxEntryCount: 1))
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected newest ZIP64 entry-count limit, got \(error)")
            }
        }
    }

    func testBSDTarZip64AndInfoZIPStdinFixturesOpenAndRead() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.bsdTarPath)
        try ZipTestSupport.requireExecutable(ZipTestSupport.infoZipPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "markerless-zip64-tools")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let bsdPayload = Data("real bsdtar zip:zip64 fixture\n".utf8)
        _ = try ZipTestSupport.write(bsdPayload, relativePath: "page.txt", below: source)
        let bsdArchive = temporary.appendingPathComponent("bsdtar-zip64.zip")
        _ = try ZipTestSupport.checkedRun(
            ZipTestSupport.bsdTarPath,
            arguments: [
                "--format", "zip", "--options", "zip:zip64",
                "-cf", bsdArchive.path, "-C", source.path, "page.txt",
            ]
        )
        try assertMarkerlessZIP64Layout(try Data(contentsOf: bsdArchive))
        let bsdReader = try ArchiveReader.open(url: bsdArchive)
        XCTAssertEqual(try bsdReader.read(bsdReader.entries[0]), bsdPayload)

        let stdinPayload = Data("real Info-ZIP stdin fixture\n".utf8)
        let stdinArchive = temporary.appendingPathComponent("infozip-stdin.zip")
        _ = try ZipTestSupport.checkedRun(
            ZipTestSupport.infoZipPath,
            arguments: ["-q", stdinArchive.path, "-"],
            standardInput: stdinPayload
        )
        try assertMarkerlessZIP64Layout(try Data(contentsOf: stdinArchive))
        let stdinReader = try ArchiveReader.open(url: stdinArchive)
        XCTAssertEqual(stdinReader.entries.map(\.name), ["-"])
        XCTAssertEqual(try stdinReader.read(stdinReader.entries[0]), stdinPayload)
    }

    func testBSDTarPipedZIPPaddingBlocksOpenAndRead() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.bsdTarPath)
        let temporary = try ZipTestSupport.temporaryDirectory(label: "bsdtar-stream-padding")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("real bsdtar streamed ZIP fixture\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "page.txt", below: source)

        for blockingFactor in [String?.none, "256"] {
            var arguments = ["--format", "zip"]
            if let blockingFactor {
                arguments.append(contentsOf: ["-b", blockingFactor])
            }
            arguments.append(contentsOf: ["-cf", "-", "-C", source.path, "page.txt"])
            let archive = try ZipTestSupport.checkedRun(
                ZipTestSupport.bsdTarPath,
                arguments: arguments
            ).standardOutput

            let expectedBlockSize = (Int(blockingFactor ?? "20") ?? 20) * 512
            XCTAssertEqual(archive.count % expectedBlockSize, 0)
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testEOCDTrailingDataWithinBoundIsAcceptedForSFXZIP() throws {
        let payload = Data("streamed bsdtar payload\n".utf8)
        let base = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "page.txt", uncompressedData: payload)],
            prefix: ZipTestSupport.makePEPrefix(count: 128)
        )

        let options = ReaderOptions(scanForSFXInData: true)

        for paddingCount in [1, 10_240, 65_535, 131_072] {
            var archive = base
            archive.append(Data(repeating: 0, count: paddingCount))
            XCTAssertEqual(
                try FormatDetector.detect(data: archive, options: options),
                .zip
            )
            let reader = try ArchiveReader.open(data: archive, options: options)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testEOCDSearchRemainsBoundedBeyondCompatibilityAllowance() throws {
        var archive = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "page.txt")],
            prefix: Data("unusual-sfx-prefix".utf8)
        )
        archive.append(Data(repeating: 0, count: 1_048_577))

        XCTAssertThrowsError(try FormatDetector.detect(data: archive))
        XCTAssertThrowsError(try ArchiveReader.open(data: archive))
    }

    func testEOCDSignatureInsideCommentDoesNotHideActualDirectory() throws {
        var falseEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        falseEndRecord.append(Data(repeating: 0, count: 18))
        var archive = try ZipTestSupport.makeArchive(
            entries: [
                HandZipEntry(
                    name: "visible.txt",
                    uncompressedData: Data("visible despite unusual comment\n".utf8)
                ),
            ],
            prefix: ZipTestSupport.makePEPrefix(count: 128),
            comment: falseEndRecord
        )
        archive.append(0)

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(scanForSFXInData: true)
        )
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(
            try reader.read(reader.entries[0]),
            Data("visible despite unusual comment\n".utf8)
        )
    }

    func testEOCDShapedSFXPrefixDoesNotHideLaterCoherentDirectory() throws {
        let payload = Data("visible after EOCD-shaped SFX prefix\n".utf8)
        let body = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])
        guard body.count <= Int(UInt16.max) else {
            throw ZipTestSupportError.fixture("SFX regression body exceeds EOCD comment field")
        }

        var prefix = Data([0x50, 0x4B, 0x05, 0x06])
        prefix.append(Data(repeating: 0, count: 16))
        appendUInt16(UInt16(body.count), to: &prefix)
        var archive = prefix
        archive.append(body)

        XCTAssertEqual(try FormatDetector.detect(data: archive), .zip)
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testEOCDShapedTrailingDataDoesNotHideCoherentDirectory() throws {
        let payload = Data("visible before false trailing record\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])

        // This is syntactically an EOCD, but its claimed one-record central
        // directory points into unrelated trailing bytes. Candidate selection
        // must retry the preceding coherent EOCD rather than hiding the ZIP.
        var falseEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        appendUInt16(0, to: &falseEndRecord) // disk
        appendUInt16(0, to: &falseEndRecord) // central-directory disk
        appendUInt16(1, to: &falseEndRecord) // entries on disk
        appendUInt16(1, to: &falseEndRecord) // total entries
        appendUInt32(46, to: &falseEndRecord) // central-directory size
        appendUInt32(0, to: &falseEndRecord) // relative offset
        appendUInt16(0, to: &falseEndRecord) // comment size
        archive.append(falseEndRecord)

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testEmptySpannedEOCDShapedTrailingDataDoesNotHideArchive() throws {
        let payload = Data("visible before false spanned EOCD\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])

        var falseEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        appendUInt16(1, to: &falseEndRecord)
        appendUInt16(1, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        appendUInt32(0, to: &falseEndRecord)
        appendUInt32(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        archive.append(falseEndRecord)

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testIncoherentLimitedEOCDShapedTrailingDataDoesNotHideArchive() throws {
        let payload = Data("visible before false limited EOCD\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])
        archive.append(Data(repeating: 0, count: 92))

        var falseEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        appendUInt16(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        appendUInt16(2, to: &falseEndRecord)
        appendUInt16(2, to: &falseEndRecord)
        appendUInt32(92, to: &falseEndRecord)
        appendUInt32(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        archive.append(falseEndRecord)

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: ReadLimits(maxEntryCount: 1))
        )
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testExpandedEOCDSearchDoesNotRechargeInitialCandidates() throws {
        let payload = Data("visible after expanded EOCD search\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])
        archive.append(Data(repeating: 0, count: 70_000))

        // This newest candidate makes the standard-window pass read the full
        // configured metadata allowance before failing. The expanded pass must
        // skip that already-attempted offset so the older real EOCD still has
        // budget to parse.
        var falseEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        appendUInt16(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        appendUInt16(1, to: &falseEndRecord)
        appendUInt16(1, to: &falseEndRecord)
        appendUInt32(65_536, to: &falseEndRecord)
        appendUInt32(0, to: &falseEndRecord)
        appendUInt16(0, to: &falseEndRecord)
        archive.append(falseEndRecord)

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(
                limits: ReadLimits(maxMetadataSize: 65_536)
            )
        )
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testNewestCoherentCandidateLimitIsNotMaskedByOlderArchive() throws {
        let older = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "older.txt"),
        ])
        let newer = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "newer-1.txt"),
            HandZipEntry(name: "newer-2.txt"),
        ])
        var concatenated = older
        concatenated.append(newer)

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: concatenated,
                options: ReaderOptions(limits: ReadLimits(maxEntryCount: 1))
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected newest archive's entry-count limit, got \(error)")
            }
        }
    }

    func testNewestUnsupportedCandidateIsNotMaskedByOlderArchive() throws {
        let older = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "older.txt"),
        ])
        var newer = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "newer.txt"),
        ])
        let newerLayout = try ZipTestSupport.layout(of: newer)
        try ZipTestSupport.writeUInt16(1, to: &newer, at: newerLayout.endRecordOffset + 4)
        try ZipTestSupport.writeUInt16(1, to: &newer, at: newerLayout.endRecordOffset + 6)
        var concatenated = older
        concatenated.append(newer)

        XCTAssertThrowsError(try ArchiveReader.open(data: concatenated)) { error in
            guard case KaitoError.unsupportedMethod("spanned") = error else {
                return XCTFail("expected newest archive's spanned error, got \(error)")
            }
        }
    }

    func testManyEOCDCandidatesHaveLinearBoundedOpenCost() throws {
        var emptyEndRecord = Data([0x50, 0x4B, 0x05, 0x06])
        emptyEndRecord.append(Data(repeating: 0, count: 18))
        let candidateCount = 20_000
        var archive = Data()
        archive.reserveCapacity(candidateCount * emptyEndRecord.count)
        for _ in 0..<candidateCount {
            archive.append(emptyEndRecord)
        }
        // Keep every candidate outside the standard 65,557-byte EOCD window
        // so this exercises the expanded compatibility scan as well.
        archive.append(Data(repeating: 0, count: 70_000))

        let start = Date()
        let reader = try ArchiveReader.open(data: archive)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(reader.entries.isEmpty)
        XCTAssertLessThan(
            elapsed,
            3,
            "EOCD candidate handling should remain linear within the bounded tail"
        )
    }

    func testCandidateDirectoryRetryWorkIsBounded() throws {
        let seed = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "seed.txt"),
        ])
        let layout = try ZipTestSupport.layout(of: seed)
        let centralDirectoryEnd = layout.centralDirectoryOffset
            + layout.centralDirectorySize
        var archive = seed.subdata(
            in: layout.centralDirectoryOffset..<centralDirectoryEnd
        )

        // The oldest candidate is a coherent one-entry central directory.
        // Every newer candidate claims the growing prefix as its directory,
        // forcing a full read and parse before the trailing EOCD bytes reveal
        // that candidate as malformed. Bound the cumulative retry work rather
        // than multiplying maxMetadataSize by the number of candidates.
        for _ in 0..<2_000 {
            try appendPrefixClaimingEndRecord(to: &archive)
        }

        let start = Date()
        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("ZIP end-record candidate metadata work")
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            3,
            "candidate retries should have a cumulative metadata-work bound"
        )
    }

    func testRetryableNonemptyCandidatesRecoverOlderCoherentDirectory() throws {
        let payload = Data("visible after false candidates\n".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "visible.txt", uncompressedData: payload),
        ])
        for _ in 0..<32 {
            try appendPrefixClaimingEndRecord(to: &archive)
        }

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testLocalExtraZeroPaddingIsAcceptedLazilyAndEagerly() throws {
        let payload = Data("zipalign-style padding\n".utf8)
        for paddingCount in 1...3 {
            let archive = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(
                    name: "aligned-\(paddingCount).txt",
                    uncompressedData: payload,
                    localExtra: Data(repeating: 0, count: paddingCount)
                ),
            ])

            let lazy = try ArchiveReader.open(data: archive)
            XCTAssertEqual(try lazy.read(lazy.entries[0]), payload)

            let eager = try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
            XCTAssertEqual(try eager.read(eager.entries[0]), payload)
        }
    }

    func testLocalExtraNonzeroShortTailIsRejectedLazilyAndEagerly() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "unaligned.txt",
                uncompressedData: Data("payload".utf8),
                localExtra: Data([0, 1, 0])
            ),
        ])

        let lazy = try ArchiveReader.open(data: archive)
        assertMalformed { try lazy.read(lazy.entries[0]) }
        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testUnusualPerEntryMetadataDegradesWithoutHidingOtherEntries() throws {
        let timestamp: UInt32 = 1_700_000_000
        var timestampWithTail = try ZipTestSupport.extendedTimestampExtra(seconds: timestamp)
        timestampWithTail.append(contentsOf: [0xAA, 0xBB, 0xCC])

        var malformedNTFSPayload = Data(repeating: 0, count: 4)
        appendUInt16(1, to: &malformedNTFSPayload)
        appendUInt16(24, to: &malformedNTFSPayload)
        malformedNTFSPayload.append(0)
        let malformedNTFS = try ZipTestSupport.extraField(
            identifier: 0x000A,
            payload: malformedNTFSPayload
        )

        var overrunTail = Data()
        appendUInt16(0xCAFE, to: &overrunTail)
        appendUInt16(20, to: &overrunTail)
        overrunTail.append(0x01)

        let invalidFlaggedUTF8 = [0x82, 0xA0] + Array(".txt".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                rawName: Array("extra-tail.txt".utf8),
                uncompressedData: Data("tail".utf8),
                centralExtra: timestampWithTail
            ),
            HandZipEntry(
                name: "ntfs.txt",
                uncompressedData: Data("ntfs".utf8),
                centralExtra: malformedNTFS
            ),
            HandZipEntry(name: "bad-second.txt", uncompressedData: Data("second".utf8)),
            HandZipEntry(name: "bad-month.txt", uncompressedData: Data("month".utf8)),
            HandZipEntry(
                rawName: invalidFlaggedUTF8,
                uncompressedData: Data("name".utf8),
                flags: 0x0800
            ),
            HandZipEntry(
                rawName: Array("overrun-tail.txt".utf8),
                uncompressedData: Data("overrun".utf8),
                centralExtra: overrunTail
            ),
            HandZipEntry(name: "healthy.txt", uncompressedData: Data("healthy".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: archive)

        let secondOffset = layout.centralEntryOffsets[2]
        let originalTime = try ZipTestSupport.readUInt16(archive, at: secondOffset + 12)
        try ZipTestSupport.writeUInt16(
            (originalTime & ~UInt16(0x001F)) | 30,
            to: &archive,
            at: secondOffset + 12
        )
        let monthOffset = layout.centralEntryOffsets[3]
        let originalDate = try ZipTestSupport.readUInt16(archive, at: monthOffset + 14)
        try ZipTestSupport.writeUInt16(
            originalDate & ~UInt16(0x01E0),
            to: &archive,
            at: monthOffset + 14
        )

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.count, 7)
        XCTAssertEqual(
            try XCTUnwrap(reader.entries[0].modificationDate).timeIntervalSince1970,
            TimeInterval(timestamp),
            accuracy: 0.001
        )
        XCTAssertNil(reader.entries[1].modificationDate)
        XCTAssertNil(reader.entries[2].modificationDate)
        XCTAssertNil(reader.entries[3].modificationDate)
        XCTAssertEqual(reader.entries[4].name, "あ.txt")
        XCTAssertEqual(reader.entries[4].rawName.declaredEncoding, .utf8)
        XCTAssertNotNil(reader.entries[5].modificationDate)
        XCTAssertEqual(reader.entries[6].name, "healthy.txt")

        let expectedPayloads = ["tail", "ntfs", "second", "month", "name", "overrun", "healthy"]
        for (entry, expected) in zip(reader.entries, expectedPayloads) {
            XCTAssertEqual(try reader.read(entry), Data(expected.utf8))
        }
    }

    func testAmbiguousLongNameZIPOpenHasBoundedCostAndKeepsMajority() throws {
        let ambiguousLongName = Array(
            repeating: [UInt8(0xA1), UInt8(0xA6)],
            count: 4_000
        ).flatMap { $0 }
        let ambiguousNames = Array(repeating: ambiguousLongName, count: 2_000)
        let archive = try ZipTestSupport.makeArchive(
            entries: ambiguousNames.map { HandZipEntry(rawName: $0) }
        )

        let start = Date()
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.count, ambiguousNames.count)
        XCTAssertTrue(reader.nameEncoding == .shiftJIS || reader.nameEncoding == .japaneseEUC)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            15,
            "16 MiB of ambiguous names should have bounded scoring cost"
        )

        let cp932 = Array(try XCTUnwrap(
            "表紙.txt".data(using: .shiftJIS, allowLossyConversion: false)
        ))
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: Array(repeating: cp932, count: 200) + [ambiguousLongName]
            ),
            .shiftJIS
        )
    }

    private func replaceZIP64EndSentinelsWithZIP32Values(
        in archive: inout Data,
        layout: ZipFixtureLayout,
        entryCount: UInt16
    ) throws {
        let relativeCentralOffset = layout.centralDirectoryOffset - layout.archiveBase
        guard relativeCentralOffset >= 0,
              relativeCentralOffset <= Int(UInt32.max),
              layout.centralDirectorySize <= Int(UInt32.max) else {
            throw ZipTestSupportError.fixture("markerless ZIP64 fixture exceeds ZIP32 fields")
        }
        try ZipTestSupport.writeUInt16(entryCount, to: &archive, at: layout.endRecordOffset + 8)
        try ZipTestSupport.writeUInt16(entryCount, to: &archive, at: layout.endRecordOffset + 10)
        try ZipTestSupport.writeUInt32(
            UInt32(layout.centralDirectorySize),
            to: &archive,
            at: layout.endRecordOffset + 12
        )
        try ZipTestSupport.writeUInt32(
            UInt32(relativeCentralOffset),
            to: &archive,
            at: layout.endRecordOffset + 16
        )
    }

    private func assertMarkerlessZIP64Layout(
        _ archive: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let endSignature = Data([0x50, 0x4B, 0x05, 0x06])
        let end = try XCTUnwrap(
            archive.range(of: endSignature, options: .backwards)?.lowerBound,
            file: file,
            line: line
        )
        XCTAssertNotEqual(try ZipTestSupport.readUInt16(archive, at: end + 10), UInt16.max)
        XCTAssertNotEqual(try ZipTestSupport.readUInt32(archive, at: end + 12), UInt32.max)
        XCTAssertNotEqual(try ZipTestSupport.readUInt32(archive, at: end + 16), UInt32.max)
        XCTAssertEqual(try ZipTestSupport.readUInt32(archive, at: end - 20), 0x0706_4B50)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        appendUInt32(UInt32(truncatingIfNeeded: value), to: &data)
        appendUInt32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
    }

    private func appendPrefixClaimingEndRecord(to archive: inout Data) throws {
        guard archive.count <= Int(UInt32.max) else {
            throw ZipTestSupportError.fixture("candidate directory exceeds ZIP32")
        }
        var endRecord = Data([0x50, 0x4B, 0x05, 0x06])
        appendUInt16(0, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        appendUInt16(1, to: &endRecord)
        appendUInt16(1, to: &endRecord)
        appendUInt32(UInt32(archive.count), to: &endRecord)
        appendUInt32(0, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        archive.append(endRecord)
    }

    private func assertMalformed(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Any
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)", file: file, line: line)
            }
        }
    }
}
