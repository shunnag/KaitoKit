import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// ISO 9660 の zisofs（Rock Ridge ZF、"Description of the zisofs Format"）。fixture は GNU xorriso が
/// 書いた 2 画像（Tests/Fixtures/iso/zisofs-{32k,128k}.iso.gz.b64）、境界は ISOImageBuilder で合成する。
final class ISOZisofsTests: XCTestCase {
    private typealias B = ISOImageBuilder

    private let expected: [String: (size: UInt64, sha: String)] = [
        "text.txt": (84_000, "fdc944406443a962675237d2789e0a9a879f7832692c608bb763c8e3f0333a57"),
        "zeros.bin": (70_000, "f51b279903037b37ea1828a1021499995718d38016cad6c0da30962a41be052f"),
        "mixed.bin": (78_000, "5dfdd07343456f1a35dfaf87971cd24d3b547e7d4b4b4f9e64091636df28c76f"),
        "small.txt": (4, "8950abfda7b727630760dd35bcf5c3daa7631aff223a90f7728c0d2521dde10c"),
        "empty": (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        "sub/deep.txt": (15_000, "15339b7447ee0e6d76eb753ff95726e20dfff23db842f37c373048e446c11f51"),
    ]

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/iso/\(name).iso.gz.b64")
        let base64 = try String(contentsOf: url, encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    // MARK: - xorriso fixtures

    func testXorrisoImagesDecodeEveryZisofsFileAtBothBlockSizes() throws {
        for (name, blockSize) in [("zisofs-32k", 32_768), ("zisofs-128k", 131_072)] {
            let reader = try ArchiveReader.open(data: try fixture(name))
            XCTAssertEqual(reader.format, .iso, name)
            let files = reader.entries.filter { $0.kind == .file }
            XCTAssertEqual(Set(files.map(\.name)), Set(expected.keys), name)
            for entry in files {
                let want = try XCTUnwrap(expected[entry.name], entry.name)
                XCTAssertEqual(entry.uncompressedSize, want.size, "\(name) \(entry.name)")
                // 1 block 未満の file と空 file も xorriso は zisofs にする（小さい方が stored で来ても受理する）。
                if entry.methodDescription == "zisofs (zlib)" {
                    XCTAssertEqual(entry.formatSpecific["zisofsBlockSize"], String(blockSize), "\(name) \(entry.name)")
                    XCTAssertNotEqual(entry.compressedSize, entry.uncompressedSize == 0 ? 1 : entry.uncompressedSize, "\(name) \(entry.name)")
                } else {
                    XCTAssertEqual(entry.methodDescription, "ISO 9660 (stored)", "\(name) \(entry.name)")
                }
                XCTAssertNil(entry.formatSpecific["unsupported"], "\(name) \(entry.name)")
                for chunk in [1, 4_099, 65_536] where chunk > 1 || want.size < 200 {
                    let data = try read(reader.stream(entry), chunk: chunk)
                    XCTAssertEqual(UInt64(data.count), want.size, "\(name) \(entry.name) chunk \(chunk)")
                    XCTAssertEqual(sha(data), want.sha, "\(name) \(entry.name) chunk \(chunk)")
                }
                XCTAssertEqual(sha(try reader.read(entry)), want.sha, "\(name) \(entry.name)")
            }
            XCTAssertTrue(files.contains { $0.methodDescription == "zisofs (zlib)" && $0.name == "text.txt" }, name)
            XCTAssertTrue(files.contains { $0.methodDescription == "zisofs (zlib)" && $0.name == "zeros.bin" }, name)
            let reopened = try reader.reopen()
            let text = try XCTUnwrap(reopened.entries.first { $0.name == "text.txt" })
            XCTAssertEqual(sha(try reopened.read(text)), expected["text.txt"]!.sha, name)
        }
    }

    // MARK: - synthetic bodies (stored zlib streams built from RFC 1950 / RFC 1951)

    /// RFC 1950 の zlib stream を stored block だけで組む（テスト用、圧縮しない）。
    private func zlibStored(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let chunk = Array(payload[offset..<min(offset + 65_535, payload.count)])
            let final: UInt8 = offset + chunk.count >= payload.count ? 1 : 0
            out.append(final) // BFINAL, BTYPE=00
            out += [UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8), UInt8(~chunk.count & 0xFF), UInt8((~chunk.count >> 8) & 0xFF)]
            out += chunk
            offset += chunk.count
        } while offset < payload.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in payload { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        let adler = (b << 16) | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        return out
    }

    /// zisofs 本文: header + pointer 配列 + block 列。`blocks` の nil は 0 埋め block。
    private func zisofsBody(size: UInt32, log2: UInt8, blocks: [[UInt8]?], pointerOverride: ((inout [UInt32]) -> Void)? = nil,
                            headerOverride: ((inout [UInt8]) -> Void)? = nil) -> [UInt8] {
        var header = ISOZisofsInfo.magic
        header += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        header += [4, log2, 0, 0]
        headerOverride?(&header)
        var pointers: [UInt32] = []
        var cursor = UInt32(16 + (blocks.count + 1) * 4)
        var data: [UInt8] = []
        for block in blocks {
            pointers.append(cursor)
            if let block {
                data += block
                cursor += UInt32(block.count)
            }
        }
        pointers.append(cursor)
        pointerOverride?(&pointers)
        var table: [UInt8] = []
        for pointer in pointers {
            table += [UInt8(pointer & 0xFF), UInt8((pointer >> 8) & 0xFF), UInt8((pointer >> 16) & 0xFF), UInt8(pointer >> 24)]
        }
        return header + table + data
    }

    private func zf(size: UInt32, log2: UInt8 = 15, version: UInt8 = 1, algorithm: [UInt8] = [0x70, 0x7A], headerSize: UInt8 = 4) -> [UInt8] {
        var entry: [UInt8] = Array("ZF".utf8) + [16, version] + algorithm + [headerSize, log2] + [UInt8](repeating: 0, count: 8)
        B.both(&entry, 8, size)
        return entry
    }

    private func open(_ builder: B, limits: ReadLimits = ReadLimits()) throws -> ArchiveReader {
        try ArchiveReader.open(data: builder.data, options: ReaderOptions(limits: limits))
    }

    func testSyntheticBlocksZeroBlocksPartialTailAndZFHeaderAreVerified() throws {
        let blockSize = 32_768
        let first = (0..<blockSize).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let tail = Array("partial tail".utf8)
        let size = UInt32(blockSize * 2 + tail.count)
        // block 0 = data, block 1 = zeros (pointer 長 0), block 2 = 12 byte の末尾。
        let body = zisofsBody(size: size, log2: 15, blocks: [zlibStored(first), nil, zlibStored(tail)])
        var b = B(sectors: 64)
        let file = b.file("Z", payload: body, su: zf(size: size))
        b.root([file], systemUse: B.sp())
        let reader = try open(b)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.methodDescription, "zisofs (zlib)")
        XCTAssertEqual(entry.uncompressedSize, UInt64(size))
        XCTAssertEqual(entry.compressedSize, UInt64(body.count))
        XCTAssertEqual(entry.formatSpecific["zisofsBlockSize"], "32768")
        let data = try reader.read(entry)
        XCTAssertEqual(Array(data.prefix(blockSize)), first)
        XCTAssertEqual(Array(data[blockSize..<(2 * blockSize)]), [UInt8](repeating: 0, count: blockSize))
        XCTAssertEqual(Array(data.suffix(tail.count)), tail)
        XCTAssertEqual(try read(reader.stream(entry), chunk: 1_000), data)

        // 128 KiB block を宣言する 1 byte file、および末尾 block が 0 埋めの file。
        var c = B(sectors: 64)
        let one = c.file("O", payload: zisofsBody(size: 1, log2: 17, blocks: [zlibStored([0x2A])]), su: zf(size: 1, log2: 17))
        let zeroTail = c.file("T", payload: zisofsBody(size: UInt32(blockSize + 5), log2: 15, blocks: [zlibStored(first), nil]),
                              su: zf(size: UInt32(blockSize + 5)))
        c.root([one, zeroTail], systemUse: B.sp())
        let both = try open(c)
        XCTAssertEqual(try both.read(both.entries[0]), Data([0x2A]))
        XCTAssertEqual(try both.read(both.entries[1]), Data(first) + Data(repeating: 0, count: 5))
    }

