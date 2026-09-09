import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

private struct ZipFixedPasswordProvider: PasswordProvider {
    let value: String?

    func password(for format: ArchiveFormat) throws -> String? {
        XCTAssertEqual(format, .zip)
        return value
    }
}

final class ZipHardeningTests: XCTestCase {
    func testIncompleteUnencryptedStoredEntryMatchesOriginalPrefix() throws {
        let original = Data((0..<(2 * 1_024 * 1_024)).map {
            UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16))
        })
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "stored", uncompressedData: original, method: 0),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let dataOffset = layout.localHeaderOffsets[0] + 30 + "stored".utf8.count
        let survived = 1_024 * 1_024 + 193
        let reader = try ArchiveReader.open(
            data: Data(archive.prefix(dataOffset + survived)),
            options: ReaderOptions(recoverDamagedArchives: true)
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isIncomplete)
        XCTAssertFalse(entry.isEncrypted)
        XCTAssertEqual(entry.uncompressedSize, UInt64(original.count))
        let payload = try reader.read(entry)
        XCTAssertEqual(payload.count, survived)
        XCTAssertEqual(payload, Data(original.prefix(survived)))
    }

    func testRecoveryRetainsStoredPayloadPrefixesAndRejectsCompleteCRCFailures() throws {
        let first = Data("complete payload".utf8)
        let last = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first", uncompressedData: first),
            HandZipEntry(name: "last", uncompressedData: last),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let dataOffset = layout.localHeaderOffsets[1] + 30 + 4
        let options = ReaderOptions(recoverDamagedArchives: true)
        for survived in [0, 1, 1_023, 4_096] {
            let cut = Data(archive.prefix(dataOffset + survived))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { error in
                guard case KaitoError.malformed(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(message, "ZIP end-of-central-directory record was not found")
            }
            let reader = try ArchiveReader.open(data: cut, options: options)
            XCTAssertEqual(reader.entries.map(\.name), ["first", "last"])
            XCTAssertFalse(reader.entries[0].isIncomplete)
            XCTAssertEqual(reader.entries[1].isIncomplete, survived < last.count)
            XCTAssertEqual(try reader.read(reader.entries[0]), first)
            XCTAssertEqual(try reader.read(reader.entries[1]), last.prefix(survived))
        }
        let partialHeader = Data(archive.prefix(layout.localHeaderOffsets[1] + 20))
        let reader = try ArchiveReader.open(data: partialHeader, options: options)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(try reader.read(reader.entries[0]), first)
        var corrupt = Data(archive.prefix(dataOffset + 20))
        corrupt[30 + 5] ^= 1
        let corruptReader = try ArchiveReader.open(data: corrupt, options: options)
        XCTAssertThrowsError(try corruptReader.read(corruptReader.entries[0])) { error in
            guard case KaitoError.checksumMismatch(entry: 0) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRecoveryEOCDAbsenceDoesNotRelaxCentralDirectoryErrorsOrLimits() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "one", uncompressedData: Data("one".utf8)),
            HandZipEntry(name: "two", uncompressedData: Data("two".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        var missingEnd = archive
        try ZipTestSupport.writeUInt32(0, to: &missingEnd, at: layout.endRecordOffset)
        XCTAssertThrowsError(try ArchiveReader.open(data: missingEnd))
        let recovered = try ArchiveReader.open(
            data: missingEnd, options: ReaderOptions(recoverDamagedArchives: true)
        )
        XCTAssertEqual(recovered.entries.map(\.name), ["one", "two"])
        for entry in recovered.entries {
            XCTAssertFalse(entry.isIncomplete)
            XCTAssertEqual(try recovered.read(entry), Data(entry.name.utf8))
        }
        var corruptDirectory = archive
        try ZipTestSupport.writeUInt32(0, to: &corruptDirectory, at: layout.centralDirectoryOffset)
        for recovery in [false, true] {
            XCTAssertThrowsError(try ArchiveReader.open(
                data: corruptDirectory, options: ReaderOptions(recoverDamagedArchives: recovery)
            ))
        }
        for limits in [
            ReadLimits(maxEntrySize: 2), ReadLimits(maxTotalUncompressedSize: 5),
            ReadLimits(maxEntryCount: 1), ReadLimits(maxMetadataSize: 29),
            ReadLimits(maxTotalMetadataSize: 1), ReadLimits(maxPathComponentCount: 0),
        ] {
            assertLimitExceeded {
                try ArchiveReader.open(data: missingEnd, options: ReaderOptions(
                    limits: limits, recoverDamagedArchives: true
                ))
            }
        }
    }

    func testRecoveryDataDescriptorsBoundDeflateAndStoredEntries() throws {
        let payload = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        // 最終の非圧縮 DEFLATE block を既存 ZIP helper に渡す。
        var deflate = Data([1, 0, 16, 255, 239])
        deflate.append(payload)
        for method: UInt16 in [0, 8] {
            let packed = method == 0 ? payload : deflate
            let archive = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(name: "one", uncompressedData: payload, compressedData: packed,
                             method: method, hasDataDescriptor: true),
                HandZipEntry(name: "two", uncompressedData: payload, compressedData: packed,
                             method: method, hasDataDescriptor: true),
            ])
            let layout = try ZipTestSupport.layout(of: archive)
            let options = ReaderOptions(recoverDamagedArchives: true)
            for end in [layout.centralDirectoryOffset, archive.count] {
                var missingEnd = Data(archive.prefix(end))
                if end == archive.count {
                    try ZipTestSupport.writeUInt32(0, to: &missingEnd, at: layout.endRecordOffset)
                }
                let reader = try ArchiveReader.open(data: missingEnd, options: options)
                XCTAssertEqual(reader.entries.count, 2)
                for entry in reader.entries {
                    XCTAssertFalse(entry.isIncomplete)
                    XCTAssertEqual(try reader.read(entry), payload)
                }
            }
            let survived = 777
            let cut = Data(archive.prefix(
                layout.localHeaderOffsets[1] + 33 + (method == 8 ? 5 : 0) + survived
            ))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut))
            let reader = try ArchiveReader.open(data: cut, options: options)
            XCTAssertEqual(reader.entries.count, 2)
            XCTAssertTrue(reader.entries[1].isIncomplete)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(try reader.read(reader.entries[1]), payload.prefix(survived))
            assertLimitExceeded {
                let limited = try ArchiveReader.open(data: cut, options: ReaderOptions(
                    limits: ReadLimits(maxTotalMetadataSize: 100), recoverDamagedArchives: true
                ))
                return try limited.read(limited.entries[0])
            }
        }
    }


    func testRecoveryClipsEncryptedPayloadWithoutTreatingCiphertextAsAuthentication() throws {
        let password = "recovery-password"
        let payload = Data(repeating: 0xA5, count: 1_024)
        let salt = Data(repeating: 0x5A, count: 16)
        let keys = try WinZipAESDerivedKeys.derive(for: WinZipAESKeyCacheKey(
            password: password, salt: salt, strength: .aes256
        ))
        var ctr = try WinZipAESCTR(encryptionKey: keys.encryptionKey)
        let ciphertext = try ctr.transform(payload)
        let authentication = Data(HMAC<Insecure.SHA1>.authenticationCode(
            for: ciphertext, using: SymmetricKey(data: keys.authenticationKey)
        ).prefix(10))
        let packed = salt + keys.passwordVerifier + ciphertext + authentication
        let extra = try ZipTestSupport.extraField(
            identifier: 0x9901, payload: Data([2, 0, 65, 69, 3, 0, 0])
        )
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "secret", uncompressedData: payload, compressedData: packed,
                         method: 99, flags: 0x0801, localExtra: extra, centralExtra: extra,
                         centralCRC32: 0, localCRC32: 0),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let dataOffset = 30 + 6 + extra.count
        let options = ReaderOptions(password: password, recoverDamagedArchives: true)
        for survived in [0, 1, 777, 1_024] {
            let cut = Data(archive.prefix(dataOffset + 18 + survived))
            XCTAssertThrowsError(try ArchiveReader.open(data: cut))
            let reader = try ArchiveReader.open(data: cut, options: options)
            XCTAssertTrue(reader.entries[0].isIncomplete)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload.prefix(survived))
        }
        let shortHeader = try ArchiveReader.open(
            data: Data(archive.prefix(dataOffset + 5)), options: options
        )
        XCTAssertTrue(shortHeader.entries[0].isIncomplete)
        XCTAssertEqual(try shortHeader.read(shortHeader.entries[0]), Data())
        var complete = Data(archive.prefix(layout.centralDirectoryOffset))
        let recovered = try ArchiveReader.open(data: complete, options: options)
        XCTAssertFalse(recovered.entries[0].isIncomplete)
        XCTAssertEqual(try recovered.read(recovered.entries[0]), payload)
        complete[complete.count - 1] ^= 1
        let corrupt = try ArchiveReader.open(data: complete, options: options)
        XCTAssertThrowsError(try corrupt.read(corrupt.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testAggregateMetadataBudgetIsPreflightedBeforeEntryParsing() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first.txt"),
            HandZipEntry(name: "second.txt"),
        ])
        let central = try XCTUnwrap(
            ZipTestSupport.layout(of: archive).centralEntryOffsets.first
        )
        // 保持する各 entry の最低コストは 256 バイト。先頭 header も壊しておき、
        // parse や配列予約より前に合計上限を検査することを確認する。
        try ZipTestSupport.writeUInt32(0xDEAD_BEEF, to: &archive, at: central)

        var limits = ReadLimits()
        limits.maxTotalMetadataSize = 511
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: limits))
        }
    }

    func testCentralDirectoryCountMustMatchParsedEntries() throws {
        let valid = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "one.txt", uncompressedData: Data("one".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: valid)

        var tooFew = valid
        try ZipTestSupport.writeUInt16(0, to: &tooFew, at: layout.endRecordOffset + 8)
        try ZipTestSupport.writeUInt16(0, to: &tooFew, at: layout.endRecordOffset + 10)
        assertMalformed { try ArchiveReader.open(data: tooFew) }

        var tooMany = valid
        try ZipTestSupport.writeUInt16(2, to: &tooMany, at: layout.endRecordOffset + 8)
        try ZipTestSupport.writeUInt16(2, to: &tooMany, at: layout.endRecordOffset + 10)
        assertMalformed { try ArchiveReader.open(data: tooMany) }
    }

    func testCentralDirectoryOffsetBeyondEOFIsRejected() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "payload.txt", uncompressedData: Data("payload".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        try ZipTestSupport.writeUInt32(
            UInt32.max - 1,
            to: &archive,
            at: layout.endRecordOffset + 16
        )
        assertMalformed { try ArchiveReader.open(data: archive) }
    }

    func testCentralVariableLengthsCannotOverrunAndUnparsableExtraTailIsIgnored() throws {
        let valid = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "short.txt", uncompressedData: Data("value".utf8)),
        ])
        let central = try XCTUnwrap(ZipTestSupport.layout(of: valid).centralEntryOffsets.first)

        var badName = valid
        try ZipTestSupport.writeUInt16(UInt16.max, to: &badName, at: central + 28)
        assertMalformed { try ArchiveReader.open(data: badName) }

        var badExtraLength = valid
        try ZipTestSupport.writeUInt16(UInt16.max, to: &badExtraLength, at: central + 30)
        assertMalformed { try ArchiveReader.open(data: badExtraLength) }

        let malformedExtra = Data([0x55, 0x78, 0x0A, 0x00, 0x01])
        let badNestedExtra = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "extra.txt", centralExtra: malformedExtra),
        ])
        let reader = try ArchiveReader.open(data: badNestedExtra)
        XCTAssertEqual(reader.entries.map(\.name), ["extra.txt"])
    }

    func testImpossibleDOSCalendarDateDegradesToMissingDate() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "invalid-date.txt"),
        ])
        let central = try XCTUnwrap(
            ZipTestSupport.layout(of: archive).centralEntryOffsets.first
        )
        // 2020-02-31。Foundation Calendar は検証しなければ 3 月へ正規化する。
        try ZipTestSupport.writeUInt16(0x505F, to: &archive, at: central + 14)
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertNil(reader.entries[0].modificationDate)
    }

    func testZIP64SignedHighBitAndOversizedDirectoryValuesAreRejected() throws {
        let oversizedEntry = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "huge.bin",
                centralExtra: try ZipTestSupport.zip64Extra(values: [UInt64.max]),
                centralUncompressedSize: UInt32.max
            ),
        ])
        assertLimitExceeded { try ArchiveReader.open(data: oversizedEntry) }

        var oversizedCount = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "one.txt")],
            forceZIP64End: true
        )
        let countLayout = try ZipTestSupport.layout(of: oversizedCount)
        let countRecord = try XCTUnwrap(countLayout.zip64EndRecordOffset)
        try ZipTestSupport.writeUInt64(UInt64.max, to: &oversizedCount, at: countRecord + 24)
        try ZipTestSupport.writeUInt64(UInt64.max, to: &oversizedCount, at: countRecord + 32)
        assertLimitExceeded { try ArchiveReader.open(data: oversizedCount) }

        var oversizedOffset = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "one.txt")],
            forceZIP64End: true
        )
        let offsetRecord = try XCTUnwrap(
            ZipTestSupport.layout(of: oversizedOffset).zip64EndRecordOffset
        )
        try ZipTestSupport.writeUInt64(UInt64.max, to: &oversizedOffset, at: offsetRecord + 48)
        assertMalformed { try ArchiveReader.open(data: oversizedOffset) }
    }

    func testZIP64CompressedSizeIsLimitedBeforeLocalHeaderAccess() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "compressed-bomb.bin",
                uncompressedData: Data([0]),
                centralExtra: try ZipTestSupport.zip64Extra(values: [129]),
                centralCompressedSize: UInt32.max
            ),
        ])
        var limits = ReadLimits()
        limits.maxEntrySize = 128
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: limits))
        }
    }

    func testZIP64ArchiveWithSFXPrefixUsesRelativeOffsets() throws {
        let payload = Data("ZIP64 plus self-extracting prefix\n".utf8)
        let prefix = ZipTestSupport.makePEPrefix(count: 1_024, fill: 0xA5)
        let archive = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "prefixed.txt", uncompressedData: payload)],
            prefix: prefix,
            forceZIP64End: true
        )
        XCTAssertEqual(try ZipTestSupport.layout(of: archive).archiveBase, prefix.count)

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(scanForSFXInData: true)
        )
        XCTAssertEqual(reader.entries.map(\.name), ["prefixed.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testStrongEncryptionBitIsRejectedInCentralAndDeferredLocalHeaders() throws {
        let centralStrong = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "central-strong.bin", flags: 0x0841),
        ])
        assertStrongEncryptionUnsupported {
            try ArchiveReader.open(data: centralStrong)
        }

        var localStrong = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "local-strong.bin",
                compressedData: Data(repeating: 0, count: 12),
                flags: 0x0801
            ),
        ])
        let local = try XCTUnwrap(
            ZipTestSupport.layout(of: localStrong).localHeaderOffsets.first
        )
        try ZipTestSupport.writeUInt16(0x0841, to: &localStrong, at: local + 6)

        let lazy = try ArchiveReader.open(
            data: localStrong,
            options: ReaderOptions(password: "unused")
        )
        assertStrongEncryptionUnsupported { try lazy.read(lazy.entries[0]) }
        assertStrongEncryptionUnsupported {
            try ArchiveReader.open(
                data: localStrong,
                options: ReaderOptions(
                    password: "unused",
                    lazyLocalHeaders: false
                )
            )
        }
    }

    func testLocalAndCentralEncryptionFlagsMustAgreeInLazyAndEagerModes() throws {
        for (centralFlags, localFlags): (UInt16, UInt16) in [
            (0x0800, 0x0801),
            (0x0801, 0x0800),
        ] {
            var archive = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(
                    name: "encryption-mismatch.bin",
                    uncompressedData: Data("payload".utf8),
                    flags: centralFlags
                ),
            ])
            let local = try XCTUnwrap(
                ZipTestSupport.layout(of: archive).localHeaderOffsets.first
            )
            try ZipTestSupport.writeUInt16(localFlags, to: &archive, at: local + 6)

            let lazy = try ArchiveReader.open(data: archive)
            assertMalformed { try lazy.read(lazy.entries[0]) }
            assertMalformed {
                try ArchiveReader.open(
                    data: archive,
                    options: ReaderOptions(lazyLocalHeaders: false)
                )
            }
        }
    }

    func testWinZipAE2RequiresZeroCentralCRC() throws {
        let aesExtra = try ZipTestSupport.extraField(
            identifier: 0x9901,
            payload: Data([0x02, 0x00, 0x41, 0x45, 0x03, 0x00, 0x00])
        )
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "ae2.bin",
                method: 99,
                flags: 0x0801,
                localExtra: aesExtra,
                centralExtra: aesExtra,
                centralCRC32: 1
            ),
        ])
        assertMalformed { try ArchiveReader.open(data: archive) }
    }

    func testMultiDiskMetadataIsRejectedForZIP32AndZIP64() throws {
        var zip32 = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "one.txt")])
        let zip32End = try ZipTestSupport.layout(of: zip32).endRecordOffset
        try ZipTestSupport.writeUInt16(1, to: &zip32, at: zip32End + 4)
        try ZipTestSupport.writeUInt16(1, to: &zip32, at: zip32End + 6)
        assertSpanned { try ArchiveReader.open(data: zip32) }

        var zip64 = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "one.txt")],
            forceZIP64End: true
        )
        let locator = try XCTUnwrap(ZipTestSupport.layout(of: zip64).zip64LocatorOffset)
        try ZipTestSupport.writeUInt32(1, to: &zip64, at: locator + 4)
        assertSpanned { try ArchiveReader.open(data: zip64) }
    }

    func testZIP32AndZIP64EndRecordCountsMustAgree() throws {
        var archive = try ZipTestSupport.makeArchive(
            entries: [HandZipEntry(name: "one.txt")],
            forceZIP64End: true
        )
        let end = try ZipTestSupport.layout(of: archive).endRecordOffset
        // Keep the remaining ZIP32 fields as sentinels so the ZIP64 path is
        // selected, but make the non-sentinel count contradict the ZIP64 count.
        try ZipTestSupport.writeUInt16(2, to: &archive, at: end + 8)
        try ZipTestSupport.writeUInt16(2, to: &archive, at: end + 10)

        assertMalformed { try ArchiveReader.open(data: archive) }
    }

    func testDuplicateNamesRemainDistinctIndexAddressableEntries() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "duplicate.txt", uncompressedData: Data("first".utf8)),
            HandZipEntry(name: "duplicate.txt", uncompressedData: Data("second".utf8)),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["duplicate.txt", "duplicate.txt"])
        XCTAssertEqual(reader.entries.map(\.index), [0, 1])
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("first".utf8))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data("second".utf8))
    }

    func testDeclaredZipBombAndMetadataLimitsFailAtOpen() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "bomb.bin",
                uncompressedData: Data([0]),
                centralUncompressedSize: 1_000_000_000
            ),
        ])
        var entryLimits = ReadLimits()
        entryLimits.maxEntrySize = 128
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: entryLimits))
        }

        var metadataLimits = ReadLimits()
        metadataLimits.maxMetadataSize = 16
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: metadataLimits))
        }

        var countLimits = ReadLimits()
        countLimits.maxEntryCount = 0
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: countLimits))
        }

        let extraArchive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "extra.bin",
                centralExtra: try ZipTestSupport.extraField(identifier: 0x7875, payload: Data())
            ),
        ])
        var recordLimits = ReadLimits()
        recordLimits.maxMetadataRecordCount = 0
        assertLimitExceeded {
            try ArchiveReader.open(
                data: extraArchive,
                options: ReaderOptions(limits: recordLimits)
            )
        }
    }

    func testZIPPathComponentLimitIsAppliedAtOpen() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "one/two/three.txt"),
        ])
        var limits = ReadLimits()
        limits.maxPathComponentCount = 2
        assertLimitExceeded {
            try ArchiveReader.open(data: archive, options: ReaderOptions(limits: limits))
        }
    }

    func testCentralDirectoryOverlapIsDeferredInLazyModeAndRejectedEagerly() throws {
        let payload = Data("overlap".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "overlap.txt",
                uncompressedData: payload,
                centralCompressedSize: UInt32(payload.count + 1)
            ),
        ])

        let lazy = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(lazyLocalHeaders: true)
        )
        XCTAssertEqual(lazy.entries.count, 1)
        assertMalformed { try lazy.read(lazy.entries[0]) }

        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testEntryPayloadCannotOverlapAnotherLocalHeader() throws {
        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "first.txt",
                uncompressedData: firstPayload,
                centralCompressedSize: UInt32(firstPayload.count + 1)
            ),
            HandZipEntry(name: "second.txt", uncompressedData: secondPayload),
        ])

        let lazy = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(lazyLocalHeaders: true)
        )
        assertMalformed { try lazy.read(lazy.entries[1]) }
        assertMalformed { try lazy.read(lazy.entries[0]) }

        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testAliasedLocalHeaderIsDetectedInLazyAndEagerModes() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first.txt", uncompressedData: Data("one".utf8)),
            HandZipEntry(name: "alias.txt", uncompressedData: Data("two".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let firstLocalOffset = layout.localHeaderOffsets[0] - layout.archiveBase
        try ZipTestSupport.writeUInt32(
            UInt32(firstLocalOffset),
            to: &archive,
            at: layout.centralEntryOffsets[1] + 42
        )

        let lazy = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(lazyLocalHeaders: true)
        )
        assertMalformed { try lazy.read(lazy.entries[0]) }
        assertMalformed { try lazy.read(lazy.entries[1]) }

        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testSameNamedEntriesCannotAliasOneLocalHeader() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "same.txt", uncompressedData: Data("one".utf8)),
            HandZipEntry(name: "same.txt", uncompressedData: Data("two".utf8)),
        ])
        let layout = try ZipTestSupport.layout(of: archive)
        let firstLocalOffset = layout.localHeaderOffsets[0] - layout.archiveBase
        try ZipTestSupport.writeUInt32(
            UInt32(firstLocalOffset),
            to: &archive,
            at: layout.centralEntryOffsets[1] + 42
        )

        let lazy = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(lazyLocalHeaders: true)
        )
        assertMalformed { try lazy.read(lazy.entries[0]) }
        assertMalformed { try lazy.read(lazy.entries[1]) }
        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testCorruptLocalHeaderDemonstratesLazyVersusEagerValidation() throws {
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "lazy.txt", uncompressedData: Data("lazy".utf8)),
        ])
        let local = try XCTUnwrap(ZipTestSupport.layout(of: archive).localHeaderOffsets.first)
        try ZipTestSupport.writeUInt32(0xDEAD_BEEF, to: &archive, at: local)

        let defaultReader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(defaultReader.entries.map(\.name), ["lazy.txt"])
        assertMalformed { try defaultReader.read(defaultReader.entries[0]) }

        assertMalformed {
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testCentralMethodAndNameRemainAuthoritativeOverLocalHeader() throws {
        let payload = Data("central values win".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "central-name.txt", uncompressedData: payload),
        ])
        let local = try XCTUnwrap(ZipTestSupport.layout(of: archive).localHeaderOffsets.first)
        try ZipTestSupport.writeUInt16(8, to: &archive, at: local + 8)
        try ZipTestSupport.writeUInt32(0x1234_5678, to: &archive, at: local + 14)
        archive[local + 30] = Character("X").asciiValue ?? 0x58

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries[0].name, "central-name.txt")
        XCTAssertEqual(reader.entries[0].methodDescription, "stored")
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testLocalFilenameLengthOnlyControlsPayloadSkip() throws {
        let name = "central-name.txt"
        let payload = Data("local length is not identity".utf8)
        var archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: name,
                uncompressedData: payload,
                localExtra: Data([0x58])
            ),
        ])
        let local = try XCTUnwrap(
            ZipTestSupport.layout(of: archive).localHeaderOffsets.first
        )
        // name を 1 バイト長く、extra を 1 バイト短くして data offset は維持する。
        try ZipTestSupport.writeUInt16(
            UInt16(name.utf8.count + 1),
            to: &archive,
            at: local + 26
        )
        try ZipTestSupport.writeUInt16(0, to: &archive, at: local + 28)

        for lazyLocalHeaders in [true, false] {
            let reader = try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(lazyLocalHeaders: lazyLocalHeaders)
            )
            XCTAssertEqual(reader.entries[0].name, name)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testLocalZIP64SizesAreValidatedOnlyWhenEntryIsRequested() throws {
        let payload = Data("local ZIP64 fields".utf8)
        let zip64 = try ZipTestSupport.zip64Extra(values: [
            UInt64(payload.count),
            UInt64(payload.count),
        ])
        let valid = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "zip64-local.txt",
                uncompressedData: payload,
                localExtra: zip64,
                localCompressedSize: UInt32.max,
                localUncompressedSize: UInt32.max
            ),
        ])
        let validReader = try ArchiveReader.open(data: valid)
        XCTAssertEqual(try validReader.read(validReader.entries[0]), payload)

        let missing = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "zip64-missing.txt",
                uncompressedData: payload,
                localCompressedSize: UInt32.max,
                localUncompressedSize: UInt32.max
            ),
        ])
        let lazy = try ArchiveReader.open(data: missing)
        assertMalformed { try lazy.read(lazy.entries[0]) }
        assertMalformed {
            try ArchiveReader.open(
                data: missing,
                options: ReaderOptions(lazyLocalHeaders: false)
            )
        }
    }

    func testTruncatedDeflateAndBadCRCFailAtEndOfRead() throws {
        let plaintext = Data(
            "hello KaitoKit\nhello KaitoKit\nhello KaitoKit\n".utf8
        )
        let rawDeflate = Data([
            0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xF0, 0x4E, 0xCC, 0x2C,
            0xC9, 0xF7, 0xCE, 0x2C, 0xE1, 0xCA, 0xC0, 0xCB, 0x05, 0x00,
        ])
        let truncated = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "truncated.txt",
                uncompressedData: plaintext,
                compressedData: Data(rawDeflate.dropLast()),
                method: 8
            ),
        ])
        let truncatedReader = try ArchiveReader.open(data: truncated)
        XCTAssertThrowsError(try truncatedReader.read(truncatedReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let payload = Data("CRC must cover the uncompressed bytes".utf8)
        let wrongCRC = CRC32.checksum(payload) ^ 1
        let corrupt = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "bad-crc.txt",
                uncompressedData: payload,
                centralCRC32: wrongCRC
            ),
        ])
        let corruptReader = try ArchiveReader.open(data: corrupt)
        XCTAssertThrowsError(try corruptReader.read(corruptReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testKnownUnsupportedZIPMethodsReportTheirNumbers() throws {
        for method: UInt16 in [93, 95, 96, 98] {
            let archive = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(name: "unsupported-\(method)", method: method),
            ])
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertThrowsError(try reader.read(reader.entries[0])) { error in
                XCTAssertEqual(error as? KaitoError, .unsupportedMethod(String(method)))
            }
        }
    }

    func testZipCryptoRequiresPasswordRejectsWrongPasswordAndUsesProvider() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "zipcrypto-reader")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("traditional encrypted reader fixture\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "secret.txt", below: source)
        let archive = temporary.appendingPathComponent("zipcrypto.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: source,
            paths: ["secret.txt"],
            archiveURL: archive,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let noPassword = try ArchiveReader.open(url: archive)
        XCTAssertTrue(try XCTUnwrap(noPassword.entries.first).isEncrypted)
        XCTAssertThrowsError(try noPassword.read(noPassword.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }

        let wrong = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "wrong-password")
        )
        XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let provided = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(
                passwordProvider: ZipFixedPasswordProvider(value: "fixed-password")
            )
        )
        XCTAssertEqual(try provided.read(provided.entries[0]), payload)

        let archiveData = try Data(contentsOf: archive)
        let layout = try ZipTestSupport.layout(of: archiveData)
        let local = layout.localHeaderOffsets[0]
        let nameLength = Int(try ZipTestSupport.readUInt16(archiveData, at: local + 26))
        let extraLength = Int(try ZipTestSupport.readUInt16(archiveData, at: local + 28))
        let dataOffset = local + 30 + nameLength + extraLength
        for available in [5, ZipCrypto.headerSize, ZipCrypto.headerSize + 17] {
            let recovered = try ArchiveReader.open(
                data: Data(archiveData.prefix(dataOffset + available)),
                options: ReaderOptions(password: "fixed-password", recoverDamagedArchives: true)
            )
            let entry = try XCTUnwrap(recovered.entries.first)
            XCTAssertTrue(entry.isIncomplete)
            XCTAssertTrue(entry.isEncrypted)
            XCTAssertEqual(
                try recovered.read(entry),
                Data(payload.prefix(max(0, available - ZipCrypto.headerSize)))
            )
        }
    }

    func testWinZipAESRequiresPasswordAndRejectsWrongPassword() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable; WinZip AES reader hardening fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "aes-reader")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("WinZip AES authenticated payload 日本語\n".utf8)
        _ = try ZipTestSupport.write(payload, relativePath: "secret.txt", below: source)
        let archive = temporary.appendingPathComponent("aes.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: source,
            paths: ["secret.txt"],
            archiveURL: archive,
            method: "Copy",
            password: "fixed-password"
        )

        let noPassword = try ArchiveReader.open(url: archive)
        XCTAssertThrowsError(try noPassword.read(noPassword.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }

        let wrong = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "wrong-password")
        )
        XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let correct = try ArchiveReader.open(
            url: archive,
            options: ReaderOptions(password: "fixed-password")
        )
        XCTAssertEqual(try correct.read(correct.entries[0]), payload)
        XCTAssertEqual(try correct.read(correct.entries[0]), payload)
    }

    func testBadCRCExtractionDoesNotPublishOrReplaceDestination() throws {
        let payload = Data(repeating: 0x4B, count: 600 * 1_024)
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "bad-crc.bin",
                uncompressedData: payload,
                centralCRC32: CRC32.checksum(payload) ^ 1
            ),
        ])
        let reader = try ArchiveReader.open(data: archive)

        try assertFailedExtractionDoesNotPublish(
            reader: reader,
            entry: try XCTUnwrap(reader.entries.first),
            expectedError: .checksumMismatch(entry: 0)
        )
    }

    func testDamagedAESExtractionDoesNotPublishOrReplaceDestination() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable; damaged AES extraction fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "aes-extraction-failure")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data(repeating: 0xA5, count: 600 * 1_024)
        _ = try ZipTestSupport.write(payload, relativePath: "damaged-aes.bin", below: source)
        let archiveURL = temporary.appendingPathComponent("aes.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: source,
            paths: ["damaged-aes.bin"],
            archiveURL: archiveURL,
            method: "Copy",
            password: "fixed-password"
        )

        var archive = try Data(contentsOf: archiveURL)
        let layout = try ZipTestSupport.layout(of: archive)
        let central = try XCTUnwrap(layout.centralEntryOffsets.first)
        let local = try XCTUnwrap(layout.localHeaderOffsets.first)
        let compressedSize = Int(try ZipTestSupport.readUInt32(archive, at: central + 20))
        let nameLength = Int(try ZipTestSupport.readUInt16(archive, at: local + 26))
        let extraLength = Int(try ZipTestSupport.readUInt16(archive, at: local + 28))
        let dataOffset = local + 30 + nameLength + extraLength
        guard compressedSize >= 10,
              dataOffset >= 0,
              dataOffset <= archive.count,
              compressedSize <= archive.count - dataOffset else {
            return XCTFail("7zz AES fixture has an invalid encrypted payload range")
        }
        archive[dataOffset + compressedSize - 1] ^= 1

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(password: "fixed-password")
        )
        try assertFailedExtractionDoesNotPublish(
            reader: reader,
            entry: try XCTUnwrap(reader.entries.first),
            expectedError: .wrongPassword
        )
    }

    func testUnencryptedDirectoryStillExtractsAfterPayloadValidation() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "folder/")
        ])
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.kind, .directory)

        let temporary = try ZipTestSupport.temporaryDirectory(label: "directory-validation")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output", isDirectory: true)
        let destination = try reader.extract(entry, to: output)

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testEncryptedDirectoryAuthenticatesBeforeFilesystemMutation() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable; encrypted directory fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "encrypted-directory")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try ZipTestSupport.write(Data(), relativePath: "dirX", below: source)
        let archiveURL = temporary.appendingPathComponent("aes.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: source,
            paths: ["dirX"],
            archiveURL: archiveURL,
            method: "Copy",
            password: "fixed-password"
        )

        var archive = try Data(contentsOf: archiveURL)
        let layout = try ZipTestSupport.layout(of: archive)
        let local = try XCTUnwrap(layout.localHeaderOffsets.first)
        let central = try XCTUnwrap(layout.centralEntryOffsets.first)
        let localNameLength = Int(try ZipTestSupport.readUInt16(archive, at: local + 26))
        let centralNameLength = Int(try ZipTestSupport.readUInt16(archive, at: central + 28))
        XCTAssertEqual(localNameLength, 4)
        XCTAssertEqual(centralNameLength, 4)
        archive[local + 30 + 3] = 0x2F
        archive[central + 46 + 3] = 0x2F

        let noPassword = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(noPassword.entries.first)
        XCTAssertEqual(entry.kind, .directory)
        let noPasswordOutput = temporary.appendingPathComponent(
            "no-password-output",
            isDirectory: true
        )
        XCTAssertThrowsError(try noPassword.extract(entry, to: noPasswordOutput)) { error in
            XCTAssertEqual(error as? KaitoError, .passwordRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: noPasswordOutput.path))

        var damaged = archive
        let compressedSize = Int(
            try ZipTestSupport.readUInt32(damaged, at: central + 20)
        )
        let localExtraLength = Int(
            try ZipTestSupport.readUInt16(damaged, at: local + 28)
        )
        let dataOffset = local + 30 + localNameLength + localExtraLength
        guard compressedSize >= 10,
              dataOffset <= damaged.count,
              compressedSize <= damaged.count - dataOffset else {
            return XCTFail("7zz AES directory fixture has an invalid payload range")
        }
        damaged[dataOffset + compressedSize - 1] ^= 1

        let damagedReader = try ArchiveReader.open(
            data: damaged,
            options: ReaderOptions(password: "fixed-password")
        )
        let damagedOutput = temporary.appendingPathComponent(
            "damaged-output",
            isDirectory: true
        )
        XCTAssertThrowsError(
            try damagedReader.extract(damagedReader.entries[0], to: damagedOutput)
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: damagedOutput.path))
    }

    private func assertFailedExtractionDoesNotPublish(
        reader: ArchiveReader,
        entry: ArchiveEntry,
        expectedError: KaitoError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "failed-extraction")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fileManager = FileManager.default

        let emptyOutput = temporary.appendingPathComponent("empty", isDirectory: true)
        XCTAssertThrowsError(
            try reader.extract(entry, to: emptyOutput),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? KaitoError, expectedError, file: file, line: line)
        }
        let absentDestination = emptyOutput.appendingPathComponent(entry.name)
        XCTAssertFalse(
            fileManager.fileExists(atPath: absentDestination.path),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: emptyOutput.path),
            [],
            file: file,
            line: line
        )

        let existingOutput = temporary.appendingPathComponent("existing", isDirectory: true)
        try fileManager.createDirectory(at: existingOutput, withIntermediateDirectories: false)
        let existingDestination = existingOutput.appendingPathComponent(entry.name)
        let original = Data("keep the original destination\n".utf8)
        try original.write(to: existingDestination)

        XCTAssertThrowsError(
            try reader.extract(entry, to: existingOutput),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? KaitoError, expectedError, file: file, line: line)
        }
        XCTAssertEqual(
            try Data(contentsOf: existingDestination),
            original,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: existingOutput.path),
            [entry.name],
            file: file,
            line: line
        )
    }

    private func assertMalformed<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertLimitExceeded<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertSpanned<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("spanned"),
                file: file,
                line: line
            )
        }
    }

    private func assertStrongEncryptionUnsupported<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("strong ZIP encryption"),
                file: file,
                line: line
            )
        }
    }
}
