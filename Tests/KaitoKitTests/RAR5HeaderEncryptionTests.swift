import Foundation
@testable import KaitoKit
import XCTest

final class RAR5HeaderEncryptionTests: XCTestCase {
    func testPasswordProviderIsResolvedDuringOpenAndRetainedByReopen() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-provider")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(String(repeating: "provider header secret 日本語\n", count: 64).utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "provider.txt", below: source)
        let archive = temporary.appendingPathComponent("provider.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["provider.txt"],
            archiveURL: archive,
            options: ["-m0", "-s-", "-hpsecret"]
        )

        let provider = CountingRARPasswordProvider(password: "secret")
        let reader = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(passwordProvider: provider)
        )
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(reader.password, "secret")
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(try reader.read(entry), payload)

        let reopened = try reader.reopen()
        XCTAssertEqual(reopened.password, "secret")
        XCTAssertEqual(try reopened.read(entry), payload)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testHeaderEncryptedStoredFileSpanningVolumesRoundTripsAndReopens() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-volume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(
            count: 20 * 1_024 + 37,
            seed: 0x48_50_56_4f_4c
        )
        _ = try ZipTestSupport.write(payload, relativePath: "spanning.bin", below: source)
        let requestedArchive = temporary.appendingPathComponent("encrypted-volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["spanning.bin"],
            archiveURL: requestedArchive,
            options: ["-m0", "-s-", "-v8k", "-hpsecret"]
        )

        let volumes = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("encrypted-volume.part")
                && $0.pathExtension == "rar"
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
        XCTAssertGreaterThan(volumes.count, 1)
        let firstVolume = try XCTUnwrap(volumes.first)

        let reader = try ArchiveReader.open(
            url: firstVolume,
            options: ReaderOptions(password: "secret")
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.entries.map(\.name), ["spanning.bin"])
        XCTAssertTrue(entry.isEncrypted)
        XCTAssertEqual(entry.formatSpecific["multiVolume"], "true")
        XCTAssertEqual(
            entry.formatSpecific["volumeSegmentCount"],
            String(volumes.count)
        )
        XCTAssertEqual(try reader.read(entry), payload)
        XCTAssertEqual(try reader.reopen().read(entry), payload)

        let output = temporary.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let extracted = try reader.extract(entry, to: output)
        XCTAssertEqual(try Data(contentsOf: extracted), payload)

        var limits = ReadLimits()
        limits.maxVolumeCount = 1
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: firstVolume,
                options: ReaderOptions(limits: limits, password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .limitExceeded("RAR5 volume count"))
        }

        // Every continuation has its own plain type-4 envelope. The locator
        // validates it before the reader derives that volume's header key.
        var damagedContinuation = [UInt8](try Data(contentsOf: volumes[1]))
        damagedContinuation[RAR5Reader.signature.count] ^= 1
        try Data(damagedContinuation).write(to: volumes[1])
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: firstVolume,
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("volume main header CRC mismatch"), reason)
        }
    }

    func testHeaderEncryptionModeCannotChangeBetweenVolumes() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-mode-switch")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(
            count: 20 * 1_024 + 19,
            seed: 0x48_50_4d_4f_44_45
        )
        _ = try ZipTestSupport.write(payload, relativePath: "spanning.bin", below: source)

        let encryptedRequest = temporary.appendingPathComponent("encrypted-switch.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["spanning.bin"],
            archiveURL: encryptedRequest,
            options: ["-m0", "-s-", "-v8k", "-hpsecret"]
        )
        let plainRequest = temporary.appendingPathComponent("plain-switch.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["spanning.bin"],
            archiveURL: plainRequest,
            options: ["-m0", "-s-", "-v8k"]
        )

        let encryptedVolumes = try generatedVolumes(
            prefixed: "encrypted-switch.part",
            in: temporary
        )
        let plainVolumes = try generatedVolumes(
            prefixed: "plain-switch.part",
            in: temporary
        )
        XCTAssertGreaterThan(encryptedVolumes.count, 1)
        XCTAssertGreaterThan(plainVolumes.count, 1)
        let encryptedContinuation = try Data(contentsOf: encryptedVolumes[1])
        let plainContinuation = try Data(contentsOf: plainVolumes[1])
        let expected = KaitoError.malformed(
            "RAR5 header encryption mode changes between volumes"
        )

        // An encrypted first volume cannot transition to visible headers.
        try plainContinuation.write(to: encryptedVolumes[1])
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: encryptedVolumes[0],
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }

        // A visible first volume rejects an encrypted continuation before it
        // asks for a password or performs that continuation's KDF.
        try encryptedContinuation.write(to: plainVolumes[1])
        XCTAssertThrowsError(try ArchiveReader.open(url: plainVolumes[0])) { error in
            XCTAssertEqual(error as? KaitoError, expected)
        }
    }

    func testHeaderKDFWorkIsCumulativeAcrossDistinctVolumeContexts() throws {
        XCTAssertEqual(
            ReadLimits().maxRAR5HeaderKDFWork,
            4 * ((UInt64(1) << 24) + 32)
        )
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-kdf-work")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(
            count: 20 * 1_024 + 23,
            seed: 0x48_50_4b_44_46
        )
        _ = try ZipTestSupport.write(payload, relativePath: "spanning.bin", below: source)
        let requested = temporary.appendingPathComponent("work-volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["spanning.bin"],
            archiveURL: requested,
            options: ["-m0", "-s-", "-v8k", "-hpsecret"]
        )
        let volumes = try generatedVolumes(prefixed: "work-volume.part", in: temporary)
        XCTAssertGreaterThan(volumes.count, 1)

        let firstBytes = [UInt8](try Data(contentsOf: volumes[0]))
        let firstEnvelope = try RAR5HPTestParser.envelope(in: firstBytes)
        let oneDerivation = (UInt64(1) << UInt64(firstEnvelope.kdfCount)) + 32
        var limits = ReadLimits()
        limits.maxRAR5HeaderKDFWork = oneDerivation

        // RAR repeats one archive-header salt across ordinary volume sets. A
        // cache hit must not be charged as if another PBKDF2 run occurred.
        let reader = try ArchiveReader.open(
            url: volumes[0],
            options: ReaderOptions(limits: limits, password: "secret")
        )
        XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), payload)

        // A structurally valid but unusual continuation context would require
        // another derivation. Change only its salt: the cumulative budget must
        // reject it before attempting to decrypt the now-inconsistent headers.
        var continuation = [UInt8](try Data(contentsOf: volumes[1]))
        let continuationEnvelope = try RAR5HPTestParser.envelope(in: continuation)
        XCTAssertEqual(continuationEnvelope.kdfCount, firstEnvelope.kdfCount)
        XCTAssertEqual(
            Array(continuation[continuationEnvelope.salt]),
            Array(firstBytes[firstEnvelope.salt])
        )
        continuation[continuationEnvelope.salt.lowerBound] ^= 1
        RAR5TestSupport.repairHeaderCRC(
            &continuation,
            layout: continuationEnvelope.block
        )
        try Data(continuation).write(to: volumes[1])

        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: volumes[0],
                options: ReaderOptions(limits: limits, password: "secret")
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("RAR5 header encryption KDF work")
            )
        }
    }

    func testHeaderEncryptedNonFirstAndExplicitZeroVolumesCannotBecomeFirst() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-first-volume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = RAR5TestSupport.deterministicPayload(
            count: 20 * 1_024,
            seed: 0x48_50_46_49_52_53_54
        )
        _ = try ZipTestSupport.write(payload, relativePath: "split.bin", below: source)
        let requested = temporary.appendingPathComponent("source-volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["split.bin"],
            archiveURL: requested,
            options: ["-m0", "-s-", "-v8k", "-hpsecret"]
        )
        let volumes = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("source-volume.part")
                && $0.pathExtension == "rar"
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
        XCTAssertGreaterThan(volumes.count, 1)

        let secondBytes = [UInt8](try Data(contentsOf: volumes[1]))
        let nonzero = KaitoError.malformed(
            "RAR5 volume number 1 does not match expected 0"
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(secondBytes),
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, nonzero)
        }
        let renamed = temporary.appendingPathComponent("renamed.part1.rar")
        try Data(secondBytes).write(to: renamed)
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: renamed,
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, nonzero)
        }

        let explicitZeroBytes = try RAR5HPTestParser.replacingFirstMainVolumeNumber(
            in: secondBytes,
            password: "secret",
            with: 0
        )
        let explicitZero = KaitoError.malformed(
            "RAR5 first volume has an explicit volume number"
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(explicitZeroBytes),
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, explicitZero)
        }
        try Data(explicitZeroBytes).write(to: renamed)
        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: renamed,
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, explicitZero)
        }
    }

    func testHeaderEncryptedSolidGroupAcrossVolumesComposesAndRestarts() throws {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-hp-solid-volume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let names = ["first.bin", "second.bin", "third.bin"]
        let shared = RAR5TestSupport.deterministicPayload(
            count: 12 * 1_024,
            seed: 0x48_50_53_4f_4c_49_44
        )
        var payloads: [Data] = []
        for (index, name) in names.enumerated() {
            let boundary = Data(
                String(repeating: "solid encrypted member \(index) 日本語\n", count: 96).utf8
            )
            let payload = shared + boundary + shared
            payloads.append(payload)
            _ = try ZipTestSupport.write(payload, relativePath: name, below: source)
        }
        let requestedArchive = temporary.appendingPathComponent("solid-volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: requestedArchive,
            options: ["-m5", "-s", "-md1m", "-v8k", "-hpsecret", "-htb"]
        )
        let volumes = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("solid-volume.part")
                && $0.pathExtension == "rar"
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
        XCTAssertGreaterThan(volumes.count, 1)
        let firstVolume = try XCTUnwrap(volumes.first)

        XCTAssertThrowsError(
            try ArchiveReader.open(
                url: firstVolume,
                options: ReaderOptions(password: "wrong")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        let reader = try ArchiveReader.open(
            url: firstVolume,
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(reader.entries.map(\.name), names)
        XCTAssertEqual(reader.entries.map(\.solidGroup), [0, 0, 0])
        XCTAssertTrue(reader.entries.allSatisfy { $0.isEncrypted })
        XCTAssertGreaterThan(
            Int(reader.entries[0].formatSpecific["volumeSegmentCount"] ?? "0") ?? 0,
            1
        )
        for index in [2, 0, 1, 2] {
            XCTAssertEqual(try reader.read(reader.entries[index]), payloads[index])
        }
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[1]), payloads[1])

        // With visible headers (`-p`), the same split archive uses tweaked
        // password-dependent hashes for non-final packed parts. Reading the
        // last member authenticates those parts while draining predecessors.
        let visibleRequested = temporary.appendingPathComponent("visible-solid-volume.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: names,
            archiveURL: visibleRequested,
            options: ["-m5", "-s", "-md1m", "-v8k", "-psecret", "-htb"]
        )
        let visibleFirst = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: temporary,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix("visible-solid-volume.part")
                    && $0.pathExtension == "rar"
            }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }.first
        )
        let visibleReader = try ArchiveReader.open(
            url: visibleFirst,
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(
            try visibleReader.read(visibleReader.entries[2]),
            payloads[2]
        )
    }

    func testArchiveEncryptionEnvelopeVersionKDFAndMetadataLimitsAreStrict() throws {
        let fixture = try makeFixture(label: "rar5-hp-limits")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = [UInt8](try Data(contentsOf: fixture.archive))
        let envelope = try RAR5HPTestParser.envelope(in: original)

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(original),
                options: ReaderOptions(password: "secret", maxRAR5KDFCountPower: 0)
            )
        ) { error in
            guard case let .unsupportedMethod(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("KDF count"), reason)
        }

        var smallMetadata = ReadLimits()
        // The 33-byte unencrypted envelope and small main header fit. The
        // encrypted file header, which includes encryption metadata, does not.
        smallMetadata.maxMetadataSize = 64
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(original),
                options: ReaderOptions(limits: smallMetadata, password: "secret")
            )
        ) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        var unsupportedVersion = original
        XCTAssertEqual(envelope.versionField.count, 1)
        unsupportedVersion[envelope.versionField.lowerBound] = 1
        RAR5TestSupport.repairHeaderCRC(
            &unsupportedVersion,
            layout: envelope.block
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(unsupportedVersion),
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("RAR5 archive encryption version 1")
            )
        }

        var unsupportedFlags = original
        XCTAssertEqual(envelope.flagsField.count, 1)
        unsupportedFlags[envelope.flagsField.lowerBound] = 3
        RAR5TestSupport.repairHeaderCRC(
            &unsupportedFlags,
            layout: envelope.block
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(unsupportedFlags),
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("RAR5 archive encryption flags 0x3")
            )
        }
    }

    func testEncryptedHeaderCRCSizeArbitraryPaddingAndTruncation() throws {
        let fixture = try makeFixture(label: "rar5-hp-framing")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = [UInt8](try Data(contentsOf: fixture.archive))
        let envelope = try RAR5HPTestParser.envelope(in: original)
        let blocks = try RAR5HPTestParser.encryptedBlocks(
            in: original,
            password: "secret"
        )
        let main = try XCTUnwrap(blocks.first { $0.type == 1 })
        let file = try XCTUnwrap(blocks.first { $0.type == 2 })
        let end = try XCTUnwrap(blocks.first { $0.type == 5 })

        var badEnvelopeCRC = original
        badEnvelopeCRC[envelope.block.offset] ^= 1
        assertOpen(
            Data(badEnvelopeCRC),
            failsMalformedContaining: "header CRC mismatch"
        )

        // The check field is advisory and carries its own four-byte checksum.
        // When that checksum is damaged, rar ignores the field and verifies
        // the password by decrypting the first header instead.
        var damagedPasswordCheck = original
        let passwordCheck = try XCTUnwrap(envelope.checkValue)
        damagedPasswordCheck[passwordCheck.lowerBound] ^= 1
        RAR5TestSupport.repairHeaderCRC(
            &damagedPasswordCheck,
            layout: envelope.block
        )
        let fallbackReader = try ArchiveReader.open(
            data: Data(damagedPasswordCheck),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(
            try fallbackReader.read(try XCTUnwrap(fallbackReader.entries.first)),
            fixture.payload
        )
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(damagedPasswordCheck),
                options: ReaderOptions(password: "wrong")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        // CBC's first plaintext block is D(C0) xor IV. Changing IV byte zero
        // therefore corrupts only the encrypted header's recorded CRC32.
        var badEncryptedCRC = original
        badEncryptedCRC[file.initializationVector.lowerBound] ^= 1
        assertOpen(
            Data(badEncryptedCRC),
            failsMalformedContaining: "encrypted header CRC mismatch"
        )

        // Make the main header size a four-byte padded vint without modifying
        // any other plaintext byte. Header-size fields are capped at 3 bytes.
        var longSizeVInt = original
        let replacement: [UInt8] = [0x80, 0x80, 0x80, 0x00]
        for index in replacement.indices {
            let plaintextIndex = 4 + index
            longSizeVInt[main.initializationVector.lowerBound + plaintextIndex]
                ^= main.plaintext[plaintextIndex] ^ replacement[index]
        }
        assertOpen(
            Data(longSizeVInt),
            failsMalformedContaining: "header-size vint exceeds 3 bytes"
        )

        XCTAssertEqual(end.ciphertext.count, 16)
        XCTAssertLessThan(end.logicalPlaintextSize, 16)
        var nonzeroPadding = original
        nonzeroPadding[
            end.initializationVector.lowerBound + end.logicalPlaintextSize
        ] ^= 1
        let paddingReader = try ArchiveReader.open(
            data: Data(nonzeroPadding),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(paddingReader.entries.count, 1)

        let truncated = Data(original.prefix(main.ciphertext.upperBound - 1))
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: truncated,
                options: ReaderOptions(password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
    }

    func testArchiveWithoutPasswordCheckUsesFirstEncryptedHeaderAsVerifier() throws {
        let fixture = try makeFixture(label: "rar5-hp-no-check")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var bytes = [UInt8](try Data(contentsOf: fixture.archive))
        let envelope = try RAR5HPTestParser.envelope(in: bytes)
        let check = try XCTUnwrap(envelope.checkValue)
        XCTAssertEqual(envelope.flags, 1)
        XCTAssertEqual(envelope.block.sizeField.count, 1)
        XCTAssertEqual(envelope.flagsField.count, 1)

        bytes[envelope.flagsField.lowerBound] = 0
        bytes.removeSubrange(check)
        bytes[envelope.block.sizeField.lowerBound] = UInt8(
            envelope.block.body.count - check.count
        )
        let shortened = try RAR5HPTestParser.envelope(in: bytes)
        RAR5TestSupport.repairHeaderCRC(&bytes, layout: shortened.block)

        XCTAssertThrowsError(try ArchiveReader.open(data: Data(bytes))) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: Data(bytes),
                options: ReaderOptions(password: "wrong")
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        let reader = try ArchiveReader.open(
            data: Data(bytes),
            options: ReaderOptions(password: "secret")
        )
        XCTAssertEqual(try reader.read(try XCTUnwrap(reader.entries.first)), fixture.payload)
    }

    private func makeFixture(
        label: String
    ) throws -> (directory: URL, archive: URL, payload: Data) {
        try RAR5TestSupport.requireRAR()
        let temporary = try ZipTestSupport.temporaryDirectory(label: label)
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(String(repeating: "strict encrypted header 日本語\n", count: 32).utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "hidden.txt", below: source)
        let archive = temporary.appendingPathComponent("header-encrypted.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["hidden.txt"],
            archiveURL: archive,
            options: ["-m0", "-s-", "-hpsecret"]
        )
        return (temporary, archive, payload)
    }

    private func generatedVolumes(
        prefixed prefix: String,
        in directory: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "rar"
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    private func assertOpen(
        _ data: Data,
        failsMalformedContaining expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: data,
                options: ReaderOptions(password: "secret")
            ),
            file: file,
            line: line
        ) { error in
            guard case let .malformed(reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(expected), reason, file: file, line: line)
        }
    }
}

private final class CountingRARPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let password: String?
    private var requests = 0

    init(password: String?) { self.password = password }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func password(for format: ArchiveFormat) throws -> String? {
        lock.lock()
        requests += 1
        lock.unlock()
        XCTAssertEqual(format, .rar)
        return password
    }
}

