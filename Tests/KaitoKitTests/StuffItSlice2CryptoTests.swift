// 指定レポート Ch.02・05・06、固定鍵 vector と CC0 fixture の検証。
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItSlice2CryptoTests: XCTestCase {
    static func resources(_ items: [(String, Int, [UInt8])] = [], typeOffset: Int = 28) -> Data {
        var data: [UInt8] = [], offsets: [Int] = []
        for (_, _, payload) in items {
            offsets.append(data.count)
            var length = [UInt8](repeating: 0, count: 4)
            StuffItContainerTests.put(UInt64(payload.count), 4, 0, &length)
            data += length + payload
        }
        var map = [UInt8](repeating: 0, count: typeOffset + 2 + items.count * 20)
        StuffItContainerTests.put(UInt64(typeOffset), 2, 24, &map)
        StuffItContainerTests.put(UInt64(map.count), 2, 26, &map)
        StuffItContainerTests.put(items.isEmpty ? 65535 : UInt64(items.count - 1), 2, typeOffset, &map)
        for (i, item) in items.enumerated() {
            let type = typeOffset + 2 + i * 8, ref = typeOffset + 2 + items.count * 8 + i * 12
            map.replaceSubrange(type..<type + 4, with: item.0.utf8)
            StuffItContainerTests.put(UInt64(ref - typeOffset), 2, type + 6, &map)
            StuffItContainerTests.put(UInt64(UInt16(bitPattern: Int16(item.1))), 2, ref, &map)
            StuffItContainerTests.put(65535, 2, ref + 2, &map)
            StuffItContainerTests.put(UInt64(offsets[i]), 3, ref + 5, &map)
        }
        var header = [UInt8](repeating: 0, count: 16)
        StuffItContainerTests.put(16, 4, 0, &header)
        StuffItContainerTests.put(UInt64(16 + data.count), 4, 4, &header)
        StuffItContainerTests.put(UInt64(data.count), 4, 8, &header)
        StuffItContainerTests.put(UInt64(map.count), 4, 12, &header)
        map.replaceSubrange(0..<16, with: header)
        return Data(header + data + map)
    }
    struct KeyVector: Decodable {
        let password_hex: String; let entry_key_hex: String; let mkey_hex: String; let expected_key_and_iv_hex: String
    }
    func testClassicKnownFixtureAndPasswordLengthVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/stuffit/slice2-key-vectors.json")
        let vectors = try JSONDecoder().decode([KeyVector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 14)
        for v in vectors {
            let password = Array(StuffItCodecTests.hex(v.password_hex))
            let mkey = Array(StuffItCodecTests.hex(v.mkey_hex))
            let keys = try StuffItCrypto.ClassicKeys(password: password, mkey: mkey)
            let fork = try keys.fork(trailer: Array(StuffItCodecTests.hex(v.entry_key_hex)))
            XCTAssertEqual(StuffItCrypto.bytes(fork.key) + StuffItCrypto.bytes(fork.iv), Array(StuffItCodecTests.hex(v.expected_key_and_iv_hex)))
            let highBits = try StuffItCrypto.ClassicKeys(password: password.map { $0 | 128 }, mkey: mkey)
            XCTAssertEqual(highBits.verifier, keys.verifier)
            XCTAssertThrowsError(try StuffItCrypto.ClassicKeys(password: [0, 1, 2], mkey: mkey)) {
                XCTAssertEqual($0 as? KaitoError, .wrongPassword)
            }
        }
    }
    func testResourceOffsetsIDsAndMalformedMaps() throws {
        let bytes = Self.resources([("MKey", 1, [0]), ("SitC", 0, Array("comment".utf8)),
                                    ("MKey", 0, Array(0..<8))], typeOffset: 40)
        let map = try StuffItResourceMap(source: DataByteSource(data: bytes), limits: ReadLimits())
        XCTAssertEqual(map.mkey, Array(0..<8)); XCTAssertEqual(map.comment, Array("comment".utf8))
        XCTAssertNil(try StuffItResourceMap(source: DataByteSource(data: Self.resources()), limits: ReadLimits()).mkey)
        for bad in [Data(), bytes.dropLast(), Self.resources([("MKey", 0, [1])]),
                    Self.resources([("SitC", 0, []), ("SitC", 0, [])])] {
            XCTAssertThrowsError(try StuffItResourceMap(source: DataByteSource(data: bad), limits: ReadLimits()))
        }
        XCTAssertThrowsError(try StuffItResourceMap(source: DataByteSource(data: bytes), limits: ReadLimits(maxMetadataRecordCount: 1)))
        var bad = bytes; bad[16] = 255
        XCTAssertThrowsError(try StuffItResourceMap(source: DataByteSource(data: bad), limits: ReadLimits()))
    }
    func testPasswordRequiredWrongChangedAndMissingMetadata() throws {
        let fixtures = StuffItCorpusTests()
        for name in ["testfile.stuffit45_dlx.mac9.password.sit.bin", "testfile.stuffit651_dlx.mac9.password.sit", "testfile.stuffit7_dlx.mac9.password.sit"] {
            let reader = try ArchiveReader.open(data: fixtures.fixture(name))
            let entry = try XCTUnwrap(reader.entries.first { $0.isEncrypted && $0.formatSpecific["fork"] == "data" })
            XCTAssertThrowsError(try reader.read(entry)) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
            reader.password = "wrong"
            XCTAssertThrowsError(try reader.read(entry)) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
            reader.password = "password"
            XCTAssertEqual(StuffItCorpusTests().sha(try reader.read(entry)), "9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25")
            let plain = try ArchiveReader.open(data: fixtures.fixture(name.replacingOccurrences(of: ".password", with: "")))
            for encrypted in reader.entries where encrypted.isEncrypted {
                let expected = try XCTUnwrap(plain.entries.first { $0.pathComponents == encrypted.pathComponents })
                XCTAssertEqual(try reader.read(encrypted), try plain.read(expected), encrypted.name)
            }
            reader.password = nil
            XCTAssertThrowsError(try reader.read(entry)) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
            XCTAssertTrue(entry.isEncrypted)
        }
        let bare = try ArchiveReader.open(data: fixtures.fixture("testfile.stuffit45_dlx.mac9.password.sit"), options: ReaderOptions(password: "password"))
        XCTAssertThrowsError(try bare.read(bare.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt encryption without archive resource fork"))
        }
        var noHash = Array(try fixtures.fixture("testfile.stuffit651_dlx.mac9.password.sit"))
        noHash[83] &= 127; noHash[98] = 0; noHash[99] = 0
        let first = Int(StuffItHeader.be32(noHash, 94))
        StuffItContainerTests.put(UInt64(CRC16.checksum(Array(noHash[..<first]))), 2, 98, &noHash)
        let missing = try ArchiveReader.open(data: Data(noHash))
        XCTAssertThrowsError(try missing.read(missing.entries[0])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt 5 encryption without archive password hash"))
        }
    }
    func testArchiveCommentsFromBothContainers() throws {
        let bytes = StuffItWrapperTests.macBinary(StuffItContainerTests.classic(), resource: Self.resources([("SitC", 0, Array("comment".utf8))]))
        XCTAssertEqual(try ArchiveReader.open(data: bytes).entries[0].formatSpecific["comment"], "comment")
        let fixtures = StuffItCorpusTests()
        for name in ["testfile.stuffit45_dlx.mac9.comment.sit.bin", "testfile.stuffit651_dlx.mac9.comment.sit"] {
            let reader = try ArchiveReader.open(data: fixtures.fixture(name))
            let comment = try XCTUnwrap(reader.entries[0].formatSpecific["comment"], name)
            XCTAssertFalse(comment.isEmpty)
        }
    }
    func testClassicEightByteCorpusVariantHasVerifiedSeed() throws {
        let keys = try StuffItCrypto.ClassicKeys(password: Array("password".utf8), mkey: Array(StuffItCodecTests.hex("e3fe9f12776699c9")))
        XCTAssertEqual(keys.verifier, 0x955a10958aac6c80)
        // Ch.05 の標準派生そのものは、長さ 8 でも引き続き 2 block である。
        XCTAssertEqual(StuffItCrypto.classicArchiveKey(password: Array("password".utf8)), 0xeb53a5151ff258ce)
        XCTAssertThrowsError(try StuffItCrypto.ClassicKeys(password: Array("passw0rd".utf8), mkey: Array(StuffItCodecTests.hex("e3fe9f12776699c9")))) {
            XCTAssertEqual($0 as? KaitoError, .wrongPassword)
        }
    }
    func testFeedbackShortReadsReplayAndPadding() throws {
        final class ShortSource: ByteSource {
            let length: UInt64 = 32
            func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
                guard !buffer.isEmpty, offset < length else { return 0 }
                buffer[0] = UInt8(offset); return 1
            }
        }
        let mode = StuffItCryptoSource.Mode.classic(key: 0xa350f1a317a7cf44, iv: 0xc41612d4f53ad57c)
        let source = try StuffItCryptoSource(source: ShortSource(), offset: 0, stored: 32, padding: 3, mode: mode)
        let expected = StuffItCodecTests.hex("6747e174e6981c3f5e632ed4b94e368411a5147f0ab93fc5b2420d2ed746bf61").prefix(29)
        XCTAssertEqual(source.length, 29)
        for offset in [0, 11, 4, 28, 29, 0] {
            var bytes = [UInt8](repeating: 0, count: 7)
            let count = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: UInt64(offset)) }
            XCTAssertEqual(Data(bytes.prefix(count)), expected.dropFirst(offset).prefix(7))
        }
        for (stored, padding): (UInt64, UInt64) in [(7, 0), (16, 17)] {
            XCTAssertThrowsError(try StuffItCryptoSource(source: ShortSource(), offset: 0, stored: stored, padding: padding, mode: mode))
        }
    }
    func testRC4ForkKeyReplayAndMD5Truncation() throws {
        let bytes = try StuffItCorpusTests().fixture("testfile.stuffit651_dlx.mac9.password.sit")
        let source = DataByteSource(data: bytes)
        var parser = StuffItParser(source: source, limits: ReadLimits()); try parser.stuffIt5()
        let archiveKey = try StuffItCrypto.sit5Key(password: Array("password".utf8), hash: XCTUnwrap(parser.archiveHash))
        XCTAssertEqual(archiveKey, Array(StuffItCodecTests.hex("5f4dcc3b5a")))
        XCTAssertEqual(parser.archiveHash, Array(StuffItCodecTests.hex("7635b98711")))
        let record = try XCTUnwrap(parser.records.first { $0.method == 0 && $0.size == 11 })
        let mode = StuffItCryptoSource.Mode.rc4(archiveKey + record.entryKey)
        let decrypted = try StuffItCryptoSource(source: source, offset: record.offset, stored: record.stored, mode: mode)
        let plaintext = try readByteRange(source: decrypted, offset: 0, count: 11)
        XCTAssertEqual(StuffItCorpusTests().sha(Data(plaintext)), "9734aef6d3788ba985e78f7b3785dc4817e770be92a4e5e57e64a92cc9c2fc25")
        for offset in [7, 0, 9, 1] {
            XCTAssertEqual(try readByteRange(source: decrypted, offset: UInt64(offset), count: 2), Array(plaintext[offset..<offset + 2]))
        }
        let fresh = try StuffItCryptoSource(source: source, offset: record.offset, stored: record.stored, mode: mode)
        XCTAssertEqual(try readByteRange(source: fresh, offset: 0, count: 11), plaintext)
    }
    func testPasswordProviderAndEncryptedCRC() throws {
        struct Provider: PasswordProvider { func password(for format: ArchiveFormat) throws -> String? { "password" } }
        let fixtures = StuffItCorpusTests()
        for name in ["testfile.stuffit45_dlx.mac9.password.sit.bin", "testfile.stuffit651_dlx.mac9.password.sit"] {
            let original = try fixtures.fixture(name)
            let source = DataByteSource(data: original)
            let envelope = try XCTUnwrap(FormatDetector.stuffItInput(source: source, limits: ReadLimits()))
            var parser = StuffItParser(source: envelope.data, limits: ReadLimits())
            if name.hasSuffix(".bin") { try parser.classic() } else { try parser.stuffIt5() }
            let index = try XCTUnwrap(parser.records.firstIndex { $0.encrypted && $0.method == 0 && $0.size > 0 })
            let good = try ArchiveReader.open(data: original, options: ReaderOptions(passwordProvider: Provider()))
            _ = try good.read(good.entries[index])
            var damaged = try readByteRange(source: envelope.data, offset: 0, count: Int(envelope.data.length))
            damaged[Int(parser.records[index].offset)] ^= 1
            let resource = try envelope.resource.map { Data(try readByteRange(source: $0, offset: 0, count: Int($0.length))) }
            let bytes = resource.map { StuffItWrapperTests.macBinary(Data(damaged), resource: $0) } ?? Data(damaged)
            let bad = try ArchiveReader.open(data: bytes, options: ReaderOptions(password: "password"))
            XCTAssertThrowsError(try bad.read(bad.entries[index])) { XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: index)) }
        }
    }
}
