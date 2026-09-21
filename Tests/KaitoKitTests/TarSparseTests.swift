import CryptoKit
import Darwin
import Foundation
@testable import KaitoKit
import XCTest

/// GNU sparse（pax 0.0 / 0.1 / 1.0、libarchive tar(5) の記述）。合成書庫は OS の bsdtar で読めることを
/// 独立に確認し、1.0 は F_PUNCHHOLE で穴を開けた実 file を bsdtar --format pax で書いた書庫でも照合する。
final class TarSparseTests: XCTestCase {
    // 実サイズ 3 MiB: [0, 4096) データ、[1 MiB, 1 MiB + 1000) データ、末尾は穴。
    private let realSize = 3 * 1_048_576
    private var fragments: [(offset: Int, bytes: [UInt8])] {
        [(0, (0..<4_096).map { UInt8(truncatingIfNeeded: $0 * 7) }),
         (1_048_576, (0..<1_000).map { UInt8(truncatingIfNeeded: 0x55 ^ $0) })]
    }
    private var expected: Data {
        var data = Data(repeating: 0, count: realSize)
        for fragment in fragments {
            data.replaceSubrange(fragment.offset..<(fragment.offset + fragment.bytes.count), with: fragment.bytes)
        }
        return data
    }
    private var storedBody: Data { Data(fragments.flatMap(\.bytes)) }

    private func paxPayload(_ records: [(String, String)]) -> Data {
        var result = Data()
        for (key, value) in records {
            let body = Array(key.utf8) + [0x3d] + Array(value.utf8) + [0x0a]
            for digitCount in 1...20 {
                let length = digitCount + 1 + body.count
                let prefix = Array(String(length).utf8)
                if prefix.count == digitCount {
                    result.append(contentsOf: prefix + [0x20] + body)
                    break
                }
            }
        }
        return result
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

    /// bsdtar（OS 同梱 libarchive）が同じ byte を復元することを独立に確認する。
    private func assertBSDTarReads(_ archive: Data, member: String, label: String) throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sparse.tar")
        try archive.write(to: url)
        // stdout へは末尾の穴を書かないので、file に展開して実サイズを含めて比較する。
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try ZipTestSupport.run(ZipTestSupport.bsdTarPath, arguments: ["-xf", url.path, "-C", output.path, member])
        XCTAssertEqual(result.terminationStatus, 0, "\(label): \(result.diagnostics)")
        let extracted = try Data(contentsOf: output.appendingPathComponent(member))
        XCTAssertEqual(extracted.count, realSize, label)
        XCTAssertEqual(sha(extracted), sha(expected), label)
    }

