import Foundation
@testable import KaitoKit
import XCTest

final class NameEncodingScorerTests: XCTestCase {
    private func rules(_ text: String) -> Double {
        NameEncodingScorer.letterRules(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
    }

    func testCaseAndAdjacentScripts() {
        XCTAssertEqual(rules("Título"), 0)
        XCTAssertEqual(rules("aBCd"), -3)
        XCTAssertEqual(rules("ABCD"), -0.3, accuracy: 0.0001)
        XCTAssertEqual(rules("ABC"), 0)
        XCTAssertEqual(rules("Tнtulo"), -5)
        XCTAssertEqual(rules("Tαtulo"), -5)
        XCTAssertEqual(rules("Tกtulo"), -5)
        XCTAssertEqual(rules("аα"), -2.5)
        XCTAssertEqual(rules("A 日本語 B"), 0)
        XCTAssertEqual(rules("PDF変換"), 0)
        XCTAssertEqual(rules("東京Photo"), 0)
        XCTAssertEqual(rules("Fran嗅ais"), 0)
        XCTAssertEqual(rules("XVII"), -0.3, accuracy: 1e-12)
        XCTAssertEqual(rules("à"), 0)
        XCTAssertEqual(rules("у"), 0)
    }

    func testPhonologyAndASCIIOnlyDenominator() {
        XCTAssertEqual(rules("бвгдж"), -2)
        XCTAssertEqual(rules("аеёи"), -1)
        XCTAssertEqual(rules("мама"), 0)
        XCTAssertEqual(rules("aeiou"), -1)
        XCTAssertEqual(rules("wśród"), 0)
        XCTAssertEqual(rules("моєї"), 0)
        XCTAssertEqual(rules("plná"), 0)
        XCTAssertEqual(rules("rstva"), 0)
        XCTAssertEqual(rules("rstvba"), -2)
        XCTAssertEqual(rules("БВГДЖ"), -1.3, accuracy: 1e-12)
    }

    func testOrthographyRejectsUnambiguousViolations() {
        let scorer = NameEncodingScorer.self
        XCTAssertTrue(scorer.orthography("เก็บภาพ น้ำ ขึ้น", language: "th").violations.isEmpty)
        XCTAssertEqual(scorer.orthography("่ก", language: "th").violations.first?.rule, "th-mark-base")
        XCTAssertEqual(scorer.orthography("เA", language: "th").violations.first?.rule, "th-leading-vowel")
        XCTAssertEqual(scorer.orthography("ำ", language: "th").violations.first?.rule, "th-sara-am")
        XCTAssertTrue(scorer.orthography("tiê\u{0301}ng", language: "vi").violations.isEmpty)
        XCTAssertEqual(scorer.orthography("b\u{0301}", language: "vi").violations.first?.rule, "vi-tone-base")
        XCTAssertEqual(scorer.orthography("a\u{0301}o\u{0300}", language: "vi").violations.first?.rule, "vi-one-tone")
    }

    private func thaiDistribution(_ text: String) -> NameEncodingScorer.Orthography {
        NameEncodingScorer.thaiDistribution(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
    }

    func testThaiCommonRatioUsesLongRunsAndPreservesBoundaries() {
        XCTAssertEqual(thaiDistribution("ขฉชซญฎฏ").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซญฎฏฐ").score, -4.2, accuracy: 1e-12)
        XCTAssertEqual(thaiDistribution("กานขฉชซญ").score, 0)
        XCTAssertEqual(thaiDistribution("กานรมลวขฉชซญฎฏฐฑฒณดต").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซ ญฎฏฐ").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซ1ญฎฏฐ").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซAญฎฏฐ").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซญฎฏิ").score, -3.675, accuracy: 1e-12)
        XCTAssertEqual(thaiDistribution("ขฉชซญฎฏิฐ").score, -4.2, accuracy: 1e-12)
        XCTAssertEqual(thaiDistribution("กรมสรรพากร").score, 0)
        XCTAssertEqual(thaiDistribution("ขฉชซญฎฏฐ").violations.first?.rule, "th-common-ratio")
        XCTAssertEqual(thaiDistribution("A ขฉชซญฎฏฐ").violations.first?.offset, 2)
        XCTAssertEqual(thaiDistribution("漢字漢字漢字漢字").score, 0)
    }

    func testThaiCommonRatioPreservesOrdinaryNames() {
        for name in ["กรมสรรพากร", "สำนักงานคณะกรรมการ", "กระทรวงศึกษาธิการ", "มหาวิทยาลัยเชียงใหม่",
                     "คณะสัตวแพทยศาสตร์", "ฟุตบอลหญิงชิงแชมป์คอนคาแคฟ", "จังหวัดพัทลุง"] {
            let evidence = thaiDistribution(name)
            XCTAssertEqual(evidence.score, 0, name)
            XCTAssertTrue(evidence.violations.isEmpty, name)
        }
    }

    func testThaiRareMarksPunctuationAndEmbeddedDigits() {
        XCTAssertEqual(thaiDistribution("กําข").score, 0)
        XCTAssertEqual(thaiDistribution("กํข").score, -2)
        XCTAssertEqual(thaiDistribution("กํา").score, 0)
        for mark in ["๎", "ฺ"] {
            XCTAssertEqual(thaiDistribution("ก" + mark + "า").score, -2)
            XCTAssertEqual(thaiDistribution(mark).violations.first?.rule, "th-rare-mark")
        }
        for punctuation in ["๏", "๚", "๛"] {
            XCTAssertEqual(thaiDistribution("ก" + punctuation + "า").score, -2)
            XCTAssertEqual(thaiDistribution(punctuation + "กา").score, 0)
            XCTAssertEqual(thaiDistribution("กา" + punctuation).score, 0)
        }
        XCTAssertEqual(thaiDistribution("ก๑า").score, -3)
        XCTAssertEqual(thaiDistribution("กิ๑า").score, -3)
        XCTAssertEqual(thaiDistribution("ก๑").score, 0)
        XCTAssertEqual(thaiDistribution("๑กา").score, 0)
        XCTAssertEqual(thaiDistribution("ก๑๒า").score, 0)
        XCTAssertEqual(thaiDistribution("ก1า").score, 0)
        XCTAssertEqual(thaiDistribution("ก๑า").violations.first?.rule, "th-internal-digit")
    }

    func testThaiPlacementProvidesOnlyWeakPositiveEvidence() {
        XCTAssertEqual(NameEncodingScorer.orthography("กิ", language: "th").positive, 0.25)
        XCTAssertEqual(NameEncodingScorer.orthography("เก", language: "th").positive, 0.25)
        XCTAssertEqual(NameEncodingScorer.orthography("กำ", language: "th").positive, 0.25)
        XCTAssertEqual(NameEncodingScorer.orthography("ิก", language: "th").score, -2)
        XCTAssertEqual(NameEncodingScorer.orthography("a\u{0301}", language: "vi").positive, 1)
    }

    func testThaiDistributionSeparatesCJKCrossDecodes() throws {
        for (text, name, language) in [("学校法人大手前学園", "euc-jp", "ja"),
                                      ("警察广场1号", "gb18030", nil),
                                      ("กรมสรรพากร", "cp874", "ja")] as [(String, String, String?)] {
            let candidate = try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == name })
            let bytes = Array(try XCTUnwrap(text.data(using: candidate.encoding)))
            let detected = EncodingDetector.detect(bytes: bytes, policy: .automatic(likelyLanguage: language))
            XCTAssertEqual(detected.encoding, candidate.encoding, text)
            XCTAssertEqual(detected.string, text)
        }
    }

    func testVietnameseEvidenceAndNFCScoring() throws {
        XCTAssertFalse(NameEncodingScorer.vietnameseEvidence("Săo"))
        XCTAssertFalse(NameEncodingScorer.vietnameseEvidence("café"))
        XCTAssertTrue(NameEncodingScorer.vietnameseEvidence("đêm"))
        XCTAssertTrue(NameEncodingScorer.vietnameseEvidence("tiê\u{0301}ng"))
        XCTAssertTrue(NameEncodingScorer.vietnameseEvidence("trăng"))
        let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "windows-1258" })
        let text = "ê\u{0301}"
        let result = try XCTUnwrap(NameEncodingScorer.score(text, bytes: [0xEA, 0xEC], candidateIndex: index, fromWindows: false))
        XCTAssertGreaterThanOrEqual(result.score, 3)
        XCTAssertEqual(result.string.unicodeScalars.map(\.value), [0xEA, 0x301])
    }

    func testEvidenceUsesScalarsButPriorUsesSharedBytes() throws {
        let bytes: [UInt8] = [0xB0, 0xA1]
        let results = NameEncodingScorer.allScores(bytes, fromWindows: false)
        XCTAssertTrue(results.allSatisfy { $0.byteCount == 2 })
        XCTAssertEqual(results.first { $0.candidateIndex == 4 }?.scalarCount, 1)
        XCTAssertEqual(results.first { $0.candidateIndex == 20 }?.scalarCount, 2)
        let vietnamese = try XCTUnwrap(NameEncodingScorer.score("ê\u{0301}", bytes: [0xEA, 0xEC], candidateIndex: 17, fromWindows: false))
        XCTAssertEqual(vietnamese.scalarCount, 1)
        XCTAssertEqual(vietnamese.byteCount, 2)
    }

    func testEquivalentDecodeReusePreservesCandidateEvidence() throws {
        let samples: [[UInt8]] = [Array("Caf".utf8) + [0xE9], Array("Me".utf8) + [0xB8] + Array("ica".utf8),
                                 Array(repeating: [UInt8(0xA1), 0xA6], count: 40).flatMap { $0 }]
            + stride(from: 128, to: 256, by: 8).map { Array(UInt8($0)...UInt8($0 + 7)) }
        for bytes in samples {
            for archive in [false, true] {
                for result in NameEncodingScorer.allScores(bytes, fromWindows: false, includeHKSCS: true, archive: archive) {
                    let candidate = NameEncodingCandidates.all[result.candidateIndex]
                    let decoded = try XCTUnwrap(candidate.decode(bytes))
                    let separate = try XCTUnwrap(NameEncodingScorer.score(decoded, bytes: bytes, candidateIndex: result.candidateIndex,
                                                                          fromWindows: false, requireVietnameseEvidence: !archive, collectLanguages: archive))
                    XCTAssertEqual(result.score, separate.score, accuracy: 1e-12, candidate.name)
                    XCTAssertEqual(result.scalarCount, separate.scalarCount)
                    XCTAssertEqual(result.byteCount, separate.byteCount)
                    XCTAssertEqual(result.languageScores, separate.languageScores)
                }
            }
        }
    }

    func testLanguageTagsAndTieOrder() {
        for tag in ["zh", "zh-Hans", "zh-CN", "ZH-cn"] { XCTAssertEqual(NameEncodingScorer.language(tag), "zh") }
        for tag in ["zh-Hant", "zh-TW", "zh-HK"] { XCTAssertEqual(NameEncodingScorer.language(tag), "zh-Hant") }
        XCTAssertEqual(NameEncodingScorer.language("uk-UA"), "uk")
        XCTAssertNil(NameEncodingScorer.language("xx"))
        XCTAssertNil(NameEncodingScorer.language(nil))
        let results = (0..<6).map { NameEncodingScorer.Result(candidateIndex: $0, string: "海", score: 2, hanOnly: true) }
        XCTAssertEqual(NameEncodingScorer.ranked(results.reversed(), likelyLanguage: nil).map(\.candidateIndex), Array(0..<6))
        XCTAssertEqual(NameEncodingScorer.ranked(results, likelyLanguage: "zh").first?.candidateIndex, 2)
        XCTAssertEqual(NameEncodingScorer.ranked(results, likelyLanguage: "ko").first?.candidateIndex, 4)
    }

    func testSymbolsUseTheirPositionWithoutChangingPriors() throws {
        let currency = EncodingDetector.detect(bytes: Array("price-".utf8) + [0x80] + Array("-quote.txt".utf8),
                                               policy: .automatic(likelyLanguage: nil), fromWindows: true)
        XCTAssertEqual(currency.encoding, .windowsCP1252)
        XCTAssertEqual(currency.string, "price-€-quote.txt")
        let coffee = EncodingDetector.detect(bytes: [0x43, 0x61, 0x66, 0x82], policy: .automatic(likelyLanguage: nil))
        XCTAssertEqual(coffee.string, "Café")
        XCTAssertEqual(coffee.encoding, NameEncodingCandidates.all.first { $0.name == "cp850" }!.encoding)
    }

    func testUnicodeCategoryAndSymbolPosition() throws {
        func symbol(_ text: String, _ offset: Int) -> Double? {
            NameEncodingScorer.symbolScore(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }, at: offset)
        }
        for text in ["„Friedrich List“", "¿Qué?"] {
            let bytes = Array(try XCTUnwrap(text.data(using: .windowsCP1252)))
            let detected = EncodingDetector.detect(bytes: bytes, policy: .automatic(likelyLanguage: nil))
            XCTAssertEqual(detected.encoding, .windowsCP1252)
            XCTAssertEqual(detected.string, text)
        }
        XCTAssertEqual(symbol("Caf‚", 3), -2)
        XCTAssertEqual(symbol("‚Caf", 0), 0)
        XCTAssertEqual(symbol("Me¸ica", 2), -5)
        XCTAssertEqual(symbol(" ¸ ", 1), 0)
        XCTAssertEqual(symbol("l´amour", 1), 0)
        XCTAssertEqual(symbol("´amour", 0), -5)
        XCTAssertEqual(symbol("a×b", 1), -2)
        XCTAssertEqual(symbol("彼×彼女", 1), 0)
        XCTAssertEqual(symbol("作品★特典", 2), 0)
        XCTAssertEqual(symbol("m²", 1), 0)
        XCTAssertEqual(symbol("°C", 0), 0)
        XCTAssertEqual(symbol("©Name", 0), 0)
        XCTAssertEqual(symbol("ï`û", 1), -2)
        XCTAssertNil(symbol("海`空", 1))
        XCTAssertEqual(symbol("aˇ", 1), 0)
        XCTAssertEqual(symbol("ˇˇ", 1), 0)
    }

    func testRepeatedIntervalsCarryNoEvidence() throws {
        func mask(_ text: String) -> [Bool] {
            NameEncodingScorer.repeatedScalars(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        for pattern in ["a", "¡Š", "あいう", "・"] {
            XCTAssertFalse(mask(String(repeating: pattern, count: 19)).contains(true))
            XCTAssertTrue(mask(String(repeating: pattern, count: 20)).allSatisfy { $0 })
        }
        let text = "café " + String(repeating: "¡Š", count: 20) + " mañana"
        let repeated = mask(text)
        XCTAssertTrue(repeated[5..<45].allSatisfy { $0 })
        XCTAssertFalse(repeated.prefix(5).contains(true))
        XCTAssertFalse(repeated.suffix(7).contains(true))
        let bytes = Array(repeating: [UInt8(0xA1), UInt8(0xA6)], count: 130).flatMap { $0 }
        for result in NameEncodingScorer.allScores(bytes, fromWindows: false, includeHKSCS: true, archive: true) {
            XCTAssertEqual(result.score, 0, accuracy: 1e-12, NameEncodingCandidates.all[result.candidateIndex].name)
        }
        let cp1252 = NameEncodingCandidates.all.firstIndex { $0.name == "windows-1252" }!
        let withWords = "café " + String(repeating: "¡¦", count: 20) + " mañana"
        let raw = Array(try XCTUnwrap(withWords.data(using: .windowsCP1252)))
        XCTAssertGreaterThan(try XCTUnwrap(NameEncodingScorer.score(withWords, bytes: raw, candidateIndex: cp1252, fromWindows: false)).score, 0)
    }

    func testAlphabeticLengthAndThaiVowelEvidence() {
        func excessive(_ text: String) -> [Bool] {
            NameEncodingScorer.excessiveLetters(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(NameEncodingScorer.traits(0xAA).script, .latin)
        XCTAssertTrue(NameEncodingScorer.traits(0xAA).letter)
        XCTAssertTrue(excessive(String(repeating: "íª", count: 20)).allSatisfy { !$0 })
        XCTAssertEqual(excessive(String(repeating: "íª", count: 21)).filter { $0 }.count, 2)
        XCTAssertEqual(excessive(String(repeating: "бж", count: 21)).filter { $0 }.count, 2)
        XCTAssertEqual(excessive(String(repeating: "αβ", count: 21)).filter { $0 }.count, 2)
        XCTAssertEqual(excessive(String(repeating: "a", count: 40) + "é").filter { $0 }.count, 1)
        XCTAssertEqual(excessive(String(repeating: "กฆ", count: 7)).filter { $0 }.count, 2)
        XCTAssertTrue(excessive(String(repeating: "กฆ", count: 7) + "า").allSatisfy { !$0 })
        XCTAssertTrue(excessive(String(repeating: "日本語", count: 30)).allSatisfy { !$0 })
    }

    func testMultibyteLatinIntrusionAndSymbolZones() throws {
        let cp932 = NameEncodingCandidates.all[0]
        XCTAssertEqual(cp932.latinIntrusions([0x72, 0x8E, 0x73]), [0, -2])
        XCTAssertEqual(cp932.latinIntrusions([0x8E, 0x73, 0x72]), [0, 0])
        XCTAssertEqual(cp932.latinIntrusions([0x32, 0x8E, 0x73]), [0, 0])
        XCTAssertEqual(cp932.latinIntrusions([0x9F, 0x56, 0x8E, 0x6A]), [0, 0])
        for name in ["euc-jp", "gb18030"] {
            let i = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == name })
            let bytes: [UInt8] = [0xA1, 0xA6, 0xA1, 0xA6]
            let text = try XCTUnwrap(NameEncodingCandidates.all[i].decode(bytes))
            XCTAssertEqual(NameEncodingCandidates.all[i].zoneScores(bytes), [0, 0])
            XCTAssertEqual(NameEncodingScorer.score(text, bytes: bytes, candidateIndex: i, fromWindows: false)?.score, 0)
        }
    }

    func testMembershipUsesOneLanguageAndFrequencyMaximum() throws {
        let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "windows-1252" })
        let bare = try XCTUnwrap(NameEncodingScorer.score("ñß", bytes: [0xF1, 0xDF], candidateIndex: index, fromWindows: false))
        let withASCII = try XCTUnwrap(NameEncodingScorer.score("aañß", bytes: [0x61, 0x61, 0xF1, 0xDF], candidateIndex: index, fromWindows: false))
        XCTAssertEqual(bare.score, 1.75)
        XCTAssertEqual(bare.scalarCount, 2)
        XCTAssertEqual(withASCII.score, bare.score)
    }

    func testHangulZoneAndQualifiedHalfWidthEvidence() throws {
        func score(_ name: String, _ bytes: [UInt8]) throws -> Double {
            let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == name })
            let text = try XCTUnwrap(NameEncodingCandidates.all[index].decode(bytes))
            return try XCTUnwrap(NameEncodingScorer.score(text, bytes: bytes, candidateIndex: index, fromWindows: false)).score
        }
        // 第5回レビューで 가 は明示された頻出音節となる。集合は重ねず、区2と頻度0.5だけを数える。
        XCTAssertEqual(try score("cp949", [0xB0, 0xA1]), 2.5)
        XCTAssertEqual(try score("cp949", [0xB0, 0xA2]), 2)
        XCTAssertEqual(try score("cp949", [0x81, 0x41]), 0.25)
        XCTAssertEqual(try score("cp949", [0xA4, 0xA1]), 0.5)
        XCTAssertEqual(try score("cp949", [0xCA, 0xA1]), 1.25)
        XCTAssertEqual(NameEncodingScorer.scalarScore(NameEncodingScorer.traits(0x65E5), language: NameEncodingScorer.hanLanguageData).value, 2)
        XCTAssertEqual(try score("cp932", [0xB1, 0xB2, 0xB3]), 0)
        XCTAssertEqual(try score("cp932", [0xC3, 0xBD, 0xC4]), 3)
        XCTAssertEqual(try score("cp932", [0x83, 0x8B, 0x81, 0x5B]), 3)
        XCTAssertEqual(try score("cp932", [0x81, 0x5B]), 0)
        XCTAssertEqual(try score("cp932", [0x95, 0x5C, 0x8E, 0x86]), 2)
        XCTAssertEqual(try score("euc-jp", [0xC9, 0xBD, 0xBB, 0xE6]), 2)
        XCTAssertFalse(EncodingDetector.nameIsLikelyHalfWidth("ｱｲｳ"))
        XCTAssertTrue(EncodingDetector.nameIsLikelyHalfWidth("ﾃｽﾄ"))
    }

    func testArchiveAppliesPriorOnlyOnceForRepeatedShortNames() {
        let bytes: [UInt8] = [0xE4, 0xE5]
        let cp1251 = NameEncodingCandidates.all.first { $0.name == "windows-1251" }!.encoding
        XCTAssertEqual(EncodingDetector.detectArchiveEncoding(names: [bytes], policy: .automatic(likelyLanguage: nil)), .windowsCP1252)
        XCTAssertEqual(EncodingDetector.detectArchiveEncoding(names: Array(repeating: bytes, count: 100), policy: .automatic(likelyLanguage: nil)), cp1251)
    }

    func testArchiveLanguageEvidenceKeepsOneAlphabetAcrossNames() throws {
        let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "windows-1250" })
        let candidate = NameEncodingCandidates.all[index]
        func scores(_ text: String) throws -> NameEncodingScorer.Result {
            let bytes = Array(try XCTUnwrap(text.data(using: candidate.encoding)))
            return try XCTUnwrap(NameEncodingScorer.score(text, bytes: bytes, candidateIndex: index,
                                                         fromWindows: false, collectLanguages: true))
        }
        let acute = try scores("á"), polish = try scores("ń"), coherent = try scores("é")
        XCTAssertEqual(acute.score + polish.score, 5)
        // á は cs/hu、ń は pl の主字母であり、別々の名前でも同じ言語では両方を主字母にできない。
        XCTAssertEqual(candidate.languages.indices.map { acute.languageScores[$0] + polish.languageScores[$0] }.max(), 3)
        XCTAssertEqual(candidate.languages.indices.map { acute.languageScores[$0] + coherent.languageScores[$0] }.max(), 5)
        XCTAssertEqual(NameEncodingScorer.frequent["ko"]?.count, 50)
        let korean = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "cp949" })
        let text = "숲에서"
        let bytes = Array(try XCTUnwrap(text.data(using: NameEncodingCandidates.all[korean].encoding)))
        // 完成型3音節の6点、頻出音節2個の1点、助詞0.5点を同じ3 scalar で平均する。
        XCTAssertEqual(try XCTUnwrap(NameEncodingScorer.score(text, bytes: bytes, candidateIndex: korean, fromWindows: false)).score, 2.5)
    }

    func testConfidenceUsesFirstSecondGap() {
        let a = NameEncodingScorer.Result(candidateIndex: 12, string: "é", score: 2, hanOnly: false)
        let equal = NameEncodingScorer.Result(candidateIndex: 14, string: "é", score: 2, hanOnly: false)
        let lower = NameEncodingScorer.Result(candidateIndex: 15, string: "È", score: 1, hanOnly: false)
        XCTAssertEqual(NameEncodingScorer.confidence([a, equal]), 0.5)
        XCTAssertEqual(NameEncodingScorer.confidence([a, lower]), 0.95)
    }

    func testPriorInfluenceDecreasesWithEvidence() {
        let index = NameEncodingCandidates.all.firstIndex { $0.name == "windows-1251" }!
        func score(_ n: Int, _ language: String?) -> Double {
            NameEncodingScorer.ranked([.init(candidateIndex: index, string: "мама", score: 2, hanOnly: false, byteCount: n)], likelyLanguage: language)[0].score
        }
        XCTAssertGreaterThan(score(1, "ru") - score(1, nil), score(100, "ru") - score(100, nil))
        XCTAssertEqual(score(1, nil), (2 + NameEncodingScorer.priorWeight * 0.6) / (1 + NameEncodingScorer.priorWeight), accuracy: 1e-12)
    }

    func testObsoleteThaiLettersAreWeakEvidenceButStillDecode() throws {
        let candidate = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "cp874" })
        let language = NameEncodingScorer.languageData[candidate]
        XCTAssertEqual(NameEncodingScorer.scalarScore(NameEncodingScorer.traits(0xE03), language: language).value, -2)
        XCTAssertEqual(NameEncodingScorer.scalarScore(NameEncodingScorer.traits(0xE05), language: language).value, -2)
        XCTAssertEqual(NameEncodingScorer.scalarScore(NameEncodingScorer.traits(0xE02), language: language).value, 2)
        XCTAssertEqual(NameEncodingCandidates.all[candidate].decode([0xA3, 0xA5]), "ฃฅ")
        XCTAssertTrue(NameEncodingScorer.orthography("ฃฅ", language: "th").violations.isEmpty)
    }

    func testMarksNumbersAndBoxDrawingAreDistinct() {
        XCTAssertTrue(NameEncodingScorer.traits(0xE48).mark)
        XCTAssertFalse(NameEncodingScorer.traits(0xE48).letter)
        XCTAssertTrue(NameEncodingScorer.traits(0xFF11).number)
        XCTAssertFalse(NameEncodingScorer.traits(0xFF11).mark)
        XCTAssertEqual(rules("╓╖"), -6)
        XCTAssertEqual(rules("第○話"), 0)
        XCTAssertEqual(rules("と○○と"), 0)
        XCTAssertEqual(rules("а○б"), -3)
        XCTAssertEqual(rules("第╬話"), -3)
        XCTAssertEqual(rules("мама"), 0)
    }

    func testAlphabetAndStressOrthography() {
        XCTAssertEqual(rules("Љиљана"), 0)
        XCTAssertEqual(rules("моєї"), 0)
        XCTAssertEqual(rules("љї"), -1)
        XCTAssertEqual(rules("џы"), -1)
        XCTAssertEqual(rules("љ ї"), 0)
        func stress(_ text: String) -> Double {
            NameEncodingScorer.latinStressEvidence(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(stress("árbol página"), 1)
        XCTAssertEqual(stress("‡rbol p‡gina"), 0)
        XCTAssertEqual(stress("heißen außen"), 2)
        XCTAssertEqual(stress("ßplan"), 0)
        XCTAssertEqual(stress("á"), 0)
        XCTAssertEqual(stress("áa oía"), 0)
    }

    func testWesternOrthographyUsesLetterPosition() {
        func evidence(_ text: String) -> Double {
            NameEncodingScorer.westernOrthographicEvidence(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(evidence("caffè città"), 1)
        XCTAssertEqual(evidence("¥à¥À"), 0)
        XCTAssertEqual(evidence("tè"), 0.5)
        XCTAssertEqual(evidence("ìà"), 0)
        XCTAssertEqual(evidence("caffä cittê"), 0)
        XCTAssertEqual(evidence("criança garçon"), 1)
        XCTAssertEqual(evidence("crianáa garcon"), 0)
        XCTAssertEqual(evidence("ève çe îà"), 0)
    }

    func testVietnameseSyllablesAndKoreanGrammar() {
        XCTAssertTrue(NameEncodingScorer.isVietnameseSyllable("trăng"))
        XCTAssertTrue(NameEncodingScorer.isVietnameseSyllable("đường"))
        XCTAssertTrue(NameEncodingScorer.isVietnameseSyllable("quyển"))
        XCTAssertFalse(NameEncodingScorer.isVietnameseSyllable("Săo"))
        XCTAssertFalse(NameEncodingScorer.isVietnameseSyllable("Uluslararasư"))
        func grammar(_ text: String) -> Double {
            NameEncodingScorer.koreanGrammar(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(grammar("2026년 9월 14일"), 1.5)
        XCTAssertEqual(grammar("정원의"), 0.5)
        XCTAssertEqual(grammar("정원"), 0)
        XCTAssertEqual(grammar("만난 새"), 0.5)
        XCTAssertEqual(grammar("만나 새"), 0)
        XCTAssertEqual(grammar("만난새"), 0)
        XCTAssertEqual(grammar("漢만난 새"), 0)
        XCTAssertEqual(grammar("난 새"), 0)
        XCTAssertEqual(grammar("숲에서"), 0.5)
        XCTAssertEqual(grammar("년 월 일"), 0)
    }

    func testArchiveRetainsByteMassForUndecodableNames() throws {
        let texts = Array(repeating: "café", count: 10) + ["„Schöne Grüße“"]
        let bytes = try texts.map { Array(try XCTUnwrap($0.data(using: .windowsCP1252))) }
        XCTAssertEqual(EncodingDetector.detectArchiveEncoding(names: bytes, policy: .automatic(likelyLanguage: nil)), .windowsCP1252)
    }

    func testOrthographyCheckIncludesVowellessRunsAndIgnoresRepetition() {
        XCTAssertTrue(EncodingDetector.checkNameOrthography(String(repeating: "กฆ", count: 20), language: "th").isEmpty)
        XCTAssertEqual(EncodingDetector.checkNameOrthography("กขคงจฉชซญฎฏฐฑ", language: "th").last?.rule, "th-vowelless-run")
        XCTAssertTrue(EncodingDetector.checkNameOrthography("กขคงจฉชซญฎฏฐฑา", language: "th").isEmpty)
    }

    func testCandidateZonesKeepVendorKanjiSeparateFromSecondTier() {
        let cp932 = NameEncodingCandidates.all[0]
        XCTAssertTrue(cp932.zones([0xED, 0x40])[0].vendorIdeograph)
        XCTAssertTrue(cp932.zones([0xFA, 0x5C])[0].vendorIdeograph)
        XCTAssertFalse(cp932.zones([0x98, 0x9F])[0].vendorIdeograph)
        XCTAssertEqual(cp932.zoneScores([0xED, 0x40]), [2])
        for candidate in NameEncodingCandidates.all where [.cp932, .gb18030, .big5, .cp949].contains(candidate.form) {
            XCTAssertEqual(candidate.latinIntrusions([0x61, 0xA4, 0x41]).last, candidate.form == .cp932 ? 0 : -2)
        }
        XCTAssertEqual(NameEncodingCandidates.all[2].latinIntrusions([0x61, 0x81, 0x30, 0x81, 0x30]), [0, 0])
    }

    func testCachedExemplarLookupMatchesCompressedTable() {
        for entry in LanguageExemplars.table {
            let cached = NameEncodingScorer.exemplars[entry.language]!
            for (ranges, kind) in [(cached.main, LanguageExemplars.Kind.main), (cached.auxiliary, .auxiliary)] {
                for value in ranges {
                    for scalar in [value - 1, value, value + 1] {
                        XCTAssertEqual(NameEncodingScorer.contains(scalar, ranges: ranges), LanguageExemplars.contains(scalar, language: entry.language, kind: kind))
                        let bit = UInt32(1) << NameEncodingScorer.exemplarLanguages.firstIndex(of: entry.language)!
                        let traits = NameEncodingScorer.traits(scalar)
                        let mask = kind == .main ? traits.mainMask : traits.auxiliaryMask
                        XCTAssertEqual(mask & bit != 0, NameEncodingScorer.contains(scalar, ranges: ranges))
                    }
                }
            }
        }
    }
}
