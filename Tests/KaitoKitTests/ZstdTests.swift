import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

// 許可資料は RFC 8878 と xxhash_spec.md。CLI は入出力の照合にだけ用いる。
final class ZstdTests: XCTestCase {
    private struct Row: Decodable {
        let name: String
        let size: UInt64
        let sha256: String
    }
    private struct Fixture: Decodable {
        let file: String
        let format: String
        let contentSize: UInt64?
        let features: [String]
        let entries: [Row]
        let decodedSize: Int
        let decodedSHA256: String
        let unsupported: Bool
    }
    private struct MatrixCase: Decodable {
        let file: String
        let input: String
        let size: UInt64
        let known: Bool
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private let zstd = "/opt/homebrew/bin/zstd"
    private let sevenZip = "/opt/homebrew/bin/7zz"

    private func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/zstd/manifest.json")))
    }

    private func fixture(_ name: String) throws -> Data {
        let bytes = try Data(contentsOf: root.appendingPathComponent("Fixtures/zstd/\(name).b64"))
        XCTAssertLessThanOrEqual(bytes.count, 40_000, name)
        return try XCTUnwrap(Data(base64Encoded: bytes, options: .ignoreUnknownCharacters))
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kaitokit-zstd-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ data: Data, limits: ReadLimits = ReadLimits(), expectedSize: UInt64? = nil) throws -> Data {
        let decoder = try ZstdDecompressor(source: DataByteSource(data), expectedSize: expectedSize, limits: limits)
        return try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil,
                               entryIndex: 0, limits: limits).readAll()
    }

    private func drain(_ stream: EntryStream, chunk: Int = 127) throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = try bytes.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { return result }
            result.append(contentsOf: bytes[..<count])
        }
    }

    func testEveryFixedFixtureListingSHAReopenAndSmallChunks() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try fixtures()
        XCTAssertEqual(fixtures.count, 46)
        let features = Set(fixtures.filter { !$0.unsupported }.flatMap(\.features))
        XCTAssertTrue(Set(["raw", "rle", "four-streams", "treeless", "repeat-fse", "fse-weights",
                           "single-segment", "window-descriptor", "concatenated", "skippable"]).isSubset(of: features))
        for fixture in fixtures {
            let data = try self.fixture(fixture.file)
            let url = directory.appendingPathComponent(fixture.file)
            try data.write(to: url)
            if fixture.unsupported {
                XCTAssertThrowsError(try ArchiveReader.open(url: url)) { error in
                    XCTAssertEqual(error as? KaitoError, .unsupportedMethod("zstd dictionary 8878"))
                }
                continue
            }
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format.rawValue, fixture.format, fixture.file)
            XCTAssertEqual(reader.entries.map(\.name), fixture.entries.map(\.name), fixture.file)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, fixture.file)
            for (entry, row) in zip(reader.entries, fixture.entries) {
                XCTAssertEqual(entry.uncompressedSize, fixture.format == "zstd" ? fixture.contentSize : row.size, fixture.file)
                let data = try reader.read(entry)
                XCTAssertEqual(UInt64(data.count), row.size, fixture.file)
                XCTAssertEqual(sha(data), row.sha256, fixture.file)
                XCTAssertEqual(try reopened.read(entry), data, fixture.file)
                XCTAssertEqual(try drain(reader.stream(entry)), data, fixture.file)
            }
        }
    }

    func testCLIGeneratedMatrix() throws {
        guard FileManager.default.isExecutableFile(atPath: zstd) else { throw XCTSkip("zstd CLI がありません") }
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        let script = root.deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/make-zstd.py")
        _ = try ZipTestSupport.checkedRun("/usr/bin/python3", arguments: [
            script.path, "--matrix", "--output", directory.path, "--zstd", zstd
        ])
        let cases = try JSONDecoder().decode([MatrixCase].self, from: Data(contentsOf: directory.appendingPathComponent("matrix.json")))
        XCTAssertEqual(cases.count, 80)
        for item in cases {
            let expected = try Data(contentsOf: directory.appendingPathComponent(item.input))
            XCTAssertEqual(UInt64(expected.count), item.size, item.file)
            let data = try Data(contentsOf: directory.appendingPathComponent(item.file))
            let reader = try ArchiveReader.open(data: data)
            XCTAssertEqual(reader.entries[0].uncompressedSize, item.known ? item.size : nil, item.file)
            XCTAssertEqual(try reader.read(reader.entries[0]), expected, item.file)
        }
        let elapsed = Date().timeIntervalSince(started)
        print("Zstd matrix: 80 cases in \(String(format: "%.3f", elapsed)) seconds")
        XCTAssertLessThan(elapsed, 60)
    }

    func testSevenZipSecondOracleForAllFixedStreamsAndZIP93() throws {
        guard FileManager.default.isExecutableFile(atPath: sevenZip) else { throw XCTSkip("7zz がありません") }
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        for item in try fixtures() where !item.unsupported && (item.file.hasSuffix(".zst") || item.format == "zip") {
            let data = try fixture(item.file)
            let url = directory.appendingPathComponent(item.file)
            try data.write(to: url)
            let oracle = try ZipTestSupport.checkedRun(sevenZip, arguments: ["x", "-so", "-bd", url.path]).standardOutput
            XCTAssertEqual(oracle.count, item.decodedSize, item.file)
            XCTAssertEqual(sha(oracle), item.decodedSHA256, item.file)
            if item.format == "zip" {
                let reader = try ArchiveReader.open(data: data)
                XCTAssertEqual(try reader.read(reader.entries[0]), oracle, item.file)
            } else { XCTAssertEqual(try decode(data), oracle, item.file) }
        }
    }

    private func assertKaitoError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue(error is KaitoError, "\(error)", file: file, line: line)
        }
    }

    func testTruncationsAndBitMutationsAreBoundedAndTyped() throws {
        let limits = ReadLimits(maxEntrySize: 8 * 1024 * 1024, maxTotalUncompressedSize: 8 * 1024 * 1024,
                                maxMetadataSize: 1024 * 1024, maxDictionarySize: 16 * 1024 * 1024)
        for item in try fixtures() {
            let original = try fixture(item.file)
            func read(_ bytes: Data) throws {
                if item.file.hasSuffix(".zst") { _ = try decode(bytes, limits: limits) }
                else {
                    let reader = try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: limits))
                    for entry in reader.entries { _ = try reader.read(entry) }
                }
            }
            for count in [original.count / 4, original.count / 2, original.count * 9 / 10, original.count - 1] {
                assertKaitoError { try read(Data(original.prefix(count))) }
            }
            for index in 0..<24 {
                var changed = original
                let offset = index * (original.count - 1) / 23
                changed[offset] ^= 1 << (index % 8)
                do {
                    try read(changed)
                    // 未使用ビット・skippable 本文・checksum 無しの変更は合法な場合もある。
                } catch { XCTAssertTrue(error is KaitoError, "\(item.file) @\(offset): \(error)") }
            }
        }
    }

    private func little(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func block(_ bytes: [UInt8], type: Int = 2, last: Bool = true, size: Int? = nil) -> [UInt8] {
        little(UInt64((size ?? bytes.count) << 3 | type << 1 | (last ? 1 : 0)), 3) + bytes
    }

    private func frame(_ blocks: [UInt8], contentSize: UInt64? = nil, window: UInt8 = 0) -> Data {
        let header: [UInt8] = contentSize.map { [0xe0] + little($0, 8) } ?? [0, window]
        return Data([0x28, 0xb5, 0x2f, 0xfd] + header + blocks)
    }

    private func bits(_ fields: [(Int, Int)]) -> [UInt8] {
        var result: [UInt8] = []
        var position = 0
        for (value, count) in fields.reversed() + [(1, 1)] {
            for bit in 0..<count {
                if position % 8 == 0 { result.append(0) }
                result[position / 8] |= UInt8((value >> bit) & 1) << (position % 8)
                position += 1
            }
        }
        return result
    }

    private func rleSequence(literals: [UInt8] = [], ll: UInt8 = 0, of: UInt8 = 0,
                             ml: UInt8 = 0, extra: [(Int, Int)] = []) -> [UInt8] {
        [UInt8(literals.count << 3)] + literals + [1, 0x54, ll, of, ml] + bits(extra)
    }

    private func assertWindow(_ data: Data, retained: Int, blocks: [[UInt8]], allocations: [Int]) throws {
        let input = try ZstdInput(source: DataByteSource(data), offset: 0, size: UInt64(data.count))
        XCTAssertEqual(try input.integer(4), ZstdFrameHeader.magic)
        let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
        XCTAssertEqual(header.retainedWindowSize, retained)
        let decoder = ZstdFrameDecoder(header: header)
        XCTAssertEqual(decoder.allocatedWindowBytes, 0)
        XCTAssertEqual(blocks.count, allocations.count)
        var produced = 0
        for (expected, allocation) in zip(blocks, allocations) {
            XCTAssertFalse(decoder.finished)
            let output = try decoder.nextBlock(input)
            XCTAssertEqual(output, expected)
            produced += output.count
            XCTAssertEqual(decoder.allocatedWindowBytes, allocation)
            XCTAssertLessThanOrEqual(decoder.allocatedWindowBytes, max(1, produced))
            XCTAssertLessThanOrEqual(decoder.allocatedWindowBytes, retained)
        }
        XCTAssertTrue(decoder.finished)
        XCTAssertEqual(input.remaining, 0)
        XCTAssertEqual(try decode(data), Data(blocks.flatMap { $0 }))
    }

    func testHugeWindowsAllocateOnlyProducedBytes() throws {
        let empty = Data([0x28, 0xb5, 0x2f, 0xfd, 0, 0xa0, 1, 0, 0])
        let concatenated = Data((0..<10_000).flatMap { _ in empty })
        let input = try ZstdInput(source: DataByteSource(concatenated), offset: 0, size: UInt64(concatenated.count))
        for _ in 0..<10_000 {
            XCTAssertEqual(try input.integer(4), ZstdFrameHeader.magic)
            let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
            XCTAssertNil(header.contentSize)
            XCTAssertEqual(header.windowSize, 1 << 30)
            XCTAssertEqual(header.retainedWindowSize, header.windowSize)
            let decoder = ZstdFrameDecoder(header: header)
            XCTAssertEqual(decoder.allocatedWindowBytes, 0)
            let output = try decoder.nextBlock(input)
            XCTAssertTrue(output.isEmpty)
            XCTAssertTrue(decoder.finished)
            XCTAssertEqual(decoder.allocatedWindowBytes, 0)
            XCTAssertLessThanOrEqual(decoder.allocatedWindowBytes, max(1, output.count))
        }
        XCTAssertEqual(input.remaining, 0)
        XCTAssertEqual(try decode(concatenated), Data())

        // 8 バイトの既知サイズが 1 GiB でも、空の最終ブロックは確保せず従来のサイズ不一致で拒否する。
        let declared = frame(block([], type: 0), contentSize: 1 << 30)
        XCTAssertEqual(declared.count, 16)
        let singleInput = try ZstdInput(source: DataByteSource(declared), offset: 0, size: UInt64(declared.count))
        XCTAssertEqual(try singleInput.integer(4), ZstdFrameHeader.magic)
        let header = try ZstdFrameHeader(input: singleInput, limits: ReadLimits())
        XCTAssertEqual(header.retainedWindowSize, 1 << 30)
        let decoder = ZstdFrameDecoder(header: header)
        XCTAssertEqual(decoder.allocatedWindowBytes, 0)
        XCTAssertThrowsError(try decoder.nextBlock(singleInput)) { error in
            XCTAssertEqual(error as? KaitoError, .malformed("zstd frame content size mismatch"))
        }
        XCTAssertEqual(decoder.allocatedWindowBytes, 0)
        XCTAssertLessThanOrEqual(decoder.allocatedWindowBytes, max(1, 0))
        XCTAssertThrowsError(try decode(declared)) { error in
            XCTAssertEqual(error as? KaitoError, .malformed("zstd frame content size mismatch"))
        }
        print("zstd 巨大 window: 空フレーム 10000 件と 16 バイト単一フレームの履歴確保は各 0 バイト")
    }

    func testRetainedWindowCapsKnownSizeAndPreservesDeclaredLimits() throws {
        for size in [0, 1, 4, 4_097] {
            let bytes = (0..<size).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
            let blocks = block(bytes, type: 0, last: false) + block([], type: 0)
            let data = Data([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0xa0] + little(UInt64(size), 8) + blocks)
            try assertWindow(data, retained: max(1, size), blocks: [bytes, []], allocations: [size, size])
            let input = try ZstdInput(source: DataByteSource(data), offset: 4, size: UInt64(data.count - 4))
            let header = try ZstdFrameHeader(input: input, limits: ReadLimits())
            XCTAssertEqual(header.windowSize, 1 << 30)
            XCTAssertEqual(header.maximumBlockSize, 128 * 1024)
            let limits = ReadLimits(maxDictionarySize: (1 << 30) - 1)
            XCTAssertThrowsError(try decode(data, limits: limits)) { error in
                guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
            }
        }
        try assertWindow(frame(block([], type: 0), contentSize: 0), retained: 0, blocks: [[]], allocations: [0])

        // 圧縮ブロックの符号化サイズが保持上限を超えても、宣言 window 内なら受理する。
        let encoded = rleSequence(literals: [97], ll: 1)
        XCTAssertGreaterThan(encoded.count, 4)
        let compressed = Data([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0xa0] + little(4, 8) + block(encoded))
        try assertWindow(compressed, retained: 4, blocks: [Array("aaaa".utf8)], allocations: [0])

        // 既知サイズを超えるブロックは、履歴を伸ばす前に拒否する。
        let oversized = Data([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0xa0] + little(1, 8)
                             + block([65, 66], type: 0, last: false) + block([], type: 0))
        let input = try ZstdInput(source: DataByteSource(oversized), offset: 4, size: UInt64(oversized.count - 4))
        let decoder = try ZstdFrameDecoder(header: ZstdFrameHeader(input: input, limits: ReadLimits()))
        XCTAssertThrowsError(try decoder.nextBlock(input)) { error in
            XCTAssertEqual(error as? KaitoError, .malformed("zstd frame output exceeds content size"))
        }
        XCTAssertEqual(decoder.allocatedWindowBytes, 0)
    }

    func testGrowingWindowMatchesAndRingTransitions() throws {
        let prefix = Array("abcdefgh".utf8)
        let first = block(prefix, type: 0, last: false)
        // 実履歴 8 バイトを超える距離も、先行リテラルを含む 11 バイト以内なら参照できる。
        let second = block(rleSequence(literals: Array("xyz".utf8), ll: 3, of: 3, extra: [(5, 3)]), last: false)
        try assertWindow(frame(first + second + block([], type: 0), window: 0xa0), retained: 1 << 30,
                         blocks: [prefix, Array("xyzbcd".utf8), []], allocations: [8, 14, 14])
        let knownGrowing = Data([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0xa0] + little(14, 8)
                                + first + second + block([], type: 0))
        try assertWindow(knownGrowing, retained: 14, blocks: [prefix, Array("xyzbcd".utf8), []],
                         allocations: [8, 14, 14])
        let tooFar = block(rleSequence(literals: Array("xyz".utf8), ll: 3, of: 3, extra: [(7, 3)]))
        XCTAssertThrowsError(try decode(frame(first + tooFar, window: 0xa0))) { error in
            XCTAssertEqual(error as? KaitoError, .malformed("zstd match exceeds history"))
        }
        // 最初のブロック内の重なる参照は、空の履歴配列とは独立に成立する。
        try assertWindow(frame(block(rleSequence(literals: [120], ll: 1), last: false) + block([], type: 0)),
                         retained: 1_024, blocks: [Array("xxxx".utf8), []], allocations: [4, 4])

        let bytes = (0..<5_000).map { UInt8(($0 * 7 + 3) % 251) }
        // 上限直前・上限ちょうど・追記中に上限到達の各状態から、複数回の折り返しを通る。
        for sizes in [[1_407, 1, 1_024, 1_024, 1_024], [1_024, 1_024, 1_024, 1_024]] {
            var encoded: [UInt8] = []
            var outputs: [[UInt8]] = []
            var allocations: [Int] = []
            var produced = 0
            for size in sizes {
                let output = Array(bytes[produced..<(produced + size)])
                encoded += block(output, type: 0, last: false)
                outputs.append(output)
                produced += size
                allocations.append(min(produced, 1_408))
            }
            let match = rleSequence(of: 10, extra: [(1_408 + 3 - 1_024, 10)])
            encoded += block(match)
            outputs.append(Array(bytes[(produced - 1_408)..<(produced - 1_405)]))
            allocations.append(1_408)
            try assertWindow(frame(encoded, window: 3), retained: 1_408, blocks: outputs, allocations: allocations)
            let known = Data([0x28, 0xb5, 0x2f, 0xfd, 0xc0, 3] + little(UInt64(produced + 3), 8) + encoded)
            try assertWindow(known, retained: 1_408, blocks: outputs, allocations: allocations)
        }
        // 直前の履歴とリテラルの合計は 1409 でも、宣言 window 1408 を超える距離を拒否する。
        let full = block(Array(bytes[..<1_408]), type: 0, last: false)
        let outsideWindow = block(rleSequence(literals: [97], ll: 1, of: 10,
                                              extra: [(1_409 + 3 - 1_024, 10)]))
        XCTAssertThrowsError(try decode(frame(full + outsideWindow, window: 3))) { error in
            XCTAssertEqual(error as? KaitoError, .malformed("zstd match exceeds history"))
        }
    }

    func testReservedFieldsBlockBoundsSizesChecksumAndDictionary() throws {
        let raw = block(Array("abc".utf8), type: 0)
        var reserved = frame(raw)
        reserved[4] |= 8
        assertKaitoError { _ = try decode(reserved) }
        var unused = frame(raw)
        unused[4] |= 16
        XCTAssertEqual(try decode(unused), Data("abc".utf8))
        for data in [frame(block([], type: 3)), frame(block([], type: 0, size: 1025)),
                     frame(block([], type: 0, size: 131073), window: 56),
                     frame(raw, contentSize: 4), frame(raw, contentSize: 2),
                     frame(raw) + Data([0]), Data([0x50, 0x2a, 0x4d, 0x18, 255, 255, 255, 255])] {
            assertKaitoError { _ = try decode(data) }
        }
        for flag: UInt8 in [1, 2, 3] {
            let count = [0, 1, 2, 4][Int(flag)]
            let dict = Data([0x28, 0xb5, 0x2f, 0xfd, flag, 0] + little(42, count))
            XCTAssertThrowsError(try decode(dict)) { error in
                XCTAssertEqual(error as? KaitoError, .unsupportedMethod("zstd dictionary 42"))
            }
        }
        var damaged = try fixture("text-l3.zst")
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try decode(damaged)) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 0))
        }
        assertKaitoError { _ = try decode(frame(raw), expectedSize: 2) }
        assertKaitoError { _ = try decode(frame(raw), expectedSize: 4) }
        XCTAssertEqual(try decode(frame(raw), expectedSize: 3), Data("abc".utf8))
    }

    func testDirectWeightsOneAndFourStreamsRLELiteralsAndFSETables() throws {
        // 二つの 1 ビット符号 0,1 を direct weights で記述する。
        let one = little(2 | (4 << 4) | (3 << 14), 3) + [128, 0x10, 0x15, 0]
        XCTAssertEqual(try decode(frame(block(one))), Data([0, 1, 0, 1]))
        let four = little(6 | (8 << 4) | (12 << 14), 3)
            + [128, 0x10, 1, 0, 1, 0, 1, 0, 5, 5, 5, 5, 0]
        XCTAssertEqual(try decode(frame(block(four))), Data([0, 1, 0, 1, 0, 1, 0, 1]))
        XCTAssertEqual(try decode(frame(block([41, 97, 0]))), Data(repeating: 97, count: 5))
        let first = block(rleSequence(literals: [120], ll: 1), last: false)
        // 直前の全 RLE table を Repeat mode で引き継ぐ。
        let repeatBlock = block([8, 121, 1, 0xfc, 1])
        XCTAssertEqual(try decode(frame(first + repeatBlock)), Data("xxxxyyyy".utf8))
        let prefix = block(Array("abcdefgh".utf8), type: 0, last: false)
        XCTAssertEqual(try decode(frame(prefix + block(rleSequence()))), Data("abcdefghefg".utf8))
        let deepest = try ZstdHuffman(weights: Array(stride(from: 11, through: 1, by: -1)))
        var reader = ZstdByteReader(bits((1...10).map { (1, $0) } + [(0, 11), (1, 11)]))
        XCTAssertEqual(try deepest.decode(from: &reader, count: 12, fourStreams: false), Array(0...11))
    }

    func testInvalidEntropyAndHistoryHaveTypedErrors() throws {
        for weights in [[], [0], [2, 2], [3, 1], [12], [11, 11]] {
            assertKaitoError { _ = try ZstdHuffman(weights: weights) }
        }
        for probabilities in [[32, 1], [32], [-2, 34], [1, 1]] {
            assertKaitoError { _ = try ZstdFSE(probabilities: probabilities, accuracyLog: 5) }
        }
        for bytes: [UInt8] in [[15], [0, 0, 0, 0, 0, 0, 0, 0], [0x10]] {
            var reader = ZstdByteReader(bytes)
            assertKaitoError { _ = try ZstdFSE.read(from: &reader, maximumLog: 6, maximumSymbol: 11) }
        }
        let treeless = little(3 | (4 << 4) | (1 << 14), 3) + [0x15, 0]
        let invalid: [[UInt8]] = [
            treeless, [0, 1, 0xfc, 1], [0, 1, 3, 1], [0, 0, 0],
            rleSequence(), rleSequence(of: 1, extra: [(1, 1)]),
            rleSequence(of: 4, extra: [(0, 4)]), rleSequence(ll: 1),
            rleSequence(of: 32), rleSequence(ml: 53),
            [0, 255, 255, 255], [0, 0x80, 1, 0x54, 0, 0, 0, 1]
        ]
        for bytes in invalid { assertKaitoError { _ = try decode(frame(block(bytes))) } }
        // 重み合計の不足が 2 の冪でない表を、実際の literals section でも拒否する。
        let badWeights = little(2 | (4 << 4) | (3 << 14), 3) + [129, 0x31, 0x15, 0]
        assertKaitoError { _ = try decode(frame(block(badWeights))) }
    }

    func testSequenceCountEncodingsAndWindowWrapWithMantissa() throws {
        for (count, encoding): (Int, [UInt8]) in [(127, [127]), (128, [128, 128]), (32512, [255, 0, 0])] {
            let prefix = block([UInt8](repeating: 65, count: 8), type: 0, last: false)
            let sequences: [UInt8] = [0] + encoding + [0x54, 0, 0, 0, 1]
            XCTAssertEqual(try decode(frame(prefix + block(sequences), window: 56)),
                           Data(repeating: 65, count: 8 + count * 3))
        }
        // window = 1024 + 3 * 128 = 1408。リングを一周し、ちょうど window 距離を参照する。
        let bytes = (0..<2048).map { UInt8(($0 * 7 + 3) % 251) }
        let prefix = block(Array(bytes[..<1024]), type: 0, last: false)
            + block(Array(bytes[1024...]), type: 0, last: false)
        let sequence = rleSequence(of: 10, extra: [(1408 + 3 - 1024, 10)])
        XCTAssertEqual(try decode(frame(prefix + block(sequence), window: 3)),
                       Data(bytes + bytes[640..<643]))
        let tooFar = rleSequence(of: 10, extra: [(1409 + 3 - 1024, 10)])
        assertKaitoError { _ = try decode(frame(prefix + block(tooFar), window: 3)) }
        let initial = block(Array("abcdefghij".utf8), type: 0, last: false)
        let setOffset = block(rleSequence(of: 3, extra: [(0, 3)]), last: false)
        let minusOne = block(rleSequence(of: 1, extra: [(1, 1)]))
        XCTAssertEqual(try decode(frame(initial + setOffset + minusOne)), Data("abcdefghijfghjfg".utf8))
    }

    func testWindowAndOutputLimitsTarAliasesAndTemporaryStaging() throws {
        let data = try fixture("long-window.zst")
        let limits = ReadLimits(maxDictionarySize: 1 << 16)
        for action in [
            { _ = try self.decode(data, limits: limits) },
            { _ = try ArchiveReader.open(data: data, options: ReaderOptions(limits: limits)) }
        ] {
            XCTAssertThrowsError(try action()) { error in
                guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
            }
        }
        let unknown = try fixture("unknown-size.zst")
        for limits in [ReadLimits(maxEntrySize: 100), ReadLimits(maxTotalUncompressedSize: 100),
                       ReadLimits(maxInMemorySize: 100)] {
            XCTAssertThrowsError(try {
                let reader = try ArchiveReader.open(data: unknown, options: ReaderOptions(limits: limits))
                _ = try reader.read(reader.entries[0])
            }()) { error in
                guard case .limitExceeded = error as? KaitoError else { return XCTFail("\(error)") }
            }
        }
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in [".tar.zst", ".tzst"] {
            let url = directory.appendingPathComponent("bundle" + suffix)
            try fixture("bundle.tar.zst").write(to: url)
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 1)))
            XCTAssertEqual(reader.format, .tar)
            XCTAssertEqual(reader.entries.map(\.name), ["hello.txt", "sub/data.bin"])
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("KaitoKit Zstandard tar\n".utf8))
            let single = try SingleFileReader(source: DataByteSource(fixture("bundle.tar.zst")), format: .zstd,
                                              options: ReaderOptions(), fallbackFileName: "bundle" + suffix)
            XCTAssertEqual(single.entries[0].name, "bundle.tar")
        }
    }

    func testSkippableMagicRangeFrameSizeFieldsAndStateReset() throws {
        for tag: UInt8 in 0x50...0x5f {
            let skip = Data([tag, 0x2a, 0x4d, 0x18, 0, 0, 0, 0])
            XCTAssertEqual(try FormatDetector.detect(data: skip), .zstd)
            XCTAssertEqual(try decode(skip), Data())
        }
        for sizeBytes in [1, 2, 4, 8] {
            let flag: UInt8 = [1: 0x20, 2: 0x60, 4: 0xa0, 8: 0xe0][sizeBytes]!
            let size = sizeBytes == 2 ? 256 : 3
            let header = [0x28, 0xb5, 0x2f, 0xfd, flag] + little(UInt64(sizeBytes == 2 ? 0 : size), sizeBytes)
            let data = Data(header + block([UInt8](repeating: 65, count: size), type: 0))
            XCTAssertEqual(try decode(data), Data(repeating: 65, count: size))
        }
        let valid = frame(block(rleSequence(literals: [120], ll: 1)))
        let repeated = frame(block([0, 1, 0xfc, 1]))
        assertKaitoError { _ = try decode(valid + repeated) }
    }

    func testXXH64IncrementalAcrossEveryStripeBoundary() throws {
        XCTAssertEqual(ZstdXXH64().value, 0xef46db3751d8e999)
        let input = [UInt8](0...255) + [UInt8](0...100)
        var full = ZstdXXH64()
        full.update(input[...])
        for chunk in 1...65 {
            var partial = ZstdXXH64()
            for offset in stride(from: 0, to: input.count, by: chunk) {
                partial.update(input[offset..<min(input.count, offset + chunk)])
            }
            XCTAssertEqual(partial.value, full.value)
        }
        let encoded = try fixture("text-l3.zst")
        let plain = try decode(encoded)
        var hash = ZstdXXH64()
        hash.update(Array(plain)[...])
        let stored = encoded.suffix(4).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        XCTAssertEqual(UInt64(UInt32(truncatingIfNeeded: hash.value)), stored)
    }

    private final class CountingSource: ByteSource, @unchecked Sendable {
        private let source: DataByteSource
        // 読取りの記録は同じロックで保護する。
        private let lock = NSLock()
        private var counts: [Int] = []
        var length: UInt64 { source.length }
        var readSizes: [Int] { lock.withLock { counts } }

        init(_ data: Data) { source = DataByteSource(data) }

        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            let count = try source.read(into: buffer, at: offset)
            lock.withLock { counts.append(count) }
            return count
        }
    }

    func testListingReadVolumeAndDirectBlockReads() throws {
        let blockSize = 128 * 1024
        let blockCount = 16
        let body = (0..<blockSize).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        let blocks = (0..<blockCount).flatMap { block(body, type: 0, last: $0 + 1 == blockCount) }
        let encoded = frame(blocks, contentSize: UInt64(blockSize * blockCount))
        let listingSource = CountingSource(encoded)
        XCTAssertEqual(try ZstdDecompressor.contentSize(source: listingSource, limits: ReadLimits()),
                       UInt64(blockSize * blockCount))
        let listingReads = listingSource.readSizes
        let listingBytes = listingReads.reduce(0, +)
        print("zstd 一覧の読取り: 入力 \(encoded.count) バイト、読取り \(listingBytes) バイト、\(listingReads.count) 回")
        XCTAssertEqual(listingReads.count, blockCount)
        XCTAssertLessThanOrEqual(listingBytes, blockCount * 4 * 1024)

        let decodeSource = CountingSource(encoded)
        let decoder = try ZstdDecompressor(source: decodeSource)
        let stream = try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil,
                                     entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try stream.readAll(), Data((0..<blockCount).flatMap { _ in body }))
        let decodeReads = decodeSource.readSizes
        XCTAssertEqual(decodeReads.reduce(0, +), encoded.count)
        XCTAssertLessThanOrEqual(decodeReads.count, (encoded.count + 64 * 1024 - 1) / (64 * 1024))
        print("zstd 復号の読取り: \(decodeReads.reduce(0, +)) バイト、\(decodeReads.count) 回")
    }

    func testInputDirectReadThresholdAndSkipBoundaries() throws {
        let bytes = Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0) })
        for request in [4_095, 4_096, 4_097] {
            let source = CountingSource(bytes)
            let input = try ZstdInput(source: source, offset: 0, size: source.length)
            XCTAssertEqual(try input.byte(), bytes[0])
            XCTAssertEqual(try input.read(4_095), Array(bytes[1..<4_096]))
            XCTAssertEqual(source.readSizes, [4_096])
            XCTAssertEqual(try input.read(request), Array(bytes[4_096..<(4_096 + request)]))
            XCTAssertEqual(source.readSizes, [4_096, max(4_096, request)])
            XCTAssertEqual(input.position, UInt64(4_096 + request))
            XCTAssertEqual(try input.byte(), bytes[4_096 + request])
        }
        for skip in [0, 4_094, 4_095, 4_096, 8_192] {
            let source = CountingSource(bytes)
            let input = try ZstdInput(source: source, offset: 0, size: source.length)
            XCTAssertEqual(try input.byte(), bytes[0])
            try input.skip(UInt64(skip))
            XCTAssertEqual(try input.read(4_096), Array(bytes[(1 + skip)..<(4_097 + skip)]))
            XCTAssertEqual(input.position, UInt64(4_097 + skip))
            XCTAssertEqual(try input.read(0), [])
            assertKaitoError { _ = try input.read(-1) }
            assertKaitoError { _ = try input.read(Int(input.remaining) + 1) }
            try input.skip(input.remaining)
            XCTAssertEqual(input.remaining, 0)
            assertKaitoError { _ = try input.byte() }
        }
    }

    private final class ShortSource: ByteSource {
        let data: Data
        let lower: UInt64
        let upper: UInt64
        var length: UInt64 { UInt64(data.count) }
        init(_ bytes: Data) {
            data = Data(repeating: 0xa5, count: 17) + bytes + Data(repeating: 0x5a, count: 29)
            lower = 17
            upper = 17 + UInt64(bytes.count)
        }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset >= lower, offset <= upper, UInt64(buffer.count) <= upper - offset else {
                throw KaitoError.malformed("test source range")
            }
            let count = min(7, buffer.count)
            data.withUnsafeBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[Int(offset)..<(Int(offset) + count)]))
            }
            return count
        }
    }

    func testByteSourceRangeShortReadsAndTerminalError() throws {
        let encoded = try fixture("table-reuse.zst")
        let source = ShortSource(encoded)
        let decoder = try ZstdDecompressor(source: source, offset: 17, compressedSize: UInt64(encoded.count))
        let stream = try EntryStream(decompressor: decoder, length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try drain(stream, chunk: 31), try decode(encoded))
        let truncated = try ZstdDecompressor(source: source, offset: 17, compressedSize: UInt64(encoded.count - 1))
        var buffer = [UInt8](repeating: 0, count: 131072)
        assertKaitoError {
            while try buffer.withUnsafeMutableBytes({ try truncated.read(into: $0) }) > 0 {}
        }
        assertKaitoError { _ = try buffer.withUnsafeMutableBytes { try truncated.read(into: $0) } }
        let large = frame(block([UInt8](repeating: 65, count: 131072), type: 0), window: 56)
        let largeSource = ShortSource(large)
        let raw = try ZstdDecompressor(source: largeSource, offset: 17, compressedSize: UInt64(large.count))
        let rawStream = try EntryStream(decompressor: raw, length: nil, expectedCRC32: nil, entryIndex: 0, limits: ReadLimits())
        XCTAssertEqual(try rawStream.readAll(), Data(repeating: 65, count: 131072))
    }
}
