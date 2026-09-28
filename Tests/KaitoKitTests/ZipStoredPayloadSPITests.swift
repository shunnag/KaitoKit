import Foundation
@_spi(ZipRawLayout) internal import KaitoKit
import XCTest
import zlib

final class ZipStoredPayloadSPITests: XCTestCase {
    func testPlainInfoZIPAndSevenZipStoredAndDeflate() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "stored-payload-spi")
        defer { try? FileManager.default.removeItem(at: directory) }
        let plaintext = Data(String(repeating: "保存 payload 日本語\n", count: 500).utf8)
        try plaintext.write(to: directory.appendingPathComponent("payload.txt"))
        for method in ["Copy", "Deflate"] {
            for encryption in ["none", "InfoZIP", "ZipCrypto", "AES128", "AES192", "AES256"] {
                let bytes = try makeArchive(in: directory, method: method, encryption: encryption)
                let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "spi-password"))
                let entry = try XCTUnwrap(reader.entries.first)
                let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: entry.index))
                XCTAssertEqual(layout.compressionMethod, method == "Copy" ? 0 : 8)
                if encryption == "InfoZIP" { XCTAssertTrue(layout.hasDataDescriptor) }
                if encryption == "ZipCrypto" { XCTAssertFalse(layout.hasDataDescriptor) }
                let stored = try reader.zipStoredPayloadStream(at: entry.index).readAll()
                let decoded = try method == "Copy" ? stored : inflateRaw(stored, size: plaintext.count)
                XCTAssertEqual(decoded, plaintext, "\(method) \(encryption)")
                XCTAssertEqual(decoded, try reader.stream(entry).readAll())
                if encryption == "none" {
                    XCTAssertEqual(stored, bytes.subdata(in: Int(layout.payloadRange.lowerBound)..<Int(layout.payloadRange.upperBound)))
                }
                if case .winZipAES = layout.encryption {
                    let material = try key(for: bytes, layout: layout, password: "spi-password")
                    let keyed = try ArchiveReader.open(data: bytes, options: ReaderOptions(
                        passwordProvider: StoredPayloadForbiddenPasswordProvider()))
                    XCTAssertEqual(try keyed.zipStoredPayloadStream(at: 0, aesKey: material).readAll(), stored)
                    XCTAssertEqual(try keyed.zipStream(at: 0, aesKey: material).readAll(), plaintext)
                    let wrong = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "wrong-password"))
                    XCTAssertThrowsError(try wrong.zipStoredPayloadStream(at: 0)) {
                        XCTAssertEqual($0 as? KaitoError, .wrongPassword)
                    }
                }
            }
        }
    }

    func testModernMethodsReturnCompressedBytesWithoutXZStaging() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "stored-modern-spi")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["xz-aes.zip", "xz-zipcrypto.zip", "zstd-aes20.zip", "zstd-aes93.zip"] {
            let bytes = try ZipModernFixtures.data(name)
            // 展開なら辞書上限に掛かる。保存 stream では codec を作らない。
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(
                limits: ReadLimits(maxDictionarySize: 1), password: ZipModernFixtures.password))
            let stored = try reader.zipStoredPayloadStream(at: 0).readAll()
            if name.hasPrefix("xz") {
                XCTAssertEqual(stored.prefix(6), Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]))
            }
            let packed = directory.appendingPathComponent(name.hasPrefix("xz") ? "payload.xz" : "payload.zst")
            try stored.write(to: packed)
            try requireTool(ZipTestSupport.sevenZipPath)
            let decoded = try ZipTestSupport.checkedRun(ZipTestSupport.sevenZipPath,
                arguments: ["x", "-so", packed.path]).standardOutput
            XCTAssertEqual(decoded, ZipModernFixtures.payload, name)
            let ordinary = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: ZipModernFixtures.password))
            XCTAssertEqual(try ordinary.stream(ordinary.entries[0]).readAll(), decoded)
            let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
            if case .winZipAES = layout.encryption {
                let material = try key(for: bytes, layout: layout, password: ZipModernFixtures.password)
                XCTAssertEqual(try reader.zipStoredPayloadStream(at: 0, aesKey: material).readAll(), stored)
                XCTAssertEqual(try ordinary.zipStream(at: 0, aesKey: material).readAll(), decoded)
                XCTAssertThrowsError(try reader.zipStream(at: 0, aesKey: material).readAll()) {
                    guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\($0)") }
                }
                var damaged = bytes
                damaged[Int(layout.payloadRange.upperBound) - 1] ^= 1
                let corrupt = try ArchiveReader.open(data: damaged, options: ReaderOptions(password: ZipModernFixtures.password))
                for supplied in [false, true] {
                    let stream = try corrupt.zipStoredPayloadStream(at: 0, aesKey: supplied ? material : nil)
                    var first: UInt8 = 0
                    XCTAssertEqual(try withUnsafeMutableBytes(of: &first) { try stream.read(into: $0) }, 1)
                    XCTAssertEqual(first, stored.first)
                    XCTAssertThrowsError(try stream.readAll()) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
                }
            }
        }
    }

    func testAESMaterialValidationAndAuthentication() throws {
        let bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/aes128-ae1.zip")
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "raw-password"))
        let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
        let material = try key(for: bytes, layout: layout, password: "raw-password")
        let stored = try reader.zipStoredPayloadStream(at: 0).readAll()
        XCTAssertEqual(try reader.zipStoredPayloadStream(at: 0, aesKey: material).readAll(), stored)
        XCTAssertEqual(try reader.zipStream(at: 0, aesKey: material).readAll(), try reader.stream(reader.entries[0]).readAll())
        for offset in [16, 32] {
            var changed = material.bytes
            changed[offset] ^= 1
            let wrong = try ZipAESKeyMaterial(salt: material.salt, strength: material.strength, bytes: changed)
            for expanded in [false, true] {
                XCTAssertThrowsError(try (expanded ? reader.zipStream(at: 0, aesKey: wrong)
                    : reader.zipStoredPayloadStream(at: 0, aesKey: wrong)).readAll()) {
                    XCTAssertEqual($0 as? KaitoError, .wrongPassword)
                }
            }
        }
        var changedSalt = material.salt
        changedSalt[0] ^= 1
        let wrongSalt = try ZipAESKeyMaterial(salt: changedSalt, strength: material.strength, bytes: material.bytes)
        let wrongStrength = try ZipAESKeyMaterial.derive(passwordBytes: Data("raw-password".utf8),
                                                       salt: Data(repeating: 0, count: 12), strength: 2)
        for wrong in [wrongSalt, wrongStrength] {
            assertMalformed { _ = try reader.zipStoredPayloadStream(at: 0, aesKey: wrong) }
            assertMalformed { _ = try reader.zipStream(at: 0, aesKey: wrong) }
        }
        let wrongPassword = try ZipAESKeyMaterial.derive(passwordBytes: Data("wrong".utf8), salt: material.salt, strength: material.strength)
        XCTAssertThrowsError(try reader.zipStream(at: 0, aesKey: wrongPassword)) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        // AE-1 は保存 stream と違い、展開 stream で CD の CRC を照合する。
        var badCRC = bytes
        let central = try XCTUnwrap(ZipTestSupport.layout(of: bytes).centralEntryOffsets.first)
        try ZipTestSupport.writeUInt32(layout.storedCRC32 ^ 1, to: &badCRC, at: central + 16)
        let corrupt = try ArchiveReader.open(data: badCRC)
        XCTAssertEqual(try corrupt.zipStoredPayloadStream(at: 0, aesKey: material).readAll(), stored)
        XCTAssertThrowsError(try corrupt.zipStream(at: 0, aesKey: material).readAll()) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 0))
        }
    }

    func testHMACFailureIsDeferredUntilFinalChunk() throws {
        for name in ["aes128-ae1", "aes128-ae2", "aes256-ae2"] {
            var bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/\(name).zip")
            let good = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "raw-password"))
            let layout = try XCTUnwrap(good.zipRawRecordLayout(at: 0))
            let material = try key(for: bytes, layout: layout, password: "raw-password")
            let stored = try good.zipStoredPayloadStream(at: 0).readAll()
            let expanded = try good.stream(good.entries[0]).readAll()
            bytes[Int(layout.payloadRange.upperBound) - 1] ^= 1
            for mode in 0..<3 {
                let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "raw-password"))
                let stream = try mode == 0 ? reader.zipStoredPayloadStream(at: 0)
                    : mode == 1 ? reader.zipStoredPayloadStream(at: 0, aesKey: material)
                    : reader.zipStream(at: 0, aesKey: material)
                let expected = mode == 2 ? expanded : stored
                var prefix = Data(count: expected.count - 1)
                XCTAssertEqual(try prefix.withUnsafeMutableBytes { try stream.read(into: $0) }, prefix.count)
                XCTAssertEqual(prefix, expected.dropLast())
                var final: UInt8 = 0
                for _ in 0..<2 {
                    XCTAssertThrowsError(try withUnsafeMutableBytes(of: &final) { try stream.read(into: $0) }) {
                        XCTAssertEqual($0 as? KaitoError, .wrongPassword)
                    }
                }
            }
        }
    }

    func testEncryptionKeyAloneCannotBeAuthenticatedByVerifierOrHMAC() throws {
        for name in ["aes128-ae1", "aes128-ae2"] {
            let bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/\(name).zip")
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "raw-password"))
            let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
            let material = try key(for: bytes, layout: layout, password: "raw-password")
            var changed = material.bytes
            changed[0] ^= 1
            let wrong = try ZipAESKeyMaterial(salt: material.salt, strength: material.strength, bytes: changed)
            // verifier と認証鍵は別 byte。暗号鍵だけの変更は HMAC の検査対象ではない。
            let stored = try reader.zipStoredPayloadStream(at: 0, aesKey: wrong).readAll()
            XCTAssertNotEqual(stored, try reader.zipStoredPayloadStream(at: 0).readAll())
            if name.hasSuffix("ae1") {
                XCTAssertThrowsError(try reader.zipStream(at: 0, aesKey: wrong).readAll()) {
                    XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: 0))
                }
            } else {
                XCTAssertEqual(try reader.zipStream(at: 0, aesKey: wrong).readAll(), stored)
            }
        }
    }

    func testZipCryptoVerifierCollisionNeedsExpandedCRC() throws {
        let bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/zipcrypto.zip")
        var collision: ArchiveReader?
        for candidate in 0..<65_536 {
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "collision-\(candidate)"))
            do {
                _ = try reader.zipStoredPayloadStream(at: 0).readAll()
                collision = reader
                break
            } catch KaitoError.wrongPassword {}
        }
        let reader = try XCTUnwrap(collision, "a one-byte ZipCrypto verifier collision must be found")
        XCTAssertThrowsError(try reader.stream(reader.entries[0]).readAll()) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
        print("ZIP-STORED-SPI ZipCrypto verifier collision: stored stream succeeds; expanded stream rejects with wrongPassword")
    }

    func testMaterialInitializerRejectsInvalidStrengthAndLengths() throws {
        for (strength, saltSize, byteSize): (UInt8, Int, Int) in [(1, 8, 34), (2, 12, 50), (3, 16, 66)] {
            for saltCount in [saltSize - 1, saltSize + 1] {
                assertMalformed { _ = try ZipAESKeyMaterial(salt: Data(count: saltCount), strength: strength, bytes: Data(count: byteSize)) }
                assertMalformed { _ = try ZipAESKeyMaterial.derive(passwordBytes: Data(), salt: Data(count: saltCount), strength: strength) }
            }
            for byteCount in [byteSize - 1, byteSize + 1] {
                assertMalformed { _ = try ZipAESKeyMaterial(salt: Data(count: saltSize), strength: strength, bytes: Data(count: byteCount)) }
            }
        }
        for strength: UInt8 in [0, 4, 255] {
            assertMalformed { _ = try ZipAESKeyMaterial(salt: Data(count: 8), strength: strength, bytes: Data(count: 34)) }
            assertMalformed { _ = try ZipAESKeyMaterial.derive(passwordBytes: Data(), salt: Data(count: 8), strength: strength) }
        }
    }

    func testUnsupportedEntriesAndIndexChecks() throws {
        let material = try ZipAESKeyMaterial.derive(passwordBytes: Data(), salt: Data(count: 8), strength: 1)
        let inputs = try ZipGoldenCorpus.inputs()
        for name in ["incomplete", "split-numbered", "split-native"] {
            let input = try XCTUnwrap(inputs.first { $0.id == name })
            try ZipGoldenCorpus.withReader(input, options: ReaderOptions(recoverDamagedArchives: true)) { reader in
                for entry in reader.entries {
                    if name == "split-native" {
                        XCTAssertEqual(try reader.zipStoredPayloadStream(at: entry.index).readAll(), try reader.stream(entry).readAll())
                    } else {
                        XCTAssertThrowsError(try reader.zipStoredPayloadStream(at: entry.index)) {
                            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("ZIP stored payload"))
                        }
                        XCTAssertThrowsError(try reader.zipStream(at: entry.index, aesKey: material)) {
                            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("ZIP stored payload"))
                        }
                    }
                }
                assertIndexErrors(reader, material: material)
            }
        }
        let tar = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1]))]))
        for expanded in [false, true] {
            XCTAssertThrowsError(try expanded ? tar.zipStream(at: 0, aesKey: material) : tar.zipStoredPayloadStream(at: 0)) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("ZIP stored payload"))
            }
        }
        assertIndexErrors(tar, material: material)
        let finder = try ZipTestSupport.checkedInFixture("appledouble/finder.zip")
        for policy in [AppleDoublePolicy.merge, .hide, .expose] {
            let reader = try ArchiveReader.open(data: finder, options: ReaderOptions(appleDoublePolicy: policy))
            for entry in reader.entries {
                if entry.formatSpecific["fork"] == "resource" {
                    XCTAssertThrowsError(try reader.zipStoredPayloadStream(at: entry.index)) {
                        XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("ZIP stored payload"))
                    }
                    XCTAssertThrowsError(try reader.zipStream(at: entry.index, aesKey: material)) {
                        XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("ZIP stored payload"))
                    }
                } else {
                    let stored = try reader.zipStoredPayloadStream(at: entry.index).readAll()
                    let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: entry.index))
                    let decoded = try layout.compressionMethod == 8
                        ? inflateRaw(stored, size: Int(XCTUnwrap(entry.uncompressedSize))) : stored
                    XCTAssertEqual(decoded, try reader.stream(entry).readAll())
                }
            }
        }
        for bytes in try [ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "plain")]),
                          ZipTestSupport.checkedInFixture("zip-golden/inputs/zipcrypto.zip")] {
            let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(passwordProvider: StoredPayloadForbiddenPasswordProvider()))
            assertMalformed { _ = try reader.zipStoredPayloadStream(at: 0, aesKey: material) }
            assertMalformed { _ = try reader.zipStream(at: 0, aesKey: material) }
            assertIndexErrors(reader, material: material)
        }
    }

    func testUnknownCompressionAndPasswordProviderFallback() throws {
        let bytes = try ZipTestSupport.checkedInFixture("zip-golden/inputs/aes128-ae1.zip")
        let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(passwordProvider: StoredPayloadPasswordProvider()))
        let layout = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
        let expected = try reader.zipStoredPayloadStream(at: 0).readAll()
        let missing = try ArchiveReader.open(data: bytes)
        XCTAssertThrowsError(try missing.zipStoredPayloadStream(at: 0)) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        let raw = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "unknown", uncompressedData: Data([1]),
                                                                     compressedData: expected, method: 96)])
        let unknown = try ArchiveReader.open(data: raw)
        XCTAssertEqual(try unknown.zipStoredPayloadStream(at: 0).readAll(), expected)
        XCTAssertThrowsError(try unknown.stream(unknown.entries[0])) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(layout.encryption, .winZipAES(strength: 1, vendorVersion: 1))
    }

    private func makeArchive(in directory: URL, method: String, encryption: String) throws -> Data {
        let archive = directory.appendingPathComponent("\(method)-\(encryption).zip")
        if encryption == "InfoZIP" {
            try requireTool(ZipTestSupport.infoZipPath)
            try ZipTestSupport.makeInfoZip(sourceDirectory: directory, paths: ["payload.txt"], archiveURL: archive,
                options: [method == "Copy" ? "-0" : "-9", "-e", "-P", "spi-password"])
        } else {
            try requireTool(ZipTestSupport.sevenZipPath)
            var args = ["a", "-bd", "-bb0", "-y", "-tzip", "-mm=\(method)"]
            if encryption != "none" { args += ["-mem=\(encryption)", "-pspi-password"] }
            _ = try ZipTestSupport.checkedRun(ZipTestSupport.sevenZipPath,
                arguments: args + [archive.path, "payload.txt"], currentDirectory: directory)
        }
        return try Data(contentsOf: archive)
    }

    private func requireTool(_ path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ZipTestSupportError.fixture("required A1 oracle is unavailable: \(path)")
        }
    }

    private func key(for bytes: Data, layout: ZipRawRecordLayout, password: String) throws -> ZipAESKeyMaterial {
        guard case .winZipAES(let strength, _) = layout.encryption else {
            throw ZipTestSupportError.fixture("expected AES fixture")
        }
        let offset = Int(layout.payloadRange.lowerBound)
        let saltLength = Int(strength) * 4 + 4
        return try ZipAESKeyMaterial.derive(passwordBytes: Data(password.utf8),
            salt: bytes.subdata(in: offset..<(offset + saltLength)), strength: strength)
    }

    private func inflateRaw(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, size))
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        XCTAssertEqual(stream.total_out, uLong(size))
        XCTAssertEqual(stream.avail_in, 0)
        return Data(output.prefix(size))
    }

    private func assertMalformed(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("\($0)", file: file, line: line) }
        }
    }

    private func assertIndexErrors(_ reader: ArchiveReader, material: ZipAESKeyMaterial) {
        for index in [-1, reader.entries.count] {
            XCTAssertThrowsError(try reader.zipStoredPayloadStream(at: index)) {
                XCTAssertEqual($0 as? KaitoError, .notFound("archive entry index \(index)"))
            }
            XCTAssertThrowsError(try reader.zipStream(at: index, aesKey: material)) {
                XCTAssertEqual($0 as? KaitoError, .notFound("archive entry index \(index)"))
            }
        }
    }
}

private struct StoredPayloadForbiddenPasswordProvider: PasswordProvider {
    func password(for format: ArchiveFormat) throws -> String? {
        XCTFail("supplied AES material must not request a password")
        throw KaitoError.passwordRequired
    }
}

private struct StoredPayloadPasswordProvider: PasswordProvider {
    func password(for format: ArchiveFormat) throws -> String? { "raw-password" }
}
