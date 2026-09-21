import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// 生 sector の CD image（BIN/CUE、.img、.mdf の並び）を ISO 9660 / UDF として読む。fixture は
/// Tests/Fixtures/bincue（rr-joliet.iso / pure150.iso を ECMA-130 §14 の sector に包んだもの、generate.py）。
final class RawSectorImageTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static func gunzipped(_ relative: String) throws -> Data {
        let base64 = try String(contentsOf: root.appendingPathComponent("Fixtures/\(relative).gz.b64"), encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }
    private static func raw(_ name: String) throws -> Data { try gunzipped("bincue/\(name)") }
    private static let isoVariants = ["mode1.bin", "mode1-garbage.bin", "mode2-subheader.bin", "mode2-plain.bin",
                                      "mode1-2448.bin", "mode2-2336.bin", "mode1-truncated.bin"]
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 6 通りの並びと trailer 欠けの image が、元の ISO と同じ entry・同じ内容を返す。
    func testRawImagesReadLikeTheUnderlyingISO() throws {
        let plain = try ArchiveReader.open(data: Self.gunzipped("iso/rr-joliet.iso"))
        XCTAssertEqual(plain.entries.count, 6)
        let expected = try plain.entries.map { try sha(plain.read($0)) }
        for name in Self.isoVariants {
            let bytes = try Self.raw(name)
            XCTAssertEqual(try FormatDetector.detect(data: bytes), .iso, name)
            let reader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(reader.format, .iso, name)
            XCTAssertEqual(reader.entries, plain.entries, name)
            XCTAssertEqual(try reader.entries.map { try sha(reader.read($0)) }, expected, name)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, plain.entries, name)
            XCTAssertEqual(try reopened.entries.map { try sha(reopened.read($0)) }, expected, name)
            // 1 byte ずつしか返さない source でも sector をまたいで同じ内容になる。
            let short = try ArchiveReader.open(source: ShortSource(bytes))
            XCTAssertEqual(try short.entries.map { try sha(short.read($0)) }, expected, name)
        }
        // 検出は sector の並びを正しく判定する。
        for (name, size, offset) in [("mode1.bin", 2352, 16), ("mode2-subheader.bin", 2352, 24), ("mode2-plain.bin", 2352, 16),
                                     ("mode1-2448.bin", 2448, 16), ("mode2-2336.bin", 2336, 8)] {
            let layout = try XCTUnwrap(RawSectorByteSource.detect(source: DataByteSource(data: try Self.raw(name))), name)
            XCTAssertEqual(layout.sectorSize, size, name)
            XCTAssertEqual(layout.userDataOffset, offset, name)
            XCTAssertEqual(layout.sectorCount, 38, name)
        }
    }

    func testPureUDFInRawSectorsIsDetectedAsUDF() throws {
        let plain = try ArchiveReader.open(data: Self.gunzipped("udf/pure150.iso"))
        let bytes = try Self.raw("udf-mode1.bin")
        XCTAssertEqual(try FormatDetector.detect(data: bytes), .udf)
        let reader = try ArchiveReader.open(data: bytes)
        XCTAssertEqual(reader.format, .udf)
        XCTAssertEqual(reader.entries, plain.entries)
        for (entry, original) in zip(reader.entries, plain.entries) where entry.kind == .file {
            XCTAssertEqual(try reader.read(entry), try plain.read(original), entry.name)
        }
    }

    /// `.cue` の URL は同じ directory の data track の image を開く（引用符あり / なし、Windows path、
    /// audio track を先に持つ 2 file 構成）。Data からは開けない。
    func testCueSheetOpensTheDataTrackImage() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["mode1.bin", "mode2-subheader.bin"] {
            try Self.raw(name).write(to: directory.appendingPathComponent(name))
        }
        for cue in ["mode1.cue", "multi.cue"] {
            let url = directory.appendingPathComponent(cue)
            try FileManager.default.copyItem(at: Self.root.appendingPathComponent("Fixtures/bincue/\(cue)"), to: url)
            XCTAssertEqual(try FormatDetector.detect(url: url), .iso, cue)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format, .iso, cue)
            XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "data.bin", "link", "sub", "sub/nested.txt", "日本語ファイル.txt"], cue)
            XCTAssertEqual(sha(try reader.read(reader.entries[1])), "e05455bcbbec58463277e8874036e57bdcf8c49c792a23ce03d6baba0765271c", cue)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries, cue)
            XCTAssertThrowsError(try ArchiveReader.open(data: Data(contentsOf: url)), cue) {
                XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
            }
        }
        // 参照先が無い cue は notFound、image でない file を指す cue は unsupportedFormat。
        let missing = directory.appendingPathComponent("missing.cue")
        try "FILE \"nowhere.bin\" BINARY\nTRACK 01 MODE1/2352\n".write(to: missing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ArchiveReader.open(url: missing)) {
            guard case .notFound = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let text = directory.appendingPathComponent("text.cue")
        try "FILE \"mode1.cue\" BINARY\nTRACK 01 MODE1/2352\n".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ArchiveReader.open(url: text)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
        // FILE 行の無い text と、binary は cue sheet ではない。
        XCTAssertNil(CueSheet.dataTrackFileName(in: Array("REM nothing here\nTRACK 01 MODE1/2352\n".utf8)))
        XCTAssertNil(CueSheet.dataTrackFileName(in: [0x46, 0x49, 0x4C, 0x45, 0x00, 0x01]))
        XCTAssertEqual(CueSheet.dataTrackFileName(in: Array("FILE a.bin BINARY\r\nTRACK 01 MODE2/2336\r\n".utf8)), Array("a.bin".utf8))
    }

    func testImagesWithoutAVolumeDescriptorAreNotDetected() throws {
        let original = try Self.raw("mode1.bin")
        // sync はあるが logical sector 16 の Mode byte が 0（空 sector）。
        var mode0 = original
        mode0[16 * 2352 + 15] = 0
        XCTAssertThrowsError(try ArchiveReader.open(data: mode0)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        // logical sector 16 の CD001 を壊す。
        var noDescriptor = original
        for index in 0..<64 { noDescriptor[16 * 2352 + 16 + index] = 0 }
        XCTAssertThrowsError(try ArchiveReader.open(data: noDescriptor)) { XCTAssertEqual($0 as? KaitoError, .unsupportedFormat) }
        // sector 16 の user data まで届かない切り詰めは image として成立しない。
        XCTAssertThrowsError(try ArchiveReader.open(data: original.prefix(16 * 2352 + 20))) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
        // 最後の sector の user data まで欠けた image は、素の ISO を同じ量だけ切ったときと同じく open が truncated
        // （ISO reader は extent を image の大きさと照合する）。
        let cut = original.prefix(original.count - 2352 - 1000)
        XCTAssertThrowsError(try ArchiveReader.open(data: cut)) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        let plain = try Self.gunzipped("iso/rr-joliet.iso")
        XCTAssertThrowsError(try ArchiveReader.open(data: plain.prefix(plain.count - 2048 - 1000))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
    }

    private final class ShortSource: ByteSource {
        let data: Data
        init(_ data: Data) { self.data = data }
        var length: UInt64 { UInt64(data.count) }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length, !buffer.isEmpty else { return 0 }
            buffer[0] = data[Int(offset)]; return 1
        }
    }
}