    private func assertReader(_ archive: Data, version: String, label: String, name: String = "holey.bin") throws {
        let reader = try ArchiveReader.open(data: archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == name }, label)
        XCTAssertEqual(entry.kind, .file, label)
        XCTAssertEqual(entry.uncompressedSize, UInt64(realSize), label)
        XCTAssertEqual(entry.compressedSize, UInt64(storedBody.count) + (version == "GNU.sparse 1.0" ? 512 : 0), label)
        XCTAssertEqual(entry.methodDescription, "tar (sparse)", label)
        XCTAssertEqual(entry.formatSpecific["sparse"], version, label)
        XCTAssertEqual(entry.formatSpecific["sparseFragmentCount"], "2", label)
        XCTAssertEqual(sha(try reader.read(entry)), sha(expected), label)
        XCTAssertEqual(sha(try read(reader.stream(entry), chunk: 3_001)), sha(expected), label)
        let after = try XCTUnwrap(reader.entries.first { $0.name == "after.txt" }, label)
        XCTAssertEqual(try reader.read(after), Data("after".utf8), label)
        XCTAssertEqual(sha(try reader.reopen().read(entry)), sha(expected), label)
    }

    private func archive01(map: String, size: Int? = nil, body: Data? = nil) throws -> Data {
        let metadata = paxPayload([("GNU.sparse.size", String(size ?? realSize)), ("GNU.sparse.map", map)])
        return try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/holey.bin", contents: metadata, type: 0x78),
            HandTarEntry(name: "holey.bin", contents: body ?? storedBody),
            HandTarEntry(name: "after.txt", contents: Data("after".utf8)),
        ])
    }

    func testPax01MapIsExpandedAndMatchesBSDTar() throws {
        let map = fragments.map { "\($0.offset),\($0.bytes.count)" }.joined(separator: ",")
        let archive = try archive01(map: map)
        try assertReader(archive, version: "GNU.sparse 0.1", label: "0.1")
        try assertBSDTarReads(archive, member: "holey.bin", label: "0.1")
    }

    func testPax00RepeatedOffsetNumbytesPairsKeepTheirOrder() throws {
        var records: [(String, String)] = [("GNU.sparse.size", String(realSize)), ("GNU.sparse.numblocks", "2")]
        for fragment in fragments {
            records.append(("GNU.sparse.offset", String(fragment.offset)))
            records.append(("GNU.sparse.numbytes", String(fragment.bytes.count)))
        }
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/holey.bin", contents: paxPayload(records), type: 0x78),
            HandTarEntry(name: "holey.bin", contents: storedBody),
            HandTarEntry(name: "after.txt", contents: Data("after".utf8)),
        ])
        try assertReader(archive, version: "GNU.sparse 0.0", label: "0.0")
        try assertBSDTarReads(archive, member: "holey.bin", label: "0.0")

        // numblocks が対の数と合わなければ malformed。
        var wrong = records
        wrong[1] = ("GNU.sparse.numblocks", "3")
        let mismatched = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/holey.bin", contents: paxPayload(wrong), type: 0x78),
            HandTarEntry(name: "holey.bin", contents: storedBody),
        ])
        XCTAssertThrowsError(try ArchiveReader.open(data: mismatched)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testPax10MapBlockRealNameAndBSDTarWriterAgree() throws {
        // 1.0: header 名は作業名、本文先頭 512 byte が改行区切り十進の map。
        var map = Data("2\n".utf8)
        for fragment in fragments { map.append(Data("\(fragment.offset)\n\(fragment.bytes.count)\n".utf8)) }
        map.append(Data(repeating: 0, count: 512 - map.count))
        let metadata = paxPayload([
            ("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0"),
            ("GNU.sparse.name", "holey.bin"), ("GNU.sparse.realsize", String(realSize)),
        ])
        let synthetic = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/holey.bin", contents: metadata, type: 0x78),
            HandTarEntry(name: "GNUSparseFile.4242/holey.bin", contents: map + storedBody),
            HandTarEntry(name: "after.txt", contents: Data("after".utf8)),
        ])
        try assertReader(synthetic, version: "GNU.sparse 1.0", label: "1.0 synthetic")
        try assertBSDTarReads(synthetic, member: "holey.bin", label: "1.0 synthetic")

        // libarchive の writer: APFS 上で穴を開けた実 file を bsdtar --format pax で書く。
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("holey.bin")
        try expected.write(to: file)
        let descriptor = open(file.path, O_RDWR)
        guard descriptor >= 0 else { return XCTFail("open failed") }
        defer { close(descriptor) }
        // 穴は 4 KiB 境界で指定する（F_PUNCHHOLE）。開けられない filesystem では skip。
        var punch = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 4_096, fp_length: 1_048_576 - 4_096)
        guard fcntl(descriptor, F_PUNCHHOLE, &punch) == 0 else {
            throw XCTSkip("F_PUNCHHOLE is unavailable here; bsdtar sparse writer check skipped")
        }
        var tail = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 1_052_672, fp_length: off_t(realSize) - 1_052_672)
        guard fcntl(descriptor, F_PUNCHHOLE, &tail) == 0 else {
            throw XCTSkip("F_PUNCHHOLE tail failed; bsdtar sparse writer check skipped")
        }
        let archiveURL = directory.appendingPathComponent("bsd.tar")
        try ZipTestSupport.checkedRun(ZipTestSupport.bsdTarPath, arguments: ["--format", "pax", "-cf", archiveURL.path, "holey.bin"], currentDirectory: directory)
        let written = try Data(contentsOf: archiveURL)
        guard written.count < realSize else {
            throw XCTSkip("bsdtar did not detect holes (\(written.count) bytes); writer check skipped")
        }
        let reader = try ArchiveReader.open(url: archiveURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "holey.bin")
        XCTAssertEqual(entry.formatSpecific["sparse"], "GNU.sparse 1.0")
        XCTAssertEqual(entry.uncompressedSize, UInt64(realSize))
        XCTAssertEqual(sha(try reader.read(entry)), sha(expected))
    }

    func testMalformedMapsAndOldGNUSparseAreRejected() throws {
        // 非昇順、実サイズ超過、格納長の不一致、奇数個、非十進。
        for (map, label) in [
            ("1048576,1000,0,4096", "descending"),
            ("0,4096,\(realSize - 500),1000", "beyond real size"),
            ("0,4096,1048576,999", "stored size mismatch"),
            ("0,4096,1048576", "odd"),
            ("0,4096,x,1000", "non-decimal"),
        ] {
            XCTAssertThrowsError(try ArchiveReader.open(data: try archive01(map: map)), label) {
                guard case .malformed = $0 as? KaitoError else { return XCTFail("\(label): \($0)") }
            }
        }
        // GNU.sparse.size を欠く map、entry 上限、fragment 数の上限。
        let noSize = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/holey.bin", contents: paxPayload([("GNU.sparse.map", "0,4096")]), type: 0x78),
            HandTarEntry(name: "holey.bin", contents: Data(fragments[0].bytes)),
        ])
        XCTAssertThrowsError(try ArchiveReader.open(data: noSize))
        let map = fragments.map { "\($0.offset),\($0.bytes.count)" }.joined(separator: ",")
        XCTAssertThrowsError(try ArchiveReader.open(data: try archive01(map: map), options: ReaderOptions(limits: ReadLimits(maxEntrySize: UInt64(realSize) - 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(data: try archive01(map: map), options: ReaderOptions(limits: ReadLimits(maxMetadataRecordCount: 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        // 合計上限は実サイズで数える。
        XCTAssertThrowsError(try ArchiveReader.open(data: try archive01(map: map), options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: UInt64(realSize) + 4)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        _ = try ArchiveReader.open(data: try archive01(map: map), options: ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: UInt64(realSize) + 5)))

        // 1.0 の major/minor が違う、realsize が無い、map が本文より長い。
        for (records, label) in [
            ([("GNU.sparse.major", "2"), ("GNU.sparse.minor", "0"), ("GNU.sparse.realsize", "10")], "major 2"),
            ([("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0")], "no realsize"),
        ] as [([(String, String)], String)] {
            let archive = try TarTestSupport.makeTar(entries: [
                HandTarEntry(name: "PaxHeader/x", contents: paxPayload(records), type: 0x78),
                HandTarEntry(name: "GNUSparseFile.1/x", contents: Data("1\n0\n5\n".utf8) + Data(repeating: 0, count: 506) + Data("hello".utf8)),
            ])
            XCTAssertThrowsError(try ArchiveReader.open(data: archive), label)
        }
        let shortBody = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/x", contents: paxPayload([("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0"), ("GNU.sparse.realsize", "5")]), type: 0x78),
            HandTarEntry(name: "GNUSparseFile.1/x", contents: Data("1\n0\n5\n".utf8)),
        ])
        XCTAssertThrowsError(try ArchiveReader.open(data: shortBody)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        // 旧 GNU の 'S' 型（header 内の sparse 表）と global header の GNU.sparse は従来どおり読まない。
        let oldGNU = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "s", contents: Data([1, 2, 3]), type: 0x53)])
        XCTAssertThrowsError(try ArchiveReader.open(data: oldGNU)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        let global = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "GlobalHead", contents: paxPayload([("GNU.sparse.size", "5")]), type: 0x67),
            HandTarEntry(name: "x", contents: Data("hello".utf8)),
        ])
        XCTAssertThrowsError(try ArchiveReader.open(data: global))
        // star / Solaris の sparse 表現は unsupportedMethod のまま。
        let star = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/x", contents: paxPayload([("SCHILY.filetype", "sparse")]), type: 0x78),
            HandTarEntry(name: "x", contents: Data("hello".utf8)),
        ])
        XCTAssertThrowsError(try ArchiveReader.open(data: star)) {
            guard case .unsupportedMethod = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testEmptyAndHoleOnlySparseFiles() throws {
        // fragment が無い（全部穴）file と、実サイズ 0 の file。
        let holes = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/z", contents: paxPayload([("GNU.sparse.size", "8192"), ("GNU.sparse.map", "")]), type: 0x78),
            HandTarEntry(name: "z", contents: Data()),
        ])
        // 空の map 文字列は要素 0 個ではなく空要素 1 個として malformed になる（0.1 の map は非空が前提）。
        XCTAssertThrowsError(try ArchiveReader.open(data: holes))
        let zeroPairs = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/z", contents: paxPayload([("GNU.sparse.size", "8192"), ("GNU.sparse.numblocks", "0")]), type: 0x78),
            HandTarEntry(name: "z", contents: Data()),
        ])
        // 対が一つも無い 0.0 は map を持たないので malformed。
        XCTAssertThrowsError(try ArchiveReader.open(data: zeroPairs))
        let oneZeroFragment = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader/z", contents: paxPayload([("GNU.sparse.size", "8192"), ("GNU.sparse.map", "8192,0")]), type: 0x78),
            HandTarEntry(name: "z", contents: Data()),
        ])
        let reader = try ArchiveReader.open(data: oneZeroFragment)
        XCTAssertEqual(reader.entries[0].uncompressedSize, 8_192)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data(repeating: 0, count: 8_192))
    }
}
