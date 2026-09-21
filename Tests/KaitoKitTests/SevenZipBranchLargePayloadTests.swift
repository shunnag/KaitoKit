import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// 2026-09-20 に 1 MiB 超の乱数 payload で再現した x86 BCJ / ARM64 filter の回帰テスト。
/// 変位が ip との加減算で符号境界をまたぐ場合の折り返し規則を、7zz 26.03 の
/// `-m1=Copy -mhc=off` 出力(packed stream = filter の encode 出力)と照合する。
final class SevenZipBranchLargePayloadTests: XCTestCase {
    // MARK: - 固定ベクタ(7zz 26.03 の出力から切り出した実測値)

    func testX86DisplacementCrossingTwoToTheTwentyFourIsNormalized() throws {
        // 乱数 payload の offset 453,175 にあった E8 候補。元の変位 0x00FE37FB に ip を足すと
        // 2^24 をまたぎ、7zz は上位 byte を 0xFF に正規化して 0xFF052237 を書く。
        // 復号側も減算後に bit 24 の符号で上位 byte を 0x00 に戻さなければならない。
        let encoded = try hex("e83722 05ff0b867c624b")
        let expected = try hex("e8fb37fe000b867c624b")
        try assertDecode(
            encoded: encoded, expected: expected,
            filter: .x86, startOffset: 453_175
        )
    }

    func testX86DisplacementBeyondSixteenMiBOfInput() throws {
        // ip が 2^24 を超えた位置でも同じ正規化が要る。7zz 26.03 で 16 MiB + 4 KiB の
        // ゼロ埋め payload の offset 0x0100_0800 に E8 00 00 00 00 を置いて取得した。
        let encoded = try hex("e8050800ff")
        let expected = try hex("e800000000")
        try assertDecode(
            encoded: encoded, expected: expected,
            filter: .x86, startOffset: 0x0100_0800
        )
    }

    func testX86NestedCandidatesAcrossTheBoundary() throws {
        // lookback state が立った状態で 2 つ目の候補が 2^24 をまたぐ場合。16 MiB + 4 KiB の
        // ゼロ埋め payload の offset 0x00FF_FFF8 に E8 E8 00 00 12 00 00 00 を置いた。先頭の E8 は
        // 5 byte 目 0x12 が sign byte でないため変換されず previousMask を立て、offset 1 の E8 が
        // mask の立った状態で変換される。7zz 26.03 の出力は E8 E8 FE FF 11 FF 00 00。
        let encoded = try hex("e8e8feff11ff0000")
        let expected = try hex("e8e8000012000000")
        try assertDecode(
            encoded: encoded, expected: expected,
            filter: .x86, startOffset: 0x00FF_FFF8
        )
        // 先の版で使った、operand の中に E8 を含むだけの候補（lookback は関与しない）も残す。
        try assertDecode(
            encoded: try hex("e8fe01e8ff000000"), expected: try hex("e80102e800000000"),
            filter: .x86, startOffset: 0x00FF_FFF8
        )
    }

    func testARM64PageDeltaWrapsAtEighteenBits() throws {
        // 乱数 payload の offset 849,124 にあった ADRP。元の page delta 0x1FF91 に
        // pc >> 12 (= 0xCF) を足すと 0x20060 となり、7zz は 18 bit の符号付き値として
        // bit 17 を immhi の上位へ符号拡張した 0x90F00313 を書く。復号も同じ折り返しが要る。
        let encoded = try hex("1303f090")
        let expected = try hex("93fc0fb0")
        try assertDecode(
            encoded: encoded, expected: expected,
            filter: .arm64, startOffset: 849_124
        )
    }

    // MARK: - 7zz オラクルによる境界サイズの掃引

