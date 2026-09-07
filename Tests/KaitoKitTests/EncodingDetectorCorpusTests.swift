import Foundation
import KaitoKit
import XCTest

final class EncodingDetectorCorpusTests: XCTestCase {
    private struct ArchiveCorpus {
        var bytes: [[UInt8]] = []
        var names: [String] = []
        var representable = 0
        var utf8Ambiguous = 0
    }

    private let japaneseNames = [
        "表紙", "目次", "漫画", "画像", "東京", "大阪", "京都", "春雨", "夏空", "秋風",
        "冬雪", "月夜", "花火", "朝顔", "夕焼", "青空", "星空", "銀河", "未来", "記憶",
        "秘密", "約束", "旅路", "音楽", "世界", "物語", "少年", "少女", "冒険", "日常",
        "第一話", "第二話", "第三話", "最終話", "前編", "後編", "番外編", "新装版", "完全版", "上巻",
        "中巻", "下巻", "第01巻", "第02巻", "第10巻", "読切", "短編集", "図書館", "喫茶店", "放課後",
        "文化祭", "夏休み", "冬休み", "桜並木", "雨上り", "海辺町", "山小屋", "時計塔", "魔法使い", "勇者伝説",
        "吾輩は猫である.txt", "注文の多い料理店.txt", "羅生門.txt", "銀河鉄道の夜.txt", "こころ.txt", "走れメロス.txt",
        "人間失格.txt", "風の又三郎.txt", "ﾃｽﾄ.txt", "ｶﾀｶﾅ.jpg", "ｺﾐｯｸ01.png", "ﾍﾟｰｼﾞ2.webp",
        "ﾌｧｲﾙ名.txt", "ｻﾝﾌﾟﾙ.zip", "①表紙.png", "②目次.txt", "③資料.dat", "髙橋.jpg",
        "髙島屋.png", "山﨑写真.webp", "㈱資料.pdf", "㍻記録.txt", "Ⅰ巻.cbz",
    ]

    func testCorpusHasRequiredJapaneseCoverage() {
        XCTAssertGreaterThanOrEqual(japaneseNames.count, 60)
        XCTAssertGreaterThanOrEqual(
            japaneseNames.filter { (2...4).contains($0.count) }.count,
            40,
            "the corpus must retain many ambiguity-prone short names"
        )
        XCTAssertGreaterThanOrEqual(
            japaneseNames.filter(containsHalfWidthKatakana).count,
            6
        )
        XCTAssertTrue(japaneseNames.contains { $0.contains("①") })
        XCTAssertTrue(japaneseNames.contains { $0.contains("髙") })
    }

    func testStrictUTF8AlwaysWinsAndRoundTripsEveryCorpusName() {
        for name in japaneseNames {
            let detection = EncodingDetector.detect(
                bytes: Array(name.utf8),
                policy: .automatic()
            )
            XCTAssertEqual(detection.encoding, .utf8, "UTF-8 precedence failed for \(name)")
            XCTAssertEqual(detection.string, name, "UTF-8 round-trip failed for \(name)")
            XCTAssertEqual(detection.confidence, 1.0)
        }
    }

