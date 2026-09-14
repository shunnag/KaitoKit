import Foundation
import CoreFoundation
@testable import KaitoKit
import XCTest

final class NameEncodingLanguageExtensionTests: XCTestCase {
    private func rules(_ text: String, _ language: String) -> NameEncodingScorer.Orthography {
        NameEncodingScorer.orthography(text, language: language)
    }

    func testAdditionalLanguagesAndWideMasks() {
        XCTAssertEqual(NameEncodingCandidates.all.count, 54)
        XCTAssertNil(NameEncodingCandidates.all.first { $0.name == "cp861" || $0.name == "viscii" })
        for entry in LanguageExemplars.additionalTable {
            let lang = entry.language.replacingOccurrences(of: "_", with: "-")
            XCTAssertNotNil(NameEncodingScorer.exemplars[lang])
            XCTAssertTrue(NameEncodingCandidates.all.contains { $0.languages.contains(lang) }, lang)
        }
        XCTAssertEqual(NameEncodingScorer.language("sr-Latn-RS"), "sr-Latn")
        XCTAssertEqual(NameEncodingScorer.language("sr-Cyrl-RS"), "sr")
        XCTAssertEqual(NameEncodingScorer.language("fa-IR"), "fa")
        XCTAssertEqual(NameEncodingScorer.language("no-NO"), "nb")
        for lang in ["sv", "tr", "uk", "vi", "zh-Hant"] {
            let index = NameEncodingScorer.exemplarLanguages.firstIndex(of: lang)!
            let mask = UInt64(1) << index
            let scalar = NameEncodingScorer.exemplars[lang]!.main[0]
            XCTAssertNotEqual(NameEncodingScorer.traits(scalar).mainMask & mask, 0, lang)
        }
        for c in NameEncodingCandidates.all { XCTAssertLessThanOrEqual(c.languages.count, 16) }
    }

    func testCompatibilityMembershipPreservesOriginalScalars() {
        for (lang, text) in [("fa", "يكیک"), ("ro", "ŞşŢţȘșȚț"), ("es", "ªº"), ("pt", "ªº")] {
            let data = NameEncodingScorer.LanguageData([lang])
            for scalar in text.unicodeScalars {
                XCTAssertEqual(NameEncodingScorer.scalarScore(NameEncodingScorer.traits(scalar.value), language: data).value, 2)
            }
        }
    }

    func testHebrewFinalFormsAndCombiningMarkBase() {
        for text in ["שלום עולם", "דרך ארוכה", "שָׁלוֹם", "מֶלֶךְ", "עץ", "מַיִם"] {
            XCTAssertTrue(rules(text, "he").violations.isEmpty, text)
        }
        XCTAssertEqual(rules("םא", "he").violations.first?.rule, "he-final-internal")
        XCTAssertEqual(rules("מ", "he").score, -1)
        XCTAssertEqual(rules("\u{05B0}א", "he").violations.first?.rule, "he-mark-base")
        XCTAssertEqual(rules("A\u{05B0}", "he").score, -3)
        // maqaf / paseq / sof pasuq は結合記号ではない。
        XCTAssertTrue(rules("אב־גד׃", "he").violations.isEmpty)
        XCTAssertTrue(rules("םא", "ru").violations.isEmpty)
    }

    func testArabicPersianPositionsAndCombiningMarkSequences() {
        for text in ["مدينة جميلة", "مُحَمَّد", "كتابٌ", "شيء", "قراءة", "موسى"] {
            XCTAssertTrue(rules(text, "ar").violations.isEmpty, text)
        }
        XCTAssertEqual(rules("ةب", "ar").violations.first?.rule, "arabic-teh-marbuta-internal")
        XCTAssertEqual(rules("ىب", "ar").violations.first?.rule, "ar-alef-maksura-internal")
        XCTAssertTrue(rules("مىان", "fa").violations.isEmpty)
        XCTAssertTrue(rules("میان", "fa").violations.isEmpty)
        XCTAssertEqual(rules("ءب", "ar").violations.first?.rule, "ar-hamza-initial")
        XCTAssertEqual(rules("A\u{064E}", "ar").violations.first?.rule, "arabic-mark-base")
        XCTAssertEqual(rules("\u{064E}ب", "ar").score, -3)
    }

