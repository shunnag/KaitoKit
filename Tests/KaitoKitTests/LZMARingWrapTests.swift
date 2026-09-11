import CryptoKit
import Foundation
import KaitoKit
import XCTest

// cooViewer-9epb: 9tlo の inline copy 最適化案で壊れた wrapped-source 経路を守る。
// 辞書 D = 4096 に対して周期 P = D - g のデータを 24 回（変異版は 40 回）展開し、
// copyLZMAMatch の dictionaryPosition < byteDistance を通す。
// 論理的な match 距離は P でも、リング上の source は destination の g バイト後ろにある。
// 故障条件はその間隔 d が 1...14、コピー長 > 16、コピー長 % 16 != 0。
// 変異版は周期ごとに乱数変異を含み、match 長と末尾位置をばらつかせる。
// g = 0, 15, 16, 32 は境界の比較用。単なる展開成功や crash の有無ではなく、
// 圧縮前の .bin から採取した SHA-256 で出力全体を検証する。
final class LZMARingWrapTests: XCTestCase {
    // 最初の 15 本はレビュー時の元書庫を保存したもの。元 .bin 自体は保存しない。
    // 追加の LZMA1 版は Scripts/fixtures/make-lzma-ringwrap.py の既定 seed で生成。
    // テスト時には乱数生成・再圧縮・外部コマンドを使わない。
    private let expectedSHA256: [String: String] = [
        "test-g0.7z": "5850b518ac4aa9edffc86fd2eb243879376e67f74b963aaf1810d8598b64477e",
        "test-g1.7z": "13ed3e5b205bc0daa0d15c462098b581d52b11549ed0bb499d6811e9baba9262",
        "test-g8.7z": "43320d4858d910defa6681fc96787f1bdd63d06a83528276306f26ace4dc1107",
        "test-g15.7z": "9fd09b3a843b7fe5f41a171972ac5f699ef2cf392f65c255f1700e66e4c74a59",
        "test-g16.7z": "d6849ba524e301a9a946b4035b0bf0cde57759e03e73d14aa3e7e5b9a844938d",
        "test-g32.7z": "f0ffa82ac5ec17e27925f79be65971ec60be64f8cb6bf47cecb14dd87f0bb27b",
        "vtest-g2.7z": "4cac69ffe76aab9da5dcbb1a52fd4b6fa24159a1ee8f2bb9aee40dd8a41bace1",
        "vtest-g3.7z": "9e524f59e9bbaabf8f700490368def65b17c9866fe0f65e523e690a9533da555",
        "vtest-g5.7z": "93db0fb6ddb48c4c581c721174258507dd2749443a2610071b68fb0d7a4e74ca",
        "vtest-g7.7z": "7a8bcbd5dc85094a030e571d27d3572f1e35cde288458388be2da7bb9326d0c9",
        "vtest-g9.7z": "1f2f9d460c7673e57053cb550a59a5b312641d2e9c3dfa117b288fde6b0a4c0e",
        "vtest-g11.7z": "e362e58cff694d9882ffcc7bacecabe5a6dbbe4ada843bd068728652c3b27a4a",
        "vtest-g13.7z": "12f2565c1a632ccca78286448d2bae8b9502388cdc79157970417d7f22741587",
        "vtest-g14.7z": "4cc802ddcacdd3c26a24be7e7e80f3b141078ae6414a8e831fb2f95e8381d860",
        "vtest-g15.7z": "40d6ca8c0c4d73790d757a97c6964837000cf6fa2f20759b5bb3a5d6274d178a",
        "lzma1-g1.7z": "0e9c8f51af5c1dc3253c320ef2266341d548b325a0f037a07b2060c0a5fa003e",
        "lzma1-g8.7z": "72bfb01dbb2b3d7490269187f5a42942ffb16284f6b3b8626e2db81b37312c64",
        "lzma-g1.zip": "0e9c8f51af5c1dc3253c320ef2266341d548b325a0f037a07b2060c0a5fa003e",
        "lzma-g8.zip": "72bfb01dbb2b3d7490269187f5a42942ffb16284f6b3b8626e2db81b37312c64",
        "alone-g1.lzma": "0e9c8f51af5c1dc3253c320ef2266341d548b325a0f037a07b2060c0a5fa003e",
        "alone-g8.lzma": "72bfb01dbb2b3d7490269187f5a42942ffb16284f6b3b8626e2db81b37312c64",
    ]