private enum RAR5HPTestParser {
    struct Envelope {
        let block: RAR5TestSupport.BlockLayout
        let versionField: Range<Int>
        let flagsField: Range<Int>
        let flags: UInt64
        let kdfCount: UInt8
        let salt: Range<Int>
        let checkValue: Range<Int>?
    }

    struct EncryptedBlock {
        let type: UInt64
        let initializationVector: Range<Int>
        let ciphertext: Range<Int>
        let data: Range<Int>
        let logicalPlaintextSize: Int
        let plaintext: [UInt8]
    }

    static func envelope(in bytes: [UInt8]) throws -> Envelope {
        let block = try ordinaryBlock(in: bytes, offset: RAR5Reader.signature.count)
        var cursor = block.body.lowerBound
        guard try readVInt(bytes, cursor: &cursor, limit: block.body.upperBound) == 4,
              try readVInt(bytes, cursor: &cursor, limit: block.body.upperBound) == 0 else {
            throw KaitoError.malformed("test fixture lacks a plain type-4 header")
        }

        let versionStart = cursor
        _ = try readVInt(bytes, cursor: &cursor, limit: block.body.upperBound)
        let versionField = versionStart..<cursor
        let flagsStart = cursor
        let flags = try readVInt(bytes, cursor: &cursor, limit: block.body.upperBound)
        let flagsField = flagsStart..<cursor
        guard cursor < block.body.upperBound else { throw KaitoError.truncated }
        let kdfCount = bytes[cursor]
        cursor += 1
        let salt = try boundedRange(start: cursor, count: 16, limit: block.body.upperBound)
        cursor = salt.upperBound
        let checkValue: Range<Int>?
        if flags & 1 != 0 {
            checkValue = try boundedRange(start: cursor, count: 12, limit: block.body.upperBound)
            cursor = checkValue!.upperBound
        } else {
            checkValue = nil
        }
        guard cursor == block.body.upperBound else {
            throw KaitoError.malformed("test fixture archive-encryption fields trail")
        }
        return Envelope(
            block: block,
            versionField: versionField,
            flagsField: flagsField,
            flags: flags,
            kdfCount: kdfCount,
            salt: salt,
            checkValue: checkValue
        )
    }