    func testSemiticScriptMixtureIncludesMarksAfterLatin() {
        func score(_ text: String) -> Double {
            NameEncodingScorer.letterRules(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(score("Aא"), -2.5)
        XCTAssertEqual(score("אA"), -2.5)
        XCTAssertEqual(score("Aب"), -2.5)
        XCTAssertEqual(score("A\u{064E}"), -2.5)
        XCTAssertEqual(score("A\u{05B0}"), -2.5)
        XCTAssertEqual(score("A ب"), 0)
        XCTAssertEqual(score("ب\u{064E}"), 0)
        XCTAssertEqual(score("א ב"), 0)
    }

    func testHardSignRulesBelongToRussianAndBulgarianUsesAVowel() {
        for text in ["объезд", "подъём", "объявление", "съю" ] {
            XCTAssertTrue(rules(text, "ru").violations.isEmpty, text)
        }
        XCTAssertEqual(rules("ъаб", "ru").violations.first?.rule, "ru-hard-sign-position")
        XCTAssertEqual(rules("аъе", "ru").violations.first?.rule, "ru-hard-sign-position")
        XCTAssertEqual(rules("бъа", "ru").violations.first?.rule, "ru-hard-sign-position")
        XCTAssertTrue(rules("България", "bg").violations.isEmpty)
        let text = "пътът"
        let p = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
        XCTAssertLessThan(NameEncodingScorer.letterRules(p, language: "ru"), NameEncodingScorer.letterRules(p, language: "bg"))
        let long = "объезд объезд объезд"
        XCTAssertTrue(rules(long, "ru").violations.contains { $0.rule == "ru-hard-sign-ratio" })
        XCTAssertFalse(rules(long, "bg").violations.contains { $0.rule == "ru-hard-sign-ratio" })
        XCTAssertTrue(rules("рощащащащащаща", "ru").violations.contains { $0.rule == "ru-shcha-ratio" })
    }

    func testAdditionalPositionsPreserveOrdinaryWordsAndCompounds() {
        for text in ["þorp", "Þjóð", "Svíþjóð", "svipþungur", "leið", "þrír", "þvottur"] {
            XCTAssertTrue(rules(text, "is").violations.isEmpty, text)
        }
        XCTAssertEqual(rules("ða", "is").violations.first?.rule, "is-eth-initial")
        XCTAssertEqual(rules("aþ", "is").violations.first?.rule, "is-thorn-final")
        XCTAssertEqual(rules("aþka", "is").violations.first?.rule, "is-thorn-cluster")
        XCTAssertTrue(rules("ða aþ", "tr").violations.isEmpty)
        XCTAssertTrue(rules("аўтар", "be").violations.isEmpty)
        XCTAssertTrue(rules("ва ўніверсітэце", "be").violations.isEmpty)
        XCTAssertEqual(rules("Ўс", "be").violations.first?.rule, "be-short-u-after-vowel")
        XCTAssertEqual(rules("Latin Ю title", "ru").violations.first?.rule, "alphabet-singleton-in-latin")
        XCTAssertTrue(rules("Юлія", "uk").violations.isEmpty)
        XCTAssertTrue(rules("“ภาพ”", "th").violations.isEmpty)
        XCTAssertEqual(rules("”ภาพ", "th").violations.first?.rule, "th-closing-quote-initial")
        func letters(_ text: String) -> Double {
            NameEncodingScorer.letterRules(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) })
        }
        XCTAssertEqual(letters("Ст"), -0.5)
        XCTAssertEqual(letters("СТ"), 0)
        XCTAssertEqual(letters("де"), 0)
        XCTAssertEqual(letters("caffŠ"), -2.5)
        XCTAssertEqual(letters("CAFÉ"), -0.3, accuracy: 1e-12)
        XCTAssertEqual(letters("café"), 0)
        XCTAssertLessThan(letters("Њаль"), letters("Маль"))
    }

