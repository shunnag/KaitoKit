import Foundation
@testable import KaitoKit
import XCTest

/// 7z の Zstandard coder（method ID 04 F7 11 01）。fixture は Homebrew libarchive 3.8.9 の
/// bsdtar が書き、zstd CLI と bsdtar で独立に検証したもの（Tests/Fixtures/sevenzip-zstd）。
final class SevenZipZstdTests: XCTestCase {
    func testMethodTableAndDescription() throws {
        let coder = SevenZipCoder(methodID: [0x04, 0xF7, 0x11, 0x01], inputCount: 1, outputCount: 1,
                                  properties: [1, 5, 3, 0, 0], firstInput: 0, firstOutput: 0)
        XCTAssertEqual(SevenZipMethod.kind(for: coder.methodID), .zstd)
        XCTAssertEqual(SevenZipMethod.description(for: coder), "Zstandard")
        // 隣の ID（7-Zip ZS の Brotli / LZ4）は従来どおり明示的に未対応。
        for other: [UInt8] in [[0x04, 0xF7, 0x11, 0x02], [0x04, 0xF7, 0x11, 0x04], [0x04, 0xF7, 0x11]] {
            guard case .unsupported = SevenZipMethod.kind(for: other) else {
                return XCTFail("\(other) must stay unsupported")
            }
        }
    }

