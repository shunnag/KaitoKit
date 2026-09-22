import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

/// classic StuffIt の分割セット（100 byte header の part、inbox/stuffit/report/06 §"Classic StuffIt
/// split files"）。part は CC0 fixture の MacBinary から fork を取り出してテスト時に合成する。同じ合成
/// part を unar 1.10.8 が "StuffIt in StuffIt split file" として読むことを開発時に確認した。
final class StuffItSplitTests: XCTestCase {
    func testR13CompleteSetsAtTheVolumeLimitOpenButExtraPartsFail() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let forks = try forks(ofMacBinary: "testfile.stuffit45_dlx.mac9.sit.bin")
        let expected = try digests(ArchiveReader.open(data: StuffItCorpusTests().fixture("testfile.stuffit45_dlx.mac9.sit.bin")))
        for count in [1, 128] {
            let directory = temporary.appendingPathComponent(String(count), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try writeParts(forks, to: directory, names: { "x.sit.\($0)" }, cuts: Array(1..<count))
            let options = ReaderOptions(limits: ReadLimits(maxVolumeCount: count))
            for url in Set([urls[0], urls[count - 1]]) {
                let reader = try ArchiveReader.open(url: url, options: options)
                XCTAssertEqual(try digests(reader), expected)
                XCTAssertEqual(try digests(reader.reopen()), expected)
            }
            // 次の part が実在するときだけ巻数上限で拒否する。
            try Data(contentsOf: urls[0]).write(to: directory.appendingPathComponent("x.sit.\(count + 1)"))
            XCTAssertThrowsError(try ArchiveReader.open(url: urls[0], options: options)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("StuffIt split part count"))
            }
        }
    }

    private struct Forks { let data: Data; let resource: Data }

    /// MacBinary（MacBinary II standard proposal）の fork を切り出す: D は BE32 @83、R は BE32 @87、
    /// data fork は 128 から、resource fork は data fork を 128 の倍数に丸めた直後。
    private func forks(ofMacBinary name: String) throws -> Forks {
        let bytes = [UInt8](try StuffItCorpusTests().fixture(name))
        let d = Int(bytes[83]) << 24 | Int(bytes[84]) << 16 | Int(bytes[85]) << 8 | Int(bytes[86])
        let r = Int(bytes[87]) << 24 | Int(bytes[88]) << 16 | Int(bytes[89]) << 8 | Int(bytes[90])
        let resourceStart = 128 + (d + 127) / 128 * 128
        return Forks(data: Data(bytes[128..<(128 + d)]), resource: Data(bytes[resourceStart..<(resourceStart + r)]))
    }

    private func header(part: Int, name: String, resource: Int, data: Int, identityTweak: UInt8 = 0) -> Data {
        var h = [UInt8](repeating: 0, count: 100)
        h[0] = 0xB0; h[1] = 0x56
        h[2] = UInt8(part >> 8); h[3] = UInt8(part & 0xFF)
        let nameBytes = Array(name.utf8)
        h[4] = UInt8(nameBytes.count)
        h.replaceSubrange(5..<(5 + nameBytes.count), with: nameBytes)
        h.replaceSubrange(68..<72, with: Array("SIT!".utf8))
        h.replaceSubrange(72..<76, with: Array("SIT!".utf8))
        h[77] = identityTweak
        for (offset, value) in [(86, resource), (90, data)] {
            h[offset] = UInt8(value >> 24); h[offset + 1] = UInt8((value >> 16) & 0xFF)
            h[offset + 2] = UInt8((value >> 8) & 0xFF); h[offset + 3] = UInt8(value & 0xFF)
        }
        return Data(h)
    }

    /// 連結 stream（resource + data）を `cuts` で切って part を書く。
    @discardableResult
    private func writeParts(_ forks: Forks, to directory: URL, names: (Int) -> String, cuts: [Int],
                            identityTweak: (Int) -> UInt8 = { _ in 0 }) throws -> [URL] {
        let stream = forks.resource + forks.data
        var boundaries = [0] + cuts + [stream.count]
        boundaries = Array(Set(boundaries)).sorted()
        var urls: [URL] = []
        for (index, start) in boundaries.dropLast().enumerated() {
            let end = boundaries[index + 1]
            let part = header(part: index + 1, name: "original.sit", resource: forks.resource.count, data: forks.data.count,
                              identityTweak: identityTweak(index + 1)) + stream[start..<end]
            let url = directory.appendingPathComponent(names(index + 1))
            try part.write(to: url)
            urls.append(url)
        }
        return urls
    }

    private func digests(_ reader: ArchiveReader) throws -> [String] {
        try reader.entries.map { entry in
            entry.name + " " + SHA256.hash(data: try reader.read(entry)).map { String(format: "%02x", $0) }.joined()
        }
    }

    func testSplitPartsReassembleBothForksAndDecryptWithTheCarriedResourceFork() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let forks = try forks(ofMacBinary: "testfile.stuffit45_dlx.mac9.password.sit.bin")
        XCTAssertGreaterThan(forks.resource.count, 0)
        let whole = try ArchiveReader.open(data: try StuffItCorpusTests().fixture("testfile.stuffit45_dlx.mac9.password.sit.bin"),
                                           options: ReaderOptions(password: "password"))
        let expected = try digests(whole)

        // 3 part: 1 つ目の境界は resource fork の途中、2 つ目は data fork の途中。
        let cuts = [forks.resource.count / 2, forks.resource.count + forks.data.count / 2]
        for (label, names) in [
            ("dot-number", { (n: Int) in "original.sit.\(n)" }),
            ("number-dot-sit", { (n: Int) in "original.\(n).sit" }),
            ("zero-padded", { (n: Int) in "original.sit.\(String(format: "%02d", n))" }),
        ] as [(String, (Int) -> String)] {
            let directory = temporary.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try writeParts(forks, to: directory, names: names, cuts: cuts)
            XCTAssertEqual(urls.count, 3, label)
            for url in urls {
                XCTAssertEqual(try FormatDetector.detect(url: url), .stuffIt, "\(label) \(url.lastPathComponent)")
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: "password"))
                XCTAssertEqual(reader.format, .stuffIt, label)
                XCTAssertEqual(try digests(reader), expected, "\(label) opened from \(url.lastPathComponent)")
                // 元 file を消しても保持した part の handle から reopen できる。
                let reopened = try reader.reopen()
                XCTAssertEqual(try digests(reopened), expected, label)
            }
        }
    }

    func testMissingMismatchedAndUnwalkableParts() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let forks = try forks(ofMacBinary: "testfile.stuffit45_dlx.mac9.sit.bin")
        let cuts = [forks.resource.count + 300]

        // part 2 が無い: 途中で切れる。
        let missing = temporary.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let urls = try writeParts(forks, to: missing, names: { "x.sit.\($0)" }, cuts: cuts)
        try FileManager.default.removeItem(at: urls[1])
        XCTAssertThrowsError(try ArchiveReader.open(url: urls[0])) { XCTAssertEqual($0 as? KaitoError, .truncated) }

        // part 2 の header が別セットのもの（identity 不一致）。
        let mismatched = temporary.appendingPathComponent("mismatched", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatched, withIntermediateDirectories: true)
        let bad = try writeParts(forks, to: mismatched, names: { "x.sit.\($0)" }, cuts: cuts, identityTweak: { $0 == 2 ? 1 : 0 })
        XCTAssertThrowsError(try ArchiveReader.open(url: bad[0])) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }

        // Data から開いた複数 part は兄弟を探せないので unsupportedMethod、単独 part で R+D を覆えば開ける。
        let good = temporary.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        let parts = try writeParts(forks, to: good, names: { "x.sit.\($0)" }, cuts: cuts)
        XCTAssertThrowsError(try ArchiveReader.open(data: try Data(contentsOf: parts[0]))) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt split file from Data"))
        }
        let single = try writeParts(forks, to: good, names: { _ in "single.sit.1" }, cuts: [])
        let fromData = try ArchiveReader.open(data: try Data(contentsOf: single[0]))
        XCTAssertEqual(fromData.format, .stuffIt)
        XCTAssertEqual(try digests(fromData), try digests(try ArchiveReader.open(url: parts[0])))

        // 名前に part 番号が無い file は単独 part として扱われ、覆えなければ unsupportedMethod。
        let unnumbered = good.appendingPathComponent("part-one.sit")
        try Data(contentsOf: parts[0]).write(to: unnumbered)
        XCTAssertThrowsError(try ArchiveReader.open(url: unnumbered)) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("StuffIt split file from Data"))
        }

        // part 番号 0 は malformed、上限を超える番号は limitExceeded。
        var zero = try Data(contentsOf: parts[0]); zero[3] = 0
        XCTAssertThrowsError(try ArchiveReader.open(data: zero)) {
            guard case .malformed = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try ArchiveReader.open(url: parts[1], options: ReaderOptions(limits: ReadLimits(maxVolumeCount: 1)))) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testSiblingNameSubstitution() {
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "whole.sit.1", partNumber: 1, target: 2), ["whole.sit.2"])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "whole.1.sit", partNumber: 1, target: 3), ["whole.3.sit"])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "disk2.sit.02", partNumber: 2, target: 10), ["disk2.sit.10"])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "disk2.sit.02", partNumber: 2, target: 3), ["disk2.sit.03", "disk2.sit.3"])
        // 2 桁の part から 1 桁の兄弟を探すときは、ゼロ埋めした綴りと埋めない綴りの両方を候補にする。
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "disk.sit.10", partNumber: 10, target: 1), ["disk.sit.01", "disk.sit.1"])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "v2.sit.1", partNumber: 1, target: 2), ["v2.sit.2"])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "whole.sit", partNumber: 1, target: 2), [])
        XCTAssertEqual(StuffItSplitSet.siblingNames(of: "whole.sit.2", partNumber: 1, target: 2), [])
    }

    /// 10 part 以上のセットは、埋めない命名でも 2 桁の part から開ける。ゼロ埋めの命名も同じ経路で確認する。
    func testTwelvePartSetsOpenFromEveryPartWithAndWithoutZeroPadding() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let forks = try forks(ofMacBinary: "testfile.stuffit45_dlx.mac9.sit.bin")
        let expected = try digests(try ArchiveReader.open(data: try StuffItCorpusTests().fixture("testfile.stuffit45_dlx.mac9.sit.bin")))
        let total = forks.resource.count + forks.data.count
        let cuts = (1..<12).map { $0 * total / 12 }
        for (label, names) in [
            ("plain", { (n: Int) in "disk.sit.\(n)" }),
            ("padded", { (n: Int) in "disk.sit.\(String(format: "%02d", n))" }),
        ] as [(String, (Int) -> String)] {
            let directory = temporary.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = try writeParts(forks, to: directory, names: names, cuts: cuts)
            XCTAssertEqual(urls.count, 12, label)
            for url in urls {
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(try digests(reader), expected, "\(label) opened from \(url.lastPathComponent)")
            }
        }
    }
}
