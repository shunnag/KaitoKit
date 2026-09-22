import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// 7z Deflate64（04 01 09）。7zz 26.03 が生成・検証した fixture の SHA-256 と照合する。
final class SevenZipDeflate64Tests: XCTestCase {
    func testMethodTableAndDescription() throws {
        let coder = SevenZipCoder(methodID: [0x04, 0x01, 0x09], inputCount: 1, outputCount: 1,
                                  properties: [], firstInput: 0, firstOutput: 0)
        XCTAssertEqual(SevenZipMethod.kind(for: coder.methodID), .deflate64)
        XCTAssertEqual(SevenZipMethod.description(for: coder), "Deflate64")
        XCTAssertEqual(SevenZipMethod.kind(for: [0x04, 0x01, 0x08]), .deflate)
        for other: [UInt8] in [[0x04, 0x01], [0x04, 0x01, 0x0A], [0x04, 0x01, 0x09, 0x00]] {
            guard case .unsupported = SevenZipMethod.kind(for: other) else {
                return XCTFail("隣接 ID は未対応のまま: \(other)")
            }
        }
    }

    func testPropertiesArityAndDeclaredSizeAreValidated() throws {
        let manifest = try manifest()
        let item = try XCTUnwrap(manifest.fixtures.first { !$0.solid })
        let stream = try XCTUnwrap(item.packedStreams.first)
        let data = try fixture(item)
        let packed = data.subdata(in: stream.offset..<stream.offset + stream.size)
        let expected = try XCTUnwrap(manifest.entries["first.bin"])
        XCTAssertEqual(sha256(try factory(packed: packed, size: stream.unpackedSize)
            .decodeAll(limit: stream.unpackedSize)), expected.sha256)
        for properties: [UInt8] in [[0], [1, 2, 3, 4]] {
            XCTAssertThrowsError(try factory(packed: packed, properties: properties,
                                            size: stream.unpackedSize).makeDecoder()) {
                XCTAssertEqual($0 as? KaitoError, .malformed("7z Deflate64 has unexpected properties"))
            }
        }
        for inputs in [0, 2] {
            XCTAssertThrowsError(try factory(packed: packed, inputs: inputs,
                                            size: stream.unpackedSize).makeDecoder()) {
                XCTAssertEqual($0 as? KaitoError, .malformed("invalid 7z coder stream arity"))
            }
        }
        for size in [stream.unpackedSize - 1, stream.unpackedSize + 1] {
            XCTAssertThrowsError(try factory(packed: packed, size: size).decodeAll(limit: size)) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("想定外のエラー: \($0)") }
            }
        }
    }

    func testFixturesListStreamReopenAndReverseReadMatchManifest() throws {
        let manifest = try manifest()
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".7z.b64") }
        XCTAssertEqual(Set(files), Set(manifest.fixtures.map(\.file)))
        for item in manifest.fixtures {
            let data = try fixture(item)
            XCTAssertEqual(sha256(data), item.sha256, item.file)
            let reader = try ArchiveReader.open(data: data)
            XCTAssertEqual(reader.format, .sevenZip)
            XCTAssertEqual(reader.entries.map(\.name), item.entries, item.file)
            let nonempty = reader.entries.filter { $0.uncompressedSize != 0 }
            if item.solid {
                XCTAssertEqual(Set(nonempty.map(\.solidGroup)), [0], item.file)
            } else {
                XCTAssertTrue(nonempty.allSatisfy { $0.solidGroup == -1 }, item.file)
                XCTAssertEqual(nonempty.count, item.blocks, item.file)
            }
            for entry in reader.entries {
                let expected = try XCTUnwrap(manifest.entries[entry.name])
                XCTAssertEqual(entry.uncompressedSize, expected.size, item.file + entry.name)
                XCTAssertFalse(entry.isEncrypted)
                if expected.size > 0 {
                    XCTAssertTrue(entry.methodDescription.contains("Deflate64"), item.file + entry.name)
                } else {
                    XCTAssertEqual(entry.methodDescription, "Copy")
                }
                try assertStream(reader.stream(entry), matches: expected, chunk: 37)
            }
            for entry in reader.entries.reversed() {
                try assertStream(reader.stream(entry), matches: XCTUnwrap(manifest.entries[entry.name]), chunk: 17)
            }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries.map(\.name), item.entries)
            for entry in reopened.entries.reversed() {
                try assertStream(reopened.stream(entry), matches: XCTUnwrap(manifest.entries[entry.name]), chunk: 257)
            }
        }
    }

    func testReadLimitsAreEnforcedWithoutLimitingSolidFolderToOneEntry() throws {
        let manifest = try manifest()
        for item in manifest.fixtures {
            let data = try fixture(item)
            let entries = try item.entries.map { try XCTUnwrap(manifest.entries[$0]) }
            let largest = try XCTUnwrap(entries.map(\.size).max())
            let total = entries.reduce(UInt64(0)) { $0 + $1.size }
            for limits in [ReadLimits(maxEntrySize: largest - 1), ReadLimits(maxTotalUncompressedSize: total - 1)] {
                XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits))) {
                    guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("想定外のエラー: \($0)") }
                }
            }
            // folder 全体は entry 上限より大きくてもよい。readAll の上限と stream も区別する。
            let limits = ReadLimits(maxEntrySize: largest, maxTotalUncompressedSize: total, maxInMemorySize: 16)
            let reader = try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits))
            let first = try XCTUnwrap(reader.entries.first { $0.name == "first.bin" })
            XCTAssertThrowsError(try reader.read(first)) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("想定外のエラー: \($0)") }
            }
            for entry in reader.entries {
                try assertStream(reader.stream(entry), matches: XCTUnwrap(manifest.entries[entry.name]), chunk: 31)
            }
        }
    }

    func testTruncatedPackedStreamsFailWithTypedErrors() throws {
        for item in try manifest().fixtures {
            let data = try fixture(item)
            for stream in item.packedStreams {
                let cutoff = stream.offset + stream.size / 2
                XCTAssertThrowsError(try ArchiveReader.open(data: Data(data.prefix(cutoff)))) {
                    self.assertTruncatedOrMalformed($0)
                }
                // metadata の欠落だけでなく、coder 自体も途中の入力切れを検出する。
                let packed = data.subdata(in: stream.offset..<stream.offset + stream.size)
                for count in [packed.count / 2, packed.count - 1] {
                    XCTAssertThrowsError(try factory(packed: Data(packed.prefix(count)), size: stream.unpackedSize)
                        .decodeAll(limit: stream.unpackedSize)) {
                        self.assertTruncatedOrMalformed($0)
                    }
                }
            }
        }
    }

    func testCorruptedPackedStreamsFailWithChecksumOrMalformed() throws {
        for item in try manifest().fixtures {
            for stream in item.packedStreams {
                var data = try fixture(item)
                // header CRC は保ち、packed stream の最初の block type だけを予約値 3 にする。
                data[stream.offset] = (data[stream.offset] & 0xF9) | 0x06
                let reader = try ArchiveReader.open(data: data)
                XCTAssertThrowsError(try reader.entries.forEach { _ = try reader.read($0) }) {
                    switch $0 as? KaitoError {
                    case .checksumMismatch, .malformed: break
                    default: XCTFail("想定外のエラー: \($0)")
                    }
                }
            }
        }
    }

    // MARK: - 補助

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let size: UInt64
            let sha256: String
        }
        struct Fixture: Decodable {
            struct PackedStream: Decodable {
                let offset: Int
                let size: Int
                let unpackedSize: UInt64
            }
            let file: String
            let sha256: String
            let solid: Bool
            let blocks: Int
            let entries: [String]
            let packedStreams: [PackedStream]
        }
        let entries: [String: Entry]
        let fixtures: [Fixture]
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sevenzip-deflate64")
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    }

    private func fixture(_ item: Manifest.Fixture) throws -> Data {
        let encoded = try Data(contentsOf: root.appendingPathComponent(item.file))
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func factory(packed: Data, properties: [UInt8] = [], inputs: Int = 1,
                         size: UInt64) throws -> SevenZipFolderDecoderFactory {
        try SevenZipFolderDecoderFactory(source: DataByteSource(data: packed),
            folder: SevenZipFolder(coders: [SevenZipCoder(methodID: [0x04, 0x01, 0x09],
                inputCount: inputs, outputCount: 1, properties: properties, firstInput: 0, firstOutput: 0)],
                bindPairs: [], packedIndices: [0], inputCount: inputs, outputCount: 1,
                finalOutputIndex: 0, unpackSizes: [size], digest: SevenZipDigest(value: nil)),
            packedRanges: [0: SevenZipPackRange(offset: 0, size: UInt64(packed.count), digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(), password: nil, keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24)
    }

    private func assertStream(_ stream: EntryStream, matches expected: Manifest.Entry, chunk: Int,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        var digest = SHA256(), total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            digest.update(data: Data(buffer.prefix(count)))
            total += UInt64(count)
        }
        XCTAssertEqual(total, expected.size, file: file, line: line)
        XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(),
                       expected.sha256, file: file, line: line)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertTruncatedOrMalformed(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        switch error as? KaitoError {
        case .truncated, .malformed: break
        default: XCTFail("想定外のエラー: \(error)", file: file, line: line)
        }
    }
}