    func testPropertiesLengthArityAndSizeAreValidated() throws {
        // `printf 'kaito-' | zstd --no-check` の 1 frame。
        let frame = try hex("28b52ffd00583100006b6169746f2d")
        let expected = Data("kaito-".utf8)
        for properties: [UInt8] in [[1, 5, 3], [1, 5, 3, 0, 0]] {
            XCTAssertEqual(try factory(packed: frame, properties: properties, size: 6).decodeAll(limit: 6), expected)
        }
        for properties: [UInt8] in [[], [1], [1, 5], [1, 5, 3, 0], [1, 5, 3, 0, 0, 0]] {
            XCTAssertThrowsError(try factory(packed: frame, properties: properties, size: 6).makeDecoder()) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertThrowsError(try factory(packed: frame, inputs: 2, size: 6).makeDecoder())
        // folder の宣言サイズと frame の内容が食い違えば失敗する（多くても少なくても）。
        for size: UInt64 in [5, 7] {
            XCTAssertThrowsError(try factory(packed: frame, size: size).decodeAll(limit: 8))
        }
    }

    func testSkippableAndConcatenatedFramesDecodeAsOneFolderStream() throws {
        // zstdmt 系の writer は skippable frame で区切った複数 frame を書く。RFC 8878 §3.1.2 の
        // skippable frame（magic 50 2A 4D 18、3 byte の payload）を 2 frame の間に置く。
        let packed = try hex(
            "28b52ffd00583100006b6169746f2d"      // "kaito-"（checksum なし）
                + "502a4d1803000000616263"           // skippable
                + "28b52ffd04582100007a737464452fa41d" // "zstd"（XXH64 付き）
        )
        XCTAssertEqual(try factory(packed: packed, size: 10).decodeAll(limit: 10), Data("kaito-zstd".utf8))
        // 末尾が skippable frame だけでも終端として扱う。
        XCTAssertEqual(
            try factory(packed: packed + hex("502a4d1800000000"), size: 10).decodeAll(limit: 10),
            Data("kaito-zstd".utf8)
        )
        // 途中で切れた frame は truncated / malformed で止まり、宣言サイズを満たさない。
        XCTAssertThrowsError(try factory(packed: Array(packed.prefix(packed.count - 3)), size: 10).decodeAll(limit: 10))
    }

    func testDictionaryFramesAndBadChecksumsAreRejectedInsideSevenZip() throws {
        // 既存 zstd fixture の辞書付き frame（Dictionary_ID 非零）は unsupportedMethod のまま。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dictionary = try XCTUnwrap(Data(base64Encoded: Data(contentsOf: root.appendingPathComponent("Fixtures/zstd/dictionary.zst.b64")), options: .ignoreUnknownCharacters))
        XCTAssertThrowsError(try factory(packed: [UInt8](dictionary), size: 1 << 20).decodeAll(limit: 1 << 20)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // XXH64 付き frame の checksum を壊すと typed error になる。
        var frame = try hex("28b52ffd04582100007a737464452fa41d")
        frame[frame.count - 1] ^= 0x01
        XCTAssertThrowsError(try factory(packed: frame, size: 4).decodeAll(limit: 4)) {
            switch $0 as? KaitoError {
            case .checksumMismatch, .malformed: break
            default: XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testFixturesListStreamReopenAndReverseRead() throws {
        for name in fixtureNames {
            let reader = try ArchiveReader.open(data: try fixture(name))
            XCTAssertEqual(reader.format, .sevenZip)
            XCTAssertEqual(Set(reader.entries.map(\.name)), Set(payloads.keys), name)
            let nonempty = reader.entries.filter { $0.uncompressedSize != 0 }
            XCTAssertEqual(Set(nonempty.map(\.solidGroup)).count, 1, name)
            for entry in nonempty {
                XCTAssertEqual(entry.methodDescription, "Zstandard", name)
                XCTAssertFalse(entry.isEncrypted)
            }
            for entry in reader.entries.reversed() {
                XCTAssertEqual(try read(reader.stream(entry), chunk: 37), payloads[entry.name], name + entry.name)
            }
            let reopened = try reader.reopen()
            for entry in reopened.entries {
                XCTAssertEqual(try reopened.read(entry), payloads[entry.name], name + entry.name)
            }
        }
    }

    func testLimitsTruncationAndDictionaryWindowAreEnforced() throws {
        for name in fixtureNames {
            let data = try fixture(name)
            for cutoff in [31, data.count / 2, data.count - 1] {
                XCTAssertThrowsError(try ArchiveReader.open(data: Data(data.prefix(cutoff))), "\(name) cutoff \(cutoff)")
            }
            for limits in [ReadLimits(maxEntrySize: 1_026), ReadLimits(maxTotalUncompressedSize: 263_429)] {
                XCTAssertThrowsError(try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits))) {
                    guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
                }
            }
            // 辞書上限は圧縮 header の LZMA（1 MiB）にも掛かるので open 自体が失敗する。
            XCTAssertThrowsError(try ArchiveReader.open(
                data: data, options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 4_096))
            )) {
                guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
            }
            let reader = try ArchiveReader.open(data: data, options: ReaderOptions(limits: ReadLimits(maxInMemorySize: 16)))
            let entry = try XCTUnwrap(reader.entries.first { $0.name == "first.bin" })
            XCTAssertThrowsError(try reader.read(entry))
            XCTAssertEqual(try read(reader.stream(entry), chunk: 17), payloads["first.bin"])
        }
    }

    func testFrameWindowIsCheckedAgainstDictionaryLimitNotFolderSize() throws {
        // `printf 'kaito-' | zstd -19 --no-content-size --no-check`: window descriptor は 8 MiB を宣言する。
        let frame = try hex("28b52ffd00683100006b6169746f2d")
        XCTAssertEqual(try factory(packed: frame, size: 6).decodeAll(limit: 6), Data("kaito-".utf8))
        XCTAssertThrowsError(
            try factory(packed: frame, size: 6, limits: ReadLimits(maxDictionarySize: 4_096)).decodeAll(limit: 6)
        ) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // folder の宣言サイズが entry 上限を超えていても、上限の判定は reader 側の仕事なので codec は通す。
        XCTAssertEqual(
            try factory(packed: frame, size: 6, limits: ReadLimits(maxEntrySize: 5)).decodeAll(limit: 6),
            Data("kaito-".utf8)
        )
    }

    // MARK: - helpers

    private let fixtureNames = ["zstd-l1.7z", "zstd-l19.7z"]
    private var payloads: [String: Data] {
        ["first.bin": Data((0..<(256 * 1025)).map { UInt8(truncatingIfNeeded: $0) }) + Data([17, 31, 127]),
         "second.bin": Data((0..<1027).map { UInt8(truncatingIfNeeded: $0 * 73 + 41) }), "empty": Data()]
    }

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let encoded = try Data(contentsOf: root.appendingPathComponent("Fixtures/sevenzip-zstd/" + name + ".b64"))
        return try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }

    private func factory(packed: [UInt8], properties: [UInt8] = [1, 5, 3, 0, 0], inputs: Int = 1,
                         size: UInt64, limits: ReadLimits = ReadLimits()) throws -> SevenZipFolderDecoderFactory {
        try SevenZipFolderDecoderFactory(source: DataByteSource(data: Data(packed)),
            folder: SevenZipFolder(coders: [SevenZipCoder(methodID: [0x04, 0xF7, 0x11, 0x01],
                inputCount: inputs, outputCount: 1, properties: properties, firstInput: 0, firstOutput: 0)],
                bindPairs: [], packedIndices: [0], inputCount: inputs, outputCount: 1,
                finalOutputIndex: 0, unpackSizes: [size], digest: SevenZipDigest(value: nil)),
            packedRanges: [0: SevenZipPackRange(offset: 0, size: UInt64(packed.count), digest: SevenZipDigest(value: nil))],
            limits: limits, password: nil, keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24)
    }

    private func read(_ stream: EntryStream, chunk: Int) throws -> Data {
        var output = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        while stream.remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }

    private func hex(_ string: String) throws -> [UInt8] {
        guard string.count.isMultiple(of: 2) else { throw KaitoError.malformed("odd test hex") }
        var result = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = end
        }
        return result
    }
}