    func testCorruptedStructuresAreRejectedWithTypedErrors() throws {
        let payload = (0..<1_000).map { UInt8(truncatingIfNeeded: $0) }
        let size = UInt32(payload.count)
        func image(_ body: [UInt8], su: [UInt8]) throws -> ArchiveReader {
            var b = B(sectors: 64)
            let file = b.file("Z", payload: body, su: su)
            b.root([file], systemUse: B.sp())
            return try open(b)
        }
        func assertRead(_ reader: ArchiveReader, _ check: (KaitoError?) -> Bool, _ label: String) {
            XCTAssertThrowsError(try reader.read(reader.entries[0]), label) {
                XCTAssertTrue(check($0 as? KaitoError), "\(label): \($0)")
            }
        }
        let good = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload)])
        XCTAssertEqual(try image(good, su: zf(size: size)).read(try image(good, su: zf(size: size)).entries[0]), Data(payload))

        // header の magic / size / block log / 予約 byte が ZF と食い違う。
        for (label, mutate) in [
            ("magic", { (h: inout [UInt8]) in h[0] ^= 1 }),
            ("size", { (h: inout [UInt8]) in h[8] ^= 1 }),
            ("headerSize", { (h: inout [UInt8]) in h[12] = 5 }),
            ("log2", { (h: inout [UInt8]) in h[13] = 16 }),
            ("reserved", { (h: inout [UInt8]) in h[14] = 1 }),
        ] as [(String, (inout [UInt8]) -> Void)] {
            let body = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload)], headerOverride: mutate)
            assertRead(try image(body, su: zf(size: size)), { if case .malformed = $0 { return true }; return false }, label)
        }
        // pointer が単調でない / extent を超える / 表の前を指す。
        for (label, mutate) in [
            ("decreasing", { (p: inout [UInt32]) in p[1] = p[0] - 1 }),
            ("beyond", { (p: inout [UInt32]) in p[1] = 1 << 20 }),
            ("beforeTable", { (p: inout [UInt32]) in p[0] = 8 }),
        ] as [(String, (inout [UInt32]) -> Void)] {
            let body = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload)], pointerOverride: mutate)
            assertRead(try image(body, su: zf(size: size)), { if case .malformed = $0 { return true }; return false }, label)
        }
        // block が宣言より長い / 短い。
        let long = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload + [1])])
        assertRead(try image(long, su: zf(size: size)), { if case .malformed = $0 { return true }; return false }, "long block")
        let short = zisofsBody(size: size, log2: 15, blocks: [zlibStored(Array(payload.dropLast()))])
        assertRead(try image(short, su: zf(size: size)), { if case .malformed = $0 { return true }; return false }, "short block")
        // 壊れた zlib stream。
        var damaged = good
        damaged[good.count - 30] ^= 0xFF
        assertRead(try image(damaged, su: zf(size: size)), { $0 != nil }, "damaged zlib")
        // extent が表より短い。
        let truncated = Array(good.prefix(16 + 4))
        var t = B(sectors: 64)
        let tf = t.file("Z", payload: truncated, su: zf(size: size))
        t.root([tf], systemUse: B.sp())
        assertRead(try open(t), { $0 == .truncated }, "short extent")
    }

    func testUnsupportedZFVariantsStayListedButUnreadable() throws {
        let payload = Array("payload".utf8)
        let size = UInt32(payload.count)
        let body = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload)])
        for (label, su) in [
            ("version2", zf(size: size, version: 2)),
            ("algorithm", zf(size: size, algorithm: [0x50, 0x5A])),
            ("headerSize", zf(size: size, headerSize: 5)),
            ("log2-14", zf(size: size, log2: 14)),
            ("log2-18", zf(size: size, log2: 18)),
            ("short", B.su("ZF")),
        ] {
            var b = B(sectors: 64)
            let file = b.file("Z", payload: body, su: su)
            b.root([file], systemUse: B.sp())
            let reader = try open(b)
            XCTAssertEqual(reader.entries[0].formatSpecific["unsupported"], "zisofs", label)
            XCTAssertEqual(reader.entries[0].methodDescription, "ISO 9660 (stored)", label)
            XCTAssertEqual(reader.entries[0].uncompressedSize, UInt64(body.count), label)
            XCTAssertThrowsError(try reader.stream(reader.entries[0]), label) {
                guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    func testZisofsOnMultiExtentFileIsUnsupportedAndEntryLimitAppliesToDeclaredSize() throws {
        let payload = Array("payload".utf8)
        let size = UInt32(payload.count)
        let body = zisofsBody(size: size, log2: 15, blocks: [zlibStored(payload)])
        // 最終 section の SUSP が優先されるので ZF は最終 section に置く。
        var b = B(sectors: 64)
        let first = b.file("M", payload: Array(body.prefix(20)), flags: 0x80)
        let second = b.file("M", payload: Array(body.dropFirst(20)), su: zf(size: size))
        b.root([first, second], systemUse: B.sp())
        let reader = try open(b)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].formatSpecific["unsupported"], "zisofs multi-extent")
        XCTAssertThrowsError(try reader.stream(reader.entries[0]))

        var c = B(sectors: 64)
        let file = c.file("Z", payload: body, su: zf(size: size))
        c.root([file], systemUse: B.sp())
        // extent（圧縮本文）と展開後サイズの両方が entry 上限の対象。
        XCTAssertThrowsError(try open(c, limits: ReadLimits(maxEntrySize: UInt64(size) - 1))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try open(c, limits: ReadLimits(maxEntrySize: UInt64(body.count))).entries[0].uncompressedSize, UInt64(size))
        let big = UInt32(body.count) + 1
        var d = B(sectors: 64)
        let inflated = d.file("Z", payload: body, su: zf(size: big))
        d.root([inflated], systemUse: B.sp())
        XCTAssertThrowsError(try open(d, limits: ReadLimits(maxEntrySize: UInt64(body.count)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testAggregateBudgetCountsExpandedSizeAndPointerTableIsMetadata() throws {
        // 70,000 byte の全 0 file は pointer 3 個だけで表現される（展開爆弾の形）。合計上限は展開後の
        // サイズで数え、pointer 表は metadata 上限で制限する。
        let image = try fixture("zisofs-32k")
        let total: UInt64 = 84_000 + 70_000 + 78_000 + 4 + 15_000
        let exact = try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: total)))
        for entry in exact.entries where entry.kind == .file { _ = try exact.read(entry) }
        XCTAssertThrowsError(try ArchiveReader.open(data: image, options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: total - 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // ZF が 4 GiB 近くを宣言しても、pointer 表（512 KiB）は extent に収まらなければ確保せず truncated。
        let payload = [UInt8](repeating: 0x41, count: 4_000)
        let body = zisofsBody(size: 4_000, log2: 15, blocks: [zlibStored(payload)])
        var b = B(sectors: 64)
        let file = b.file("Z", payload: body, su: zf(size: 0xFFFF_FFFF, log2: 15))
        b.root([file], systemUse: B.sp())
        let huge = try open(b)
        XCTAssertEqual(huge.entries[0].uncompressedSize, 0xFFFF_FFFF)
        XCTAssertThrowsError(try huge.stream(huge.entries[0])) { XCTAssertEqual($0 as? KaitoError, .truncated) }
        // 宣言サイズは entry 上限（既定 4 GiB）の内側でも合計上限には掛かる。
        XCTAssertThrowsError(try open(b, limits: ReadLimits(maxTotalUncompressedSize: 0xFFFF_FFFE))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testZeroLengthExtentWithOutOfRangeLBAIsAcceptedAsEmptyFile() throws {
        // libarchive の iso9660 writer は空 file と symlink の LBA に 0xFFFFFFF0 を書く。
        var b = B(sectors: 64)
        let empty = B.record(Array("E".utf8), lba: 0xFFFF_FFF0, length: 0)
        let link = B.record(Array("L".utf8), lba: 0xFFFF_FFF0, length: 0, su: B.su("SL", [0, 0, 6] + Array("target".utf8)))
        let normal = b.file("N", payload: Array("normal".utf8))
        b.root([empty, link, normal], systemUse: B.sp())
        let reader = try open(b)
        XCTAssertEqual(reader.entries.map(\.name), ["E", "L", "N"])
        XCTAssertEqual(reader.entries[0].kind, .file)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data())
        XCTAssertEqual(reader.entries[1].kind, .symlink)
        XCTAssertEqual(reader.entries[1].formatSpecific["linkPath"], "target")
        XCTAssertEqual(try reader.read(reader.entries[2]), Data("normal".utf8))
        // 長さのある extent の範囲外 LBA は従来どおり拒否する。
        var c = B(sectors: 64)
        c.root([B.record(Array("X".utf8), lba: 0xFFFF_FFF0, length: 7)], systemUse: B.sp())
        XCTAssertThrowsError(try open(c))
    }
}
