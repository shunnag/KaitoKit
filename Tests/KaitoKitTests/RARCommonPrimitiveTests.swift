import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class RARCommonPrimitiveTests: XCTestCase {
    func testBlake2sRFC7693VectorsAndIncrementalUpdates() throws {
        XCTAssertEqual(
            Blake2s.checksum(Data()),
            try hex("69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9")
        )
        XCTAssertEqual(
            Blake2s.checksum(Data("abc".utf8)),
            try hex("508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982")
        )

        let input = Data((0..<257).map { UInt8(truncatingIfNeeded: $0) })
        var incremental = Blake2s()
        incremental.update(input.prefix(1))
        incremental.update(input.dropFirst(1).prefix(63))
        incremental.update(input.dropFirst(64).prefix(65))
        incremental.update(input.dropFirst(129))
        XCTAssertEqual(incremental.finalize(), Blake2s.checksum(input))
        XCTAssertEqual(incremental.finalize(), Blake2s.checksum(input))
    }

    func testBlake2spReferenceVectorsAcrossStripeBoundaries() throws {
        XCTAssertEqual(
            Blake2sp.checksum(Data()),
            try hex("dd0e891776933f43c7d032b08a917e25741f8aa9a12c12e1cac8801500f2ca4f")
        )
        XCTAssertEqual(
            Blake2sp.checksum(Data("abc".utf8)),
            try hex("70f75b58f1fecab821db43c88ad84edde5a52600616cd22517b7bb14d440a7d5")
        )

        let stripe = (0..<256).map { UInt8($0) }
        let oneKiB = Data((0..<4).flatMap { _ in stripe })
        let expectedOneKiB = try hex(
            "c9f79171d19c3703b7ebf9f762ce3fd24b302e2281f72da31a65014ff923c859"
        )
        XCTAssertEqual(Blake2sp.checksum(oneKiB), expectedOneKiB)

        var incremental = Blake2sp()
        var offset = 0
        for chunkSize in [1, 63, 64, 65, 7, 129, 2, 256, 437] {
            let end = min(oneKiB.count, offset + chunkSize)
            incremental.update(oneKiB[offset..<end])
            offset = end
            if offset == oneKiB.count { break }
        }
        if offset < oneKiB.count {
            incremental.update(oneKiB[offset...])
        }
        XCTAssertEqual(incremental.finalize(), expectedOneKiB)
        XCTAssertEqual(incremental.finalize(), expectedOneKiB)

        var longBytes = (0..<16).flatMap { _ in stripe }
        longBytes.append(contentsOf: [0x78, 0x79, 0x7A])
        XCTAssertEqual(
            Blake2sp.checksum(Data(longBytes)),
            try hex("9e36ccaf54c42fdabe5e5e9fdfaa492b8b86a622f4cdd69e33bdc20bde217725")
        )
    }

    func testRAR3KeyDerivationVectorAndPasswordEncoding() throws {
        XCTAssertEqual(
            RAR3KeyDerivation.passwordBytes("A😀"),
            Data([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE])
        )
        let keys = try RAR3KeyDerivation.derive(
            password: "password",
            salt: Array(try hex("0001020304050607"))
        )
        XCTAssertEqual(keys.key, try hex("20f3fb49c2976b56cf873c55fbf242ed"))
        XCTAssertEqual(
            keys.initializationVector,
            try hex("04c8774671e283d90519dca70a85fb65")
        )

        let cache = RAR3KeyCache(capacity: 1)
        XCTAssertEqual(
            try cache.key(password: "password", salt: Array(try hex("0001020304050607"))),
            keys
        )
        XCTAssertThrowsError(
            try RAR3KeyDerivation.derive(password: "password", salt: [0])
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR3 AES salt is not 8 bytes")
            )
        }
    }

    func testRAR5KeyDerivationMatchesRAR723ArchiveVector() throws {
        let keys = try RAR5KeyDerivation.derive(
            password: "secret",
            salt: Array(try hex("ead583e148dc040e9fcc14b20a9a3bf4")),
            count: 15
        )
        XCTAssertEqual(
            keys.encryptionKey,
            try hex("a3371b10fcd0e963a8459ee0423e6de76bb8f7ba2e972fa8133f6ade13e3702d")
        )
        XCTAssertEqual(
            keys.hashKey,
            try hex("3348351def9ddd77c248433860913dfaa016ac5d7ac6b429e2ef907bcd45bb2c")
        )
        XCTAssertEqual(
            keys.passwordCheckValue,
            try hex("adc29773483c99c8323aa356")
        )
        XCTAssertTrue(
            try keys.verify(passwordCheckValue: Array(keys.passwordCheckValue))
        )
        // A damaged self-check is unusable rather than evidence of a wrong
        // password; readers fall back to decrypted-header/payload integrity.
        XCTAssertFalse(
            try keys.verify(passwordCheckValue: Array(repeating: 0, count: 12))
        )
        let wrongKeys = try RAR5KeyDerivation.derive(
            password: "wrong",
            salt: Array(try hex("ead583e148dc040e9fcc14b20a9a3bf4")),
            count: 15
        )
        XCTAssertThrowsError(
            try keys.verify(passwordCheckValue: Array(wrongKeys.passwordCheckValue))
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        let cache = RAR5KeyCache(capacity: 1)
        XCTAssertEqual(
            try cache.key(
                password: "secret",
                salt: Array(try hex("ead583e148dc040e9fcc14b20a9a3bf4")),
                count: 15
            ),
            keys
        )
    }

    func testRAR5KDFBoundsAndChecksumMACVectors() throws {
        let countZero = try RAR5KeyDerivation.derive(
            password: "",
            salt: Array(0..<16),
            count: 0
        )
        XCTAssertEqual(
            countZero.encryptionKey,
            try hex("c6b7413bebb763bda962e5d94e24327e07d4daa9e97c14ea4126ba4b7ccb0d16")
        )
        XCTAssertEqual(
            countZero.hashKey,
            try hex("33733b599b86375aff1856e5bde19410cd7529f478c0ae44540f1c4382cd9a14")
        )
        XCTAssertEqual(
            countZero.passwordCheckValue,
            try hex("18800c2685e30021928c26db")
        )

        XCTAssertThrowsError(
            try RAR5KeyDerivation.derive(
                password: "secret",
                salt: Array(repeating: 0, count: 16),
                count: 25
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("RAR5 KDF count 25 exceeds 24")
            )
        }
        XCTAssertThrowsError(
            try RAR5KeyDerivation.derive(password: "secret", salt: [0], count: 0)
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 AES salt is not 16 bytes")
            )
        }

        let hashKey = try hex(
            "3348351def9ddd77c248433860913dfaa016ac5d7ac6b429e2ef907bcd45bb2c"
        )
        XCTAssertEqual(RAR5ChecksumMAC.crc32(0x1234_5678, hashKey: hashKey), 0xD9DF_1CF4)
        let digest = try hex(
            "9e36ccaf54c42fdabe5e5e9fdfaa492b8b86a622f4cdd69e33bdc20bde217725"
        )
        XCTAssertEqual(
            try RAR5ChecksumMAC.blake2sp(digest, hashKey: hashKey),
            try hex("47d6c8d192d5479dea8246244d3490e8bcc69aed7e823e7156c518a5f1333dbe")
        )
    }

    func testRARAESCBCByteSourceMatchesNISTAndSupportsUnalignedReads() throws {
        let key = try hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = try hex("000102030405060708090a0b0c0d0e0f")
        let plaintext = try hex(
            "6bc1bee22e409f96e93d7e117393172a" +
                "ae2d8a571e03ac9c9eb76fac45af8e51" +
                "30c81c46a35ce411e5fbc1191a0a52ef" +
                "f69f2445df4f9b17ad2b417be66c3710"
        )
        let ciphertext = try hex(
            "7649abac8119b246cee98e9b12e9197d" +
                "5086cb9b507219ee95db113a917678b2" +
                "73bed6b8e3c1743b7116e69e22229516" +
                "3ff1caa1681fac09120eca307586e1a7"
        )
        var container = Data(repeating: 0xA5, count: 7)
        container.append(ciphertext)
        container.append(Data(repeating: 0x5A, count: 5))
        let encryptedSource = RARShortReadingByteSource(data: container, maximumReadSize: 3)
        let source = try RARAESCBCByteSource(
            source: encryptedSource,
            ciphertextOffset: 7,
            ciphertextSize: UInt64(ciphertext.count),
            plaintextSize: UInt64(plaintext.count),
            key: key,
            initializationVector: iv
        )

        for (offset, count) in [(0, 64), (1, 1), (7, 23), (15, 18), (16, 31), (17, 29), (47, 17)] {
            XCTAssertEqual(
                Data(try readByteRange(source: source, offset: UInt64(offset), count: count)),
                plaintext.subdata(in: offset..<(offset + count)),
                "offset \(offset), count \(count)"
            )
        }
        var byte: UInt8 = 0
        XCTAssertEqual(
            try withUnsafeMutableBytes(of: &byte) {
                try source.read(into: $0, at: UInt64(plaintext.count))
            },
            0
        )

        let aes256Ciphertext = try hex(
            "f58c4c04d6e5f1ba779eabfb5f7bfbd6" +
                "9cfc4e967edb808d679f777bc6702c7d" +
                "39f23369a9d9bacfa530e26304231461" +
                "b2eb05e2c39be9fcda6c19078c6a9d1b"
        )
        let aes256 = try RARAESCBCByteSource(
            source: DataByteSource(data: aes256Ciphertext),
            ciphertextOffset: 0,
            ciphertextSize: UInt64(aes256Ciphertext.count),
            plaintextSize: UInt64(plaintext.count),
            key: try hex(
                "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"
            ),
            initializationVector: iv
        )
        XCTAssertEqual(
            Data(try readByteRange(source: aes256, offset: 13, count: 39)),
            plaintext.subdata(in: 13..<52)
        )
    }

    func testRARStandardFiltersKnownTransformsAndErrors() throws {
        var delta: [UInt8] = [255, 254, 253, 246, 253, 252]
        try RARStandardFilters.delta(&delta, channels: 2)
        XCTAssertEqual(delta, [1, 10, 3, 13, 6, 17])

        var e8: [UInt8] = [0x90, 0xE8, 0x20, 0, 0, 0, 0x90]
        try RARStandardFilters.e8(
            &e8,
            fileOffset: 0x10,
            includeE9: false,
            addressMode: .rar5
        )
        XCTAssertEqual(e8, [0x90, 0xE8, 0x0E, 0, 0, 0, 0x90])

        var e8PastTranslationRange: [UInt8] = [0xE8, 0x20, 0, 0, 0]
        try RARStandardFilters.e8(
            &e8PastTranslationRange,
            fileOffset: 0x0100_0000,
            includeE9: false,
            addressMode: .rar5
        )
        XCTAssertEqual(e8PastTranslationRange, [0xE8, 0x1F, 0, 0, 0])

        var e8e9PastTranslationRange: [UInt8] = [0xE9, 0x20, 0, 0, 0]
        try RARStandardFilters.e8(
            &e8e9PastTranslationRange,
            fileOffset: 0x0100_0000,
            includeE9: true,
            addressMode: .rar5
        )
        XCTAssertEqual(e8e9PastTranslationRange, [0xE9, 0x1F, 0, 0, 0])

        var e8CrossingTranslationBoundary: [UInt8] = [0x90, 0xE8, 0x20, 0, 0, 0]
        try RARStandardFilters.e8(
            &e8CrossingTranslationBoundary,
            fileOffset: 0x00FF_FFFE,
            includeE9: false,
            addressMode: .rar5
        )
        XCTAssertEqual(e8CrossingTranslationBoundary, [0x90, 0xE8, 0x20, 0, 0, 0])

        var e8SignedRangeUsesReducedPosition: [UInt8] = [0xE8, 0xFF, 0xFF, 0xFF, 0xFF]
        try RARStandardFilters.e8(
            &e8SignedRangeUsesReducedPosition,
            fileOffset: 0x7FFF_FFFF,
            includeE9: false,
            addressMode: .rar5
        )
        XCTAssertEqual(e8SignedRangeUsesReducedPosition, [0xE8, 0xFF, 0xFF, 0xFF, 0xFF])

        var rar3PositionIsNotReduced: [UInt8] = [0xE8, 0x20, 0, 0, 0]
        try RARStandardFilters.e8(
            &rar3PositionIsNotReduced,
            fileOffset: 0x0100_0000,
            includeE9: false,
            addressMode: .rar3
        )
        XCTAssertEqual(rar3PositionIsNotReduced, [0xE8, 0x1F, 0, 0, 0xFF])

        var arm: [UInt8] = [0x20, 0, 0, 0xEB, 1, 2, 3, 4]
        try RARStandardFilters.arm(&arm, fileOffset: 0x10)
        XCTAssertEqual(arm, [0x1C, 0, 0, 0xEB, 1, 2, 3, 4])

        var rgb: [UInt8] = [255, 254, 246, 253, 251, 252]
        try RARStandardFilters.rgb(&rgb, width: 6, positionR: 0)
        XCTAssertEqual(rgb, [11, 10, 15, 16, 13, 22])

        var audio: [UInt8] = [255, 255, 246, 255]
        try RARStandardFilters.audio(&audio, channels: 2)
        XCTAssertEqual(audio, [1, 10, 2, 11])

        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 53,
                crc32: 0xAD57_6887
            ),
            .e8
        )
        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 57,
                crc32: 0x3CD7_E57E
            ),
            .e8e9
        )
        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 120,
                crc32: 0x3769_893F
            ),
            .itanium
        )
        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 29,
                crc32: 0x0E06_077D
            ),
            .delta
        )
        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 149,
                crc32: 0x1C2C_5DC8
            ),
            .rgb
        )
        XCTAssertEqual(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 216,
                crc32: 0xBC85_E701
            ),
            .audio
        )
        XCTAssertNil(
            RARStandardFilters.recognizeRAR3Program(
                byteCount: 158,
                crc32: 0xBC85_E701
            )
        )

        XCTAssertNil(RARStandardFilters.recognizeRAR3Program([1, 2, 3]))
        XCTAssertThrowsError(try RARStandardFilters.requireRAR3Program([1, 2, 3])) {
            XCTAssertEqual(
                $0 as? KaitoError,
                .unsupportedMethod("RAR3 custom VM filter")
            )
        }
        XCTAssertThrowsError(try RARStandardFilters.delta(&delta, channels: 0))
    }

    func testRARConcatenatedSourceCrossesShortReadingSegmentsAndEnforcesLimits() throws {
        let first = RARShortReadingByteSource(
            data: Data("XabcY".utf8),
            maximumReadSize: 1
        )
        let second = RARShortReadingByteSource(
            data: Data("ZZdefghQ".utf8),
            maximumReadSize: 2
        )
        let source = try RARConcatenatedByteSource(
            segments: [
                RARSourceSegment(source: first, offset: 1, length: 3),
                RARSourceSegment(source: second, offset: 2, length: 5),
            ],
            maximumLength: 8
        )
        XCTAssertEqual(source.length, 8)
        XCTAssertEqual(
            Data(try readByteRange(source: source, offset: 2, count: 5)),
            Data("cdefg".utf8)
        )
        XCTAssertThrowsError(
            try RARConcatenatedByteSource(
                segments: [RARSourceSegment(source: first, offset: 1, length: 3)],
                maximumLength: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("RAR split stream exceeds configured maximum")
            )
        }
        XCTAssertThrowsError(
            try RARConcatenatedByteSource(
                segments: [RARSourceSegment(source: first, offset: 4, length: 2)],
                maximumLength: 2
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertThrowsError(
            try RARConcatenatedByteSource(
                segments: [
                    RARSourceSegment(source: first, offset: 1, length: 1),
                    RARSourceSegment(source: second, offset: 2, length: 1),
                ],
                maximumLength: 2,
                maximumSegmentCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("RAR split stream has too many segments")
            )
        }
    }

    func testRARVolumeLocatorNamesAndValidatesRAR5Numbers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-RARVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rar4Signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        let oldFirst = directory.appendingPathComponent("old.rar")
        let oldSecond = directory.appendingPathComponent("old.r00")
        try rar4Signature.write(to: oldFirst)
        try rar4Signature.write(to: oldSecond)
        let oldLocator = try RARVolumeLocator(firstVolumeURL: oldFirst, naming: .rar4Old)
        XCTAssertEqual(try oldLocator.locate(volumeNumber: 1).url, oldSecond)

        let newFirst = directory.appendingPathComponent("new.part01.rar")
        let newSecond = directory.appendingPathComponent("new.part02.rar")
        try rar4Signature.write(to: newFirst)
        try rar4Signature.write(to: newSecond)
        let newLocator = try RARVolumeLocator(firstVolumeURL: newFirst, naming: .rar4New)
        XCTAssertEqual(try newLocator.locate(volumeNumber: 1).url, newSecond)

        let rar5First = directory.appendingPathComponent("five.part1.rar")
        let rar5Second = directory.appendingPathComponent("five.part2.rar")
        try rar5Volume(number: 0).write(to: rar5First)
        try rar5Volume(number: 1).write(to: rar5Second)
        let rar5Locator = try RARVolumeLocator(firstVolumeURL: rar5First, naming: .rar5)
        XCTAssertEqual(try rar5Locator.locate(volumeNumber: 1).url, rar5Second)

        let anonymous = try RARVolumeLocator(
            dataBackedSource: DataByteSource(data: rar5Volume(number: 0)),
            naming: .rar5
        )
        XCTAssertThrowsError(try anonymous.locate(volumeNumber: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("multi-volume from Data")
            )
        }

        let wrongFirst = directory.appendingPathComponent("wrong.part1.rar")
        let wrongSecond = directory.appendingPathComponent("wrong.part2.rar")
        try rar5Volume(number: 0).write(to: wrongFirst)
        try rar5Volume(number: 2).write(to: wrongSecond)
        let wrongLocator = try RARVolumeLocator(firstVolumeURL: wrongFirst, naming: .rar5)
        XCTAssertThrowsError(try wrongLocator.locate(volumeNumber: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 volume number 2 does not match expected 1")
            )
        }
    }

    func testRARVolumeLocatorPreservesPartMarkerAndExtensionSpelling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-RARVolumeCase-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let rar4Signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        let rar4First = directory.appendingPathComponent("Four.PaRt0001.RAR")
        let rar4Second = directory.appendingPathComponent("Four.PaRt0002.RAR")
        try rar4Signature.write(to: rar4First)
        try rar4Signature.write(to: rar4Second)
        let rar4Locator = try RARVolumeLocator(
            firstVolumeURL: rar4First,
            naming: .rar4New
        )
        XCTAssertEqual(try rar4Locator.locate(volumeNumber: 1).url, rar4Second)

        let rar5First = directory.appendingPathComponent("Five.PART1.RaR")
        let rar5Second = directory.appendingPathComponent("Five.PART2.RaR")
        try rar5Volume(number: 0).write(to: rar5First)
        try rar5Volume(number: 1).write(to: rar5Second)
        let rar5Locator = try RARVolumeLocator(
            firstVolumeURL: rar5First,
            naming: .rar5
        )
        XCTAssertEqual(try rar5Locator.locate(volumeNumber: 1).url, rar5Second)

        let fallbackFirst = directory.appendingPathComponent("Fallback.RAR")
        let fallbackSecond = directory.appendingPathComponent("Fallback.part2.RAR")
        try rar5Volume(number: 0).write(to: fallbackFirst)
        try rar5Volume(number: 1).write(to: fallbackSecond)
        let fallbackLocator = try RARVolumeLocator(
            firstVolumeURL: fallbackFirst,
            naming: .rar5
        )
        XCTAssertEqual(
            try fallbackLocator.locate(volumeNumber: 1).url,
            fallbackSecond
        )
    }

    func testRAR5VolumeLocatorBoundsMainHeaderBeforeAllocating() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-RARVolumeHeader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ordinary = directory.appendingPathComponent("ordinary.part1.rar")
        try rar5Volume(number: 0).write(to: ordinary)
        XCTAssertThrowsError(
            try RARVolumeLocator(
                firstVolumeURL: ordinary,
                naming: .rar5,
                maxMetadataSize: 2
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .limitExceeded("size 3 exceeds limit 2"))
        }

        let wideSize = directory.appendingPathComponent("wide.part1.rar")
        try rar5Volume(
            sizeField: [0x82, 0x80, 0x80, 0x00],
            body: [1, 0]
        ).write(to: wideSize)
        XCTAssertThrowsError(
            try RARVolumeLocator(firstVolumeURL: wideSize, naming: .rar5)
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 header-size vint exceeds 3 bytes")
            )
        }

        let undersized = directory.appendingPathComponent("small.part1.rar")
        try rar5Volume(sizeField: [1], body: [1]).write(to: undersized)
        XCTAssertThrowsError(
            try RARVolumeLocator(firstVolumeURL: undersized, naming: .rar5)
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR5 header size is too small")
            )
        }
    }

    func testRARVolumeLocatorRejectsFIFOAndSymlinkSiblings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-RARVolumeKinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("kind.part1.rar")
        let second = directory.appendingPathComponent("kind.part2.rar")
        try rar5Volume(number: 0).write(to: first)
        let locator = try RARVolumeLocator(firstVolumeURL: first, naming: .rar5)

        XCTAssertEqual(Darwin.mkfifo(second.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try locator.locate(volumeNumber: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR volume is not a regular file")
            )
        }

        try FileManager.default.removeItem(at: second)
        let target = directory.appendingPathComponent("target.rar")
        try rar5Volume(number: 1).write(to: target)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: target)
        XCTAssertThrowsError(try locator.locate(volumeNumber: 1)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR volume is not a regular file")
            )
        }

        let fifoFirst = directory.appendingPathComponent("fifo.part1.rar")
        XCTAssertEqual(Darwin.mkfifo(fifoFirst.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try FileByteSource(url: fifoFirst)) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("file is not a regular file")
            )
        }

        let linkedFirst = directory.appendingPathComponent("linked.part1.rar")
        try FileManager.default.createSymbolicLink(
            at: linkedFirst,
            withDestinationURL: first
        )
        XCTAssertThrowsError(
            try RARVolumeLocator(firstVolumeURL: linkedFirst, naming: .rar5)
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("RAR volume is not a regular file")
            )
        }
    }

    func testRARVolumeLocatorUsesDirectoryCapturedBeforeFirstSourceOpen() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-RARVolumeSwap-\(UUID().uuidString)")
        let active = parent.appendingPathComponent("active", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = active.appendingPathComponent("swap.part1.rar")
        let second = active.appendingPathComponent("swap.part2.rar")
        try rar5Volume(number: 0).write(to: first)
        try rar5Volume(number: 1).write(to: second)
        let opened = try FileByteSource.openAnchored(url: first)

        try FileManager.default.moveItem(at: active, to: moved)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        try FileManager.default.linkItem(
            at: moved.appendingPathComponent("swap.part1.rar"),
            to: first
        )
        try rar5Volume(number: 2).write(to: second)

        let locator = try RARVolumeLocator(
            firstVolumeURL: first,
            firstVolumeSource: opened.source,
            firstVolumeDirectory: opened.directory,
            naming: .rar5
        )
        let located = try locator.locate(volumeNumber: 1)
        XCTAssertEqual(located.number, 1)
    }

    func testRARVolumeLocatorRetainsItsOpenedDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-RARVolumeAnchor-\(UUID().uuidString)")
        let active = parent.appendingPathComponent("active", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = active.appendingPathComponent("anchor.part1.rar")
        let second = active.appendingPathComponent("anchor.part2.rar")
        try rar5Volume(number: 0).write(to: first)
        try rar5Volume(number: 1).write(to: second)
        let locator = try RARVolumeLocator(firstVolumeURL: first, naming: .rar5)

        try FileManager.default.moveItem(at: active, to: moved)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        try rar5Volume(number: 2).write(to: second)

        let located = try locator.locate(volumeNumber: 1)
        XCTAssertEqual(located.number, 1)
    }

    private func rar5Volume(number: UInt8) -> Data {
        let body: [UInt8] = number == 0 ? [1, 0, 1] : [1, 0, 3, number]
        return rar5Volume(sizeField: [UInt8(body.count)], body: body)
    }

    private func rar5Volume(sizeField: [UInt8], body: [UInt8]) -> Data {
        let signature = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        let checksum = CRC32.checksum(sizeField + body)
        var result = signature
        result.append(UInt8(truncatingIfNeeded: checksum))
        result.append(UInt8(truncatingIfNeeded: checksum >> 8))
        result.append(UInt8(truncatingIfNeeded: checksum >> 16))
        result.append(UInt8(truncatingIfNeeded: checksum >> 24))
        result.append(contentsOf: sizeField)
        result.append(contentsOf: body)
        return result
    }

    private func hex(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else {
            throw KaitoError.malformed("invalid test hex")
        }
        var result = Data()
        result.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            guard let end = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<end], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = end
        }
        return result
    }
}

private final class RARShortReadingByteSource: ByteSource {
    private let source: DataByteSource
    private let maximumReadSize: Int

    var length: UInt64 { source.length }

    init(data: Data, maximumReadSize: Int) {
        precondition(maximumReadSize > 0)
        self.source = DataByteSource(data: data)
        self.maximumReadSize = maximumReadSize
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        let count = min(buffer.count, maximumReadSize)
        return try source.read(
            into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
            at: offset
        )
    }
}
