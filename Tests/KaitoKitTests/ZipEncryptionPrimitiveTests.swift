import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class ZipEncryptionPrimitiveTests: XCTestCase {
    func testWinZipAESMetadataParsesAE1AndAE2() throws {
        let ae1 = try WinZipAESMetadata(
            extraFieldPayload: Data([0x01, 0x00, 0x41, 0x45, 0x01, 0x08, 0x00])
        )
        XCTAssertEqual(ae1.vendorVersion, .ae1)
        XCTAssertEqual(ae1.strength, .aes128)
        XCTAssertEqual(ae1.compressionMethod, 8)
        XCTAssertTrue(ae1.shouldVerifyCRC)

        let ae2 = try WinZipAESMetadata(
            extraFieldPayload: Data([0x02, 0x00, 0x41, 0x45, 0x03, 0x0C, 0x00, 0xFF])
        )
        XCTAssertEqual(ae2.vendorVersion, .ae2)
        XCTAssertEqual(ae2.strength, .aes256)
        XCTAssertEqual(ae2.compressionMethod, 12)
        XCTAssertFalse(ae2.shouldVerifyCRC)
    }

    func testWinZipAESMetadataRejectsUnknownValues() {
        XCTAssertThrowsError(
            try WinZipAESMetadata(
                extraFieldPayload: Data([0x02, 0x00, 0x58, 0x59, 0x03, 0x00, 0x00])
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .malformed("WinZip AES extra field has an invalid vendor ID")
            )
        }
        XCTAssertThrowsError(
            try WinZipAESMetadata(
                extraFieldPayload: Data([0x03, 0x00, 0x41, 0x45, 0x03, 0x00, 0x00])
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .unsupportedMethod("WinZip AES vendor version 3")
            )
        }
    }

    func testWinZipAESPBKDF2VectorsForEveryStrength() throws {
        let fixtures: [(WinZipAESStrength, String, String)] = [
            (
                .aes128,
                "12345678",
                "f531154d46d1bdbbcc1fcce02d6b4c93950a74f130afc7ea53c6558aaa0d82f0a30a"
            ),
            (
                .aes192,
                "123456789012",
                "4a4b7675ec33b14aa6a3c65cfedfeb07291113ad700759dd1a6da8059831dfd6" +
                    "ac235937b9c5bf95b32daff464d42fdff98a"
            ),
            (
                .aes256,
                "1234567890123456",
                "b2ebdde419a5116f9604a8d20609b8c0402da3fdf60fc95bc02069a8e04810ce" +
                    "a095112c6ba48dcf3b4a78f87dafa8f219dfd36388bc8af02f6a07e22dedd4528954"
            )
        ]

        for (strength, saltText, expectedHex) in fixtures {
            let cacheKey = WinZipAESKeyCacheKey(
                password: "password",
                salt: Data(saltText.utf8),
                strength: strength
            )
            let keys = try WinZipAESDerivedKeys.derive(for: cacheKey)
            var material = keys.encryptionKey
            material.append(keys.authenticationKey)
            material.append(keys.passwordVerifier)
            XCTAssertEqual(material, try decodeHex(expectedHex), "strength: \(strength)")
        }
    }

    func testWinZipAESCTRPreservesPartialBlockState() throws {
        let key = Data(repeating: 0, count: 16)
        let input = Data((0..<49).map(UInt8.init))

        var wholeCTR = try WinZipAESCTR(encryptionKey: key)
        let whole = try wholeCTR.transform(input)

        var splitCTR = try WinZipAESCTR(encryptionKey: key)
        var split = try splitCTR.transform(Data(input.prefix(3)))
        split.append(try splitCTR.transform(Data(input.dropFirst(3).prefix(17))))
        split.append(try splitCTR.transform(Data(input.dropFirst(20))))
        XCTAssertEqual(split, whole)

        var decryptCTR = try WinZipAESCTR(encryptionKey: key)
        XCTAssertEqual(try decryptCTR.transform(whole), input)
    }

    func testWinZipAESCTRStartsAtOffsetsAroundBlockBoundary() throws {
        let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        let plaintext = Data((0..<97).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 11) })
        var encryptionCTR = try WinZipAESCTR(encryptionKey: key)
        let ciphertext = try encryptionCTR.transform(plaintext)

        for offset in [17, 15, 16] {
            let end = offset + 31
            var rangeCTR = try WinZipAESCTR(
                encryptionKey: key,
                streamOffset: UInt64(offset)
            )
            XCTAssertEqual(
                try rangeCTR.transform(Data(ciphertext[offset..<end])),
                Data(plaintext[offset..<end]),
                "stream offset \(offset)"
            )
        }
    }

    func testWinZipAESByteSourceHandlesShortSequentialReads() throws {
        let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        let authenticationKey = Data(
            (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 19 &+ 5) }
        )
        let plaintext = Data((0..<97).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 11) })
        var encryptionCTR = try WinZipAESCTR(encryptionKey: key)
        let ciphertext = try encryptionCTR.transform(plaintext)
        let authenticationCode = Data(
            HMAC<Insecure.SHA1>.authenticationCode(
                for: ciphertext,
                using: SymmetricKey(data: authenticationKey)
            ).prefix(WinZipAESPayload.authenticationCodeSize)
        )

        let prefix = Data(repeating: 0xA5, count: 7)
        var container = prefix
        container.append(ciphertext)
        container.append(Data(repeating: 0x5A, count: 5))
        let shortSource = ShortReadingByteSource(data: container, maximumReadSize: 3)
        let source = try WinZipAESByteSource(
            source: shortSource,
            ciphertextOffset: UInt64(prefix.count),
            ciphertextSize: UInt64(ciphertext.count),
            encryptionKey: key,
            authenticationKey: authenticationKey,
            storedAuthenticationCode: authenticationCode
        )

        XCTAssertEqual(
            try readSourceRange(source, offset: 0, count: plaintext.count),
            plaintext
        )
        try source.finishAndVerify()
    }

    func testWinZipAESByteSourceHandlesBackwardGappedAndPostFinishReads() throws {
        let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 23 &+ 7) })
        let authenticationKey = Data(
            (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 11) }
        )
        let plaintext = Data(
            (0..<113).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 9) }
        )
        var encryptionCTR = try WinZipAESCTR(encryptionKey: key)
        let ciphertext = try encryptionCTR.transform(plaintext)
        let authenticationCode = Data(
            HMAC<Insecure.SHA1>.authenticationCode(
                for: ciphertext,
                using: SymmetricKey(data: authenticationKey)
            ).prefix(WinZipAESPayload.authenticationCodeSize)
        )

        let prefix = Data(repeating: 0xC3, count: 9)
        var container = prefix
        container.append(ciphertext)
        container.append(Data(repeating: 0x3C, count: 4))
        let shortSource = ShortReadingByteSource(data: container, maximumReadSize: 4)
        let source = try WinZipAESByteSource(
            source: shortSource,
            ciphertextOffset: UInt64(prefix.count),
            ciphertextSize: UInt64(ciphertext.count),
            encryptionKey: key,
            authenticationKey: authenticationKey,
            storedAuthenticationCode: authenticationCode
        )

        // 最初の読み込みでは穴を空け、次に 0 から通常のストリーム経路へ入る。
        // その後の範囲で後方と前方の両方へ移動する。
        XCTAssertEqual(
            try readSourceRange(source, offset: 17, count: 23),
            Data(plaintext[17..<40])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 0, count: 13),
            Data(plaintext[..<13])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 3, count: 19),
            Data(plaintext[3..<22])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 44, count: 31),
            Data(plaintext[44..<75])
        )

        try source.finishAndVerify()
        XCTAssertEqual(
            try readSourceRange(source, offset: 15, count: 35),
            Data(plaintext[15..<50])
        )

        var byte: UInt8 = 0
        let eofCount = try withUnsafeMutableBytes(of: &byte) { storage in
            try source.read(into: storage, at: UInt64(plaintext.count))
        }
        XCTAssertEqual(eofCount, 0)
    }

    func testWinZipAESRandomReadDecryptsTheExactBytesThatWereAuthenticated() throws {
        let key = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 41 &+ 3) })
        let authenticationKey = Data(
            (0..<16).map { UInt8(truncatingIfNeeded: $0 &* 43 &+ 5) }
        )
        let plaintext = Data(
            (0..<79).map { UInt8(truncatingIfNeeded: $0 &* 47 &+ 13) }
        )
        var encryptionCTR = try WinZipAESCTR(encryptionKey: key)
        let ciphertext = try encryptionCTR.transform(plaintext)
        let authenticationCode = Data(
            HMAC<Insecure.SHA1>.authenticationCode(
                for: ciphertext,
                using: SymmetricKey(data: authenticationKey)
            ).prefix(WinZipAESPayload.authenticationCodeSize)
        )

        let prefix = Data(repeating: 0xA7, count: 6)
        var container = prefix
        container.append(ciphertext)
        let mutatingSource = MutatingOnRepeatedReadByteSource(data: container)
        let source = try WinZipAESByteSource(
            source: mutatingSource,
            ciphertextOffset: UInt64(prefix.count),
            ciphertextSize: UInt64(ciphertext.count),
            encryptionKey: key,
            authenticationKey: authenticationKey,
            storedAuthenticationCode: authenticationCode
        )

        // 事前認証後に source を再読すると、ここでは意図的に変更した暗号文を受け取る。
        // ランダムアクセス経路は、認証した走査中に取得した要求範囲をそのまま使う必要がある。
        XCTAssertEqual(
            try readSourceRange(source, offset: 17, count: 29),
            Data(plaintext[17..<46])
        )
        XCTAssertEqual(
            mutatingSource.maximumReadCount(
                in: prefix.count..<(prefix.count + ciphertext.count)
            ),
            1
        )
    }

    func testZipCryptoByteSourceHandlesShortNonsequentialRangeReads() throws {
        let password = "range-password"
        let plaintext = Data(
            (0..<113).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 9) }
        )
        let crc32 = CRC32.checksum(plaintext)
        var cleartext = Data((0..<11).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        cleartext.append(UInt8(truncatingIfNeeded: crc32 >> 24))
        cleartext.append(plaintext)
        var cipher = ZipCryptoReferenceCipher(password: password)
        let encryptedPayload = cipher.encrypt(cleartext)

        let prefix = Data(repeating: 0xC3, count: 9)
        var container = prefix
        container.append(encryptedPayload)
        container.append(Data(repeating: 0x3C, count: 4))
        let shortSource = ShortReadingByteSource(data: container, maximumReadSize: 4)
        let source = try ZipCryptoByteSource(
            source: shortSource,
            offset: UInt64(prefix.count),
            compressedSize: UInt64(encryptedPayload.count),
            password: password,
            crc32: crc32,
            dosTime: 0,
            usesDataDescriptor: false
        )

        XCTAssertEqual(
            try readSourceRange(source, offset: 17, count: 23),
            Data(plaintext[17..<40])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 3, count: 19),
            Data(plaintext[3..<22])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 44, count: 31),
            Data(plaintext[44..<75])
        )
        XCTAssertEqual(
            try readSourceRange(source, offset: 15, count: 35),
            Data(plaintext[15..<50])
        )

        var byte: UInt8 = 0
        let eofCount = try withUnsafeMutableBytes(of: &byte) { storage in
            try source.read(into: storage, at: UInt64(plaintext.count))
        }
        XCTAssertEqual(eofCount, 0)
    }

    func testZipCryptoArchiveStreamsPastInMemoryLimit() throws {
        let fixture = try makeFixtureDirectory(label: "zipcrypto-streaming")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data(
            (0..<32_769).map { UInt8(truncatingIfNeeded: $0 &* 41 &+ 7) }
        )
        try plaintext.write(to: fixture.input)
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: fixture.directory,
            paths: [fixture.input.lastPathComponent],
            archiveURL: fixture.archive,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let reader = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(
                limits: streamingLimits,
                password: "fixed-password"
            )
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }

        let stream = try reader.stream(entry)
        XCTAssertEqual(
            try readStreamPrefix(stream, count: plaintext.count, bufferSize: 37),
            plaintext
        )
        XCTAssertEqual(stream.remaining, 0)
    }

    func testWinZipAESArchiveStreamsPastLimitAndDefersDamagedTag() throws {
        let fixture = try makeFixtureDirectory(label: "winzip-aes-streaming")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data(
            (0..<32_785).map { UInt8(truncatingIfNeeded: $0 &* 43 &+ 5) }
        )
        try plaintext.write(to: fixture.input)
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: fixture.directory,
            paths: [fixture.input.lastPathComponent],
            archiveURL: fixture.archive,
            method: "Copy",
            password: "fixed-password"
        )

        let reader = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(
                limits: streamingLimits,
                password: "fixed-password"
            )
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
        XCTAssertEqual(
            try readStreamPrefix(
                reader.stream(entry),
                count: plaintext.count,
                bufferSize: 41
            ),
            plaintext
        )

        var damagedArchive = try Data(contentsOf: fixture.archive)
        let record = try parseLocalRecord(damagedArchive)
        let payloadRange = try XCTUnwrap(damagedArchive.range(of: record.payload))
        damagedArchive[damagedArchive.index(before: payloadRange.upperBound)] ^= 1
        let damagedReader = try ArchiveReader.open(
            data: damagedArchive,
            options: ReaderOptions(
                limits: streamingLimits,
                password: "fixed-password"
            )
        )
        let damagedEntry = try XCTUnwrap(damagedReader.entries.first)
        let damagedStream = try damagedReader.stream(damagedEntry)
        XCTAssertEqual(
            try readStreamPrefix(
                damagedStream,
                count: plaintext.count - 1,
                bufferSize: 43
            ),
            Data(plaintext.dropLast())
        )
        XCTAssertEqual(damagedStream.remaining, 1)

        var finalByte: UInt8 = 0
        XCTAssertThrowsError(
            try withUnsafeMutableBytes(of: &finalByte) { storage in
                try damagedStream.read(into: storage)
            }
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testTraditionalZipCryptoAgainstInfoZIP() throws {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zip.path) else {
            throw XCTSkip("/usr/bin/zip is unavailable")
        }

        let fixture = try makeFixtureDirectory(label: "zipcrypto")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data("traditional encryption \u{65e5}\u{672c}\u{8a9e}\n".utf8)
        try plaintext.write(to: fixture.input)

        try run(
            zip,
            arguments: [
                "-q", "-0", "-e", "-P", "fixed-password",
                fixture.archive.path,
                fixture.input.lastPathComponent
            ],
            currentDirectory: fixture.directory
        )

        let record = try parseLocalRecord(Data(contentsOf: fixture.archive))
        XCTAssertEqual(record.method, 0)
        XCTAssertNotEqual(record.flags & 1, 0)
        XCTAssertEqual(
            try ZipCrypto.decrypt(
                payloadIncludingHeader: record.payload,
                password: "fixed-password",
                crc32: record.crc32,
                dosTime: record.dosTime,
                usesDataDescriptor: (record.flags & 0x0008) != 0
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try ZipCrypto.decrypt(
                payloadIncludingHeader: record.payload,
                password: "wrong",
                crc32: record.crc32,
                dosTime: record.dosTime,
                usesDataDescriptor: (record.flags & 0x0008) != 0
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testWinZipAES256Against7Zip() throws {
        let sevenZip = URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
        guard FileManager.default.isExecutableFile(atPath: sevenZip.path) else {
            throw XCTSkip("/opt/homebrew/bin/7zz is unavailable; WinZip AES fixture skipped")
        }

        let fixture = try makeFixtureDirectory(label: "winzip-aes")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data("WinZip AES-256 compatibility \u{65e5}\u{672c}\u{8a9e}\n".utf8)
        try plaintext.write(to: fixture.input)

        try run(
            sevenZip,
            arguments: [
                "a", "-bd", "-y", "-tzip", "-mm=Copy", "-mem=AES256",
                "-pfixed-password", fixture.archive.path, fixture.input.lastPathComponent
            ],
            currentDirectory: fixture.directory
        )

        let record = try parseLocalRecord(Data(contentsOf: fixture.archive))
        XCTAssertEqual(record.method, 99)
        let aesExtra = try extraField(id: WinZipAESMetadata.extraFieldID, in: record.extra)
        let metadata = try WinZipAESMetadata(extraFieldPayload: aesExtra)
        XCTAssertEqual(metadata.strength, .aes256)
        XCTAssertEqual(metadata.compressionMethod, 0)

        let result = try WinZipAES.decrypt(
            payload: record.payload,
            password: "fixed-password",
            metadata: metadata
        )
        XCTAssertEqual(result.data, plaintext)

        let cachedResult = try WinZipAES.decrypt(
            payload: record.payload,
            password: "fixed-password",
            metadata: metadata,
            cachedKeys: result.derivedKeys
        )
        XCTAssertEqual(cachedResult.data, plaintext)

        XCTAssertThrowsError(
            try WinZipAES.decrypt(
                payload: record.payload,
                password: "wrong",
                metadata: metadata
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        var damaged = record.payload
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        let preparedDamage = try WinZipAES.prepareDecryption(
            payload: damaged,
            password: "fixed-password",
            metadata: metadata
        )
        XCTAssertEqual(preparedDamage.data, plaintext)
        XCTAssertThrowsError(try preparedDamage.authenticationCheck.verify()) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        XCTAssertThrowsError(
            try WinZipAES.decrypt(
                payload: damaged,
                password: "fixed-password",
                metadata: metadata
            )
        ) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        // 誤パスワードの後に正しい鍵をキャッシュでき、再読み込みで再利用できる。
        let reader = try ArchiveReader.open(
            url: fixture.archive,
            options: ReaderOptions(password: "wrong")
        )
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
        reader.password = "fixed-password"
        XCTAssertEqual(try reader.read(entry), plaintext)
        XCTAssertEqual(try reader.read(entry), plaintext)
        reader.password = "wrong"
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }

        var damagedArchive = try Data(contentsOf: fixture.archive)
        let originalPayload = record.payload
        let payloadRange = try XCTUnwrap(damagedArchive.range(of: originalPayload))
        damagedArchive[damagedArchive.index(before: payloadRange.upperBound)] ^= 1
        let damagedArchiveURL = fixture.directory.appendingPathComponent("damaged.zip")
        try damagedArchive.write(to: damagedArchiveURL)
        let damagedReader = try ArchiveReader.open(
            url: damagedArchiveURL,
            options: ReaderOptions(password: "fixed-password")
        )
        let damagedEntry = try XCTUnwrap(damagedReader.entries.first)
        XCTAssertThrowsError(try damagedReader.read(damagedEntry)) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    private struct FixturePaths {
        let directory: URL
        let input: URL
        let archive: URL
    }

    private struct LocalRecord {
        let flags: UInt16
        let method: UInt16
        let dosTime: UInt16
        let crc32: UInt32
        let extra: Data
        let payload: Data
    }

    private func makeFixtureDirectory(label: String) throws -> FixturePaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaitoKit-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return FixturePaths(
            directory: directory,
            input: directory.appendingPathComponent("payload.txt"),
            archive: directory.appendingPathComponent("fixture.zip")
        )
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL
    ) throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let diagnostics = standardError.fileHandleForReading.readDataToEndOfFile()
            throw KaitoError.malformed(
                "fixture command failed: \(String(decoding: diagnostics, as: UTF8.self))"
            )
        }
    }

    private func parseLocalRecord(_ archive: Data) throws -> LocalRecord {
        guard archive.count >= 30,
              try readUInt32LE(archive, at: 0) == 0x0403_4B50 else {
            throw KaitoError.malformed("test fixture has no local ZIP header")
        }

        let flags = try readUInt16LE(archive, at: 6)
        let method = try readUInt16LE(archive, at: 8)
        let dosTime = try readUInt16LE(archive, at: 10)
        var crc32 = try readUInt32LE(archive, at: 14)
        var compressedSize = Int(try readUInt32LE(archive, at: 18))
        if (flags & 0x0008) != 0 {
            let centralOffset = try singleEntryCentralDirectoryOffset(archive)
            guard try readUInt32LE(archive, at: centralOffset) == 0x0201_4B50 else {
                throw KaitoError.malformed("invalid test central-directory header")
            }
            crc32 = try readUInt32LE(archive, at: centralOffset + 16)
            compressedSize = Int(try readUInt32LE(archive, at: centralOffset + 20))
        }
        let nameLength = Int(try readUInt16LE(archive, at: 26))
        let extraLength = Int(try readUInt16LE(archive, at: 28))
        let extraStart = 30 + nameLength
        let dataStart = extraStart + extraLength
        let dataEnd = dataStart + compressedSize
        guard extraStart <= dataStart, dataStart <= dataEnd, dataEnd <= archive.count else {
            throw KaitoError.truncated
        }

        return LocalRecord(
            flags: flags,
            method: method,
            dosTime: dosTime,
            crc32: crc32,
            extra: Data(archive[extraStart..<dataStart]),
            payload: Data(archive[dataStart..<dataEnd])
        )
    }

    private func singleEntryCentralDirectoryOffset(_ archive: Data) throws -> Int {
        let signature = Data([0x50, 0x4B, 0x05, 0x06])
        guard let endRange = archive.range(of: signature, options: .backwards),
              archive.count - endRange.lowerBound >= 22 else {
            throw KaitoError.malformed("test fixture has no end record")
        }
        return Int(try readUInt32LE(archive, at: endRange.lowerBound + 16))
    }

    private func extraField(id expectedID: UInt16, in data: Data) throws -> Data {
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else {
                throw KaitoError.malformed("truncated test extra-field header")
            }
            let id = try readUInt16LE(data, at: offset)
            let size = Int(try readUInt16LE(data, at: offset + 2))
            let valueStart = offset + 4
            let valueEnd = valueStart + size
            guard valueStart <= valueEnd, valueEnd <= data.count else {
                throw KaitoError.malformed("truncated test extra-field value")
            }
            if id == expectedID {
                return Data(data[valueStart..<valueEnd])
            }
            offset = valueEnd
        }
        throw KaitoError.notFound("test extra field \(expectedID)")
    }

    private func readUInt16LE(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else {
            throw KaitoError.truncated
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            throw KaitoError.truncated
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private var streamingLimits: ReadLimits {
        var limits = ReadLimits()
        limits.maxInMemorySize = 8
        return limits
    }

    private func readSourceRange(
        _ source: any ByteSource,
        offset: Int,
        count: Int
    ) throws -> Data {
        var result = Data(count: count)
        var filled = 0
        while filled < count {
            let actual = try result.withUnsafeMutableBytes { storage in
                try source.read(
                    into: UnsafeMutableRawBufferPointer(
                        rebasing: storage[filled..<count]
                    ),
                    at: UInt64(offset + filled)
                )
            }
            guard actual > 0, actual <= count - filled else {
                throw KaitoError.truncated
            }
            filled += actual
        }
        return result
    }

    private func readStreamPrefix(
        _ stream: EntryStream,
        count: Int,
        bufferSize: Int
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while result.count < count {
            let requested = min(buffer.count, count - result.count)
            let actual = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested])
                )
            }
            guard actual > 0, actual <= requested else {
                throw KaitoError.truncated
            }
            result.append(contentsOf: buffer.prefix(actual))
        }
        return result
    }

    private func decodeHex(_ text: String) throws -> Data {
        guard text.utf8.count.isMultiple(of: 2) else {
            throw KaitoError.malformed("invalid test hex")
        }

        var result = Data()
        result.reserveCapacity(text.utf8.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

private final class ShortReadingByteSource: ByteSource {
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

private final class MutatingOnRepeatedReadByteSource: ByteSource, @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var readCounts: [Int]

    let length: UInt64

    init(data: Data) {
        self.data = data
        self.readCounts = [Int](repeating: 0, count: data.count)
        self.length = UInt64(data.count)
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let start = Int(offset)
        let count = min(buffer.count, data.count - start)
        guard count > 0, let destination = buffer.baseAddress else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        for index in 0..<count {
            let sourceIndex = start + index
            let original = data[sourceIndex]
            destination.storeBytes(
                of: readCounts[sourceIndex] == 0 ? original : original ^ 0x80,
                toByteOffset: index,
                as: UInt8.self
            )
            readCounts[sourceIndex] += 1
        }
        return count
    }

    func maximumReadCount(in range: Range<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCounts[range].max() ?? 0
    }
}

private struct ZipCryptoReferenceCipher {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    init(password: String) {
        for byte in password.utf8 {
            update(with: byte)
        }
    }

    mutating func encrypt(_ plaintext: Data) -> Data {
        var result = Data()
        result.reserveCapacity(plaintext.count)
        for byte in plaintext {
            let temporary = key2 | 2
            let product = temporary &* (temporary ^ 1)
            let keyStream = UInt8(truncatingIfNeeded: product >> 8)
            result.append(byte ^ keyStream)
            update(with: byte)
        }
        return result
    }

    private mutating func update(with byte: UInt8) {
        key0 = Self.crc32Update(key0, byte: byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc32Update(
            key2,
            byte: UInt8(truncatingIfNeeded: key1 >> 24)
        )
    }

    private static func crc32Update(_ crc: UInt32, byte: UInt8) -> UInt32 {
        var value = crc ^ UInt32(byte)
        for _ in 0..<8 {
            let polynomial: UInt32 = value & 1 == 0 ? 0 : 0xEDB8_8320
            value = (value >> 1) ^ polynomial
        }
        return value
    }
}