    // 各書庫を独立したテストにし、1 本の展開失敗でも残りの検証を続ける。
    func testSevenZipLZMA2PeriodicG0() throws { try assertLZMA2(gap: 0) }
    func testSevenZipLZMA2PeriodicG1() throws { try assertLZMA2(gap: 1) }
    func testSevenZipLZMA2PeriodicG8() throws { try assertLZMA2(gap: 8) }
    func testSevenZipLZMA2PeriodicG15() throws { try assertLZMA2(gap: 15) }
    func testSevenZipLZMA2PeriodicG16() throws { try assertLZMA2(gap: 16) }
    func testSevenZipLZMA2PeriodicG32() throws { try assertLZMA2(gap: 32) }

    func testSevenZipLZMA2VariedG2() throws { try assertLZMA2(gap: 2, varied: true) }
    func testSevenZipLZMA2VariedG3() throws { try assertLZMA2(gap: 3, varied: true) }
    func testSevenZipLZMA2VariedG5() throws { try assertLZMA2(gap: 5, varied: true) }
    func testSevenZipLZMA2VariedG7() throws { try assertLZMA2(gap: 7, varied: true) }
    func testSevenZipLZMA2VariedG9() throws { try assertLZMA2(gap: 9, varied: true) }
    func testSevenZipLZMA2VariedG11() throws { try assertLZMA2(gap: 11, varied: true) }
    func testSevenZipLZMA2VariedG13() throws { try assertLZMA2(gap: 13, varied: true) }
    func testSevenZipLZMA2VariedG14() throws { try assertLZMA2(gap: 14, varied: true) }
    func testSevenZipLZMA2VariedG15() throws { try assertLZMA2(gap: 15, varied: true) }

    func testSevenZipLZMA1G1() throws {
        try assertFixture("lzma1-g1.7z", format: .sevenZip, method: "LZMA", size: 98_280)
    }

    func testSevenZipLZMA1G8() throws {
        try assertFixture("lzma1-g8.7z", format: .sevenZip, method: "LZMA", size: 98_112)
    }

    func testZipLZMAG1() throws {
        try assertFixture("lzma-g1.zip", format: .zip, method: "lzma", size: 98_280)
    }

    func testZipLZMAG8() throws {
        try assertFixture("lzma-g8.zip", format: .zip, method: "lzma", size: 98_112)
    }

    // Alone 形式には CRC がないため、SHA-256 による内容検証が特に重要。
    func testLZMAAloneG1() throws {
        try assertFixture("alone-g1.lzma", format: .lzma, method: "LZMA (Alone)", size: 98_280)
    }

    func testLZMAAloneG8() throws {
        try assertFixture("alone-g8.lzma", format: .lzma, method: "LZMA (Alone)", size: 98_112)
    }

    private func assertLZMA2(
        gap: Int,
        varied: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let name = "\(varied ? "vtest" : "test")-g\(gap).7z"
        try assertFixture(
            name, format: .sevenZip, method: "LZMA2",
            size: (4_096 - gap) * (varied ? 40 : 24), file: file, line: line
        )
    }

    private func assertFixture(
        _ name: String,
        format: ArchiveFormat,
        method: String,
        size: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(expectedSHA256[name], name, file: file, line: line)
        let archive = try ZipTestSupport.checkedInFixture("lzma-ringwrap/\(name)")
        // magic のない .lzma の形式判定には拡張子が必要なので、URL から開く。
        let directory = try ZipTestSupport.temporaryDirectory(label: "lzma-ringwrap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try archive.write(to: url)
        // 最小辞書 4 KiB と同じ上限を課し、大辞書の fixture への置換を検出する。
        let reader = try ArchiveReader.open(
            url: url,
            options: ReaderOptions(limits: ReadLimits(maxDictionarySize: 4_096))
        )
        XCTAssertEqual(reader.format, format, name, file: file, line: line)
        XCTAssertEqual(reader.entries.count, 1, name, file: file, line: line)
        let entry = try XCTUnwrap(reader.entries.first, name, file: file, line: line)
        XCTAssertEqual(entry.methodDescription, method, name, file: file, line: line)
        let decoded = try reader.read(entry)
        XCTAssertEqual(decoded.count, size, name, file: file, line: line)
        XCTAssertEqual(
            SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined(),
            expected, name, file: file, line: line
        )
    }
}