    static func encryptedBlocks(
        in bytes: [UInt8],
        password: String
    ) throws -> [EncryptedBlock] {
        let envelope = try envelope(in: bytes)
        let keys = try RAR5KeyDerivation.derive(
            password: password,
            salt: Array(bytes[envelope.salt]),
            count: envelope.kdfCount
        )
        let source = DataByteSource(data: Data(bytes))
        var offset = envelope.block.data.upperBound
        var result: [EncryptedBlock] = []

        while offset < bytes.count {
            let iv = try boundedRange(start: offset, count: 16, limit: bytes.count)
            let firstCiphertext = try boundedRange(
                start: iv.upperBound,
                count: 16,
                limit: bytes.count
            )
            let firstSource = try RARAESCBCByteSource(
                source: source,
                ciphertextOffset: UInt64(firstCiphertext.lowerBound),
                ciphertextSize: 16,
                plaintextSize: 16,
                key: keys.encryptionKey,
                initializationVector: Data(bytes[iv])
            )
            let first = try readByteRange(source: firstSource, offset: 0, count: 16)
            var sizeCursor = 4
            let headerSize = try readVInt(
                first,
                cursor: &sizeCursor,
                limit: first.count
            )
            guard headerSize <= UInt64(Int.max - sizeCursor) else {
                throw KaitoError.malformed("test fixture header is too large")
            }
            let logicalSize = sizeCursor + Int(headerSize)
            let ciphertextSize = (logicalSize + 15) & ~15
            let ciphertext = try boundedRange(
                start: iv.upperBound,
                count: ciphertextSize,
                limit: bytes.count
            )
            let plaintextSource = try RARAESCBCByteSource(
                source: source,
                ciphertextOffset: UInt64(ciphertext.lowerBound),
                ciphertextSize: UInt64(ciphertext.count),
                plaintextSize: UInt64(ciphertext.count),
                key: keys.encryptionKey,
                initializationVector: Data(bytes[iv])
            )
            let plaintext = try readByteRange(
                source: plaintextSource,
                offset: 0,
                count: ciphertext.count
            )

            var bodyCursor = sizeCursor
            let type = try readVInt(
                plaintext,
                cursor: &bodyCursor,
                limit: logicalSize
            )
            let flags = try readVInt(
                plaintext,
                cursor: &bodyCursor,
                limit: logicalSize
            )
            if flags & 1 != 0 {
                _ = try readVInt(
                    plaintext,
                    cursor: &bodyCursor,
                    limit: logicalSize
                )
            }
            let dataSize = flags & 2 != 0
                ? try readVInt(plaintext, cursor: &bodyCursor, limit: logicalSize)
                : 0
            guard dataSize <= UInt64(Int.max) else {
                throw KaitoError.malformed("test fixture data is too large")
            }
            let data = try boundedRange(
                start: ciphertext.upperBound,
                count: Int(dataSize),
                limit: bytes.count
            )
            result.append(EncryptedBlock(
                type: type,
                initializationVector: iv,
                ciphertext: ciphertext,
                data: data,
                logicalPlaintextSize: logicalSize,
                plaintext: plaintext
            ))
            offset = data.upperBound
            if type == 5 { break }
        }
        return result
    }

