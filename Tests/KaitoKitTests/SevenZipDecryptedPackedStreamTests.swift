import Foundation
import Synchronization
@_spi(SevenZipEditLayout) @testable import KaitoKit
import XCTest

final class SevenZipDecryptedPackedStreamTests: XCTestCase {
    private struct Corpus: Decodable {
        struct AES: Decodable {
            let scope: String
            let folderIndex: Int
            let password: String
            let plaintextLength: UInt64
            let plaintextSHA256: String
        }
        let archives: [String: [AES]]
    }

    func testAllFrozenMainAESOutputsWithRecordingOffAndOn() throws {
        let expected = try JSONDecoder().decode(Corpus.self,
            from: Data(contentsOf: SevenZipGolden.root.appendingPathComponent("expected-decrypted.json")))
        var checked = 0
        for (name, folders) in expected.archives.sorted(by: { $0.key < $1.key }) {
            for recording in [false, true] {
                var options = ReaderOptions(password: "secret")
                options.recordsSevenZipEditLayout = recording
                let main = folders.filter { $0.scope == "main" }
                guard !main.isEmpty else { continue }
                let reader = try ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent(name), options: options)
                for folder in main {
                    reader.password = folder.password
                    let stream = try reader.sevenZipDecryptedPackedStream(folder: folder.folderIndex, packedInput: 0)
                    XCTAssertEqual(stream.remaining, folder.plaintextLength, name)
                    var data = Data()
                    // CBC の block 境界と末尾の padding をまたぐ。
                    for size in [1, 15, 17, 65537] {
                        var buffer = [UInt8](repeating: 0, count: size)
                        let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    data.append(try stream.readAll())
                    XCTAssertEqual(data.count, Int(folder.plaintextLength), name)
                    XCTAssertEqual(SevenZipGolden.sha(data), folder.plaintextSHA256, "\(name)/\(folder.folderIndex)")
                    XCTAssertEqual(stream.remaining, 0)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 20)
        print("7Z-DECRYPTED main AES folder/mode checks=\(checked)")
    }

    func testErrorsProviderAndCurrentPassword() throws {
        let provider = SevenZipEditPasswordProvider()
        let reader = try ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent("copyaes.7z"),
            options: ReaderOptions(passwordProvider: provider))
        XCTAssertThrowsError(try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
        XCTAssertEqual(provider.calls.withLock { $0 }, 0)
        for folder in [-1, 2, Int.max] {
            XCTAssertThrowsError(try reader.sevenZipDecryptedPackedStream(folder: folder, packedInput: 0)) {
                XCTAssertEqual($0 as? KaitoError, .notFound("7z folder \(folder)"))
            }
        }
        for input in [-1, 1, Int.max] {
            XCTAssertThrowsError(try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: input)) {
                XCTAssertEqual($0 as? KaitoError, .notFound("7z packed input \(input)"))
            }
        }
        reader.password = "secret"
        let correct = try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll()
        reader.password = "wrong"
        let wrong = try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll()
        XCTAssertEqual(correct.count, wrong.count)
        XCTAssertNotEqual(correct, wrong)
        reader.password = "secret"
        XCTAssertEqual(try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll(), correct)
        let plain = try ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent("g_plain.7z"))
        XCTAssertThrowsError(try plain.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("7z packed input is not read by AES"))
        }
        let limited = try ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent("g_aes.7z"),
            options: ReaderOptions(password: "secret", maxSevenZipAESCyclesPower: 0))
        XCTAssertThrowsError(try limited.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("7zAES cycle power 19"))
        }
    }

    func testKeyCacheIsSharedWithHeaderAndEntryStreams() throws {
        for name in ["g_aes.7z", "g_aesh.7z", "z_aes.7z", "z_aesh.7z"] {
            let derivations = Mutex(0)
            try SevenZipAESKeyCache.$didDeriveKey.withValue({ derivations.withLock { $0 += 1 } }) {
                let reader = try ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent(name),
                    options: ReaderOptions(password: "secret"))
                _ = try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll()
                XCTAssertEqual(derivations.withLock { $0 }, 1, name)
                _ = try reader.sevenZipDecryptedPackedStream(folder: 0, packedInput: 0).readAll()
                let entry = try XCTUnwrap(reader.entries.first { $0.isEncrypted })
                _ = try reader.read(entry)
                XCTAssertEqual(derivations.withLock { $0 }, 1, name)
            }
        }
    }

    func testPackDigestIsVerifiedBeforeAESAndIndirectAESIsRejected() throws {
        let bytes = Data(repeating: 0, count: 16)
        let source = CountingByteSource(DataByteSource(bytes))
        let aes = SevenZipCoder(methodID: [6, 0xf1, 7, 1], inputCount: 1, outputCount: 1,
            properties: [0x3f], firstInput: 0, firstOutput: 0)
        let folder = SevenZipFolder(coders: [aes], bindPairs: [], packedIndices: [0], inputCount: 1,
            outputCount: 1, finalOutputIndex: 0, unpackSizes: [16], digest: .init(value: nil))
        let verifier = SevenZipPackedStreamVerifier(source: source)
        let cache = SevenZipAESKeyCache()
        func factory(crc: UInt32) throws -> SevenZipFolderDecoderFactory {
            try SevenZipFolderDecoderFactory(source: source, folder: folder,
                packedRanges: [0: .init(offset: 0, size: 16, digest: .init(value: crc))],
                limits: ReadLimits(), password: "secret", keyCache: cache,
                maximumAESCyclesPower: 24, packedStreamVerifier: verifier)
        }
        XCTAssertThrowsError(try factory(crc: 0).makeDecryptedPackedDecoder(packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .checksumMismatch(entry: -1))
        }
        let good = try factory(crc: CRC32.checksum([UInt8](bytes)))
        _ = try good.makeDecryptedPackedDecoder(packedInput: 0)
        source.reset()
        _ = try good.makeDecryptedPackedDecoder(packedInput: 0)
        XCTAssertEqual(source.bytesRead, 0)
        let copy = SevenZipCoder(methodID: [0], inputCount: 1, outputCount: 1, properties: [], firstInput: 1, firstOutput: 1)
        let indirect = SevenZipFolder(coders: [aes, copy], bindPairs: [.init(input: 0, output: 1)],
            packedIndices: [1], inputCount: 2, outputCount: 2, finalOutputIndex: 0,
            unpackSizes: [16, 16], digest: .init(value: nil))
        let indirectFactory = try SevenZipFolderDecoderFactory(source: source, folder: indirect,
            packedRanges: [1: .init(offset: 0, size: 16, digest: .init(value: nil))],
            limits: ReadLimits(), password: "secret", keyCache: cache, maximumAESCyclesPower: 24)
        XCTAssertThrowsError(try indirectFactory.makeDecryptedPackedDecoder(packedInput: 0)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("7z packed input is not read by AES"))
        }
    }
}

private final class SevenZipEditPasswordProvider: PasswordProvider {
    let calls = Mutex(0)
    func password(for format: ArchiveFormat) throws -> String? {
        calls.withLock { $0 += 1 }
        return "secret"
    }
}