    func testAbjadFrequentLettersHaveTheSameBonusAtEveryLength() throws {
        for (name, short, longer) in [("windows-1255", "הו", "הוהו"), ("windows-1256", "لم", "ململ")] {
            let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == name })
            let candidate = NameEncodingCandidates.all[index]
            func score(_ text: String) throws -> Double {
                let bytes = Array(try XCTUnwrap(text.data(using: candidate.encoding)))
                return try XCTUnwrap(NameEncodingScorer.score(text, bytes: bytes, candidateIndex: index, fromWindows: false)).score
            }
            XCTAssertEqual(try score(short), 2.5, accuracy: 1e-12)
            XCTAssertEqual(try score(longer), 2.5, accuracy: 1e-12)
        }
    }

    func testCachedLanguageRuleContextMatchesDirectEvaluation() {
        let samples = ["הו", "שלום עולם", "aBŠ", "Ўс", "ва ўніверсітэце", "объезд объезд объезд", "България", "Aَ", "شَهْر", "Þjóð", "aþka", "Њаль"]
        for text in samples {
            let properties = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            var state = NameEncodingScorer.LetterRuleState()
            for p in properties { state.append(p) }
            state.finish()
            for language in ["he", "ar", "fa", "ru", "uk", "be", "bg", "sr", "mk", "is", "en"] {
                let direct = NameEncodingScorer.additionalOrthography(properties, language: language)
                let cached = NameEncodingScorer.additionalOrthography(properties, language: language, context: state.context)
                XCTAssertEqual(cached.score, direct.score, "\(text) / \(language)")
                XCTAssertEqual(cached.violations.map(\.rule), direct.violations.map(\.rule))
                XCTAssertEqual(cached.violations.map(\.offset), direct.violations.map(\.offset))
            }
        }
    }

    func testScoringSupplementDoesNotBecomeACustomPublicDecoder() throws {
        // کتاب پژوهش。ک を含むため CF の厳密復号は失敗する。
        let hex = "98cac7c820818ee6e5d4" // 自作の短い表検査名。
        let chars = Array(hex)
        let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
        let candidate = try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == "windows-1256" })
        XCTAssertNil(EncodingDetector.decode(bytes: bytes, as: candidate.encoding))
        let automatic = EncodingDetector.detect(bytes: bytes, policy: .automatic(likelyLanguage: "fa"))
        XCTAssertEqual(automatic.encoding, candidate.encoding)
        XCTAssertEqual(automatic.string, EncodingDetector.detect(bytes: bytes, policy: .fixed(candidate.encoding)).string)
        XCTAssertNotEqual(automatic.string, candidate.decode(bytes))
    }

    func testUndefinedMasksExcludeBeforeScoringBeyondTheScalarLimit() throws {
        for c in NameEncodingCandidates.all where c.form == .single {
            for byte in 0..<256 {
                let masked = c.undefinedBytes[byte / 64] & (UInt64(1) << (byte % 64)) != 0
                XCTAssertEqual(masked, c.singleByteTable[byte] == nil, "\(c.name) \(byte)")
            }
        }
        for (name, byte) in [("windows-1255", UInt8(0xD9)), ("windows-1253", 0xAA), ("cp869", 0x80)] {
            let index = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == name })
            let bytes = Array(repeating: UInt8(0x61), count: 300) + [byte]
            XCTAssertFalse(NameEncodingScorer.allScores(bytes, fromWindows: false, archive: true).contains { $0.candidateIndex == index })
        }
    }

    func testScoreOnlyOrthographyAndUnboundedDiagnosticContext() {
        for language in ["he", "ar", "fa", "ru", "uk", "be", "bg", "is"] {
            let properties = "םא ىب ةب Aَ ъаб ða aþ Latin Ю title".unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            let diagnostic = NameEncodingScorer.additionalOrthography(properties, language: language)
            let scoreOnly = NameEncodingScorer.additionalOrthography(properties, language: language, recordViolations: false)
            XCTAssertEqual(scoreOnly.score, diagnostic.score)
            XCTAssertTrue(scoreOnly.violations.isEmpty)
        }
        // 測定 API は採点の256 scalar上限を持たない。長い入力でも属性集計がオーバーフローしない。
        let properties = Array(repeating: NameEncodingScorer.traits(0x61), count: 40_000)
        XCTAssertEqual(NameEncodingScorer.LanguageRuleContext(properties).latin, 40_000)
        XCTAssertTrue(NameEncodingScorer.additionalOrthography(properties, language: "he").violations.isEmpty)
    }

    func testExpandingByteMaskPreservesEveryCFScalar() {
        for (index, candidate) in NameEncodingCandidates.all.enumerated() where candidate.form == .single {
            for byte in 0..<256 {
                guard let scalars = candidate.singleByteTable[byte] else { continue }
                let mask = NameEncodingScorer.expandingBytes[index]
                let expands = mask[byte / 64] & (UInt64(1) << (byte % 64)) != 0
                XCTAssertEqual(expands, scalars.count != 1, "\(candidate.name) \(byte)")
                if !expands {
                    XCTAssertEqual([NameEncodingScorer.singleByteTraits[index][byte].scalar], scalars)
                }
            }
        }
    }

    func testCP1256SupplementIsDetectionOnlyAndMacBidiIsIgnored() throws {
        let arabic = try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == "windows-1256" })
        let expected: [UInt8: UInt32] = [0x8A: 0x679, 0x8F: 0x688, 0x98: 0x6A9, 0x9A: 0x691,
                                        0x9F: 0x6BA, 0xAA: 0x6BE, 0xC0: 0x6C1, 0xFF: 0x6D2]
        XCTAssertEqual(NameEncodingCandidates.cp1256Supplement, expected)
        for (byte, scalar) in expected {
            XCTAssertEqual(arabic.decode([byte])?.unicodeScalars.map(\.value), [scalar])
            XCTAssertNil(EncodingDetector.decode(bytes: [byte], as: arabic.encoding))
        }
        for name in ["x-mac-arabic", "x-mac-farsi"] {
            let c = try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == name })
            XCTAssertEqual(c.decode(Array(" 01-".utf8)), " 01-")
            XCTAssertTrue(c.singleByteTable.compactMap { $0 }.flatMap { $0 }.allSatisfy {
                !(0x202A...0x202E).contains($0) && !(0x2066...0x2069).contains($0)
            })
        }
    }

    func testPriorsPreserveStrictFamilyOrderAndExistingTies() throws {
        let families = [
            [["windows-1253"], ["iso-8859-7"], ["cp737", "cp869"], ["x-mac-greek"]],
            [["windows-1254"], ["iso-8859-9"], ["cp857"], ["x-mac-turkish"]],
            [["windows-1255"], ["iso-8859-8"], ["cp862"], ["x-mac-hebrew"]],
            [["windows-1256"], ["iso-8859-6"], ["cp864"], ["x-mac-arabic", "x-mac-farsi"]],
            [["windows-1257"], ["iso-8859-13"], ["iso-8859-4"], ["cp775"]],
            [["windows-1252"], ["iso-8859-15"], ["iso-8859-10"], ["cp850", "cp437", "macintosh"], ["cp865"], ["x-mac-icelandic"]],
            [["windows-1250"], ["iso-8859-2"], ["iso-8859-16"], ["cp852"], ["x-mac-centraleurroman"], ["x-mac-romanian", "x-mac-croatian"]],
            [["windows-1251"], ["koi8-u", "koi8-r"], ["cp866"], ["cp855"], ["iso-8859-5", "x-mac-cyrillic"], ["x-mac-ukrainian"]],
            [["cp874"], ["x-mac-thai"]],
        ]
        XCTAssertEqual(Set(NameEncodingScorer.priors.keys), Set(NameEncodingCandidates.all.map(\.name)))
        for family in families {
            var previous = Double.infinity
            for tier in family {
                let values = try tier.map { name in
                    NameEncodingScorer.prior(for: try XCTUnwrap(NameEncodingCandidates.all.first { $0.name == name }))
                }
                XCTAssertLessThan(values[0], previous, tier.joined(separator: ","))
                for value in values { XCTAssertEqual(value, values[0]) }
                previous = values[0]
            }
        }
    }

    func testIcelandicAcuteYBelongsOnlyToIcelandicComponent() {
        XCTAssertTrue(rules("nýr lýðveldi Ýmir", "is").violations.contains { $0.rule == "is-y-acute-initial-upper" })
        XCTAssertEqual(rules("ný", "is").score, -2)
        XCTAssertEqual(rules("nýr lýsir", "is").score, -1.5)
        XCTAssertEqual(rules("Ýmir", "is").score, -1)
        XCTAssertTrue(rules("nýr", "is").violations.isEmpty)
        XCTAssertTrue(rules("ný Ýmir nýr lýsir", "tr").violations.isEmpty)
    }

    func testGreekMonotonicAccentAndSigmaPositions() {
        for text in ["κόσμος", "άλλη μέρα", "Μαΐου", "σπίτι", "ΣΟΣ"] {
            XCTAssertTrue(rules(text, "el").violations.isEmpty, text)
        }
        XCTAssertEqual(rules("άέή", "el").score, -4)
        XCTAssertEqual(rules("άέ ήί", "el").score, -4)
        XCTAssertEqual(rules("ςα", "el").score, -2)
        XCTAssertEqual(rules("αςα", "el").score, -2)
        XCTAssertEqual(rules("ασ", "el").score, -1)
        XCTAssertTrue(rules("ας", "el").violations.isEmpty)
        XCTAssertTrue(rules("άέή ςα ασ", "ru").violations.isEmpty)
    }

    func testBracketsAndSemiticSymbolsUseAdjacentLetters() {
        for (text, index) in [("a(b", 1), ("א[ב", 1), ("ا]ب", 1), ("א\\ב", 1), ("ا❊ب", 1)] {
            let p = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            XCTAssertEqual(NameEncodingScorer.symbolScore(p, at: index), -2, text)
        }
        for (text, index) in [("(אב)", 0), ("a (b)", 2), ("אב [גד]", 3)] {
            let p = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            XCTAssertNotEqual(NameEncodingScorer.symbolScore(p, at: index), -2, text)
        }
    }

    func testCaretAndSymbolBridgedScriptMixture() {
        for (text, index) in [("ا^ب", 1), ("^بت", 0), ("a^", 1)] {
            let p = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            XCTAssertEqual(NameEncodingScorer.symbolScore(p, at: index), -5, text)
        }
        let arithmetic = "2^3".unicodeScalars.map { NameEncodingScorer.traits($0.value) }
        XCTAssertEqual(NameEncodingScorer.symbolScore(arithmetic, at: 1), 0)
        for (text, expected) in [("ô£ذ", -2.5), ("ا×a", -2.5), ("a£b", 0), ("ô £ ذ", 0), ("ô££ذ", 0)] {
            let p = text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
            XCTAssertEqual(NameEncodingScorer.letterRules(p), expected, text)
        }
    }

    func testGreekDiaeresisAndLanguageSpecificApostrophes() {
        for text in ["λαϊκός", "Μαΐου", "πραΰς", "φαΐ", "απ’ το", "μου ’πε", "‘ήλιος’"] {
            XCTAssertFalse(rules(text, "el").violations.contains {
                $0.rule == "el-diaeresis-without-vowel" || $0.rule == "el-initial-apostrophe-vowel"
            }, text)
        }
        for text in ["χΰι", "λϋι", "ΐα"] {
            XCTAssertTrue(rules(text, "el").violations.contains { $0.rule == "el-diaeresis-without-vowel" }, text)
        }
        XCTAssertTrue(rules("’ήλιος", "el").violations.contains { $0.rule == "el-initial-apostrophe-vowel" })
        XCTAssertTrue(rules("’exemple", "fr").violations.contains { $0.rule == "fr-initial-apostrophe" })
        for text in ["l’oiseau", "d’hiver", "‘exemple’"] {
            XCTAssertFalse(rules(text, "fr").violations.contains { $0.rule == "fr-initial-apostrophe" }, text)
        }
        XCTAssertFalse(rules("’t Hooft", "nl").violations.contains { $0.rule == "fr-initial-apostrophe" })
    }

    func testLatinDensityExcludesVietnameseAndShortWords() {
        func penalty(_ text: String, _ language: String? = nil) -> Double {
            NameEncodingScorer.letterRules(text.unicodeScalars.map { NameEncodingScorer.traits($0.value) }, language: language)
        }
        XCTAssertEqual(penalty("áéíóbç"), -2)
        for text in ["áéíabc", "áéíóbc", "účetní", "Służbę", "Lošťák"] {
            XCTAssertEqual(penalty(text), 0, text)
        }
        XCTAssertEqual(penalty("áéabcd"), 0)
        XCTAssertEqual(penalty("áéabc"), 0)
        XCTAssertEqual(penalty("áéíóbç", "vi"), 0)
    }

    func testHebrewFinalEvidenceAndCyrillicRatioScopes() {
        XCTAssertEqual(rules("שלום עולם", "he").score, 1)
        XCTAssertEqual(rules("ם ן ף ץ", "he").positive, 0)
        XCTAssertEqual(rules("לֹןֶ עַף", "he").positive, 1)
        XCTAssertEqual(rules("םא", "he").score, -3)
        XCTAssertTrue(rules("יום טוב", "ru").violations.isEmpty)
        XCTAssertFalse(rules("ййабвгдежзи", "ru").violations.contains { $0.rule == "ru-short-i-ratio" })
        XCTAssertTrue(rules("ййабвгдежзика", "ru").violations.contains { $0.rule == "ru-short-i-ratio" })
        for language in ["ru", "uk", "be", "bg", "sr", "mk"] {
            XCTAssertTrue(rules("ййабвгдежзика", language).violations.contains { $0.rule == "\(language)-short-i-ratio" })
            XCTAssertTrue(rules("рощащащащащаща", language).violations.contains { $0.rule == "\(language)-shcha-ratio" })
            let hardSigns = rules("объезд объезд объезд", language).violations
            XCTAssertEqual(hardSigns.contains { $0.rule == "\(language)-hard-sign-ratio" }, ["ru", "uk", "be"].contains(language))
        }
        XCTAssertTrue(rules("България България", "bg").violations.isEmpty)
    }

    func testIdentifyingLettersUseTheExistingByteBonuses() throws {
        for (language, letters) in [("lt", "ųėįąčšžū"), ("lv", "āēīūķļņčšž"), ("et", "õäöüšž"),
                                    ("ro", "ăâîșțşţ"), ("hr", "čćđšž"), ("sl", "čšž"), ("sk", "ľĺŕôäčšťž"),
                                    ("da", "æøå"), ("nb", "æøå"), ("sv", "äöå"), ("fi", "äö"), ("is", "ðæö"),
                                    ("nl", "ëïé"), ("sr-Latn", "čćđšž"), ("bg", "ъ"), ("sr", "њљћџј"),
                                    ("mk", "ќѓѕџљњј"), ("be", "іоўь")] {
            let data = NameEncodingScorer.LanguageData([language])
            for scalar in letters.unicodeScalars {
                let score = NameEncodingScorer.scalarScore(NameEncodingScorer.traits(scalar.value), language: data)
                XCTAssertEqual(score.bonuses[0], 1, "\(language): \(scalar)")
            }
        }
        for (language, letters) in [("is", "þÞýÝ"), ("sr", "ѕЅђЂ"), ("sk", "áéíó"), ("sv", "àá"), ("fi", "åÅ")] {
            for scalar in letters.unicodeScalars {
                XCTAssertFalse(try XCTUnwrap(NameEncodingScorer.frequent[language]).contains(scalar.value))
            }
        }
    }

    func testWesternOrthographicEvidenceIsCommonToCandidateComponents() throws {
        let candidateIndex = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == "windows-1252" })
        let bytes = Array(try XCTUnwrap("città".data(using: .windowsCP1252)))
        let score = try XCTUnwrap(NameEncodingScorer.score("", bytes: bytes, candidateIndex: candidateIndex,
            fromWindows: false, requireVietnameseEvidence: false, collectLanguages: true))
        let languages = NameEncodingCandidates.all[candidateIndex].languages
        let it = try XCTUnwrap(languages.firstIndex(of: "it"))
        let fr = try XCTUnwrap(languages.firstIndex(of: "fr"))
        XCTAssertGreaterThan(NameEncodingScorer.westernOrthographicEvidence("città".unicodeScalars.map { NameEncodingScorer.traits($0.value) }), 0)
        // à の所属と加点が同じなら、grave の証拠も言語成分間で等しい。
        XCTAssertEqual(score.languageScores[it], score.languageScores[fr])
    }

    func testRepeatedCP862EvidenceAndJapaneseArchiveComponents() throws {
        let bytes = Array(repeating: [UInt8(0xA1), UInt8(0xA6)], count: 4_000).flatMap { $0 }
        let results = NameEncodingScorer.allScores(bytes, fromWindows: false, archive: true)
        for name in ["cp932", "cp862"] {
            let i = try XCTUnwrap(NameEncodingCandidates.all.firstIndex { $0.name == name })
            let result = try XCTUnwrap(results.first { $0.candidateIndex == i })
            XCTAssertEqual(result.score, 0)
            for language in NameEncodingCandidates.all[i].languages.indices { XCTAssertEqual(result.languageScores[language], 0) }
        }
        let cover = Array(try XCTUnwrap("表紙.txt".data(using: .shiftJIS)))
        XCTAssertEqual(EncodingDetector.detectArchiveEncoding(names: Array(repeating: cover, count: 200) + [bytes]), .shiftJIS)
    }


    func testEquivalentTablesPreserveIndependentScores() throws {
        let samples = (128...255).map { [UInt8(0x61), UInt8($0), UInt8(0x62)] }
            + [Array(repeating: [UInt8(0xA1), UInt8(0xA6)], count: 30).flatMap { $0 }]
        for bytes in samples {
            for result in NameEncodingScorer.allScores(bytes, fromWindows: false, archive: true) {
                let candidate = NameEncodingCandidates.all[result.candidateIndex]
                guard candidate.form == .single, candidate.name != "windows-1258" else { continue }
                let direct = try XCTUnwrap(NameEncodingScorer.score("", bytes: bytes, candidateIndex: result.candidateIndex,
                    fromWindows: false, requireVietnameseEvidence: false, collectLanguages: true))
                XCTAssertEqual(result.score.bitPattern, direct.score.bitPattern, candidate.name)
                XCTAssertEqual(result.scalarCount, direct.scalarCount)
                for i in candidate.languages.indices { XCTAssertEqual(result.languageScores[i].bitPattern, direct.languageScores[i].bitPattern, candidate.name) }
            }
        }
    }


    func testGreekFinalSigmaAndCapitalStartACompoundComponent() {
        let compound = "ΝίκοςΆννα"
        let separated = "Νίκος Άννα"
        XCTAssertTrue(rules(compound, "el").violations.isEmpty)
        let properties = compound.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
        let spaced = separated.unicodeScalars.map { NameEncodingScorer.traits($0.value) }
        XCTAssertEqual(NameEncodingScorer.letterRules(properties, language: "el"), NameEncodingScorer.letterRules(spaced, language: "el"))
        XCTAssertLessThan(NameEncodingScorer.letterRules(properties), NameEncodingScorer.letterRules(properties, language: "el"))
        XCTAssertTrue(rules("νίκοςάλφα", "el").violations.contains { $0.rule == "el-final-sigma-internal" })
        XCTAssertTrue(rules("άέ", "el").violations.contains { $0.rule == "el-multiple-tonos" })
    }

}
