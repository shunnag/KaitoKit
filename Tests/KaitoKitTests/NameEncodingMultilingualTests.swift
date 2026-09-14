import Foundation
@testable import KaitoKit
import XCTest

final class NameEncodingMultilingualTests: XCTestCase {
    // 第5回レビュー: かなの有無を日本語の条件にせず、漢字だけの自作書庫で交差復号を検査する。
    private let kanjiCollection = [
        "青山春樹 山川写真 第01巻", "藤原夏美 星空物語 第02巻", "高橋冬子 海辺日記 第03巻",
        "森田秋夫 月光庭園 第04巻", "中村春乃 東方旅行 第05巻", "石川正人 山里図鑑 第06巻",
        "山田直子 草原生活 第07巻", "大川和彦 海底冒険 第08巻", "松本千春 四季風景 第09巻",
        "小林朝子 森林観察 第10巻",
    ]

    private func assertCollection(_ names: [String], encoding: String, languages: [String?]) throws {
        let candidate = try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == encoding })
        let bytes = try names.map { Array(try XCTUnwrap($0.data(using: candidate.encoding))) }
        for language in languages {
            let selected = EncodingDetector.detectArchiveEncoding(names: bytes, policy: .automatic(likelyLanguage: language))
            XCTAssertEqual(selected, candidate.encoding, "\(encoding), language=\(language ?? "nil")")
            for (raw, expected) in zip(bytes, names) {
                XCTAssertEqual(EncodingDetector.resolveUndeclaredName(bytes: raw, policy: .automatic(likelyLanguage: language), archiveEncoding: selected).string, expected)
            }
        }
    }

    func testKanjiOnlyEUCJPCollectionKeepsJapaneseWithAndWithoutPrior() throws {
        try assertCollection(kanjiCollection, encoding: "euc-jp", languages: ["ja", nil])
    }

    func testKanjiOnlyCP932CollectionKeepsJapaneseWithAndWithoutPrior() throws {
        try assertCollection(kanjiCollection, encoding: "cp932", languages: ["ja", nil])
    }

    func testHangulOnlyCollectionWinsDespiteJapanesePrior() throws {
        try assertCollection([
            "김하늘 별빛 여행", "이서연 바다 이야기", "박지우 숲속 사진", "최도윤 달빛 정원", "정수아 겨울 산책",
            "한민준 봄날 편지", "오하린 여름 기록", "윤서준 가을 풍경", "강지안 고향 일기", "장예린 마음 지도",
        ], encoding: "cp949", languages: ["ja"])
    }

    private struct Name {
        let id: String
        let language: String
        let encoding: String
        let bytes: [UInt8]
        let text: String
    }

    private func names() throws -> [Name] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/encoding/names-multilingual.tsv")
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let hex = Array(fields[3])
            let bytes = try stride(from: 0, to: hex.count, by: 2).map { i in
                try XCTUnwrap(UInt8(String(hex[i...i + 1]), radix: 16))
            }
            return Name(id: fields[0], language: fields[1], encoding: fields[2], bytes: bytes, text: fields[4])
        }
    }

    func testAuthoredNamesDecodeIndividually() throws {
        for name in try names() {
            let result = EncodingDetector.detect(bytes: name.bytes, policy: .automatic(likelyLanguage: name.language))
            XCTAssertEqual(result.string.unicodeScalars.map(\.value), name.text.unicodeScalars.map(\.value),
                           "\(name.id): \(result.string)")
        }
    }

    func testAuthoredNamesDecodeInArchivesOfOneThreeAndTen() throws {
        let groups = Dictionary(grouping: try names()) { $0.language + "/" + $0.encoding }
        for (key, members) in groups {
            XCTAssertTrue((8...12).contains(members.count), key)
            for k in [1, 3, 10] {
                for offset in members.indices {
                    let sample = (0..<k).map { members[(offset + $0) % members.count] }
                    let selected = EncodingDetector.detectArchiveEncoding(names: sample.map(\.bytes), policy: .automatic(likelyLanguage: sample[0].language))
                    for name in sample {
                        let result = EncodingDetector.resolveUndeclaredName(bytes: name.bytes, policy: .automatic(likelyLanguage: name.language), archiveEncoding: selected)
                        XCTAssertEqual(result.string.unicodeScalars.map(\.value), name.text.unicodeScalars.map(\.value),
                                       "\(key) k=\(k) \(name.id): \(result.string)")
                    }
                }
            }
        }
    }
}