    func testArchiveLevelCP932AndEUCJPCorporaRoundTrip156LegacyNames() throws {
        // Darwin の shiftJIS は CP932 拡張を含むため、このラベルで評価する。
        let cp932 = try makeArchiveCorpus(encoding: .shiftJIS, label: "CP932")
        let eucJP = try makeArchiveCorpus(encoding: .japaneseEUC, label: "EUC-JP")

        XCTAssertGreaterThanOrEqual(cp932.representable, 60)
        XCTAssertGreaterThanOrEqual(eucJP.representable, 60)
        XCTAssertEqual(cp932.bytes.count + eucJP.bytes.count, 156)
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: cp932.bytes),
            .shiftJIS
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: eucJP.bytes),
            .japaneseEUC
        )
        XCTAssertEqual(
            try decodeArchive(cp932.bytes, encoding: .shiftJIS),
            cp932.names
        )
        XCTAssertEqual(
            try decodeArchive(eucJP.bytes, encoding: .japaneseEUC),
            eucJP.names
        )

        // legacy バイト列自体が厳密 UTF-8 の場合、設計契約上 UTF-8 が必ず優先される。
        // この相反するケースだけを archive の legacy 候補から除外する。
        XCTAssertGreaterThan(cp932.utf8Ambiguous + eucJP.utf8Ambiguous, 0)
    }

    func testArchiveDetectionIgnoresStrictUTF8NamesInMixedList() throws {
        let cp932 = try makeArchiveCorpus(encoding: .shiftJIS, label: "CP932")
        let utf8Names = [
            Array("表紙-UTF8.png".utf8),
            Array("plain-ascii.txt".utf8),
        ]
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: utf8Names + cp932.bytes
            ),
            .shiftJIS
        )
        XCTAssertNil(EncodingDetector.detectArchiveEncoding(names: utf8Names))
    }

    func testOneOutlierDoesNotFlipArchiveMajority() throws {
        let cp932 = try makeArchiveCorpus(encoding: .shiftJIS, label: "CP932")
        let eucJP = try makeArchiveCorpus(encoding: .japaneseEUC, label: "EUC-JP")
        let cp932Majority = Array(cp932.bytes.prefix(24)) + [try XCTUnwrap(eucJP.bytes.first)]
        let eucJPMajority = Array(eucJP.bytes.prefix(24)) + [try XCTUnwrap(cp932.bytes.first)]

        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: cp932Majority),
            .shiftJIS
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: eucJPMajority),
            .japaneseEUC
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: Array(cp932.bytes.prefix(2)) + [try XCTUnwrap(eucJP.bytes.first)]
            ),
            .shiftJIS
        )
    }

    func testAmbiguousEUCJPSingletonMatchesPerNameDetection() throws {
        let bytes = Array(try XCTUnwrap(
            "目次.txt".data(using: .japaneseEUC, allowLossyConversion: false)
        ))
        XCTAssertNotNil(EncodingDetector.decode(bytes: bytes, as: .shiftJIS))
        XCTAssertEqual(
            EncodingDetector.detect(bytes: bytes).encoding,
            .japaneseEUC
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: [bytes]),
            .japaneseEUC
        )
        XCTAssertEqual(
            EncodingDetector.decode(bytes: bytes, as: .japaneseEUC),
            "目次.txt"
        )
    }

    func testEUCShiftPrefixOutlierDoesNotOverrideCP932Majority() throws {
        let cp932: [UInt8] = [0xA1, 0xA6, 0x2E, 0x78]
        let eucJP = Array(try XCTUnwrap(
            "ﾃｽﾄ.txt".data(using: .japaneseEUC, allowLossyConversion: false)
        ))
        XCTAssertEqual(EncodingDetector.detect(bytes: cp932).encoding, .shiftJIS)
        XCTAssertEqual(EncodingDetector.detect(bytes: eucJP).encoding, .japaneseEUC)

        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: Array(repeating: cp932, count: 4) + [eucJP]
            ),
            .shiftJIS
        )
    }

    func testExactVoteTieUsesSingleArchiveGuess() throws {
        let cp932 = Array(try XCTUnwrap(
            "｡ﾃｽﾄｶ｡".data(using: .shiftJIS, allowLossyConversion: false)
        ))
        let eucJP = Array(try XCTUnwrap(
            "ﾃｽﾄ.txt".data(using: .japaneseEUC, allowLossyConversion: false)
        ))
        XCTAssertNotNil(EncodingDetector.decode(bytes: cp932, as: .japaneseEUC))
        XCTAssertNotNil(EncodingDetector.decode(bytes: eucJP, as: .shiftJIS))
        XCTAssertEqual(EncodingDetector.detect(bytes: cp932).encoding, .shiftJIS)
        XCTAssertEqual(EncodingDetector.detect(bytes: eucJP).encoding, .japaneseEUC)

        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: [cp932, eucJP]),
            .japaneseEUC
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: [eucJP, cp932]),
            .japaneseEUC
        )
    }

    func testAmbiguousMajorityIsIndependentOfNameOrderBeyondFormerVoteCap() throws {
        let cp932 = Array(try XCTUnwrap(
            "｡ﾃｽﾄｶ｡".data(using: .shiftJIS, allowLossyConversion: false)
        ))
        let eucJP = Array(try XCTUnwrap(
            "ﾃｽﾄ.txt".data(using: .japaneseEUC, allowLossyConversion: false)
        ))
        XCTAssertNotNil(EncodingDetector.decode(bytes: cp932, as: .japaneseEUC))
        XCTAssertNotNil(EncodingDetector.decode(bytes: eucJP, as: .shiftJIS))

        let cpMinority = Array(repeating: cp932, count: 512)
        let eucMajority = Array(repeating: eucJP, count: 1_000)
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: cpMinority + eucMajority),
            .japaneseEUC
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: eucMajority + cpMinority),
            .japaneseEUC
        )

        let cpMajority = Array(repeating: cp932, count: 1_000)
        let eucMinority = Array(repeating: eucJP, count: 512)
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: cpMajority + eucMinority),
            .shiftJIS
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(names: eucMinority + cpMajority),
            .shiftJIS
        )
    }

    func testArchivePoliciesAndNonJapaneseFallback() throws {
        // C3 A9 は厳密 UTF-8 だが、固定ポリシーでは従来どおり Shift-JIS を優先する。
        let validUTF8 = Array("é.txt".utf8)
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: [validUTF8],
                policy: .fixed(.shiftJIS)
            ),
            .shiftJIS
        )
        XCTAssertNil(
            EncodingDetector.detectArchiveEncoding(
                names: [validUTF8],
                policy: .utf8Only
            )
        )
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: [[0xFF]],
                policy: .utf8Only
            ),
            .utf8
        )

        let cp1252 = Array(try XCTUnwrap(
            "price-€-quote.txt".data(using: .windowsCP1252)
        ))
        XCTAssertNil(String(data: Data(cp1252), encoding: .utf8))
        XCTAssertEqual(
            EncodingDetector.detectArchiveEncoding(
                names: [cp1252],
                policy: .automatic(likelyLanguage: nil),
                fromWindows: true
            ),
            .windowsCP1252
        )
    }

    func testAmbiguousLegacyBytesStillHonorStrictUTF8Precedence() throws {
        let legacy = try XCTUnwrap(
            "旅路".data(using: .japaneseEUC, allowLossyConversion: false)
        )
        let strictUTF8 = try XCTUnwrap(String(data: legacy, encoding: .utf8))
        XCTAssertNotEqual(strictUTF8, "旅路")

        let detection = EncodingDetector.detect(bytes: Array(legacy), policy: .automatic())
        XCTAssertEqual(detection.encoding, .utf8)
        XCTAssertEqual(detection.string, strictUTF8)
        XCTAssertEqual(detection.confidence, 1.0)
    }

    func testCP932NECAndIBMExtensionBytes() throws {
        let nec = try XCTUnwrap(
            "①".data(using: .shiftJIS, allowLossyConversion: false)
        )
        let ibm = try XCTUnwrap(
            "髙".data(using: .shiftJIS, allowLossyConversion: false)
        )
        XCTAssertEqual(Array(nec), [0x87, 0x40])
        XCTAssertEqual(Array(ibm), [0xEE, 0xE0])

        let necDetection = EncodingDetector.detect(bytes: Array(nec), policy: .automatic())
        XCTAssertEqual(necDetection.encoding, .shiftJIS)
        XCTAssertEqual(necDetection.string, "①")

        let ibmDetection = EncodingDetector.detect(bytes: Array(ibm), policy: .automatic())
        XCTAssertEqual(ibmDetection.encoding, .shiftJIS)
        XCTAssertEqual(ibmDetection.string, "髙")
    }

    func testExplicitDecodeAndPolicies() throws {
        let name = "髙橋①.jpg"
        let cp932 = try XCTUnwrap(
            name.data(using: .shiftJIS, allowLossyConversion: false)
        )
        XCTAssertEqual(
            EncodingDetector.decode(bytes: Array(cp932), as: .shiftJIS),
            name
        )

        let fixed = EncodingDetector.detect(
            bytes: Array(cp932),
            policy: .fixed(.shiftJIS)
        )
        XCTAssertEqual(fixed.encoding, .shiftJIS)
        XCTAssertEqual(fixed.string, name)
        XCTAssertEqual(fixed.confidence, 1.0)

        let invalidUTF8 = EncodingDetector.detect(
            bytes: [0xFF],
            policy: .utf8Only
        )
        XCTAssertEqual(invalidUTF8.encoding, .utf8)
        XCTAssertEqual(invalidUTF8.confidence, 0.0)
        XCTAssertTrue(invalidUTF8.string.contains("�"))

        let empty = EncodingDetector.detect(bytes: [], policy: .automatic())
        let ascii = EncodingDetector.detect(
            bytes: Array("cover01.jpg".utf8),
            policy: .automatic(likelyLanguage: nil)
        )
        XCTAssertEqual(empty.encoding, .utf8)
        XCTAssertEqual(empty.string, "")
        XCTAssertEqual(ascii.encoding, .utf8)
        XCTAssertEqual(ascii.string, "cover01.jpg")
    }

    private func makeArchiveCorpus(
        encoding: String.Encoding,
        label: String
    ) throws -> ArchiveCorpus {
        var corpus = ArchiveCorpus()

        for name in japaneseNames {
            guard let encoded = name.data(
                using: encoding,
                allowLossyConversion: false
            ) else {
                continue
            }
            corpus.representable += 1
            XCTAssertEqual(
                String(data: encoded, encoding: encoding),
                name,
                "Foundation \(label) fixture did not round-trip: \(name)"
            )

            if let strictUTF8 = String(data: encoded, encoding: .utf8) {
                corpus.utf8Ambiguous += 1
                let detection = EncodingDetector.detect(
                    bytes: Array(encoded),
                    policy: .automatic()
                )
                XCTAssertEqual(detection.encoding, .utf8)
                XCTAssertEqual(detection.string, strictUTF8)
                continue
            }
            corpus.bytes.append(Array(encoded))
            corpus.names.append(name)
        }

        return corpus
    }

    private func decodeArchive(
        _ names: [[UInt8]],
        encoding: String.Encoding
    ) throws -> [String] {
        try names.map { bytes in
            try XCTUnwrap(EncodingDetector.decode(bytes: bytes, as: encoding))
        }
    }

    private func containsHalfWidthKatakana(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in
            (0xFF61...0xFF9F).contains(scalar.value)
        }
    }
}