    static func replacingFirstMainVolumeNumber(
        in bytes: [UInt8],
        password: String,
        with replacement: UInt8
    ) throws -> [UInt8] {
        let main = try XCTUnwrap(
            encryptedBlocks(in: bytes, password: password).first { $0.type == 1 }
        )
        guard main.ciphertext.count >= 16,
              main.plaintext.count >= 16,
              main.logicalPlaintextSize <= main.plaintext.count else {
            throw KaitoError.truncated
        }
        var changed = main.plaintext
        var cursor = 4
        _ = try readVInt(changed, cursor: &cursor, limit: main.logicalPlaintextSize)
        guard try readVInt(changed, cursor: &cursor, limit: main.logicalPlaintextSize) == 1 else {
            throw KaitoError.malformed("test fixture lacks an encrypted main header")
        }
        let commonFlags = try readVInt(
            changed,
            cursor: &cursor,
            limit: main.logicalPlaintextSize
        )
        if commonFlags & 1 != 0 {
            _ = try readVInt(changed, cursor: &cursor, limit: main.logicalPlaintextSize)
        }
        if commonFlags & 2 != 0 {
            _ = try readVInt(changed, cursor: &cursor, limit: main.logicalPlaintextSize)
        }
        let archiveFlags = try readVInt(
            changed,
            cursor: &cursor,
            limit: main.logicalPlaintextSize
        )
        guard archiveFlags & 3 == 3 else {
            throw KaitoError.malformed("test fixture main header is not numbered")
        }
        let numberStart = cursor
        _ = try readVInt(changed, cursor: &cursor, limit: main.logicalPlaintextSize)
        guard cursor == numberStart + 1 else {
            throw KaitoError.malformed("test fixture volume number is not one byte")
        }
        changed[numberStart] = replacement

        let checksum = CRC32.checksum(
            Array(changed[4..<main.logicalPlaintextSize])
        )
        for index in 0..<4 {
            changed[index] = UInt8(truncatingIfNeeded: checksum >> (index * 8))
        }

        var result = bytes
        // CBC's first plaintext block is D(C0) xor IV. All changed fields fit
        // in that block, so adjust the IV without requiring an encryptor.
        for index in 0..<16 where changed[index] != main.plaintext[index] {
            result[main.initializationVector.lowerBound + index]
                ^= changed[index] ^ main.plaintext[index]
        }
        return result
    }

