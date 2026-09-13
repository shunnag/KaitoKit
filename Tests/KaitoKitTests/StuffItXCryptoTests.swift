// Ch.13 の固定値と人工書庫で、KDF・層順・framing・password の境界を検証する。
import CryptoKit
import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class StuffItXCryptoTests: XCTestCase {
    typealias Writer = StuffItXContainerTests.Writer
    static func hex(_ text: String) -> [UInt8] { Array(StuffItCodecTests.hex(text)) }
    static func records(_ ciphers: [(UInt64, UInt64)]) -> [StuffItXAlgorithm] {
        ciphers.map { .init(key: 4, value: $0.0, keyLength: $0.1) }
    }
    static let aesPayload = hex("45457e5f0c6402f7e5927cd0763a246021806239c4ff80b548ca45df82dd61847ce4b2624f032aa73dc0900b19")
    static let aesPlaintext = hex("14770000000c00000005740b1e4004361fbfba590e1c9c9980b7ff")

    func testPublishedKeysAndVerifiers() throws {
        let rows = [
            (8, "67b8172b1740a428", "4560"),
            (16, "67b8172b1740a428a148ab4c1f8f10ea", "557b"),
            (32, "95f5ed48c871277593afbf891a72b43f325eaeb3eea336572fc877b9f8644612", "4545"),
            (64, "e9b8ba3fa4c35e5f58e6232917b56fa633b8b5e2926627cfc3a0c0c0b846e31460f4aa0edc2200a2b5ab89070c841c7bfc780934f4281cc4bed4b6efdbbeb310", "cd6a")
        ]
        for (length, key, verifier) in rows {
            let material = try StuffItXCrypto.derive(Array("password".utf8), length: length)
            XCTAssertEqual(material, Self.hex(key))
            XCTAssertEqual(try StuffItXCrypto.derive(material, length: 2), Self.hex(verifier))
        }
    }

    func testFourContinuingSnapshotsAndCounts() {
        let values = ["42ad129a1acc9a97580ac35c7194019b", "97e90f3bc55ee74542507cb08fdfeee8",
                      "9525c3a2866cea1250838cfd29f48a52", "d4a937bb1b0a7950c4153ca41eea22d9"]
        let before: [UInt64] = [0, 56, 120, 184], saved: [UInt64] = [17, 73, 161, 225]
        let after: [UInt64] = [56, 120, 184, 248]
        var state = StuffItXContinuingMD5(), source = Array("password".utf8)
        for round in 0..<2 {
            var output: [UInt8] = []
            for j in 0..<2 {
                let i = round * 2 + j
                XCTAssertEqual(state.byteCount, before[i])
                state.absorb("StuffIt".utf8); state.absorb([0, UInt8(16 * j)]); state.absorb(source)
                XCTAssertEqual(state.byteCount, saved[i])
                let snapshot = state.snapshot()
                XCTAssertEqual(snapshot, Self.hex(values[i])); XCTAssertEqual(state.byteCount, after[i])
                output += snapshot
            }
            source = output
        }
    }

    func testFirstSnapshotMatchesMD5AcrossPaddingBoundaries() {
        for length in [0, 1, 7, 8, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 255] {
            let input = (0..<length).map { UInt8(truncatingIfNeeded: $0 * 37) }
            var state = StuffItXContinuingMD5(); state.absorb(input)
            XCTAssertEqual(state.snapshot(), Array(Insecure.MD5.hash(data: input)), "length=\(length)")
        }
    }

    func testCompletePublishedAESExampleAndFraming() throws {
        let crypto = try StuffItXCrypto(password: "password", algorithms: Self.records([(0, 32)]))
        XCTAssertEqual(Self.aesPayload.count, 45); XCTAssertEqual(Self.aesPlaintext.count, 27)
        // verifier・IV・暗号 block の途中をすべて framing 境界にする。
        var storage = Data(), ranges: [Range<UInt64>] = []
        for byte in Self.aesPayload {
            storage.append(0xee); let start = UInt64(storage.count)
            storage.append(byte); ranges.append(start..<start + 1)
        }
        let framed = try StuffItXFramedInput(source: DataByteSource(storage), ranges: ranges)
        let decrypted = try crypto.decrypt(framed)
        XCTAssertEqual(decrypted.length, 27)
        for chunk in [1, 7, 16, 65_536] {
            XCTAssertEqual(try Self.collect(decrypted, chunk: chunk), Self.aesPlaintext)
        }
        let cyanide = try StuffItXCodec.make(method: 1, source: decrypted, size: 12, limits: ReadLimits())
        let data = try StuffItXCodecTests.collect(cyanide, chunk: 1)
        XCTAssertEqual(data.count, 12); XCTAssertEqual(CRC32.checksum(data), 0x6ec18ffe)
        let wrong = try StuffItXCrypto(password: "wrong", algorithms: Self.records([(0, 32)]))
        XCTAssertThrowsError(try wrong.decrypt(framed)) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
    }

    static func collect(_ source: any ByteSource, chunk: Int) throws -> [UInt8] {
        var output: [UInt8] = [], buffer = [UInt8](repeating: 0, count: chunk)
        while output.count < source.length {
            let n = try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: UInt64(output.count)) }
            guard n > 0 else { throw KaitoError.truncated }; output += buffer.prefix(n)
        }
        return output
    }

    // テスト用の書込み方向。鍵スライスを先頭から適用し、IV/salt ごと外側の暗号へ渡す。
    static func seal(_ data: [UInt8], password: String = "password", ciphers: [(UInt64, UInt64)]) throws -> [UInt8] {
        let total = ciphers.reduce(0) { $0 + Int($1.1) }
        let material = try StuffItXCrypto.derive(Array(password.utf8), length: total)
        var payload = data, offset = 0
        for (cipher, count) in ciphers {
            let key = Array(material[offset..<offset + Int(count)]); offset += Int(count)
            let layer = StuffItXCrypto.Layer(cipher: cipher, key: key)
            let prefix = (0..<layer.prefixSize).map { UInt8(truncatingIfNeeded: $0 * 13 + offset) }
            var encrypted: [UInt8] = []
            if cipher == 3 {
                let rc4 = try StuffItRC4(key: key + prefix)
                encrypted = payload.map { rc4.transform($0) }
            } else {
                var feedback = prefix
                for start in stride(from: 0, to: payload.count, by: prefix.count) {
                    let mask = try StuffItXCrypto.encryptBlock(feedback, layer: layer)
                    let block = Array(payload[start..<min(start + prefix.count, payload.count)])
                    feedback = zip(block, mask).map { $0 ^ $1 }; encrypted += feedback
                }
            }
            payload = prefix + encrypted
        }
        return try StuffItXCrypto.derive(material, length: 2) + payload
    }

    func testAllCiphersLayerOrderPartialBlocksAndRandomReads() throws {
        let cases: [[(UInt64, UInt64)]] = [
            [(0, 16)], [(0, 24)], [(0, 32)], [(1, 5)], [(1, 6)], [(1, 7)], [(1, 56)], [(2, 8)], [(3, 1)], [(3, 64)],
            [(0, 32), (3, 64)], [(3, 64), (0, 32)], [(1, 16), (2, 8), (0, 24)], [(3, 8), (3, 8)]
        ]
        let plain = (0..<83).map { UInt8(truncatingIfNeeded: $0 * 7) }
        for ciphers in cases {
            let crypto = try StuffItXCrypto(password: "password", algorithms: Self.records(ciphers))
            let source = try crypto.decrypt(DataByteSource(Data(Self.seal(plain, ciphers: ciphers))))
            XCTAssertEqual(try Self.collect(source, chunk: 3), plain)
            for offset in [41, 0, 82, 16, 8] {
                let count = min(19, plain.count - offset)
                XCTAssertEqual(try readByteRange(source: source, offset: UInt64(offset), count: count), Array(plain[offset..<offset + count]))
            }
            let empty = try Self.seal([], ciphers: ciphers)
            XCTAssertEqual(try crypto.decrypt(DataByteSource(Data(empty))).length, 0)
            for length in [0, 1, 2, empty.count - 1] {
                XCTAssertThrowsError(try crypto.decrypt(DataByteSource(Data(empty.prefix(length))))) {
                    XCTAssertEqual($0 as? KaitoError, .truncated)
                }
            }
        }
    }

    func testKeySizeProfileAndOverflowBeforeDerivation() throws {
        for (cipher, lengths): (UInt64, [UInt64]) in [(0, [16, 24, 32]), (1, [5, 56]), (2, [8]), (3, [1, 1_024])] {
            for length in lengths { XCTAssertEqual(try StuffItXCrypto.validate(Self.records([(cipher, length)])), Int(length)) }
        }
        for pair: (UInt64, UInt64) in [(0, 15), (0, 33), (1, 4), (1, 57), (2, 7), (2, 9), (3, 1_025), (4, 16)] {
            XCTAssertThrowsError(try StuffItXCrypto.validate(Self.records([pair]))) {
                guard case KaitoError.unsupportedMethod = $0 else { return XCTFail("\($0)") }
            }
        }
        for length: UInt64 in [0, 65_537, .max] {
            XCTAssertThrowsError(try StuffItXCrypto.validate(Self.records([(3, length)])))
        }
        XCTAssertThrowsError(try StuffItXCrypto.validate([.init(key: 4, value: 0, keyLength: nil)]))
        let maximum = Self.records(Array(repeating: (3, 1_024), count: 64))
        XCTAssertEqual(try StuffItXCrypto.validate(maximum), 65_536)
        XCTAssertThrowsError(try StuffItXCrypto.validate(maximum + Self.records([(3, 1)])))
        for length in [-1, 0, 65_537, Int.max] { XCTAssertThrowsError(try StuffItXCrypto.derive([], length: length)) }
    }

    static func archive(password: String = "password", encryptedCatalog: Bool = false, auxiliary: Bool = false) throws -> Data {
        var w = Writer(data: Data("StuffIt!".utf8)); w.element(7, extra: 5)
        w.element(2, [(1, 1), (2, 0)])
        var catalog = Writer(); catalog.p2(1); catalog.string(Data("file".utf8)); catalog.p2(0); catalog.align()
        let ciphers: [(UInt64, UInt64)] = [(0, 32), (3, 64)]
        let algorithms: [(UInt64, UInt64, UInt64?)] = [(2, 0, nil)] + ciphers.map { (4, $0.0, $0.1) }
        w.element(5, [(5, UInt64(catalog.data.count))], encryptedCatalog ? algorithms : [(2, 0, nil)])
        let catalogPayload = encryptedCatalog ? try seal(Array(catalog.data), password: password, ciphers: ciphers) : Array(catalog.data)
        w.frames(catalogPayload.map { Data([$0]) }); w.frames([StuffItXReaderTests.checksum(catalog.data)])
        w.element(3, [(2, 1), (3, 10), (4, 0), (5, 3)], extra: auxiliary ? 3 : 0)
        if !auxiliary { w.element(3, [(2, 1), (3, 10), (4, 1), (5, 2)], extra: 1) }
        let plain = Data("ABCDE".utf8)
        w.element(1, [(1, 10), (5, 5)], algorithms)
        w.frames(try seal(Array(plain), password: password, ciphers: ciphers).map { Data([$0]) })
        w.frames([StuffItXReaderTests.checksum(plain)]); w.element(0)
        return w.data
    }

    final class Provider: PasswordProvider {
        let calls = Mutex(0)
        let value: String?
        init(_ value: String?) { self.value = value }
        func password(for format: ArchiveFormat) throws -> String? {
            XCTAssertEqual(format, .stuffItX); calls.withLock { $0 += 1 }; return value
        }
    }

    func testPasswordErrorsCatalogProviderAndPasswordChanges() throws {
        let data = try Self.archive()
        let reader = try ArchiveReader.open(data: data)
        XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        reader.password = "wrong"
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        reader.password = "password"
        XCTAssertEqual(try reader.read(reader.entries[1]), Data("DE".utf8))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("ABC".utf8))
        reader.password = nil
        XCTAssertThrowsError(try reader.stream(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        let provider = Provider("password")
        let provided = try ArchiveReader.open(data: data, options: ReaderOptions(passwordProvider: provider))
        XCTAssertEqual(provider.calls.withLock { $0 }, 0)
        XCTAssertEqual(try provided.read(provided.entries[0]), Data("ABC".utf8))
        XCTAssertEqual(provider.calls.withLock { $0 }, 1)

        let catalog = try Self.archive(encryptedCatalog: true)
        for value: String? in [nil, "wrong"] {
            XCTAssertThrowsError(try ArchiveReader.open(data: catalog, options: ReaderOptions(password: value))) {
                XCTAssertEqual($0 as? KaitoError, value == nil ? .passwordRequired : .wrongPassword)
            }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: catalog, options: ReaderOptions(passwordProvider: Provider(nil)))) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
        let catalogProvider = Provider("password")
        let unlocked = try ArchiveReader.open(data: catalog, options: ReaderOptions(passwordProvider: catalogProvider))
        XCTAssertEqual(catalogProvider.calls.withLock { $0 }, 1); XCTAssertEqual(unlocked.password, "password")
        XCTAssertEqual(try unlocked.read(unlocked.entries[1]), Data("DE".utf8))
        let reopened = try unlocked.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[0]), Data("ABC".utf8))
        XCTAssertEqual(catalogProvider.calls.withLock { $0 }, 1)
    }

    func testUTF8EmbeddedZeroAndEncryptedAuxiliaryListing() throws {
        let password = "日é\0本"
        let reader = try ArchiveReader.open(data: Self.archive(password: password, encryptedCatalog: true), options: ReaderOptions(password: password))
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("ABC".utf8))
        reader.password = "日e\u{301}\0本"
        XCTAssertThrowsError(try reader.read(reader.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        reader.password = password
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("ABC".utf8))
        let auxiliary = try ArchiveReader.open(data: Self.archive(auxiliary: true))
        XCTAssertEqual(auxiliary.entries.count, 1); XCTAssertTrue(auxiliary.entries[0].isEncrypted)
        XCTAssertThrowsError(try auxiliary.read(auxiliary.entries[0])) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
        auxiliary.password = "wrong"
        XCTAssertThrowsError(try auxiliary.read(auxiliary.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        auxiliary.password = "password"
        XCTAssertEqual(try auxiliary.read(auxiliary.entries[0]), Data())
    }

    func testCoordinatorReusesMaterialAcrossBackwardSeek() throws {
        let source = DataByteSource(try Self.archive())
        let element = try XCTUnwrap(StuffItXElementParser(source: source, limits: ReadLimits()).parse().first { $0.type == 1 })
        let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: 5, limits: ReadLimits(), password: "password")
        XCTAssertNil(coordinator.crypto)
        let tail = try coordinator.stream(offset: 3, length: 2)
        XCTAssertEqual(try StuffItXCodecTests.collect(tail, chunk: 1), Data("DE".utf8))
        let retained = try XCTUnwrap(coordinator.crypto)
        let head = try coordinator.stream(offset: 0, length: 3)
        XCTAssertTrue(coordinator.crypto === retained)
        XCTAssertEqual(try StuffItXCodecTests.collect(head, chunk: 1), Data("ABC".utf8))
        coordinator.setPassword("wrong")
        XCTAssertNil(coordinator.crypto)
        XCTAssertThrowsError(try StuffItXCodecTests.collect(head, chunk: 1))
        XCTAssertThrowsError(try coordinator.stream(offset: 0, length: 3)) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
    }

    func testLayeredStreamingCrossesInputBufferBoundaries() throws {
        let plain = (0..<40_003).map { UInt8(truncatingIfNeeded: $0 * 29) }
        let ciphers: [(UInt64, UInt64)] = [(0, 32), (3, 64)]
        let payload = try Self.seal(plain, ciphers: ciphers)
        let crypto = try StuffItXCrypto(password: "password", algorithms: Self.records(ciphers))
        let source = try crypto.decrypt(DataByteSource(Data(payload)))
        XCTAssertEqual(try Self.collect(source, chunk: 113), plain)
        XCTAssertEqual(try readByteRange(source: source, offset: 16_377, count: plain.count - 16_377), Array(plain.dropFirst(16_377)))
    }

    func testExternalEncryptedStreamsAndDESCompressedCounterparts() throws {
        guard let path = ProcessInfo.processInfo.environment["STUFFIT_SLICE6_CORPUS"] else { throw XCTSkip("外部コーパス未指定") }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("cc0")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".password.") && $0.pathExtension == "sitx" }
        XCTAssertEqual(files.count, 10)
        var verified = 0, catalogs = 0, jpeg = 0, encryptedMethod5 = 0
        let plain = try FileByteSource(url: directory.appendingPathComponent("testfile.stuffit_deluxe_2009.win.sitx"))
        let plainElements = try StuffItXElementParser(source: plain, limits: ReadLimits()).parse()
        for file in files {
            let source = try FileByteSource(url: file)
            let elements = try StuffItXElementParser(source: source, limits: ReadLimits()).parse()
            for element in elements where element.algorithms.contains(where: { $0.key == 4 }) {
                let size = try XCTUnwrap(element.attributes[5])
                if element.type == 5 || element.compression == 7 {
                    let crypto = try StuffItXCrypto(password: "password", algorithms: element.algorithms)
                    let decrypted = try crypto.decrypt(StuffItXFramedInput(source: source, ranges: element.data))
                    if element.type == 5 {
                        XCTAssertEqual(decrypted.length, 73); catalogs += 1
                        let candidate = try FileByteSource(url: directory.appendingPathComponent("testfile.stuffit_deluxe_2009.win.backcompat.sitx"))
                        let catalog = try XCTUnwrap(StuffItXElementParser(source: candidate, limits: ReadLimits()).parse().first { $0.type == 5 })
                        let expected = try StuffItXFramedInput(source: candidate, ranges: catalog.data)
                        XCTAssertEqual(try Self.collect(decrypted, chunk: 1), try Self.collect(expected, chunk: 7))
                    } else {
                        let counterpart = try XCTUnwrap(plainElements.first { $0.type == 1 && $0.compression == 7 })
                        let expected = try StuffItXFramedInput(source: plain, ranges: counterpart.data)
                        XCTAssertEqual(try Self.collect(decrypted, chunk: 1), try Self.collect(expected, chunk: 7))
                        XCTAssertEqual(decrypted.length, 168); jpeg += 1; continue
                    }
                }
                let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: size,
                                                            limits: ReadLimits(), password: "password")
                let data = try StuffItXCodecTests.collect(coordinator.stream(offset: 0, length: size), chunk: 113)
                XCTAssertEqual(UInt64(data.count), size)
                if element.type == 1 {
                    XCTAssertTrue(element.algorithms.contains { $0.key == 2 && $0.value == 0 }); verified += 1
                    if file.lastPathComponent == "testfile.stuffit_deluxe_2009.win.password.des.sitx", element.compression == 5 {
                        encryptedMethod5 += 1
                    }
                }
            }
        }
        XCTAssertEqual(verified, 38); XCTAssertEqual(catalogs, 1); XCTAssertEqual(jpeg, 1)
        XCTAssertGreaterThan(encryptedMethod5, 0)
        print("暗号実コーパス: 10 書庫、最終 CRC 一致 \(verified)、catalog 圧縮入力一致 \(catalogs)、JPEG 圧縮入力一致 \(jpeg)")
    }
}
