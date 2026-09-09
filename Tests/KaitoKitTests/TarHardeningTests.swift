import Foundation
import KaitoKit
import XCTest

final class TarHardeningTests: XCTestCase {
    func testRecoveryRetainsTarHeadersAndAvailablePayloadWithoutRelaxingLimits() throws {
        let first = Data("first".utf8)
        let last = Data(repeating: 0xA5, count: 16_384)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "first", contents: first),
            HandTarEntry(name: "last", contents: last),
        ])
        for end in [1_024 + 17, 1_536, 1_536 + 8_192, 1_536 + last.count] {
            let cut = Data(archive.prefix(end))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { error in
                guard case KaitoError.truncated = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let reader = try ArchiveReader.open(
                data: cut, options: ReaderOptions(recoverDamagedArchives: true)
            )
            XCTAssertEqual(reader.entries.count, end < 1_536 ? 1 : 2)
            XCTAssertFalse(reader.entries[0].isIncomplete)
            XCTAssertEqual(try reader.read(reader.entries[0]), first)
            if reader.entries.count == 2 {
                XCTAssertEqual(reader.entries[1].isIncomplete, end < 1_536 + last.count)
                XCTAssertEqual(try reader.read(reader.entries[1]), last.prefix(end - 1_536))
            }
        }
        let cut = Data(archive.prefix(1_536 + 8_192))
        for limits in [ReadLimits(maxEntrySize: 16_383), ReadLimits(maxEntryCount: 1),
                       ReadLimits(maxTotalUncompressedSize: 16_384),
                       ReadLimits(maxTotalMetadataSize: 100)] {
            XCTAssertThrowsError(try ArchiveReader.open(data: cut, options: ReaderOptions(
                limits: limits, recoverDamagedArchives: true
            ))) { error in
                guard case KaitoError.limitExceeded = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        var malformed = cut
        malformed[1_024] ^= 1
        XCTAssertThrowsError(try ArchiveReader.open(
            data: malformed, options: ReaderOptions(recoverDamagedArchives: true)
        ))
    }

    func testRecoveryStopsAtCutTarExtensionMetadata() throws {
        let first = Data("kept".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "first", contents: first),
            HandTarEntry(name: "././@LongLink", contents: Data(repeating: 65, count: 1_024),
                         type: 76),
            HandTarEntry(name: "last"),
        ])
        let cut = Data(archive.prefix(1_536 + 25))
        XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { error in
            guard case KaitoError.truncated = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let reader = try ArchiveReader.open(
            data: cut, options: ReaderOptions(recoverDamagedArchives: true)
        )
        XCTAssertEqual(reader.entries.map(\.name), ["first"])
        XCTAssertEqual(try reader.read(reader.entries[0]), first)
    }


    func testForgedArchiveEntryIsRejectedByAllEntryOperations() throws {
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "payload.txt", contents: Data("trusted".utf8)),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let canonical = try XCTUnwrap(reader.entries.first)
        let forged = ArchiveEntry(
            index: canonical.index,
            rawName: canonical.rawName,
            name: canonical.name,
            pathComponents: canonical.pathComponents,
            kind: .symlink,
            uncompressedSize: canonical.uncompressedSize,
            compressedSize: canonical.compressedSize,
            modificationDate: canonical.modificationDate,
            posixPermissions: canonical.posixPermissions,
            isEncrypted: canonical.isEncrypted,
            solidGroup: canonical.solidGroup,
            crc32: canonical.crc32,
            methodDescription: canonical.methodDescription,
            formatSpecific: ["linkPath": "pivot/outside.txt"]
        )

        XCTAssertThrowsError(try reader.stream(forged)) { error in
            self.assertNotFound(error)
        }
        XCTAssertThrowsError(try reader.read(forged)) { error in
            self.assertNotFound(error)
        }

        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        XCTAssertThrowsError(try reader.extract(forged, to: output)) { error in
            self.assertNotFound(error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testHardLinkTargetCannotTraversePreexistingSymlinkPivot() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = try TarTestSupport.write(
            Data("outside-sentinel".utf8),
            relativePath: "target.txt",
            below: outside
        )
        try FileManager.default.createSymbolicLink(
            atPath: output.appendingPathComponent("pivot").path,
            withDestinationPath: "../outside"
        )

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "pivot/target.txt", contents: Data("archived".utf8)),
            HandTarEntry(name: "created-hardlink", type: 0x31, linkName: "pivot/target.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.last)

        XCTAssertThrowsError(try reader.extract(entry, to: output))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside-sentinel".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("created-hardlink").path
            )
        )
    }

    func testHardLinkCannotBindToPreexistingNonArchiveFile() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let victimData = Data("caller-owned target".utf8)
        let destinationData = Data("caller-owned destination".utf8)
        let victim = try TarTestSupport.write(
            victimData,
            relativePath: "victim.txt",
            below: output
        )
        let destination = try TarTestSupport.write(
            destinationData,
            relativePath: "alias.txt",
            below: output
        )
        let victimInode = try inode(of: victim)
        let destinationInode = try inode(of: destination)

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "alias.txt", type: 0x31, linkName: "victim.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)

        XCTAssertThrowsError(
            try reader.extract(
                entry,
                to: output,
                options: ExtractionOptions(overwriteExisting: true)
            )
        ) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimData)
        XCTAssertEqual(try Data(contentsOf: destination), destinationData)
        XCTAssertEqual(try inode(of: victim), victimInode)
        XCTAssertEqual(try inode(of: destination), destinationInode)
    }

    func testHardLinkCannotBindToUnmaterializedArchiveTarget() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let victimData = Data("caller-owned target".utf8)
        let victim = try TarTestSupport.write(
            victimData,
            relativePath: "victim.txt",
            below: output
        )
        let victimInode = try inode(of: victim)

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "victim.txt", contents: Data("archive target".utf8)),
            HandTarEntry(name: "alias.txt", type: 0x31, linkName: "victim.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)

        XCTAssertThrowsError(try reader.extract(reader.entries[1], to: output)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: victim), victimData)
        XCTAssertEqual(try inode(of: victim), victimInode)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.appendingPathComponent("alias.txt").path)
        )
    }

    func testHardLinkCannotBindThroughUnresolvedArchiveLink() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let targetData = Data("caller-owned intermediate".utf8)
        let destinationData = Data("caller-owned final".utf8)
        let target = try TarTestSupport.write(
            targetData,
            relativePath: "a",
            below: output
        )
        let destination = try TarTestSupport.write(
            destinationData,
            relativePath: "b",
            below: output
        )

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "a", type: 0x31, linkName: "missing"),
            HandTarEntry(name: "b", type: 0x31, linkName: "a"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let link = try XCTUnwrap(reader.entries.last)

        XCTAssertThrowsError(
            try reader.extract(
                link,
                to: output,
                options: ExtractionOptions(overwriteExisting: true)
            )
        ) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData)
        XCTAssertEqual(try Data(contentsOf: destination), destinationData)
    }

    func testHardLinkToEarlierRegularFileSharesContentAndInode() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let payload = Data("hard-link payload".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "files/original.txt", contents: payload),
            HandTarEntry(
                name: "files/alias.txt",
                type: 0x31,
                linkName: "files/original.txt"
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .hardlink])

        _ = try reader.extract(reader.entries[0], to: output)
        _ = try reader.extract(reader.entries[1], to: output)

        let original = output.appendingPathComponent("files/original.txt")
        let alias = output.appendingPathComponent("files/alias.txt")
        XCTAssertEqual(try Data(contentsOf: original), payload)
        XCTAssertEqual(try Data(contentsOf: alias), payload)
        XCTAssertEqual(try inode(of: original), try inode(of: alias))
    }

    func testHardLinkExtractionKeepsProvenanceForUncreatedPrivateRoot() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/KaitoKitTests-\(UUID().uuidString)/output",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let payload = Data("hard-link private-root payload".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "original.txt", contents: payload),
            HandTarEntry(name: "alias.txt", type: 0x31, linkName: "original.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)

        _ = try reader.extract(reader.entries[0], to: root)
        _ = try reader.extract(reader.entries[1], to: root)

        let original = root.appendingPathComponent("original.txt")
        let alias = root.appendingPathComponent("alias.txt")
        XCTAssertEqual(try Data(contentsOf: alias), payload)
        XCTAssertEqual(try inode(of: original), try inode(of: alias))
    }

    func testHardLinkExtractionKeepsProvenanceForRelativeRootBelowTmp() throws {
        let manager = FileManager.default
        let originalWorkingDirectory = manager.currentDirectoryPath
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/KaitoKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        guard manager.changeCurrentDirectoryPath(workingDirectory.path) else {
            return XCTFail("could not enter the temporary working directory")
        }
        defer {
            _ = manager.changeCurrentDirectoryPath(originalWorkingDirectory)
            try? manager.removeItem(at: workingDirectory)
        }

        let root = URL(fileURLWithPath: "relative-output", isDirectory: true)
        XCTAssertFalse(manager.fileExists(atPath: root.path))

        let payload = Data("hard-link relative-root payload".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "original.txt", contents: payload),
            HandTarEntry(name: "alias.txt", type: 0x31, linkName: "original.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)

        _ = try reader.extract(reader.entries[0], to: root)
        _ = try reader.extract(reader.entries[1], to: root)

        let original = root.appendingPathComponent("original.txt")
        let alias = root.appendingPathComponent("alias.txt")
        XCTAssertEqual(try Data(contentsOf: alias), payload)
        XCTAssertEqual(try inode(of: original), try inode(of: alias))
    }

    func testHardLinkChainEndingAtEarlierRegularFileSucceeds() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let payload = Data("hard-link chain".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "a", contents: payload),
            HandTarEntry(name: "b", type: 0x31, linkName: "a"),
            HandTarEntry(name: "c", type: 0x31, linkName: "b"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        for entry in reader.entries {
            _ = try reader.extract(entry, to: output)
        }

        let identities = try ["a", "b", "c"].map {
            try inode(of: output.appendingPathComponent($0))
        }
        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("c")), payload)
    }

    func testPAXLinkDataHardLinkCanExtractWithoutFilesystemTarget() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let payload = Data("pax linkdata payload".utf8)
        let metadata = try paxPayload([
            ("linkpath", Array("target".utf8)),
            ("size", Array(String(payload.count).utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "target", contents: payload),
            HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
            HandTarEntry(
                name: "standalone-link",
                contents: payload,
                type: 0x31,
                linkName: "target"
            ),
            HandTarEntry(name: "after.txt", contents: Data("after".utf8)),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let link = reader.entries[1]
        XCTAssertEqual(link.uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try reader.read(link), payload)
        XCTAssertEqual(reader.entries.map(\.name), ["target", "standalone-link", "after.txt"])
        XCTAssertEqual(try reader.read(reader.entries[2]), Data("after".utf8))

        _ = try reader.extract(link, to: output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.appendingPathComponent("target").path)
        )
        XCTAssertEqual(
            try Data(contentsOf: output.appendingPathComponent("standalone-link")),
            payload
        )
    }

    func testPAXLinkDataUpdatesMaterializedTargetAndPreservesHardLink() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let targetPayload = Data("original-target-data\n".utf8)
        let linkPayload = Data("pax-linkdata-payload\n".utf8)
        let metadata = try paxPayload([
            ("linkpath", Array("target".utf8)),
            ("size", Array(String(linkPayload.count).utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "target", contents: targetPayload, mode: 0o000),
            HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
            HandTarEntry(
                name: "alias",
                contents: linkPayload,
                type: 0x31,
                linkName: "target"
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        _ = try reader.extract(reader.entries[0], to: output)
        _ = try reader.extract(reader.entries[1], to: output)

        let target = output.appendingPathComponent("target")
        let alias = output.appendingPathComponent("alias")
        XCTAssertEqual(try inode(of: target), try inode(of: alias))
        XCTAssertEqual(try Data(contentsOf: target), linkPayload)
        XCTAssertEqual(try Data(contentsOf: alias), linkPayload)
    }

    func testUnmarkedPAXLinkDataUsesStructuralLookahead() throws {
        let payload = Data("unmarked pax linkdata".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "target", contents: payload),
            HandTarEntry(
                name: "alias",
                contents: payload,
                type: 0x31,
                linkName: "target"
            ),
            HandTarEntry(name: "after.txt", contents: Data("after".utf8)),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["target", "alias", "after.txt"])
        XCTAssertEqual(reader.entries[1].uncompressedSize, UInt64(payload.count))
        XCTAssertEqual(try reader.read(reader.entries[1]), payload)
        XCTAssertEqual(try reader.read(reader.entries[2]), Data("after".utf8))
    }

    func testHardLinkToModeZeroRegularFileSharesInodeAndContent() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let payload = Data("mode-zero hard-link payload".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(
                name: "files/original.txt",
                contents: payload,
                mode: 0o000
            ),
            HandTarEntry(
                name: "files/alias.txt",
                type: 0x31,
                linkName: "files/original.txt"
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        _ = try reader.extract(reader.entries[0], to: output)
        let original = output.appendingPathComponent("files/original.txt")
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: original.path
        )
        let originalMode = try XCTUnwrap(
            originalAttributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(originalMode.uint16Value & 0o7777, 0o000)

        _ = try reader.extract(reader.entries[1], to: output)
        let alias = output.appendingPathComponent("files/alias.txt")
        XCTAssertEqual(try inode(of: original), try inode(of: alias))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: alias.path
        )
        XCTAssertEqual(try Data(contentsOf: original), payload)
        XCTAssertEqual(try Data(contentsOf: alias), payload)
    }

    func testPreexistingSameInodeHardLinkDestinationIsRejectedAndPreserved() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let payload = Data("preexisting alias".utf8)
        let target = try TarTestSupport.write(
            payload,
            relativePath: "target.txt",
            below: output
        )
        let destination = output.appendingPathComponent("destination.txt")
        try FileManager.default.linkItem(at: target, to: destination)
        let originalInode = try inode(of: destination)
        XCTAssertEqual(originalInode, try inode(of: target))

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "target.txt", contents: payload),
            HandTarEntry(
                name: "destination.txt",
                type: 0x31,
                linkName: "target.txt"
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.last)

        XCTAssertThrowsError(
            try reader.extract(
                entry,
                to: output,
                options: ExtractionOptions(overwriteExisting: true)
            )
        ) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try inode(of: destination), originalInode)
        XCTAssertEqual(try inode(of: target), originalInode)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: target), payload)
    }

    func testDotHardLinkTargetsRejectWithoutReplacingDestination() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let sentinelData = Data("destination sentinel".utf8)
        let destination = try TarTestSupport.write(
            sentinelData,
            relativePath: "destination.txt",
            below: output
        )
        let originalInode = try inode(of: destination)

        for target in [".", "./"] {
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "destination.txt", type: 0x31, linkName: target),
            ])
            let reader = try ArchiveReader.open(data: archive)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertThrowsError(
                try reader.extract(
                    entry,
                    to: output,
                    options: ExtractionOptions(overwriteExisting: true)
                )
            ) { error in
                guard case KaitoError.malformed = error else {
                    return XCTFail("expected malformed, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: destination), sentinelData)
            XCTAssertEqual(try inode(of: destination), originalInode)
        }
    }

    func testInvalidHardLinkTargetsDoNotReplaceExistingDestination() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        for (label, target, createTargetDirectory) in [
            ("missing", "missing-target", false),
            ("directory", "directory-target", true),
        ] {
            let output = temporary.appendingPathComponent(label, isDirectory: true)
            let sentinelData = Data("\(label) destination sentinel".utf8)
            let destination = try TarTestSupport.write(
                sentinelData,
                relativePath: "destination.txt",
                below: output
            )
            if createTargetDirectory {
                try FileManager.default.createDirectory(
                    at: output.appendingPathComponent(target, isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
            let originalInode = try inode(of: destination)
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: target, contents: Data("archived target".utf8)),
                HandTarEntry(name: "destination.txt", type: 0x31, linkName: target),
            ])
            let reader = try ArchiveReader.open(data: archive)
            let entry = try XCTUnwrap(reader.entries.last)

            XCTAssertThrowsError(
                try reader.extract(
                    entry,
                    to: output,
                    options: ExtractionOptions(overwriteExisting: true)
                )
            )
            XCTAssertEqual(try Data(contentsOf: destination), sentinelData)
            XCTAssertEqual(try inode(of: destination), originalInode)
        }
    }

    func testSymbolicLinkTargetCannotTraversePreexistingSymlinkPivot() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let linkDirectory = output.appendingPathComponent("links", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = try TarTestSupport.write(
            Data("outside-sentinel".utf8),
            relativePath: "target.txt",
            below: outside
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkDirectory.appendingPathComponent("pivot").path,
            withDestinationPath: "../../outside"
        )

        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "links/created-symlink", type: 0x32, linkName: "pivot/target.txt"),
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)

        XCTAssertThrowsError(try reader.extract(entry, to: output))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside-sentinel".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: linkDirectory.appendingPathComponent("created-symlink").path
            )
        )
    }

    func testOldGNUHeaderDoesNotInterpretSparseAreaAsUstarPrefix() throws {
        let originalName = "payload.txt"
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: originalName, contents: Data("value".utf8)),
        ])
        let oldGNU = try editingFirstHeader(in: archive) { header in
            header.replaceSubrange(257..<265, with: Array("ustar  \0".utf8))
            header.replaceSubrange(345..<500, with: repeatElement(0, count: 155))
            header.replaceSubrange(345..<361, with: Array("forged-prefix/xx".utf8))
        }

        let reader = try ArchiveReader.open(data: oldGNU)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, originalName)
        XCTAssertEqual(entry.rawName.bytes, Array(originalName.utf8))
    }

    func testOctalSizeRejectsDigitsAfterNULTerminator() throws {
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "first"),
            HandTarEntry(name: "second"),
        ])
        let smuggled = try editingFirstHeader(in: archive) { header in
            header.replaceSubrange(
                124..<136,
                with: [0] + [UInt8](repeating: 0x30, count: 7) + Array("1000".utf8)
            )
        }

        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("smuggled.tar")
        try smuggled.write(to: url)
        XCTAssertThrowsError(try ArchiveReader.open(url: url)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testTarDetectorRejectsChecksumDigitsAfterNULTerminator() throws {
        let archive = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "entry")])
        var noMagic = try editingFirstHeader(in: archive) { header in
            header.replaceSubrange(257..<265, with: [UInt8](repeating: 0, count: 8))
        }
        let checksumDigits = Array(noMagic[148..<154])
        noMagic.replaceSubrange(
            148..<156,
            with: [UInt8(0)] + checksumDigits + [UInt8(0x20)]
        )

        XCTAssertThrowsError(try FormatDetector.detect(data: noMagic)) { error in
            XCTAssertEqual(error as? KaitoError, .unsupportedFormat)
        }
    }

    func testValidatedTarWinsOverShortStreamSignatureInPathname() throws {
        for name in ["BZh9-tar-entry", "xx-lh5-tar-entry"] {
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: name, contents: Data("tar".utf8)),
            ])
            XCTAssertEqual(try FormatDetector.detect(data: archive), .tar)
            XCTAssertEqual(try ArchiveReader.open(data: archive).entries.first?.name, name)
        }

        let signatures: [[UInt8]] = [
            [0x50, 0x4b, 0x03, 0x04],
            [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00],
            [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
            [0x1f, 0x8b],
            [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00],
        ]
        for signature in signatures {
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "collision-name", contents: Data("tar".utf8)),
            ])
            let collision = try editingFirstHeader(in: archive) { header in
                header.replaceSubrange(0..<signature.count, with: signature)
            }
            XCTAssertEqual(try FormatDetector.detect(data: collision), .tar)
        }
    }

    func testNoBodyMemberSizeHintDoesNotHideFollowingHeader() throws {
        for type in [UInt8(0x31), 0x32, 0x33, 0x34, 0x35, 0x36] {
            let firstName = type == 0x35 ? "folder/" : "special-\(type)"
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: firstName, type: type, linkName: "target"),
                HandTarEntry(name: "after.txt", contents: Data("visible".utf8)),
            ])
            let sizeHint = try editingFirstHeader(in: archive) { header in
                header.replaceSubrange(
                    124..<136,
                    with: [UInt8](repeating: 0x30, count: 7) + Array("1000".utf8) + [0]
                )
            }

            let reader = try ArchiveReader.open(data: sizeHint)
            XCTAssertEqual(reader.entries.map(\.name), [firstName, "after.txt"])
            XCTAssertEqual(reader.entries.first?.uncompressedSize, 0)
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("visible".utf8))
        }
    }

    func testPAXSizeBodyOnSpecialMemberDoesNotHideFollowingHeader() throws {
        let payload = Data(repeating: 0xa5, count: 512)
        for type in [UInt8(0x32), 0x35] {
            let metadata = try paxPayload([
                ("size", Array("512".utf8)),
            ])
            let name = type == 0x35 ? "folder/" : "link"
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
                HandTarEntry(
                    name: name,
                    contents: payload,
                    type: type,
                    linkName: "target"
                ),
                HandTarEntry(name: "after.txt", contents: Data("visible".utf8)),
            ])

            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(reader.entries.map(\.name), [name, "after.txt"])
            XCTAssertEqual(reader.entries[0].uncompressedSize, 512)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(try reader.read(reader.entries[1]), Data("visible".utf8))
        }
    }

    func testSUNHolesDataPAXRecordRejectsSparseEntry() throws {
        let metadata = try paxPayload([
            ("SUN.holesdata", Array("0,1".utf8)),
        ])
        for type in [UInt8(0x78), UInt8(0x58)] {
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "PaxHeader", contents: metadata, type: type),
                HandTarEntry(name: "sparse.bin", contents: Data([0xaa])),
            ])

            XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
                guard case KaitoError.unsupportedMethod = error else {
                    return XCTFail("expected unsupportedMethod, got \(error)")
                }
            }
        }
    }

    func testInvalidUTF8PAXLinkPathIsRejected() throws {
        let metadata = try paxPayload([
            ("linkpath", [0xc3, 0x28]),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
            HandTarEntry(name: "link", type: 0x32),
        ])

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testUnknownUnicodePAXKeywordIsIgnored() throws {
        let metadata = try paxPayload([
            ("会社.属性", Array("値".utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
            HandTarEntry(name: "payload.txt", contents: Data("value".utf8)),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["payload.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("value".utf8))
    }

    func testConflictingPAXAndGNULongNameHeadersAreRejected() throws {
        let metadata = try paxPayload([
            ("path", Array("pax-name.txt".utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader", contents: metadata, type: 0x78),
            HandTarEntry(
                name: "LongName",
                contents: Data(Array("gnu-name.txt\0".utf8)),
                type: 0x4c
            ),
            HandTarEntry(name: "header-name.txt"),
        ])

        XCTAssertThrowsError(try ArchiveReader.open(data: archive)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testEmptyLocalPAXValueDeletesInheritedGlobalValue() throws {
        let global = try paxPayload([
            ("path", Array("global-name.txt".utf8)),
        ])
        let local = try paxPayload([
            ("path", []),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "GlobalHead", contents: global, type: 0x67),
            HandTarEntry(name: "LocalHead", contents: local, type: 0x78),
            HandTarEntry(name: "header-name.txt", contents: Data("value".utf8)),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["header-name.txt"])
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), Data("value".utf8))
    }

    func testPositiveBase256SizeAndNegativeBase256ModificationTime() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "base256.bin", contents: payload),
        ])
        let base256 = try editingFirstHeader(in: archive) { header in
            header.replaceSubrange(
                124..<136,
                with: [0x80] + [UInt8](repeating: 0, count: 10) + [0x03]
            )
            header.replaceSubrange(
                136..<148,
                with: [UInt8](repeating: 0xff, count: 11) + [0xfe]
            )
        }

        let reader = try ArchiveReader.open(data: base256)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.uncompressedSize, 3)
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(
            try XCTUnwrap(entry.modificationDate).timeIntervalSince1970,
            -2,
            accuracy: 0.001
        )
    }

    func testSignedByteChecksumHeaderIsAcceptedByDetectorAndReader() throws {
        let payload = Data("signed checksum".utf8)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "signed.txt", contents: payload),
        ])
        let signedChecksumArchive = try editingFirstHeader(
            in: archive,
            checksumUsesSignedBytes: true
        ) { header in
            header.replaceSubrange(
                257..<265,
                with: [UInt8](repeating: 0, count: 8)
            )
            header[500] = 0xff
        }

        XCTAssertEqual(try FormatDetector.detect(data: signedChecksumArchive), .tar)
        let reader = try ArchiveReader.open(data: signedChecksumArchive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "signed.txt")
        XCTAssertEqual(try reader.read(entry), payload)
    }

    func testPAXMetadataRecordLimitAppliesAcrossGlobalAndLocalHeaders() throws {
        let firstGlobal = try paxPayload([
            ("path", Array("global-name.txt".utf8)),
        ])
        let secondGlobal = try paxPayload([
            ("uid", Array("501".utf8)),
        ])
        let local = try paxPayload([
            ("gid", Array("20".utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "GlobalOne", contents: firstGlobal, type: 0x67),
            HandTarEntry(name: "GlobalTwo", contents: secondGlobal, type: 0x67),
            HandTarEntry(name: "Local", contents: local, type: 0x78),
            HandTarEntry(name: "payload.txt"),
        ])
        var limits = ReadLimits()
        limits.maxMetadataRecordCount = 2

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testPAXMetadataRecordLimitCountsRepeatedKeys() throws {
        let metadata = try paxPayload([
            ("path", Array("first.txt".utf8)),
            ("path", Array("second.txt".utf8)),
            ("path", Array("third.txt".utf8)),
        ])
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "Local", contents: metadata, type: 0x78),
            HandTarEntry(name: "header-name.txt"),
        ])
        var limits = ReadLimits()
        limits.maxMetadataRecordCount = 2

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            self.assertLimitExceeded(error)
        }
    }

    func testPathComponentLimitRejectsEntryAndLinkPaths() throws {
        var limits = ReadLimits()
        limits.maxPathComponentCount = 2

        let boundaryArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "one/two"),
        ])
        let boundaryReader = try ArchiveReader.open(
            data: boundaryArchive,
            options: ReaderOptions(limits: limits)
        )
        XCTAssertEqual(boundaryReader.entries.map(\.name), ["one/two"])

        let deepEntryArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "one/two/three"),
        ])
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: deepEntryArchive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            self.assertLimitExceeded(error)
        }

        let deepLinkArchive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "link", type: 0x32, linkName: "one/two/target"),
        ])
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: deepLinkArchive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            self.assertLimitExceeded(error)
        }
    }

    func testTotalMetadataLimitCountsGlobalPAXValuesRepeatedAcrossEntries() throws {
        let repeatedPath = String(repeating: "global-name-", count: 8) + "file.txt"
        let pathMetadata = try paxPayload([
            ("path", Array(repeatedPath.utf8)),
        ])
        let ownerMetadata = try paxPayload([
            ("uid", Array("123456789".utf8)),
        ])
        let globalHeaders = [
            HandTarEntry(name: "GlobalPath", contents: pathMetadata, type: 0x67),
            HandTarEntry(name: "GlobalOwner", contents: ownerMetadata, type: 0x67),
        ]
        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 900

        let singleEntryArchive = try TarTestSupport.makeTar(
            entries: globalHeaders + [HandTarEntry(name: "first.txt")]
        )
        let singleReader = try ArchiveReader.open(
            data: singleEntryArchive,
            options: ReaderOptions(limits: limits)
        )
        XCTAssertEqual(singleReader.entries.map(\.name), [repeatedPath])
        XCTAssertEqual(singleReader.entries.first?.formatSpecific["uid"], "123456789")

        let repeatedEntryArchive = try TarTestSupport.makeTar(
            entries: globalHeaders + [
                HandTarEntry(name: "first.txt"),
                HandTarEntry(name: "second.txt"),
            ]
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: repeatedEntryArchive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            self.assertLimitExceeded(error)
        }
    }

    func testTotalMetadataLimitChargesPathComponentStorage() throws {
        let deepName = Array(repeating: "a", count: 40).joined(separator: "/")
        let flatName = String(repeating: "a", count: deepName.utf8.count)
        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 800

        let flat = try TarTestSupport.makeTar(entries: [HandTarEntry(name: flatName)])
        XCTAssertNoThrow(
            try ArchiveReader.open(data: flat, options: ReaderOptions(limits: limits))
        )

        let deep = try TarTestSupport.makeTar(entries: [HandTarEntry(name: deepName)])
        XCTAssertThrowsError(
            try ArchiveReader.open(data: deep, options: ReaderOptions(limits: limits))
        ) { error in
            self.assertLimitExceeded(error)
        }
    }

    private func assertNotFound(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case KaitoError.notFound = error else {
            return XCTFail("expected notFound, got \(error)", file: file, line: line)
        }
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    private func assertLimitExceeded(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case KaitoError.limitExceeded = error else {
            return XCTFail("expected limitExceeded, got \(error)", file: file, line: line)
        }
    }

    private func editingFirstHeader(
        in archive: Data,
        checksumUsesSignedBytes: Bool = false,
        mutation: (inout [UInt8]) -> Void
    ) throws -> Data {
        guard archive.count >= 512 else { throw KaitoError.truncated }
        var header = Array(archive.prefix(512))
        mutation(&header)
        for index in 148..<156 {
            header[index] = 0x20
        }
        let checksum: UInt64
        if checksumUsesSignedBytes {
            let signed = header.reduce(Int64(0)) {
                $0 + Int64(Int8(bitPattern: $1))
            }
            guard signed >= 0 else {
                throw TarTestSupportError.fieldTooLong("negative signed checksum")
            }
            checksum = UInt64(signed)
        } else {
            checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        }
        let digits = Array(String(checksum, radix: 8).utf8)
        guard digits.count <= 6 else {
            throw TarTestSupportError.fieldTooLong("checksum")
        }
        let field = [UInt8](repeating: 0x30, count: 6 - digits.count)
            + digits + [0, 0x20]
        header.replaceSubrange(148..<156, with: field)

        var result = archive
        result.replaceSubrange(result.startIndex..<(result.startIndex + 512), with: header)
        return result
    }

    private func paxPayload(_ records: [(String, [UInt8])]) throws -> Data {
        var result = Data()
        for (key, value) in records {
            let body = Array(key.utf8) + [0x3d] + value + [0x0a]
            var foundRecord: [UInt8]?
            for digitCount in 1...20 {
                let length = digitCount + 1 + body.count
                let prefix = Array(String(length).utf8)
                if prefix.count == digitCount {
                    foundRecord = prefix + [0x20] + body
                    break
                }
            }
            guard let foundRecord else {
                throw TarTestSupportError.fieldTooLong("pax record")
            }
            result.append(contentsOf: foundRecord)
        }
        return result
    }
}
