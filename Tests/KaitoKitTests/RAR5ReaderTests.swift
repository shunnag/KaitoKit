import Foundation
@testable import KaitoKit
import XCTest

final class RAR5ReaderTests: XCTestCase {
    func testGeneratedStoredJapaneseNamesDirectoriesAndEmptyFiles() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-stored")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let payload = Data("RAR5 UTF-8 日本語 payload\n".utf8)
        _ = try ZipTestSupport.write(
            payload,
            relativePath: "日本語/画像 01.txt",
            below: source
        )
        _ = try ZipTestSupport.write(Data(), relativePath: "empty.txt", below: source)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("空のディレクトリ", isDirectory: true),
            withIntermediateDirectories: false
        )

        let archive = temporary.appendingPathComponent("stored.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["日本語", "empty.txt", "空のディレクトリ"],
            archiveURL: archive,
            options: ["-m0", "-s-"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.format, .rar)
        XCTAssertNil(reader.nameEncoding)

        let japanese = try XCTUnwrap(
            reader.entries.first { $0.name == "日本語/画像 01.txt" }
        )
        XCTAssertEqual(japanese.rawName.declaredEncoding, .utf8)
        XCTAssertEqual(japanese.pathComponents, ["日本語", "画像 01.txt"])
        XCTAssertEqual(japanese.kind, .file)
        XCTAssertEqual(japanese.methodDescription, "RAR5 stored")
        XCTAssertEqual(japanese.solidGroup, -1)
        XCTAssertEqual(try reader.read(japanese), payload)

        let empty = try XCTUnwrap(reader.entries.first { $0.name == "empty.txt" })
        XCTAssertEqual(empty.kind, .file)
        XCTAssertEqual(empty.uncompressedSize, 0)
        XCTAssertEqual(try reader.read(empty), Data())

        let directory = try XCTUnwrap(
            reader.entries.first { $0.name == "空のディレクトリ" }
        )
        XCTAssertEqual(directory.kind, .directory)
        XCTAssertEqual(directory.uncompressedSize, 0)
        XCTAssertEqual(try reader.read(directory), Data())
    }

    func testGeneratedSymbolicAndHardLinksRetainSafeTargets() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-links")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("RAR5 linked payload\n".utf8)
        let originalURL = try ZipTestSupport.write(
            payload,
            relativePath: "original.txt",
            below: source
        )
        try FileManager.default.linkItem(
            at: originalURL,
            to: source.appendingPathComponent("hard.txt")
        )
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("symbolic.txt").path,
            withDestinationPath: "original.txt"
        )
        let archive = temporary.appendingPathComponent("links.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["original.txt", "hard.txt", "symbolic.txt"],
            archiveURL: archive,
            options: ["-m0", "-s-", "-oh", "-ol"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let original = try XCTUnwrap(reader.entries.first { $0.name == "original.txt" })
        let hard = try XCTUnwrap(reader.entries.first { $0.name == "hard.txt" })
        let symbolic = try XCTUnwrap(reader.entries.first { $0.name == "symbolic.txt" })
        XCTAssertEqual(hard.kind, .hardlink)
        XCTAssertEqual(hard.uncompressedSize, 0)
        XCTAssertEqual(hard.compressedSize, 0)
        XCTAssertEqual(hard.formatSpecific["linkPath"], "original.txt")
        XCTAssertEqual(hard.formatSpecific["hardLinkTargetIndex"], String(original.index))
        XCTAssertEqual(try reader.read(hard), Data())
        XCTAssertEqual(symbolic.kind, .symlink)
        XCTAssertEqual(symbolic.formatSpecific["linkPath"], "original.txt")

        let unmaterializedOutput = temporary.appendingPathComponent(
            "unmaterialized-output",
            isDirectory: true
        )
        XCTAssertThrowsError(try reader.extract(hard, to: unmaterializedOutput)) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("target was not materialized"), reason)
        }

        // The first extraction creates this `/private/tmp` root. Its
        // standardized path changes once it exists on Darwin, but the
        // subsequent hard link must retain the first entry's provenance.
        let output = URL(
            fileURLWithPath: "/private/tmp/KaitoKitTests-\(UUID().uuidString)/output",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let extractedOriginal = try reader.extract(original, to: output)
        let extractedHard = try reader.extract(hard, to: output)
        let extractedSymbolic = try reader.extract(symbolic, to: output)
        XCTAssertEqual(try Data(contentsOf: extractedOriginal), payload)
        XCTAssertEqual(try Data(contentsOf: extractedHard), payload)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: extractedOriginal.path)
        let hardAttributes = try FileManager.default.attributesOfItem(atPath: extractedHard.path)
        XCTAssertEqual(
            originalAttributes[.systemFileNumber] as? NSNumber,
            hardAttributes[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: extractedSymbolic.path),
            "original.txt"
        )
    }

    func testHardLinkExtractionKeepsProvenanceForUncreatedRelativeRootBelowTmp() throws {
        let payload = Data("RAR5 hard-link root spelling payload".utf8)
        let target = "original.txt"
        let redirection = RAR5TestSupport.vint(4)
            + RAR5TestSupport.vint(0)
            + RAR5TestSupport.vint(UInt64(target.utf8.count))
            + Array(target.utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: target,
                contents: payload,
                attributes: 0o100644
            ),
            RAR5TestSupport.storedFile(
                name: "alias.txt",
                contents: Data(),
                unpackedSize: UInt64(payload.count),
                dataCRC32: CRC32.checksum(payload),
                attributes: 0o100644,
                extra: RAR5TestSupport.extraRecord(type: 0x05, payload: redirection)
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .hardlink])

        func assertHardLinkExtraction(to root: URL) throws {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            let original = try reader.extract(reader.entries[0], to: root)
            let alias = try reader.extract(reader.entries[1], to: root)
            XCTAssertEqual(try Data(contentsOf: alias), payload)
            let originalAttributes = try FileManager.default.attributesOfItem(
                atPath: original.path
            )
            let aliasAttributes = try FileManager.default.attributesOfItem(
                atPath: alias.path
            )
            XCTAssertEqual(
                originalAttributes[.systemFileNumber] as? NSNumber,
                aliasAttributes[.systemFileNumber] as? NSNumber
            )
        }

        let manager = FileManager.default
        let originalWorkingDirectory = manager.currentDirectoryPath
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/KaitoKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        guard manager.changeCurrentDirectoryPath(workingDirectory.path) else {
            return XCTFail("could not enter the temporary working directory")
        }
        defer {
            _ = manager.changeCurrentDirectoryPath(originalWorkingDirectory)
            try? manager.removeItem(at: workingDirectory)
        }
        try assertHardLinkExtraction(
            to: URL(fileURLWithPath: "relative-output", isDirectory: true)
        )
    }

    func testGeneratedSolidHardLinkDoesNotInterruptLaterCompressedMember() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-solid-hard-link")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let shared = Data(String(repeating: "solid hard-link history 日本語\n", count: 2_048).utf8)
        let firstPayload = shared
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x48_4c_31)
        let finalPayload = shared
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x48_4c_32)
        let original = try ZipTestSupport.write(
            firstPayload,
            relativePath: "original.bin",
            below: source
        )
        try FileManager.default.linkItem(
            at: original,
            to: source.appendingPathComponent("hard.bin")
        )
        _ = try ZipTestSupport.write(
            finalPayload,
            relativePath: "after.bin",
            below: source
        )

        let archive = temporary.appendingPathComponent("solid-hard-link.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["original.bin", "hard.bin", "after.bin"],
            archiveURL: archive,
            options: ["-m5", "-s", "-ds", "-oh", "-md1m"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, 0])
        XCTAssertEqual(reader.entries[1].kind, .hardlink)
        XCTAssertEqual(try reader.read(reader.entries[1]), Data())
        XCTAssertEqual(try reader.read(reader.entries[2]), finalPayload)
        XCTAssertEqual(try reader.read(reader.entries[0]), firstPayload)

        let output = temporary.appendingPathComponent("solid-output", isDirectory: true)
        for entry in reader.entries {
            _ = try reader.extract(entry, to: output)
        }
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("after.bin")),
            finalPayload
        )
    }

    func testGeneratedSolidFileReferenceDoesNotInterruptLaterCompressedMember() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-solid-file-reference")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let shared = Data(String(repeating: "solid file-reference history 日本語\n", count: 2_048).utf8)
        let repeatedPayload = shared
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x46_52_31)
        let finalPayload = shared
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x46_52_32)
        _ = try ZipTestSupport.write(
            repeatedPayload,
            relativePath: "original.bin",
            below: source
        )
        _ = try ZipTestSupport.write(
            repeatedPayload,
            relativePath: "reference.bin",
            below: source
        )
        _ = try ZipTestSupport.write(
            finalPayload,
            relativePath: "after.bin",
            below: source
        )

        let archive = temporary.appendingPathComponent("solid-file-reference.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["original.bin", "reference.bin", "after.bin"],
            archiveURL: archive,
            options: ["-m5", "-s", "-ds", "-oi", "-md1m"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, 0])
        XCTAssertEqual(reader.entries[1].kind, .other)
        XCTAssertEqual(reader.entries[1].formatSpecific["redirectionType"], "5")
        XCTAssertEqual(try reader.read(reader.entries[1]), Data())
        XCTAssertEqual(try reader.read(reader.entries[2]), finalPayload)
        XCTAssertEqual(try reader.read(reader.entries[0]), repeatedPayload)
    }

    func testGeneratedMaximumCompressionRoundTrips() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-compressed")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let payload = Data(String(repeating: "RAR5 compressed smoke 日本語\n", count: 1_024).utf8)
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x52_41_52_35)
        _ = try ZipTestSupport.write(payload, relativePath: "compressed.bin", below: source)
        let archive = temporary.appendingPathComponent("compressed.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["compressed.bin"],
            archiveURL: archive,
            options: ["-m5", "-s-", "-md1m"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "compressed.bin")
        XCTAssertEqual(entry.formatSpecific["method"], "5")
        // The field stores the minimum dictionary needed by this stream, not
        // necessarily the encoder's configured maximum.
        XCTAssertEqual(entry.formatSpecific["dictionarySize"], String(128 * 1_024))
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testGeneratedQuickOpenServiceDataIsSkippedConsistently() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-quick-open")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(count: 64 * 1_024, seed: 0x51_4f)
        _ = try ZipTestSupport.write(payload, relativePath: "quick-open.bin", below: source)
        let archive = temporary.appendingPathComponent("quick-open.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["quick-open.bin"],
            archiveURL: archive,
            options: ["-m0", "-qo+"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["quick-open.bin"])
        XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), payload)
    }

    func testGeneratedSolidGroupSupportsForwardBackwardRandomAndOverlappingAccess() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-solid")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let names = ["first.txt", "second.txt", "third.txt"]
        var payloads: [Data] = []
        for (index, name) in names.enumerated() {
            let shared = Data(String(repeating: "solid shared history 日本語\n", count: 768).utf8)
            let payload = shared
                + Data(String(repeating: "entry \(index) boundary\n", count: 257).utf8)
                + shared
            payloads.append(payload)
            _ = try ZipTestSupport.write(payload, relativePath: name, below: source)
        }
        let archive = temporary.appendingPathComponent("solid.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: archive,
            options: ["-m5", "-s", "-md1m", "-htb"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.name), names)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0, 0])
        XCTAssertEqual(reader.entries.first?.formatSpecific["solid"], "false")
        XCTAssertEqual(reader.entries.dropFirst().map { $0.formatSpecific["solid"] }, ["true", "true"])
        XCTAssertTrue(reader.entries.allSatisfy {
            $0.formatSpecific["hashType"] == "BLAKE2sp"
        })

        // A direct request for the final member drains and verifies both
        // predecessors before exposing its bytes.
        XCTAssertEqual(try reader.read(reader.entries[2]), payloads[2])
        // Moving backward restarts at the group leader.
        XCTAssertEqual(try reader.read(reader.entries[0]), payloads[0])
        for index in [1, 2, 0, 2, 1, 0] {
            XCTAssertEqual(try reader.read(reader.entries[index]), payloads[index])
        }

        // Starting a newer range invalidates an overlapping handle, while the
        // coordinator privately drains its remainder to retain forward state.
        let overlapping = try ArchiveReader.open(url: archive)
        let abandoned = try overlapping.stream(overlapping.entries[0])
        var prefix = Data(count: 31)
        let prefixCount = try prefix.withUnsafeMutableBytes { try abandoned.read(into: $0) }
        XCTAssertEqual(prefixCount, prefix.count)
        XCTAssertEqual(try overlapping.read(overlapping.entries[2]), payloads[2])
        var byte: UInt8 = 0
        XCTAssertThrowsError(
            try withUnsafeMutableBytes(of: &byte) { try abandoned.read(into: $0) }
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("invalidated this stream"), reason)
        }

        // Reopen owns an independent coordinator: advancing it neither
        // invalidates nor mutates an in-flight range on the original reader.
        let independent = try ArchiveReader.open(url: archive)
        let originalStream = try independent.stream(independent.entries[0])
        var originalPrefix = Data(count: 17)
        _ = try originalPrefix.withUnsafeMutableBytes { try originalStream.read(into: $0) }
        let reopened = try independent.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[2]), payloads[2])
        originalPrefix.append(try originalStream.readAll())
        XCTAssertEqual(originalPrefix, payloads[0])

        let output = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        for index in names.indices {
            let url = try reader.extract(reader.entries[index], to: output)
            XCTAssertEqual(try Data(contentsOf: url), payloads[index])
        }

        // Seeking directly to a later member must not bypass integrity for a
        // predecessor whose decoder state it consumes.
        var corrupted = [UInt8](try Data(contentsOf: archive))
        let firstLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: corrupted).first { !$0.data.isEmpty }
        )
        let firstDigest = [UInt8](Blake2sp.checksum(payloads[0]))
        let digestOffset = try XCTUnwrap(firstLayout.body.indices.first { offset in
            offset <= firstLayout.body.upperBound - firstDigest.count
                && Array(corrupted[offset..<(offset + firstDigest.count)]) == firstDigest
        })
        corrupted[digestOffset] ^= 1
        RAR5TestSupport.repairHeaderCRC(&corrupted, layout: firstLayout)
        let corruptedReader = try ArchiveReader.open(data: Data(corrupted))
        XCTAssertThrowsError(try corruptedReader.read(corruptedReader.entries[2])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }

        let crcArchive = temporary.appendingPathComponent("solid-crc.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: crcArchive,
            options: ["-m5", "-s", "-md1m", "-htc"]
        )
        let crcReader = try ArchiveReader.open(url: crcArchive)
        XCTAssertNotNil(crcReader.entries[0].crc32)
        XCTAssertEqual(try crcReader.read(crcReader.entries[2]), payloads[2])

        var crcCorrupted = [UInt8](try Data(contentsOf: crcArchive))
        let crcLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: crcCorrupted).first { !$0.data.isEmpty }
        )
        let crc = CRC32.checksum(payloads[0])
        let crcBytes = (0..<4).map {
            UInt8(truncatingIfNeeded: crc >> UInt32($0 * 8))
        }
        let crcOffset = try XCTUnwrap(crcLayout.body.indices.first { offset in
            offset <= crcLayout.body.upperBound - crcBytes.count
                && Array(crcCorrupted[offset..<(offset + crcBytes.count)]) == crcBytes
        })
        crcCorrupted[crcOffset] ^= 1
        RAR5TestSupport.repairHeaderCRC(&crcCorrupted, layout: crcLayout)
        let badCRCReader = try ArchiveReader.open(data: Data(crcCorrupted))
        XCTAssertThrowsError(try badCRCReader.read(badCRCReader.entries[2])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }

        var limited = ReadLimits()
        limited.maxDictionarySize = 64 * 1_024
        let limitedReader = try ArchiveReader.open(
            url: crcArchive,
            options: ReaderOptions(limits: limited)
        )
        XCTAssertThrowsError(try limitedReader.stream(limitedReader.entries[2])) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testGeneratedSolidGroupAllowsStoredMembersDictionaryDecreaseAndEmptyLeader() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-solid-edges")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        // A stored member does not mutate the LZ history. The final compressed
        // member can therefore refer through it to the first member.
        let shared = RAR5TestSupport.deterministicPayload(
            count: 512 * 1_024,
            seed: 0x53_54_4f_52_45
        )
        let stored = RAR5TestSupport.deterministicPayload(
            count: 256 * 1_024,
            seed: 0x4d_49_44_44_4c_45
        )
        _ = try ZipTestSupport.write(shared, relativePath: "a.bin", below: source)
        _ = try ZipTestSupport.write(stored, relativePath: "b.jpg", below: source)
        _ = try ZipTestSupport.write(shared, relativePath: "c.bin", below: source)
        let mixedArchive = temporary.appendingPathComponent("mixed.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["a.bin"],
            archiveURL: mixedArchive,
            options: ["-m5", "-s", "-md1m"]
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["b.jpg"],
            archiveURL: mixedArchive,
            options: ["-m0", "-s"]
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["c.bin"],
            archiveURL: mixedArchive,
            options: ["-m5", "-s", "-md1m"]
        )
        let mixedReader = try ArchiveReader.open(url: mixedArchive)
        XCTAssertEqual(mixedReader.entries.map(\.solidGroup), [0, 0, 0])
        XCTAssertEqual(
            mixedReader.entries.map { $0.formatSpecific["method"] },
            ["5", "0", "5"]
        )
        XCTAssertEqual(try mixedReader.read(mixedReader.entries[2]), shared)
        XCTAssertEqual(try mixedReader.read(mixedReader.entries[1]), stored)
        XCTAssertEqual(try mixedReader.read(mixedReader.entries[0]), shared)

        // Compression info is a member-specific minimum, so it may decrease
        // inside one group; the coordinator allocates the group's maximum.
        let repeated = Data(repeating: 0x5a, count: 512 * 1_024)
        _ = try ZipTestSupport.write(repeated, relativePath: "d.bin", below: source)
        _ = try ZipTestSupport.write(repeated, relativePath: "e.bin", below: source)
        let dictionaryArchive = temporary.appendingPathComponent("dictionary-change.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["d.bin"],
            archiveURL: dictionaryArchive,
            options: ["-m5", "-s", "-md1m"]
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["e.bin"],
            archiveURL: dictionaryArchive,
            options: ["-m5", "-s", "-md512k"]
        )
        let dictionaryReader = try ArchiveReader.open(url: dictionaryArchive)
        XCTAssertEqual(dictionaryReader.entries.map(\.solidGroup), [0, 0])
        XCTAssertEqual(try dictionaryReader.read(dictionaryReader.entries[1]), repeated)

        // RAR emits a table-only compressed block for an empty group leader.
        // It remains valid when its declared unpacked size is marked unknown.
        _ = try ZipTestSupport.write(Data(), relativePath: "empty.bin", below: source)
        _ = try ZipTestSupport.write(repeated, relativePath: "after-empty.bin", below: source)
        let emptyArchive = temporary.appendingPathComponent("empty-leader.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["empty.bin"],
            archiveURL: emptyArchive,
            options: ["-m5", "-s", "-md1m"]
        )
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["after-empty.bin"],
            archiveURL: emptyArchive,
            options: ["-m5", "-s", "-md1m"]
        )
        let emptyReader = try ArchiveReader.open(url: emptyArchive)
        XCTAssertEqual(try emptyReader.read(emptyReader.entries[0]), Data())
        XCTAssertEqual(try emptyReader.read(emptyReader.entries[1]), repeated)

        var unknownBytes = [UInt8](try Data(contentsOf: emptyArchive))
        let emptyLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: unknownBytes).first { !$0.data.isEmpty }
        )
        try RAR5TestSupport.markFileUnpackedSizeUnknown(
            &unknownBytes,
            layout: emptyLayout
        )
        let unknownReader = try ArchiveReader.open(data: Data(unknownBytes))
        XCTAssertNil(unknownReader.entries[0].uncompressedSize)
        XCTAssertEqual(try unknownReader.read(unknownReader.entries[0]), Data())
        XCTAssertEqual(try unknownReader.read(unknownReader.entries[1]), repeated)
    }

    func testGeneratedEncryptedSolidGroupSupportsPasswordChangesAndRandomAccess() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-solid-encrypted")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let names = ["first.txt", "second.txt", "third.txt"]
        var payloads: [Data] = []
        for (index, name) in names.enumerated() {
            let payload = Data(
                String(repeating: "encrypted solid shared history 日本語\n", count: 512).utf8
            ) + Data(String(repeating: "member \(index)\n", count: 193).utf8)
            payloads.append(payload)
            _ = try ZipTestSupport.write(
                payload,
                relativePath: name,
                below: source
            )
        }
        let archive = temporary.appendingPathComponent("solid-encrypted.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: archive,
            options: ["-m5", "-s", "-md1m", "-psecret", "-htb"]
        )

        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0, 0])
        XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
        XCTAssertTrue(reader.entries.allSatisfy {
            $0.formatSpecific["hashType"] == "BLAKE2sp"
        })

        reader.password = "wrong"
        XCTAssertThrowsError(try reader.read(reader.entries[2])) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        reader.password = "secret"
        for index in [2, 0, 1, 2, 1, 0] {
            XCTAssertEqual(try reader.read(reader.entries[index]), payloads[index])
        }
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[2]), payloads[2])

        // Changing credentials invalidates every live range before releasing
        // the reader's coordinator reference. Retaining old handles across
        // repeated changes must neither expose old-password state nor keep a
        // usable solid dictionary alive.
        for iteration in 0..<4 {
            let stale = try reader.stream(reader.entries[0])
            var firstByte: UInt8 = 0
            XCTAssertEqual(
                try withUnsafeMutableBytes(of: &firstByte) { try stale.read(into: $0) },
                1
            )
            reader.password = "wrong-\(iteration)"
            XCTAssertThrowsError(try reader.stream(reader.entries[0])) { error in
                XCTAssertEqual(error as? KaitoError, .wrongPassword)
            }
            XCTAssertThrowsError(
                try withUnsafeMutableBytes(of: &firstByte) { try stale.read(into: $0) }
            ) { error in
                guard case let .malformed(reason) = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertTrue(reason.contains("invalidated this stream"), reason)
            }
            reader.password = "secret"
        }

        // Removing every advisory verifier forces a wrong password through the
        // compressed decoder, including predecessors drained while seeking to
        // the final solid member. Structural decoder failures remain a password
        // error until some independent check has authenticated the password.
        var noCheckSolid = [UInt8](try Data(contentsOf: archive))
        let encryptedLayouts = try RAR5TestSupport.blockLayouts(in: noCheckSolid)
            .filter { !$0.data.isEmpty }
        for layout in encryptedLayouts.reversed() {
            try RAR5TestSupport.removeFileEncryptionCheck(
                &noCheckSolid,
                layout: layout
            )
        }
        let noCheckSolidReader = try ArchiveReader.open(
            data: Data(noCheckSolid),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(
            try noCheckSolidReader.read(noCheckSolidReader.entries[2]),
            payloads[2]
        )
        let wrongNoCheckSolidReader = try ArchiveReader.open(
            data: Data(noCheckSolid),
            options: ReaderOptions(password: "wrong")
        )
        XCTAssertThrowsError(
            try wrongNoCheckSolidReader.read(wrongNoCheckSolidReader.entries[2])
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        // `-p` exposes headers, so rar uses password-dependent (tweaked)
        // checksums. Exercise the CRC HashMAC path as well as BLAKE2sp above.
        let crcArchive = temporary.appendingPathComponent("solid-encrypted-crc.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: crcArchive,
            options: ["-m5", "-s", "-md1m", "-psecret", "-htc"]
        )
        let crcReader = try ArchiveReader.open(
            url: crcArchive,
            options: ReaderOptions(password: "secret")
        )
        XCTAssertTrue(crcReader.entries.allSatisfy { $0.crc32 != nil })
        XCTAssertEqual(try crcReader.read(crcReader.entries[2]), payloads[2])
    }

    func testGeneratedSplitEntryFromDataReportsMultiVolumeRequirement() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-volume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(count: 8 * 1_024, seed: 0x56_4f_4c)
        _ = try ZipTestSupport.write(payload, relativePath: "split.bin", below: source)
        let requestedArchive = temporary.appendingPathComponent("volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["split.bin"],
            archiveURL: requestedArchive,
            options: ["-m0", "-v1k"]
        )

        let volumes = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("volume.part") && $0.pathExtension == "rar" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let firstVolume = try XCTUnwrap(volumes.first)
        XCTAssertGreaterThan(volumes.count, 1)
        let reader = try ArchiveReader.open(data: Data(contentsOf: firstVolume))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.formatSpecific["splitAfter"], "true")
        XCTAssertThrowsError(try reader.read(entry)) { error in
            guard case let .unsupportedMethod(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "multi-volume from Data")
        }
    }

    func testGeneratedDictionaryAboveFourMiBHonorsConfiguredLimit() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-dictionary")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let distantMatch = RAR5TestSupport.deterministicPayload(
            count: 256 * 1_024,
            seed: 0x64_69_63_74
        )
        let payload = distantMatch
            + RAR5TestSupport.deterministicPayload(count: 5 * 1_024 * 1_024, seed: 0x67_61_70)
            + distantMatch
        _ = try ZipTestSupport.write(payload, relativePath: "dictionary.txt", below: source)
        let archive = temporary.appendingPathComponent("dictionary.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["dictionary.txt"],
            archiveURL: archive,
            options: ["-m5", "-s-", "-md64m"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        let dictionaryText = try XCTUnwrap(entry.formatSpecific["dictionarySize"])
        let dictionarySize = try XCTUnwrap(UInt64(dictionaryText))
        XCTAssertGreaterThan(dictionarySize, 4 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(dictionarySize, 64 * 1_024 * 1_024)
        XCTAssertEqual(try reader.read(entry), payload)

        var limits = ReadLimits()
        limits.maxDictionarySize = 4 * 1_024 * 1_024
        let limitedReader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(limits: limits)
        )
        let limitedEntry = try XCTUnwrap(limitedReader.entries.first)
        XCTAssertThrowsError(try limitedReader.stream(limitedEntry)) { error in
            guard case let .limitExceeded(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("exceeds limit"), reason)
        }
    }

    func testGeneratedEncryptedStoredBlake2ArchiveChecksPasswordAndPayload() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-encrypted-blake")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(String(repeating: "encrypted BLAKE2sp 日本語\n", count: 128).utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "secret.txt", below: source)
        let archive = temporary.appendingPathComponent("encrypted.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["secret.txt"],
            archiveURL: archive,
            options: ["-m0", "-s-", "-psecret", "-htb"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertEqual(entry.formatSpecific["encryption"], "RAR5 AES-256")
        XCTAssertEqual(entry.formatSpecific["hashType"], "BLAKE2sp")
        XCTAssertEqual(entry.formatSpecific["hash"]?.count, 64)

        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        reader.password = "wrong"
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        reader.password = "secret"
        XCTAssertEqual(try reader.read(entry), payload)

        // The verifier's final four bytes checksum its first eight. Damage to
        // that self-check makes the field unusable, so payload integrity must
        // be the fallback password verifier.
        var damagedCheck = [UInt8](try Data(contentsOf: archive))
        let encryptedLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: damagedCheck).first { !$0.data.isEmpty }
        )
        let checkRange = try XCTUnwrap(
            RAR5TestSupport.fileEncryptionCheckRange(
                in: damagedCheck,
                layout: encryptedLayout
            )
        )
        damagedCheck[checkRange.lowerBound] ^= 1
        RAR5TestSupport.repairHeaderCRC(&damagedCheck, layout: encryptedLayout)
        let fallbackReader = try ArchiveReader.open(
            data: Data(damagedCheck),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(
            try fallbackReader.read(try XCTUnwrap(fallbackReader.entries.first)),
            payload
        )
        let wrongFallbackReader = try ArchiveReader.open(
            data: Data(damagedCheck),
            options: ReaderOptions(password: "wrong")
        )
        XCTAssertThrowsError(
            try wrongFallbackReader.read(try XCTUnwrap(wrongFallbackReader.entries.first))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        var corrupted = [UInt8](try Data(contentsOf: archive))
        let layouts = try RAR5TestSupport.blockLayouts(in: corrupted)
        let payloadLayout = try XCTUnwrap(layouts.first { !$0.data.isEmpty })
        corrupted[payloadLayout.data.lowerBound] ^= 0x01
        let corruptedReader = try ArchiveReader.open(
            data: Data(corrupted),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertThrowsError(
            try corruptedReader.read(try XCTUnwrap(corruptedReader.entries.first))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }

        let limitedKDFReader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(maxRAR5KDFCountPower: 0)
        )
        let limitedKDFEntry = try XCTUnwrap(limitedKDFReader.entries.first)
        XCTAssertThrowsError(try limitedKDFReader.stream(limitedKDFEntry)) { error in
            guard case let .unsupportedMethod(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("KDF count"), reason)
        }
    }

    func testGeneratedEncryptedStoredCRCChecksPasswordAndPayload() throws {
        XCTAssertEqual(
            ReaderOptions(maxRAR5KDFCountPower: .max).maxRAR5KDFCountPower,
            24
        )
        var raised = ReaderOptions()
        raised.maxRAR5KDFCountPower = .max
        XCTAssertEqual(raised.maxRAR5KDFCountPower, 24)
        raised.maxSevenZipAESCyclesPower = .max
        XCTAssertEqual(raised.maxSevenZipAESCyclesPower, 62)
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-encrypted-crc")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(String(repeating: "encrypted CRC32 \u{65e5}\u{672c}\u{8a9e}\n", count: 128).utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "secret-crc.txt", below: source)
        let archive = temporary.appendingPathComponent("encrypted-crc.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["secret-crc.txt"],
            archiveURL: archive,
            options: ["-m0", "-s-", "-psecret", "-htc"]
        )

        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertNotNil(entry.crc32)
        XCTAssertNil(entry.formatSpecific["hashType"])

        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        reader.password = "wrong"
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        reader.password = "secret"
        XCTAssertEqual(try reader.read(entry), payload)

        var corrupted = [UInt8](try Data(contentsOf: archive))
        let payloadLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: corrupted).first { !$0.data.isEmpty }
        )
        corrupted[payloadLayout.data.lowerBound] ^= 0x01
        let corruptedReader = try ArchiveReader.open(
            data: Data(corrupted),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertThrowsError(
            try corruptedReader.read(try XCTUnwrap(corruptedReader.entries.first))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testGeneratedEncryptedCompressedBlake2ArchiveRoundTrips() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-encrypted-m5")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(String(repeating: "encrypted compressed 日本語\n", count: 2_048).utf8)
            + RAR5TestSupport.deterministicPayload(count: 16_385, seed: 0x45_4e_43_4d_35)
        _ = try ZipTestSupport.write(payload, relativePath: "secret-m5.bin", below: source)
        let archive = temporary.appendingPathComponent("encrypted-m5.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["secret-m5.bin"],
            archiveURL: archive,
            options: ["-m5", "-s-", "-md1m", "-psecret", "-htb"]
        )

        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "secret")
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertEqual(entry.formatSpecific["method"], "5")
        XCTAssertEqual(entry.formatSpecific["hashType"], "BLAKE2sp")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testCompressedEncryptionWithoutValidCheckNormalizesPasswordErrors() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(
            label: "rar5-encrypted-m5-no-check"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let repeated = Data(
            String(repeating: "ambiguous compressed password 日本語\n", count: 2_048).utf8
        )
        let payload = repeated
            + RAR5TestSupport.deterministicPayload(count: 16_391, seed: 0x4e_4f_43_48_45_43_4b)
            + repeated
        _ = try ZipTestSupport.write(payload, relativePath: "secret.bin", below: source)
        let archiveURL = temporary.appendingPathComponent("secret.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["secret.bin"],
            archiveURL: archiveURL,
            options: ["-m5", "-s-", "-md1m", "-psecret", "-htb"]
        )

        let original = [UInt8](try Data(contentsOf: archiveURL))
        let originalLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: original).first { !$0.data.isEmpty }
        )

        var noCheck = original
        _ = try RAR5TestSupport.removeFileEncryptionCheck(
            &noCheck,
            layout: originalLayout
        )
        let noCheckReader = try ArchiveReader.open(
            data: Data(noCheck),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(try noCheckReader.read(try XCTUnwrap(noCheckReader.entries.first)), payload)
        let wrongNoCheckReader = try ArchiveReader.open(
            data: Data(noCheck),
            options: ReaderOptions(password: "wrong")
        )
        XCTAssertThrowsError(
            try wrongNoCheckReader.read(try XCTUnwrap(wrongNoCheckReader.entries.first))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        var damagedCheck = original
        let check = try XCTUnwrap(
            RAR5TestSupport.fileEncryptionCheckRange(
                in: damagedCheck,
                layout: originalLayout
            )
        )
        damagedCheck[check.lowerBound] ^= 1
        RAR5TestSupport.repairHeaderCRC(&damagedCheck, layout: originalLayout)
        let damagedCheckReader = try ArchiveReader.open(
            data: Data(damagedCheck),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(
            try damagedCheckReader.read(try XCTUnwrap(damagedCheckReader.entries.first)),
            payload
        )
        let wrongDamagedCheckReader = try ArchiveReader.open(
            data: Data(damagedCheck),
            options: ReaderOptions(password: "wrong")
        )
        XCTAssertThrowsError(
            try wrongDamagedCheckReader.read(
                try XCTUnwrap(wrongDamagedCheckReader.entries.first)
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        // With the original valid verifier, the correct password is positively
        // known before decoding. Ciphertext damage must retain its structural
        // malformed diagnosis instead of being mislabeled as a bad password.
        var corrupted = original
        corrupted[originalLayout.data.lowerBound] ^= 1
        let corruptedReader = try ArchiveReader.open(
            data: Data(corrupted),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertThrowsError(
            try corruptedReader.read(try XCTUnwrap(corruptedReader.entries.first))
        ) { error in
            guard case .malformed = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testGeneratedHeaderEncryptedArchiveRoundTrips() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-header-encryption")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("header encrypted 日本語\n".utf8)
        _ = try ZipTestSupport.write(
            payload,
            relativePath: "hidden.txt",
            below: source
        )
        let archive = temporary.appendingPathComponent("header-encrypted.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["hidden.txt"],
            archiveURL: archive,
            options: ["-m0", "-hpsecret"]
        )

        XCTAssertThrowsError(try ArchiveReader.open(url: archive)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: archive,
                options: ReaderOptions(password: "wrong")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(reader.entries.map(\.name), ["hidden.txt"])
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(try reader.reopen().read(entry), payload)
    }

    func testStoredEntryWithUnknownUnpackedSizeStreamsToItsPhysicalEnd() throws {
        let payload = Data("unknown RAR5 stored size\n".utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "unknown.txt",
                contents: payload,
                fileFlags: 0x0008
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertNil(entry.uncompressedSize)
        XCTAssertEqual(entry.formatSpecific["unpackedSizeUnknown"], "true")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testDeclaredEntrySizeAboveLimitStillOpensAndListsButStreamRejects() throws {
        let payload = RAR5TestSupport.deterministicPayload(count: 65, seed: 0x4c_49_53_54)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "listed.bin", contents: payload),
        ])
        var limits = ReadLimits()
        limits.maxEntrySize = 64
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "listed.bin")
        XCTAssertEqual(entry.uncompressedSize, UInt64(payload.count))
        XCTAssertThrowsError(try reader.stream(entry)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("size 65 exceeds limit 64")
            )
        }
    }

    func testGeneratedCompressedEntryWithUnknownUnpackedSizeUsesBlockEnd() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(
            label: "rar5-compressed-unknown-size"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let repeated = Data(String(repeating: "unknown compressed size \u{65e5}\u{672c}\u{8a9e}\n", count: 2_048).utf8)
        let payload = repeated
            + RAR5TestSupport.deterministicPayload(count: 8_193, seed: 0x55_4e_4b_4e_4f_57_4e)
            + repeated
        _ = try ZipTestSupport.write(payload, relativePath: "unknown.bin", below: source)
        let archiveURL = temporary.appendingPathComponent("unknown.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["unknown.bin"],
            archiveURL: archiveURL,
            options: ["-m5", "-s-", "-qo-", "-md1m"]
        )

        var archive = [UInt8](try Data(contentsOf: archiveURL))
        let fileLayout = try XCTUnwrap(
            RAR5TestSupport.blockLayouts(in: archive).first { !$0.data.isEmpty }
        )
        try RAR5TestSupport.markFileUnpackedSizeUnknown(
            &archive,
            layout: fileLayout
        )

        let reader = try ArchiveReader.open(data: Data(archive))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertNil(entry.uncompressedSize)
        XCTAssertEqual(entry.formatSpecific["unpackedSizeUnknown"], "true")
        XCTAssertNotEqual(entry.formatSpecific["method"], "0")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testVIntAcceptsPaddingAndRetainsOnlyLowSixtyFourBits() throws {
        var padded = RAR5ByteCursor([0x80, 0x80, 0x80, 0x00])
        XCTAssertEqual(try padded.readVInt(), 0)
        XCTAssertTrue(padded.isAtEnd)

        var maximum = RAR5ByteCursor(Array(repeating: 0xff, count: 9) + [0x7f])
        XCTAssertEqual(try maximum.readVInt(), UInt64.max)
        XCTAssertTrue(maximum.isAtEnd)

        var overlong = RAR5ByteCursor(Array(repeating: 0x80, count: 11))
        XCTAssertThrowsError(try overlong.readVInt()) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("exceeds 10 bytes"), reason)
        }
    }

    func testHeaderSizeVIntIsLimitedToThreeBytes() throws {
        let body: [UInt8] = [0x01, 0x00]
        let size: [UInt8] = [0x82, 0x80, 0x80, 0x00]
        var covered = size
        covered += body
        var archive = Data(RAR5Reader.signature)
        appendLittle(CRC32.checksum(covered), to: &archive)
        archive.append(contentsOf: covered)

        assertOpenThrows(archive, category: "malformed", containing: "header-size vint")
    }

    func testHeaderCRCMismatchIsRejectedBeforePublishingEntries() throws {
        let payload = Data("crc protected".utf8)
        var bytes = [UInt8](RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "crc.txt", contents: payload),
        ]))
        let layouts = try RAR5TestSupport.blockLayouts(in: bytes)
        let fileHeader = try XCTUnwrap(layouts.dropFirst().first)
        bytes[fileHeader.body.lowerBound] ^= 0x20

        assertOpenThrows(Data(bytes), category: "malformed", containing: "header CRC")
    }

    func testEveryProperPrefixOfStoredArchiveIsRejectedAsTruncatedOrUnsupported() throws {
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "prefix.txt",
                contents: Data("all physical boundaries must be checked".utf8)
            ),
        ])
        XCTAssertNoThrow(try ArchiveReader.open(data: archive))
        for count in 0..<archive.count {
            XCTAssertThrowsError(
                try ArchiveReader.open(data: Data(archive.prefix(count))),
                "prefix length \(count) unexpectedly opened"
            )
        }
    }

    func testDictionaryEncodingRejectsImpossibleValueButStoredEntriesIgnoreLimit() throws {
        // Version 0 is limited to exponent 15 (4 GiB) by the technote.
        let invalidVersionZero = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "v0.bin",
                contents: Data(),
                compressionInfo: UInt64(16) << 10
            ),
        ])
        assertOpenThrows(
            invalidVersionZero,
            category: "malformed",
            containing: "version 0 dictionary exponent"
        )

        // Stored entries never allocate a dictionary, so even an encoded 64 GiB
        // requirement does not prevent safe archive enumeration or extraction.
        let sixtyFourGiB = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "v1.bin",
                contents: Data(),
                compressionInfo: 1 | (UInt64(19) << 10)
            ),
        ])
        var storedLimits = ReadLimits()
        storedLimits.maxDictionarySize = 1
        let storedReader = try ArchiveReader.open(
            data: sixtyFourGiB,
            options: ReaderOptions(limits: storedLimits)
        )
        let storedEntry = try XCTUnwrap(storedReader.entries.first)
        XCTAssertEqual(
            storedEntry.formatSpecific["dictionarySize"],
            String(UInt64(64) * 1_024 * 1_024 * 1_024)
        )
        XCTAssertEqual(try storedReader.read(storedEntry), Data())

        let oneGiB = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "maximum.bin",
                contents: Data(),
                compressionInfo: 1 | (UInt64(13) << 10)
            ),
        ])
        let reader = try RAR5Reader(
            source: DataByteSource(data: oneGiB),
            options: ReaderOptions()
        )
        XCTAssertEqual(
            reader.entries.first?.formatSpecific["dictionarySize"],
            String(1 * 1_024 * 1_024 * 1_024)
        )

        let compressed = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "compressed.bin",
                contents: Data([0]),
                compressionInfo: (UInt64(1) << 7) | (UInt64(4) << 10)
            ),
        ])
        var compressedLimits = ReadLimits()
        compressedLimits.maxDictionarySize = 1 * 1_024 * 1_024
        let compressedReader = try ArchiveReader.open(
            data: compressed,
            options: ReaderOptions(limits: compressedLimits)
        )
        let compressedEntry = try XCTUnwrap(compressedReader.entries.first)
        XCTAssertThrowsError(try compressedReader.stream(compressedEntry)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("size 2097152 exceeds limit 1048576")
            )
        }
    }

    func testCompressedVersionOneIsExplicitlyUnsupportedEvenWithLegacyAlgorithmBit() throws {
        let compressionInfo = UInt64(1) | (UInt64(1) << 7) | (UInt64(1) << 20)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "version-one.bin",
                contents: Data([0]),
                compressionInfo: compressionInfo
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.stream(entry)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("RAR compression algorithm version 1")
            )
        }
    }

    func testFileCopyRedirectionHasAnEmptyDataStreamButExtractionIsUnsupported() throws {
        let target = "original.txt"
        let payload = RAR5TestSupport.vint(5)
            + RAR5TestSupport.vint(0)
            + RAR5TestSupport.vint(UInt64(target.utf8.count))
            + Array(target.utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: target,
                contents: Data("original".utf8)
            ),
            RAR5TestSupport.storedFile(
                name: "copy.txt",
                contents: Data(),
                extra: RAR5TestSupport.extraRecord(type: 0x05, payload: payload)
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let copy = try XCTUnwrap(reader.entries.first { $0.name == "copy.txt" })
        XCTAssertEqual(copy.kind, .other)
        XCTAssertEqual(copy.uncompressedSize, 0)
        XCTAssertEqual(copy.compressedSize, 0)
        XCTAssertEqual(copy.formatSpecific["redirectionType"], "5")
        XCTAssertEqual(try reader.read(copy), Data())

        let output = try ZipTestSupport.temporaryDirectory(label: "rar5-file-copy")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertThrowsError(try reader.extract(copy, to: output)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("RAR5 file-copy redirection")
            )
        }
    }

    func testHardLinksAndFileReferencesAreZeroBodyAndDoNotJoinSolidOutputAccounting() throws {
        func redirection(
            type: UInt64,
            name: String,
            target: String,
            declaredSize: UInt64
        ) -> Data {
            let payload = RAR5TestSupport.vint(type)
                + RAR5TestSupport.vint(0)
                + RAR5TestSupport.vint(UInt64(target.utf8.count))
                + Array(target.utf8)
            return RAR5TestSupport.storedFile(
                name: name,
                contents: Data(),
                unpackedSize: declaredSize,
                dataCRC32: CRC32.checksum(Data("declared target bytes".utf8)),
                compressionInfo: type == 4
                    ? 0x40 | 2
                    : 0x40 | (UInt64(6) << 7),
                extra: RAR5TestSupport.extraRecord(type: 0x05, payload: payload)
            )
        }

        let firstPayload = Data("declared target bytes".utf8)
        let finalPayload = Data("solid member after links".utf8)
        let archive = RAR5TestSupport.archive(mainFlags: 0x04, blocks: [
            RAR5TestSupport.storedFile(name: "original.txt", contents: firstPayload),
            redirection(
                type: 4,
                name: "hard.txt",
                target: "original.txt",
                declaredSize: UInt64(firstPayload.count)
            ),
            redirection(
                type: 5,
                name: "reference.txt",
                target: "original.txt",
                declaredSize: UInt64(firstPayload.count)
            ),
            RAR5TestSupport.storedFile(
                name: "after.txt",
                contents: finalPayload,
                compressionInfo: 0x40
            ),
        ])
        var limits = ReadLimits()
        limits.maxTotalUncompressedSize = UInt64(firstPayload.count + finalPayload.count)
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )

        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, -1, 0])
        let hard = reader.entries[1]
        let reference = reader.entries[2]
        XCTAssertEqual(hard.kind, .hardlink)
        XCTAssertEqual(reference.kind, .other)
        for link in [hard, reference] {
            XCTAssertEqual(link.uncompressedSize, 0)
            XCTAssertEqual(link.compressedSize, 0)
            XCTAssertEqual(try reader.read(link), Data())
            let stream = try reader.stream(link)
            var byte: UInt8 = 0xff
            XCTAssertEqual(
                try withUnsafeMutableBytes(of: &byte) { try stream.read(into: $0) },
                0
            )
        }

        // A direct request for the later member skips both zero-body records
        // while retaining the preceding data-bearing solid member.
        XCTAssertEqual(try reader.read(reader.entries[3]), finalPayload)
        XCTAssertEqual(try reader.read(reader.entries[0]), firstPayload)
    }

    func testUnixSymlinkWithoutRedirectionReadsItsTargetFromStoredData() throws {
        let target = "target.txt"
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "symbolic.txt",
                contents: Data(target.utf8),
                attributes: 0o120777
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.kind, .symlink)
        XCTAssertEqual(entry.formatSpecific["linkTargetStoredAsData"], "true")
        XCTAssertNil(entry.formatSpecific["linkPath"])
        XCTAssertEqual(try reader.read(entry), Data(target.utf8))

        let output = try ZipTestSupport.temporaryDirectory(label: "rar5-unix-symlink")
        defer { try? FileManager.default.removeItem(at: output) }
        let extracted = try reader.extract(entry, to: output)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: extracted.path),
            target
        )
    }

    func testUnusualPerFileCompatibilityValuesFailOnlyWhenThatEntryStreams() throws {
        func encryptionExtra(version: UInt64, kdfCount: UInt8) -> [UInt8] {
            var payload = RAR5TestSupport.vint(version)
            guard version == 0 else {
                return RAR5TestSupport.extraRecord(type: 0x01, payload: payload)
            }
            payload += RAR5TestSupport.vint(0)
            payload.append(kdfCount)
            payload += [UInt8](repeating: 0, count: 32)
            return RAR5TestSupport.extraRecord(type: 0x01, payload: payload)
        }

        let goodPayload = Data("ordinary entry remains readable".utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "good.txt", contents: goodPayload),
            RAR5TestSupport.storedFile(
                name: "method-6.bin",
                contents: Data([0]),
                compressionInfo: UInt64(6) << 7
            ),
            RAR5TestSupport.storedFile(
                name: "version-2.bin",
                contents: Data(),
                compressionInfo: 2 | (UInt64(31) << 10)
            ),
            RAR5TestSupport.storedFile(
                name: "encryption-version-1.bin",
                contents: Data(),
                includeCRC32: false,
                extra: encryptionExtra(version: 1, kdfCount: 0)
            ),
            RAR5TestSupport.storedFile(
                name: "kdf-1.bin",
                contents: Data(),
                includeCRC32: false,
                extra: encryptionExtra(version: 0, kdfCount: 1)
            ),
        ])
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(maxRAR5KDFCountPower: 0)
        )
        XCTAssertEqual(reader.entries.count, 5)
        XCTAssertEqual(try reader.read(reader.entries[0]), goodPayload)

        let expected: [KaitoError] = [
            .unsupportedMethod("RAR5 compression method 6"),
            .unsupportedMethod("RAR compression version 2"),
            .unsupportedMethod("RAR5 file encryption version 1"),
            .unsupportedMethod("RAR5 KDF count 1"),
        ]
        for (entry, expectedError) in zip(reader.entries.dropFirst(), expected) {
            XCTAssertThrowsError(try reader.stream(entry)) { error in
                XCTAssertEqual(error as? KaitoError, expectedError)
            }
        }
    }

    func testMalformedExtraRecordsAndRecordCountAreBounded() throws {
        let exceedsArea: [UInt8] = [0x05, 0x40]
        let malformed = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "extra.bin",
                contents: Data(),
                extra: exceedsArea
            ),
        ])
        assertOpenThrows(malformed, category: "malformed", containing: "extra record")

        let extras = RAR5TestSupport.extraRecord(type: 0x40)
            + RAR5TestSupport.extraRecord(type: 0x41)
        let tooMany = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "records.bin",
                contents: Data(),
                extra: extras
            ),
        ])
        var limits = ReadLimits()
        limits.maxMetadataRecordCount = 1
        XCTAssertThrowsError(
            try RAR5Reader(
                source: DataByteSource(data: tooMany),
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case let .limitExceeded(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("extra record count"), reason)
        }

        let oneRecordPerHeader = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "first.bin",
                contents: Data(),
                extra: RAR5TestSupport.extraRecord(type: 0x40)
            ),
            RAR5TestSupport.storedFile(
                name: "second.bin",
                contents: Data(),
                extra: RAR5TestSupport.extraRecord(type: 0x41)
            ),
        ])
        let perHeaderReader = try RAR5Reader(
            source: DataByteSource(data: oneRecordPerHeader),
            options: ReaderOptions(limits: limits)
        )
        XCTAssertEqual(perHeaderReader.entries.map(\.name), ["first.bin", "second.bin"])
    }

    func testSixtyFiveThousandSixHundredHeadersMayEachCarryOneTimeRecord() throws {
        let memberCount = 65_600
        let timePayload: [UInt8] = [0x03, 0, 0, 0, 0]
        let timeExtra = RAR5TestSupport.extraRecord(
            type: 0x03,
            payload: timePayload
        )
        var blocks: [Data] = []
        blocks.reserveCapacity(memberCount)
        for index in 0..<memberCount {
            blocks.append(RAR5TestSupport.storedFile(
                name: String(format: "%05d", index),
                contents: Data(),
                includeCRC32: false,
                extra: timeExtra
            ))
        }

        let archive = RAR5TestSupport.archive(blocks: blocks)
        let reader = try RAR5Reader(
            source: DataByteSource(data: archive),
            options: ReaderOptions()
        )
        XCTAssertEqual(reader.entries.count, memberCount)
        XCTAssertEqual(
            reader.entries.last?.modificationDate,
            Date(timeIntervalSince1970: 0)
        )
    }

    func testNamesRequireStrictUTF8AndWindowsRejectsBackslashes() throws {
        let invalidUTF8 = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(rawName: [0xc0, 0xaf], contents: Data()),
        ])
        assertOpenThrows(invalidUTF8, category: "malformed", containing: "valid UTF-8")

        let backslash = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "folder\\name.txt",
                contents: Data(),
                hostOS: 0
            ),
        ])
        assertOpenThrows(backslash, category: "malformed", containing: "backslash")

        let absolute = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "/absolute.txt", contents: Data()),
        ])
        assertOpenThrows(absolute, category: "malformed", containing: "unsafe")
    }

    func testUnknownHeadersRequireSkipFlagAndPreserveFollowingFile() throws {
        let unknown = RAR5TestSupport.block(type: 0x40, specific: [0xaa, 0xbb])
        let rejected = RAR5TestSupport.archive(mainFlags: 0, blocks: [unknown])
        assertOpenThrows(rejected, category: "unsupported", containing: "header type")

        let skippable = RAR5TestSupport.block(
            type: 0x40,
            flags: 0x0004,
            specific: [0xaa, 0xbb],
            data: Data([1, 2, 3])
        )
        let payload = Data("after extension".utf8)
        let accepted = RAR5TestSupport.archive(blocks: [
            skippable,
            RAR5TestSupport.storedFile(name: "after.txt", contents: payload),
        ])
        let reader = try ArchiveReader.open(data: accepted)
        XCTAssertEqual(reader.entries.map(\.name), ["after.txt"])
        XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), payload)
    }

    func testServiceHeadersRejectFileOnlyFlagsAndSkipUnknownCompressionMethods() throws {
        func service(fileFlags: UInt64, compression: UInt64) -> Data {
            var specific = RAR5TestSupport.vint(fileFlags)
            specific += RAR5TestSupport.vint(0) // unpacked size
            specific += RAR5TestSupport.vint(0) // reserved attributes
            specific += RAR5TestSupport.vint(compression)
            specific += RAR5TestSupport.vint(1) // Unix
            specific += RAR5TestSupport.vint(2)
            specific += Array("QO".utf8)
            return RAR5TestSupport.block(type: 3, specific: specific)
        }

        assertOpenThrows(
            RAR5TestSupport.archive(blocks: [service(fileFlags: 0x0001, compression: 0)]),
            category: "malformed",
            containing: "directory flag"
        )
        assertOpenThrows(
            RAR5TestSupport.archive(blocks: [service(fileFlags: 0, compression: 0x0040)]),
            category: "malformed",
            containing: "solid flag"
        )
        let payload = Data("after unusual service".utf8)
        let unusualMethod = RAR5TestSupport.archive(blocks: [
            service(fileFlags: 0, compression: UInt64(6) << 7),
            RAR5TestSupport.storedFile(name: "after.txt", contents: payload),
        ])
        let reader = try ArchiveReader.open(data: unusualMethod)
        XCTAssertEqual(reader.entries.map(\.name), ["after.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testForwardAndUnsafeHardLinkTargetsRemainUnresolved() throws {
        func hardLink(name: String, target: String) -> Data {
            let payload = RAR5TestSupport.vint(4)
                + RAR5TestSupport.vint(0)
                + RAR5TestSupport.vint(UInt64(target.utf8.count))
                + Array(target.utf8)
            return RAR5TestSupport.storedFile(
                name: name,
                contents: Data(),
                extra: RAR5TestSupport.extraRecord(type: 0x05, payload: payload)
            )
        }

        let archive = RAR5TestSupport.archive(blocks: [
            hardLink(name: "forward.txt", target: "later.txt"),
            RAR5TestSupport.storedFile(name: "later.txt", contents: Data("later".utf8)),
            hardLink(name: "unsafe.txt", target: "../outside.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let forward = try XCTUnwrap(reader.entries.first { $0.name == "forward.txt" })
        let unsafe = try XCTUnwrap(reader.entries.first { $0.name == "unsafe.txt" })
        XCTAssertEqual(forward.kind, .hardlink)
        XCTAssertNil(forward.formatSpecific["hardLinkTargetIndex"])
        XCTAssertNil(unsafe.formatSpecific["hardLinkTargetIndex"])
    }

    func testFourHundredSixteenDeterministicContainerMutantsDoNotCrashOrHang() throws {
        let seed = [UInt8](RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "mutant-seed.bin",
                contents: RAR5TestSupport.deterministicPayload(count: 2_048, seed: 0x4d_55_54)
            ),
        ]))
        let layouts = try RAR5TestSupport.blockLayouts(in: seed)
        let fileHeader = try XCTUnwrap(layouts.dropFirst().first)
        var limits = ReadLimits()
        limits.maxEntrySize = 256 * 1_024
        limits.maxInMemorySize = 256 * 1_024
        limits.maxEntryCount = 16
        limits.maxMetadataSize = 64 * 1_024
        limits.maxMetadataRecordCount = 64
        limits.maxPathComponentCount = 16
        limits.maxTotalMetadataSize = 256 * 1_024
        limits.maxDictionarySize = 1 * 1_024 * 1_024
        let options = ReaderOptions(limits: limits)

        var completed = 0
        for mutation in 0..<288 {
            var bytes = seed
            let first = fileHeader.body.lowerBound
                + (mutation &* 29 &+ 7) % fileHeader.body.count
            bytes[first] ^= UInt8(1) << UInt8(mutation % 8)
            if mutation.isMultiple(of: 3) {
                let second = fileHeader.body.lowerBound
                    + (mutation &* 17 &+ 3) % fileHeader.body.count
                bytes[second] &+= UInt8(truncatingIfNeeded: mutation | 1)
            }
            RAR5TestSupport.repairHeaderCRC(&bytes, layout: fileHeader)
            exerciseMutant(Data(bytes), options: options)
            completed += 1
        }
        for mutation in 0..<64 {
            let removed = 1 + (mutation &* 31) % (seed.count - 1)
            exerciseMutant(Data(seed.dropLast(removed)), options: options)
            completed += 1
        }
        for mutation in 0..<64 {
            var bytes = seed
            let position = (mutation &* 131 &+ 11) % bytes.count
            bytes[position] ^= UInt8(1) << UInt8(mutation % 8)
            exerciseMutant(Data(bytes), options: options)
            completed += 1
        }
        XCTAssertEqual(completed, 416)
    }

    private func exerciseMutant(_ data: Data, options: ReaderOptions) {
        guard let reader = try? ArchiveReader.open(data: data, options: options) else { return }
        for entry in reader.entries.prefix(4) {
            _ = try? reader.read(entry)
        }
    }

    private func assertOpenThrows(
        _ archive: Data,
        category: String,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RAR5Reader(
                source: DataByteSource(data: archive),
                options: ReaderOptions()
            ),
            file: file,
            line: line
        ) { error in
            guard let kaito = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            switch (category, kaito) {
            case ("malformed", .malformed), ("unsupported", .unsupportedMethod):
                break
            default:
                return XCTFail("unexpected error category: \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                String(describing: kaito).contains(expected),
                "\(kaito)",
                file: file,
                line: line
            )
        }
    }

    private func appendLittle(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