    private static func ordinaryBlock(
        in bytes: [UInt8],
        offset: Int
    ) throws -> RAR5TestSupport.BlockLayout {
        let crcEnd = try boundedRange(start: offset, count: 4, limit: bytes.count).upperBound
        var cursor = crcEnd
        let sizeStart = cursor
        let headerSize = try readVInt(bytes, cursor: &cursor, limit: bytes.count)
        let sizeField = sizeStart..<cursor
        guard headerSize <= UInt64(Int.max - cursor) else { throw KaitoError.truncated }
        let body = try boundedRange(
            start: cursor,
            count: Int(headerSize),
            limit: bytes.count
        )
        var bodyCursor = body.lowerBound
        _ = try readVInt(bytes, cursor: &bodyCursor, limit: body.upperBound)
        let flags = try readVInt(bytes, cursor: &bodyCursor, limit: body.upperBound)
        if flags & 1 != 0 {
            _ = try readVInt(bytes, cursor: &bodyCursor, limit: body.upperBound)
        }
        let dataSize = flags & 2 != 0
            ? try readVInt(bytes, cursor: &bodyCursor, limit: body.upperBound)
            : 0
        guard dataSize <= UInt64(Int.max) else { throw KaitoError.truncated }
        let data = try boundedRange(
            start: body.upperBound,
            count: Int(dataSize),
            limit: bytes.count
        )
        return RAR5TestSupport.BlockLayout(
            offset: offset,
            sizeField: sizeField,
            body: body,
            data: data
        )
    }

    private static func readVInt(
        _ bytes: [UInt8],
        cursor: inout Int,
        limit: Int
    ) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard cursor < limit, cursor < bytes.count else { throw KaitoError.truncated }
            let byte = bytes[cursor]
            cursor += 1
            let shift = index * 7
            if shift < 64 {
                let useful = min(7, 64 - shift)
                value |= (UInt64(byte & 0x7f) & ((UInt64(1) << useful) - 1)) << shift
            }
            if byte & 0x80 == 0 { return value }
        }
        throw KaitoError.malformed("test fixture vint exceeds 10 bytes")
    }

    private static func boundedRange(
        start: Int,
        count: Int,
        limit: Int
    ) throws -> Range<Int> {
        guard start >= 0, count >= 0, start <= limit, count <= limit - start else {
            throw KaitoError.truncated
        }
        return start..<(start + count)
    }
}