    func testBranchFiltersMatchSevenZipAcrossPayloadSizes() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable at \(ZipTestSupport.sevenZipPath); branch filter sweep skipped"
        )
        let directory = try ZipTestSupport.temporaryDirectory(label: "branch-sweep")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sizes = [
            8_192,
            256 * 1_024 + 4,
            1_048_576,
            1_114_112,
            2 * 1_048_576,
            4 * 1_048_576,
        ]
        let filters: [(name: String, filter: SevenZipBranchFilter)] = [
            ("BCJ", .x86), ("ARM64", .arm64),
        ]
        for (index, size) in sizes.enumerated() {
            let payload = Self.seededPayload(count: size, seed: 0x9E37_79B9_7F4A_7C15 &+ UInt64(index))
            let payloadURL = directory.appendingPathComponent("payload-\(size).bin")
            try Data(payload).write(to: payloadURL)
            for (name, filter) in filters {
                let archiveURL = directory.appendingPathComponent("\(name)-\(size).7z")
                try ZipTestSupport.checkedRun(
                    ZipTestSupport.sevenZipPath,
                    arguments: [
                        "a", "-bd", "-bb0", "-y", "-t7z", "-mhc=off",
                        "-m0=\(name)", "-m1=Copy", archiveURL.path, payloadURL.lastPathComponent,
                    ],
                    currentDirectory: directory
                )
                let archive = [UInt8](try Data(contentsOf: archiveURL))
                // -mhc=off の単一 folder では packed stream が署名 header 32 byte の直後に置かれる。
                guard archive.count >= 32 + size else {
                    XCTFail("\(name) \(size): archive is shorter than its payload (\(archive.count) bytes)")
                    continue
                }
                let encoded = Array(archive[32..<(32 + size)])
                let decoder = try BCJFilterDecompressor(
                    input: FixedChunkDecompressor(encoded, maximumRead: 200_000),
                    filter: filter,
                    expectedSize: UInt64(size)
                )
                let decoded = try drain(decoder, bufferSize: 65_536)
                XCTAssertEqual(
                    decoded.count, payload.count, "\(name) \(size): length"
                )
                if let firstMismatch = zip(decoded, payload).enumerated()
                    .first(where: { $0.element.0 != $0.element.1 })?.offset
                {
                    XCTFail("\(name) \(size): first mismatch at byte \(firstMismatch)")
                }
            }
        }
    }

    func testBranchFilterOverLZMA2ArchiveExtractsThroughReader() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable at \(ZipTestSupport.sevenZipPath); branch archive skipped"
        )
        let directory = try ZipTestSupport.temporaryDirectory(label: "branch-lzma2")
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = 1_114_112
        let payload = Self.seededPayload(count: size, seed: 0x2545_F491_4F6C_DD1D)
        let payloadURL = directory.appendingPathComponent("payload.bin")
        try Data(payload).write(to: payloadURL)
        let expectedDigest = SHA256.hash(data: Data(payload))
            .map { String(format: "%02x", $0) }.joined()

        for name in ["BCJ", "ARM64"] {
            let archiveURL = directory.appendingPathComponent("\(name).7z")
            try ZipTestSupport.checkedRun(
                ZipTestSupport.sevenZipPath,
                arguments: [
                    "a", "-bd", "-bb0", "-y", "-t7z",
                    "-m0=\(name)", "-m1=LZMA2", archiveURL.path, payloadURL.lastPathComponent,
                ],
                currentDirectory: directory
            )
            let reader = try ArchiveReader.open(url: archiveURL)
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertTrue(
                entry.methodDescription.split(separator: "+").contains(Substring(name)),
                "\(name): \(entry.methodDescription)"
            )
            let data = try reader.read(entry)
            XCTAssertEqual(data.count, size, name)
            XCTAssertEqual(
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                expectedDigest,
                name
            )
        }
    }

    // MARK: - helpers

    /// 決定的な擬似乱数 payload(xorshift64*)。fixture を持ち込まずに毎回同じ byte 列を作る。
    private static func seededPayload(count: Int, seed: UInt64) -> [UInt8] {
        var state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 0x2545_F491_4F6C_DD1D
            for shift in stride(from: 0, to: 64, by: 8) where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
        return bytes
    }

    private func assertDecode(
        encoded: [UInt8],
        expected: [UInt8],
        filter: SevenZipBranchFilter,
        startOffset: UInt64
    ) throws {
        for chunk in [1, 2, 3, 4, 5, 7, 31] {
            let decoder = try BCJFilterDecompressor(
                input: FixedChunkDecompressor(encoded, maximumRead: chunk),
                filter: filter,
                startOffset: startOffset,
                expectedSize: UInt64(expected.count)
            )
            XCTAssertEqual(try drain(decoder, bufferSize: 3), expected, "input chunk \(chunk)")
        }
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> [UInt8] {
        var result = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var iterations = 0
        while !decoder.isFinished {
            let count = try buffer.withUnsafeMutableBytes { storage in
                // storage は固定長配列で、decoder は返却 count より先へ書き込まない。
                try decoder.read(into: storage)
            }
            guard count > 0 else { throw KaitoError.malformed("test decoder stalled") }
            result.append(contentsOf: buffer[..<count])
            iterations += 1
            guard iterations < 1_000_000 else {
                throw KaitoError.malformed("test decoder did not terminate")
            }
        }
        return result
    }

    private func hex(_ string: String) throws -> [UInt8] {
        let compact = string.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else {
            throw KaitoError.malformed("odd test hex")
        }
        var result = [UInt8]()
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else {
                throw KaitoError.malformed("invalid test hex")
            }
            result.append(byte)
            index = end
        }
        return result
    }
}

private final class FixedChunkDecompressor: Decompressor {
    private let bytes: [UInt8]
    private let maximumRead: Int
    private var offset = 0

    init(_ bytes: [UInt8], maximumRead: Int) {
        self.bytes = bytes
        self.maximumRead = maximumRead
    }

    var isFinished: Bool { offset == bytes.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        let count = min(buffer.count, maximumRead, bytes.count - offset)
        buffer.copyBytes(from: bytes[offset..<(offset + count)])
        offset += count
        return count
    }
}
