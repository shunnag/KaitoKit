import Foundation

// 設計書「採点 2〜7」: 復号の証拠と減衰する事前確率を分離し、言語で候補を除外しない。
// 語ごとの字母の規則は NameEncodingScorer+LetterRules.swift、言語ごとの正書法は NameEncodingScorer+NameOrthography.swift、
// 日本語の二候補の決定は JapaneseNameEncodingResolver.swift にある。
enum NameEncodingScorer {
    typealias Candidate = NameEncodingCandidates.Candidate

    /// 採点の調整値。値を変えるときは name-encoding の検証記録の測定をやり直す。
    enum Tuning {
        // 設計書「採点 2」: 区点配置で第1水準・常用域（得点 2）の外にある文字の得点。
        static let secondTierScore = 0.5
        // 小差の Han 候補は言語で一度だけ決め、その後日本語経路へ委ねる（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
        static let hanTieThreshold = 0.4
        // 非 ASCII の証拠が増えるにつれて事前確率の重みを減らす（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
        static let priorWeight = 3.5
        static let languagePriorBonus = 1.0
        // 候補ごとの事前確率。同点時の順位も兼ねる。
        static let priors: [String: Double] = [
            "windows-1252": 1, "cp932": 0.8, "euc-jp": 0.8,
            "windows-1250": 0.6, "windows-1251": 0.6, "gb18030": 0.6,
            "cp950": 0.5, "cp949": 0.5, "cp874": 0.4, "iso-8859-15": 0.4,
            "koi8-u": 0.3, "koi8-r": 0.3, "windows-1253": 0.3, "windows-1254": 0.3,
            "iso-8859-2": 0.3, "windows-1258": 0.3, "cp866": 0.2, "cp850": 0.2,
            "macintosh": 0.2, "windows-1255": 0.2, "windows-1256": 0.2, "windows-1257": 0.2,
            "iso-8859-5": 0.1, "x-mac-centraleurroman": 0.1, "x-mac-cyrillic": 0.1, "big5-hkscs": 0.1,
            "iso-8859-7": 0.2, "cp737": 0.1, "cp869": 0.1, "x-mac-greek": 0.05,
            "iso-8859-9": 0.2, "cp857": 0.1, "x-mac-turkish": 0.05,
            "iso-8859-8": 0.15, "cp862": 0.1, "x-mac-hebrew": 0.05,
            "iso-8859-6": 0.15, "cp864": 0.1, "x-mac-arabic": 0.05, "x-mac-farsi": 0.05,
            "iso-8859-13": 0.15, "iso-8859-4": 0.12, "cp775": 0.1,
            "iso-8859-10": 0.3, "cp437": 0.2, "cp865": 0.15, "x-mac-icelandic": 0.1,
            "iso-8859-16": 0.25, "cp852": 0.15, "x-mac-romanian": 0.05, "x-mac-croatian": 0.05,
            "cp855": 0.15, "x-mac-ukrainian": 0.05, "x-mac-thai": 0.05,
        ]
        /// 採点で読む先頭の scalar 数（1 byte 候補では byte 数）。EncodingDetector の日本語経路の上限と同じ値。
        static let scoringScalarLimit = 256
    }

    struct Result {
        let candidateIndex: Int
        let string: String
        let score: Double
        let hanOnly: Bool
        let scalarCount: Int
        let byteCount: Int
        let languageScores: SIMD16<Double>

        init(candidateIndex: Int, string: String, score: Double, hanOnly: Bool, scalarCount: Int = 1, byteCount: Int = 1,
             languageScores: SIMD16<Double>? = nil) {
            self.candidateIndex = candidateIndex; self.string = string; self.score = score
            self.hanOnly = hanOnly; self.scalarCount = scalarCount; self.byteCount = byteCount
            self.languageScores = languageScores ?? SIMD16(repeating: score)
        }
    }

    struct Exemplars: Sendable {
        let main: [UInt32]
        let auxiliary: [UInt32]
    }
    static let exemplars: [String: Exemplars] = Dictionary(uniqueKeysWithValues:
        LanguageExemplars.allTable.map { ($0.language.replacingOccurrences(of: "_", with: "-"),
                                      Exemplars(main: $0.main, auxiliary: $0.auxiliary)) }
    )

    static func contains(_ scalar: UInt32, ranges: [UInt32]) -> Bool {
        var lower = 0
        var upper = ranges.count / 2
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if scalar < ranges[middle * 2] { upper = middle }
            else if scalar > ranges[middle * 2 + 1] { lower = middle + 1 }
            else { return true }
        }
        return false
    }

    static func language(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let parts = tag.lowercased().split(separator: "-")
        guard let primary = parts.first else { return nil }
        if primary == "zh" {
            if parts.contains("hant") { return "zh-Hant" }
            if parts.contains("hans") { return "zh" }
            return parts.contains("tw") || parts.contains("hk") ? "zh-Hant" : "zh"
        }
        if primary == "sr", parts.contains("latn") { return "sr-Latn" }
        let value = primary == "no" ? "nb" : String(primary)
        return exemplars[value] != nil ? value : nil
    }

    // 設計書「採点 5」: 公知の短い頻出・識別文字リスト。コーパスから集計しない。
    static let frequent: [String: Set<UInt32>] = Dictionary(uniqueKeysWithValues: [
        "ja": "のにるとはをたがでて", "zh": "的一是不了在人有我他", "zh-Hant": "的一是不了在人有我他",
        "ko": "이다의는에가을를지기하고도로한어서스자리아나사대시인수있게라부정상국년일전제주그여소화원요마성동보등", "th": "านรกเอยมลว", "vi": "aăâeêioôơuưyđ",
        "lt": "iaseųėįąčšžū", "lv": "aiesāēīūķļņčšž", "et": "aeiõäöüšž",
        "ro": "eaiăâîșțşţ", "hr": "aeiončćđšž", "sl": "aeiončšž", "sk": "ntsrľĺŕôäčšťž",
        "da": "aerntæøå", "nb": "aerntæøå", "sv": "enrtsäöå", "fi": "itnesäöu",
        "is": "arnistðæö", "nl": "enatirdsëïé", "sr-Latn": "aeiončćđšž",
        "bg": "аеиотнръ", "sr": "аеиоњљћџј", "mk": "аеиоќѓѕџљњј", "be": "аеіоўяьн",
        "he": "יוהאלרמתשנ", "ar": "اليمونرتبة", "fa": "اليمونرتبةیه",
        "uk": "оаинвітеірїєґ", "ru": "оеаинтсрвлыэъёд", "el": "αεοιτνσρη",
        "es": "eaosrnidlctñ¿¡", "pt": "aeosridmntãõç", "fr": "esaitnruloçœ",
        "de": "enisratdhußäöü", "it": "eaionlrtsc", "en": "etaoinshrd",
        "pl": "aioeznrwstłąćęńśźż", "cs": "oeanitsvrlčřěů", "hu": "eatlnskomziőű", "tr": "aeinrlıkduğş",
    ].map { lang, text in
        var values = Set((text + text.uppercased()).unicodeScalars.map(\.value))
        // 設計書「採点 5」: 同じ母音のアクセント違いも扱い、á が ß に一律に負ける誤判定を避ける。
        for entry in LanguageExemplars.allTable where entry.language == lang {
            for i in stride(from: 0, to: entry.main.count, by: 2) where entry.main[i] < 0x250 {
                for value in entry.main[i]...min(entry.main[i + 1], 0x24F) {
                    if let scalar = Unicode.Scalar(value),
                       let base = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first,
                       values.contains(base.value) { values.insert(value) }
                }
            }
        }
        return (lang, values)
    })

    enum Script: UInt8, Sendable, Hashable { case other, latin, cyrillic, greek, thai, han, kana, hangul, hebrew, arabic }
    static func script(_ value: UInt32) -> Script {
        switch value {
        case 0xAA, 0xBA, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFB00...0xFB06: return .latin
        case 0x400...0x52F: return .cyrillic
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0xE00...0xE7F: return .thai
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return .han
        case 0x3040...0x30FF, 0xFF61...0xFF9F: return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3: return .hangul
        case 0x590...0x5FF, 0xFB1D...0xFB4F: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        default: return .other
        }
    }

    struct Traits: Sendable {
        let scalar: UInt32
        let category: Unicode.GeneralCategory
        let mainMask: UInt64
        let auxiliaryMask: UInt64
        let script: Script
        let letter: Bool
        let number: Bool
        let mark: Bool
        let upper: Bool
        let lower: Bool
        let vowel: Bool
        let bad: Bool
        let acute: Bool
        let alphabetFlags: AlphabetFlags
    }
    /// 言語規則が参照する字母の種類。Traits は scalar ごと、LanguageRuleContext は名前全体の和集合を持つ。
    struct AlphabetFlags: OptionSet, Sendable {
        let rawValue: UInt16
        /// セルビア・マケドニアの専用字（southSlavicLetters）。
        static let southSlavic = AlphabetFlags(rawValue: 1 << 0)
        /// 東スラブの専用字（eastSlavicLetters）。
        static let eastSlavic = AlphabetFlags(rawValue: 1 << 1)
        /// ъ / Ъ
        static let hardSign = AlphabetFlags(rawValue: 1 << 2)
        /// щ / Щ
        static let shcha = AlphabetFlags(rawValue: 1 << 3)
        /// ў / Ў
        static let shortU = AlphabetFlags(rawValue: 1 << 4)
        /// þ / Þ
        static let thorn = AlphabetFlags(rawValue: 1 << 5)
        /// ð / Ð
        static let eth = AlphabetFlags(rawValue: 1 << 6)
        /// ý / Ý
        static let yAcute = AlphabetFlags(rawValue: 1 << 7)
        /// й / Й
        static let shortI = AlphabetFlags(rawValue: 1 << 8)
        /// is の正書法規則が見る字。
        static let icelandic: AlphabetFlags = [.thorn, .eth, .yAcute]
    }
    static let vowels = Set("aeiouyæœøıAEIOUYÆŒØаеиоуыэюяёіїєАЕИОУЫЭЮЯЁІЇЄαεηιουωΑΕΗΙΟΥΩ".unicodeScalars.map(\.value))
    // 言語名の解決は一度だけ。BMP の所属マスクは候補をまたいで共有する（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    static let exemplarLanguages = exemplars.keys.sorted()
    static let exemplarSets = exemplarLanguages.map { exemplars[$0]! }
    static let basicTraits: [Traits] = (0...0xFFFF).map { makeTraits(UInt32($0)) }
    static func traits(_ value: UInt32) -> Traits {
        value <= 0xFFFF ? basicTraits[Int(value)] : makeTraits(value)
    }
    private static func makeTraits(_ value: UInt32) -> Traits {
        if (0xD800...0xDFFF).contains(value) {
            return Traits(scalar: value, category: .surrogate, mainMask: 0, auxiliaryMask: 0, script: .other, letter: false, number: false, mark: false, upper: false, lower: false, vowel: false, bad: true, acute: false, alphabetFlags: [])
        }
        let scalar = Unicode.Scalar(value)!
        let p = scalar.properties
        let category = p.generalCategory
        let bad = category == .control || category == .privateUse || category == .unassigned || category == .surrogate
        let letter = category == .uppercaseLetter || category == .lowercaseLetter || category == .titlecaseLetter || category == .otherLetter || category == .modifierLetter
        var vowel = vowels.contains(value)
        if !vowel, script(value) == .latin || script(value) == .greek {
            if let base = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first {
                vowel = vowels.contains(base.value)
            }
        }
        let number = category == .decimalNumber
        let mark = category == .nonspacingMark || category == .spacingMark || category == .enclosingMark
        var mainMask: UInt64 = 0
        var auxiliaryMask: UInt64 = 0
        for (i, set) in exemplarSets.enumerated() {
            // legacy の互換綴りと es / pt の序数標識は CLDR main と同じ所属にする。
            let compatible = exemplarLanguages[i] == "fa" && [UInt32(0x64A), 0x643].contains(value)
                || exemplarLanguages[i] == "ro" && [UInt32(0x15E), 0x15F, 0x162, 0x163].contains(value)
                || (exemplarLanguages[i] == "es" || exemplarLanguages[i] == "pt") && (value == 0xAA || value == 0xBA)
            if compatible || contains(value, ranges: set.main) { mainMask |= 1 << i }
            if contains(value, ranges: set.auxiliary) { auxiliaryMask |= 1 << i }
        }
        return Traits(scalar: value, category: category, mainMask: mainMask, auxiliaryMask: auxiliaryMask, script: script(value), letter: letter, number: number, mark: mark,
                      upper: p.isUppercase, lower: p.isLowercase, vowel: vowel, bad: bad,
                      acute: acuteVowels.contains(value),
                      alphabetFlags: alphabetFlags(value))
    }
    private static func alphabetFlags(_ value: UInt32) -> AlphabetFlags {
        var flags: AlphabetFlags = []
        if southSlavicLetters.contains(value) { flags.insert(.southSlavic) }
        if eastSlavicLetters.contains(value) { flags.insert(.eastSlavic) }
        switch value {
        case 0x44A, 0x42A: flags.insert(.hardSign)
        case 0x449, 0x429: flags.insert(.shcha)
        case 0x45E, 0x40E: flags.insert(.shortU)
        case 0xFE, 0xDE: flags.insert(.thorn)
        case 0xF0, 0xD0: flags.insert(.eth)
        case 0xFD, 0xDD: flags.insert(.yAcute)
        case 0x439, 0x419: flags.insert(.shortI)
        default: break
        }
        return flags
    }
    // 設計書「性能」: 1 byte 候補の文字属性も初期化時に確定し、名前ごとの Unicode 問合せを避ける。
    static let byteTraits: [[[Traits]?]] = NameEncodingCandidates.all.map { candidate in
        candidate.singleByteTable.map { $0?.map { traits($0) } }
    }

    static let singleByteTraits: [[Traits]] = byteTraits.map { entries in
        entries.map { $0?.first ?? basicTraits[0] }
    }

    // byte 数と、1対1復号で不変の反復区間は候補をまたいで一度だけ調べる（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    struct ByteEvidence {
        let count: Int
        let present: SIMD4<UInt64>
        let repeated: [Bool]
        let possibleLongWord: Bool
        init(_ bytes: [UInt8]) {
            var count = 0
            var present = SIMD4<UInt64>.zero
            for byte in bytes {
                if byte >= 128 { count += 1 }
                present[Int(byte) / 64] |= UInt64(1) << (Int(byte) % 64)
            }
            self.count = count
            self.present = present
            repeated = repeatedMask(Array(bytes.prefix(Tuning.scoringScalarLimit)))
            var run = 0
            var longest = 0
            for byte in bytes.prefix(Tuning.scoringScalarLimit) {
                if byte >= 128 || (65...90).contains(byte) || (97...122).contains(byte) { run += 1; longest = max(longest, run) }
                else { run = 0 }
            }
            possibleLongWord = longest > 40
        }
    }
    static let oneToOneTables = NameEncodingCandidates.all.map { candidate in
        let entries = candidate.singleByteTable.compactMap { $0 }
        return entries.allSatisfy { $0.count == 1 } && Set(entries.compactMap(\.first)).count == entries.count
    }

    struct EquivalentTable: Sendable {
        let candidateIndex: Int
        let differences: SIMD4<UInt64>
    }
    // 同じ言語集合・同じ復号 scalar 列には同じ証拠を与える。候補間の表の差を一度だけ求め、
    // その差に入力 byte が触れない場合だけ計算を共有する。prior と厳密復号の成否は共有しない。
    static let equivalentTables: [[EquivalentTable]] = NameEncodingCandidates.all.enumerated().map { index, candidate in
        guard candidate.form == .single, candidate.name != "windows-1258" else { return [] }
        return (0..<index).compactMap { previous in
            let other = NameEncodingCandidates.all[previous]
            guard other.form == .single, other.languages == candidate.languages else { return nil }
            var differences = SIMD4<UInt64>.zero
            for byte in 0..<256 where other.singleByteTable[byte] != candidate.singleByteTable[byte] {
                differences[byte / 64] |= UInt64(1) << (byte % 64)
            }
            return EquivalentTable(candidateIndex: previous, differences: differences)
        }
    }

    static func allScores(_ bytes: [UInt8], fromWindows: Bool, includeHKSCS: Bool = false, archive: Bool = false) -> [Result] {
        var results: [Result] = []
        results.reserveCapacity(NameEncodingCandidates.all.count)
        // SIMD16 と文字列を候補ごとに二重保持せず、共有元は結果配列の添字で参照する。
        var byCandidate = [Int](repeating: -1, count: NameEncodingCandidates.all.count)
        var nonBMP: [UInt32: Traits] = [:]
        let byteEvidence = ByteEvidence(bytes)
        var cp950Decoded = false
        for index in NameEncodingCandidates.all.indices {
            let candidate = NameEncodingCandidates.all[index]
            if candidate.name == "big5-hkscs", cp950Decoded, !includeHKSCS { continue }
            // 256 bit の存在集合と未定義集合の交差で、復号・採点より先に候補を落とす。
            if candidate.form == .single, (candidate.undefinedBytes & byteEvidence.present) != .zero { continue }
            let text: String
            if archive, candidate.form == .single, candidate.name != "windows-1258" {
                // 書庫集計では採点に使わない文字列を生成せず、全 byte の厳密性と表引きだけを行う。
                text = ""
            } else {
                guard let decoded = candidate.decode(bytes) else { continue }
                text = decoded
            }
            if candidate.name == "cp950" { cp950Decoded = true }
            if let previous = equivalentTables[index].first(where: {
                ($0.differences & byteEvidence.present) == .zero && byCandidate[$0.candidateIndex] >= 0
            }) {
                let same = results[byCandidate[previous.candidateIndex]]
                let result = Result(candidateIndex: index, string: text, score: same.score,
                                    hanOnly: same.hanOnly, scalarCount: same.scalarCount, byteCount: same.byteCount,
                                    languageScores: same.languageScores)
                results.append(result)
                byCandidate[index] = results.count - 1
                continue
            }
            if let result = score(text, bytes: bytes, candidateIndex: index, fromWindows: fromWindows, requireVietnameseEvidence: !archive, nonBMP: &nonBMP, byteEvidence: byteEvidence, collectLanguages: archive) {
                results.append(result)
                byCandidate[index] = results.count - 1
            }
        }
        return results
    }

    struct LanguageData: Sendable {
        let masks: [UInt64]
        let unionMask: UInt64
        let scripts: Set<Script>
        let bonuses: [Set<UInt32>]
        let additionalRules: [Bool]
        let requiresLanguageRules: Bool
        let western: Bool
        let thai: Bool
        let greek: Bool
        init(_ languages: [String]) {
            // 言語名の比較と規則の有無は、名前ごとの hot loop より前に確定する。
            additionalRules = languages.map { ["fr", "is", "el", "he", "ar", "fa", "ru", "uk", "be", "bg", "sr", "mk"].contains($0) }
            requiresLanguageRules = languages.contains { ["he", "ar", "ru", "is", "el", "fr"].contains($0) }
            western = languages.contains("it")
            thai = languages.contains("th")
            greek = languages.contains("el")
            masks = languages.map { language in
                exemplarLanguages.firstIndex(of: language).map { UInt64(1) << $0 } ?? 0
            }
            unionMask = masks.reduce(0, |)
            scripts = Set(languages.flatMap { language -> [Script] in
                switch language {
                case "ja": return [.han, .kana]
                case "zh", "zh-Hant": return [.han]
                case "ko": return [.hangul, .han]
                case "ru", "uk", "bg", "sr", "mk", "be": return [.cyrillic]
                case "th": return [.thai]
                case "el": return [.greek]
                case "he": return [.hebrew]
                case "ar", "fa": return [.arabic]
                default: return [.latin]
                }
            })
            bonuses = languages.map { frequent[$0] ?? [] }
        }
    }
    static let languageData = NameEncodingCandidates.all.map { LanguageData($0.languages) }
    static let hanLanguageData = LanguageData(["ja", "zh", "zh-Hant"])
    struct ScalarScore: Sendable {
        let values: SIMD16<Int16>
        let bonuses: SIMD16<Int16>
        let count: Int
        var value: Double { Double((0..<count).reduce(Int16.min) { max($0, values[$1]) }) / 2 }
    }
    static func scalarScore(_ p: Traits, language: LanguageData) -> ScalarScore {
        func uniform(_ value: Double) -> ScalarScore {
            ScalarScore(values: SIMD16(repeating: Int16(value * 2)), bonuses: .zero, count: language.masks.count)
        }
        if p.scalar < 128 { return uniform(0) }
        if p.bad { return uniform(-4) }
        if p.number { return uniform(0.5) }
        if p.scalar == 0xE03 || p.scalar == 0xE05 { return uniform(-2) }
        // 記号・修飾文字の値は位置規則に任せ、文字集合や頻度と重ねない（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
        if !p.letter && !p.mark || p.category == .modifierLetter { return uniform(0) }
        let union = (p.mainMask | p.auxiliaryMask) & language.unionMask != 0
        var values = SIMD16<Int16>.zero
        var bonuses = SIMD16<Int16>.zero
        for (i, mask) in language.masks.enumerated() {
            if p.mainMask & mask != 0 { values[i] = 4 }
            else if p.auxiliaryMask & mask != 0 { values[i] = 2 }
            else if union { values[i] = 1 }
            else { values[i] = language.scripts.contains(p.script) ? -2 : -4 }
            bonuses[i] = language.bonuses[i].contains(p.scalar) ? 1 : 0
        }
        return ScalarScore(values: values, bonuses: bonuses, count: language.masks.count)
    }
    static let expandingBytes: [SIMD4<UInt64>] = NameEncodingCandidates.all.map { candidate in
        var mask = SIMD4<UInt64>.zero
        for (byte, entry) in candidate.singleByteTable.enumerated() where entry != nil && entry?.count != 1 {
            mask[byte / 64] |= UInt64(1) << (byte % 64)
        }
        return mask
    }
    static let byteScores: [[[ScalarScore]?]] = byteTraits.enumerated().map { index, entries in
        entries.map { $0?.map { scalarScore($0, language: languageData[index]) } }
    }

    // 1 scalar 表は平坦化し、hot loop で Optional 配列の保持・解放を繰り返さない。
    static let singleByteScores: [[ScalarScore]] = byteScores.enumerated().map { index, entries in
        entries.map { $0?.first ?? ScalarScore(values: .zero, bonuses: .zero, count: languageData[index].masks.count) }
    }

    static func score(_ text: String, bytes: [UInt8], candidateIndex: Int, fromWindows: Bool, requireVietnameseEvidence: Bool = true, collectLanguages: Bool = false) -> Result? {
        var nonBMP: [UInt32: Traits] = [:]
        return score(text, bytes: bytes, candidateIndex: candidateIndex, fromWindows: fromWindows,
                     requireVietnameseEvidence: requireVietnameseEvidence, nonBMP: &nonBMP, byteEvidence: ByteEvidence(bytes), collectLanguages: collectLanguages)
    }

    private static func score(_ text: String, bytes: [UInt8], candidateIndex: Int, fromWindows: Bool,
                              requireVietnameseEvidence: Bool, nonBMP: inout [UInt32: Traits], byteEvidence: ByteEvidence, collectLanguages: Bool) -> Result? {
        let candidate = NameEncodingCandidates.all[candidateIndex]
        let candidateLanguage = languageData[candidateIndex]
        let vietnamese = candidate.name == "windows-1258"
        if vietnamese, requireVietnameseEvidence, !vietnameseEvidence(text) { return nil }
        // 採点だけ NFC、呼出側へ返す scalar 列は保存する（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
        let scoringText = vietnamese ? String(text.unicodeScalars.prefix(Tuning.scoringScalarLimit)).precomposedStringWithCanonicalMapping : text
        let single = candidate.form == .single && !vietnamese
        // 表に展開文字があっても、入力がその byte を含まなければ平坦な表を使える。
        let singleScalar = (expandingBytes[candidateIndex] & byteEvidence.present) == .zero
        let properties: [Traits]
        if single {
            if singleScalar {
                let table = singleByteTraits[candidateIndex]
                properties = bytes.prefix(Tuning.scoringScalarLimit).map { table[Int($0)] }
            } else {
                properties = Array(bytes.prefix(Tuning.scoringScalarLimit).flatMap { byteTraits[candidateIndex][Int($0)] ?? [] }
                    .prefix(Tuning.scoringScalarLimit))
            }
        } else {
            properties = scoringText.unicodeScalars.prefix(Tuning.scoringScalarLimit).map { scalar in
                if scalar.value <= 0xFFFF { return basicTraits[Int(scalar.value)] }
                if let cached = nonBMP[scalar.value] { return cached }
                let value = makeTraits(scalar.value)
                nonBMP[scalar.value] = value
                return value
            }
        }
        let zones = candidate.isCJK ? candidate.zones(bytes) : []
        let cachedScores = single ? singleByteScores[candidateIndex] : []
        // 0.5刻みを2倍整数化。256 scalar の各成分は −2048〜1024 に収まり Int16 を超えない。
        var bonuses = SIMD16<Int16>.zero
        var totals = SIMD16<Int16>.zero
        var total = 0.0
        var count = 0
        let repeated = single && oneToOneTables[candidateIndex] ? byteEvidence.repeated : repeatedScalars(properties)
        let ruleProperties = repeated.contains(true) ? properties.enumerated().map { repeated[$0.offset] ? basicTraits[32] : $0.element } : properties
        let ruleText = repeated.contains(true) ? String(String.UnicodeScalarView(ruleProperties.map { Unicode.Scalar($0.scalar)! })) : scoringText
        let excessive = byteEvidence.possibleLongWord || properties.contains(where: { $0.script == .thai }) ? excessiveLetters(ruleProperties) : []
        var rules = LetterRuleState(skipLatinDensity: vietnamese, greek: candidateLanguage.greek)
        var hanOnly = true
        var sawHan = false
        let halfWidth = candidate.isJapanese && properties.contains { (0xFF61...0xFF9F).contains($0.scalar) }
            && JapaneseNameEncodingResolver.isLikelyHalfWidthName(text)
        let scores: [ScalarScore]
        if single, !singleScalar {
            scores = Array(bytes.prefix(Tuning.scoringScalarLimit).flatMap { byteScores[candidateIndex][Int($0)] ?? [] }
                .prefix(Tuning.scoringScalarLimit))
        } else { scores = [] }
        for (offset, p) in properties.enumerated() {
            let value = p.scalar
            // 語の状態も同じ走査で更新し、反復区間は空白として境界を切る。
            let ruleProperty = ruleProperties[offset]
            if (0x2500...0x25FF).contains(ruleProperty.scalar), !cjkGeometricNotation(ruleProperties, at: offset) { rules.penalty -= 3 }
            rules.append(ruleProperty)
            if repeated[offset] { if value > 127 { count += 1 }; continue }
            if p.letter, value > 127 {
                if p.script == .han { sawHan = true } else { hanOnly = false }
            }
            guard value > 127 else {
                total += symbolScore(ruleProperties, at: offset) ?? 0
                continue
            }
            count += 1
            if (0xFF61...0xFF9F).contains(value), candidate.isJapanese {
                total += halfWidth ? 3 : 0
                continue
            }
            let contribution: ScalarScore
            if single, singleScalar {
                contribution = cachedScores[Int(bytes[offset])]
            } else if single { contribution = scores[offset] }
            else {
                let language = candidate.form == .cp949 && p.script == .han ? hanLanguageData : languageData[candidateIndex]
                contribution = scalarScore(p, language: language)
            }
            let tooLong = offset < excessive.count && excessive[offset]
            var fixed: Double? = symbolScore(ruleProperties, at: offset)
            if tooLong { fixed = -2 }
            if candidate.isCJK, offset < zones.count, !p.bad {
                if p.script == .han, p.letter {
                    // 設計書「採点 2」: 漢字の集合と区分類は同じ文字の妥当性を測る（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
                    // 二つの尺度を平均し、全音節を含むハングル main の二重加点も避ける。
                    // Han は開いた集合で、CLDR の代表字外にも人名・地名の正字があるため所属の下限は +0.5。
                    fixed = zones[offset].vendorIdeograph ? zones[offset].score : (zones[offset].score + max(0.5, contribution.value)) / 2
                } else if (0xAC00...0xD7A3).contains(value), candidate.form == .cp949 {
                    fixed = zones[offset].score
                } else if p.script == .hangul, candidate.form == .cp949 { fixed = 0.5 }
                else if p.script == .kana, value < 0xFF00, p.letter {
                    // 長音符・繰り返し記号は一般の修飾文字と異なり、かなの直後では語の音形を表す。
                    if p.category != .modifierLetter || offset > 0 && properties[offset - 1].script == .kana && properties[offset - 1].letter { fixed = 3 }
                }
            }
            if let fixed { total += fixed }
            else {
                totals &+= contribution.values
            }
            if offset < zones.count { total += zones[offset].latinIntrusion }
            total += latinStressEvidence(ruleProperties, at: offset)
            // ハングル main は重ねず、公知の頻出音節だけを他言語と同じ頻度証拠にする（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
            if !tooLong {
                bonuses &+= contribution.bonuses
            }
        }
        let membership = Double((0..<candidate.languages.count).reduce(Int16.min) { max($0, totals[$1]) }) / 2
        let frequency = Double(bonuses.max()) / 2
        total += membership + frequency
        rules.finish()
        var value = total / Double(max(1, count)) + rules.penalty
        let western = properties.contains(where: { $0.script == .latin && $0.scalar > 127 }) ? westernEvidence(ruleProperties) : .zero
        value += western.sum()
        if candidateLanguage.thai {
            value += orthography(ruleProperties.map(\.scalar), language: "th").boundedScore(scalarCount: count)
            value += thaiDistribution(ruleProperties).score
        }
        // 頻度と同じ正の証拠として平均し、助詞に見える偶然の語末一つで文字全体の証拠を覆さない。
        if candidate.form == .cp949 { value += koreanGrammar(ruleProperties) / Double(max(1, count)) }
        if vietnamese { value += orthography(ruleText, language: "vi", maximumScalars: Tuning.scoringScalarLimit).boundedScore(scalarCount: count) }
        var languageScores = SIMD16<Double>(repeating: value)
        let common = value - (membership + frequency) / Double(max(1, count))
        let languageRules = candidateLanguage.requiresLanguageRules
        if collectLanguages && candidate.languages.count > 1 || languageRules {
            // 最良言語を決める前に、所属・頻度・正書法を同じ言語の成分へ合算する。
            for i in candidate.languages.indices {
                let language = candidate.languages[i]
                var adjustment = candidateLanguage.additionalRules[i]
                    ? additionalOrthography(ruleProperties, language: language, context: rules.context, recordViolations: false).score : 0
                if language == "bg", rules.context.flags.contains(.hardSign) {
                    adjustment += letterRules(ruleProperties, language: "bg") - rules.penalty
                }
                languageScores[i] = common + (Double(totals[i]) + Double(bonuses[i])) / (2 * Double(max(1, count))) + adjustment
            }
            if languageRules { value = candidate.languages.indices.reduce(-Double.infinity) { max($0, languageScores[$1]) } }
        }
        return Result(candidateIndex: candidateIndex, string: text, score: value,
                      hanOnly: sawHan && hanOnly, scalarCount: count, byteCount: byteEvidence.count, languageScores: languageScores)
    }

    // 1〜3 scalar の20回以上の反復は言語的証拠を持たず、区間外だけを通常採点する（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    static func repeatedScalars(_ properties: [Traits]) -> [Bool] {
        if properties.count < 20 { return [Bool](repeating: false, count: properties.count) }
        return repeatedMask(properties.map(\.scalar))
    }
    private static func repeatedMask<T: Equatable>(_ properties: [T]) -> [Bool] {
        var repeated = [Bool](repeating: false, count: properties.count)
        for period in 1...3 {
            var start = 0
            while start + period * 20 <= properties.count {
                var end = start + period
                while end < properties.count, properties[end] == properties[end - period] { end += 1 }
                if end - start >= period * 20 {
                    for i in start..<end { repeated[i] = true }
                    start = end
                } else { start += max(1, end - start - period) }
            }
        }
        return repeated
    }

    static func alphabetic(_ script: Script) -> Bool {
        script == .latin || script == .cyrillic || script == .greek
    }

    private static func symbolAlphabet(_ script: Script) -> Bool {
        alphabetic(script) || script == .hebrew || script == .arabic
    }

    // 開き引用符・分離アクセント・演算記号を一般カテゴリと隣接文字で区別する（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    static func symbolScore(_ properties: [Traits], at offset: Int) -> Double? {
        let p = properties[offset]
        // 通常の文字と句読点は隣接 scalar を読む前に確定する。
        if p.scalar < 128 {
            switch p.scalar {
            case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x60, 0x7E, 0x5E, 0x7C, 0x5C, 0x2B, 0x3D, 0x3C, 0x3E, 0x24, 0x25, 0x26, 0x40, 0x23, 0x2A: break
            default: return nil
            }
        } else {
            switch p.category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return nil
            case .modifierLetter, .otherNumber: return 0
            case .openPunctuation, .closePunctuation: break
            case .initialPunctuation, .finalPunctuation,
                 .otherPunctuation, .dashPunctuation, .connectorPunctuation:
                if p.scalar != 0x201A && p.scalar != 0x201E { return 0 }
            default: break
            }
        }

        let left = offset > 0 ? properties[offset - 1] : nil
        let right = offset + 1 < properties.count ? properties[offset + 1] : nil
        let beside = left?.letter == true || right?.letter == true
        let between = left?.letter == true && right?.letter == true
        // 括弧は両側が字母の位置だけを減点し、通常の括弧付き副題は許す。
        if between, p.category == .openPunctuation || p.category == .closePunctuation { return -2 }
        // ASCII の circumflex も分離した修飾記号。語頭でも字母の隣なら Sk の −5 を適用する。
        // backtick の既存の引用・区切り扱いとは区別し、数式の 2^3 は減点しない。
        if p.scalar == 0x5E { return beside ? -5 : 0 }
        if p.scalar < 128 {
            if between, let left, let right,
               symbolAlphabet(left.script), symbolAlphabet(right.script), left.scalar > 127 || right.scalar > 127 { return -2 }
            return nil
        }
        switch p.category {
        case .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .dashPunctuation, .connectorPunctuation:
            return (p.scalar == 0x201A || p.scalar == 0x201E) && left?.letter == true ? -2 : 0
        case .modifierSymbol:
            if p.scalar == 0xB4, between { return 0 }
            return beside ? -5 : 0
        case .currencySymbol, .mathSymbol, .otherSymbol:
            // 罫線は letterRules の −3 / 文字で扱う。日本語の「彼×彼女」は通常の結合表記。
            if (0x2500...0x25FF).contains(p.scalar) { return 0 }
            if between, let left, let right, symbolAlphabet(left.script), symbolAlphabet(right.script) { return -2 }
            return 0
        case .otherNumber, .modifierLetter: return 0
        default: return nil
        }
    }

    // 分かち書きする文字体系の語長と、タイ文字の無母音 run を別に扱う（Documentation/verification/2026-09-14-name-encoding-multilingual.md）。
    static func excessiveLetters(_ properties: [Traits]) -> [Bool] {
        var result = [Bool](repeating: false, count: properties.count)
        var alphabetLength = 0
        var thaiStart = 0
        var thaiHasVowel = false
        func finishThai(_ end: Int) {
            if !thaiHasVowel, end - thaiStart > 12 {
                for i in (thaiStart + 12)..<end where properties[i].letter { result[i] = true }
            }
        }
        for (i, p) in properties.enumerated() {
            if p.letter, alphabetic(p.script) {
                alphabetLength += 1
                if alphabetLength > 40, p.scalar > 127 { result[i] = true }
            } else if !p.mark { alphabetLength = 0 }
            if p.script == .thai {
                if i == 0 || properties[i - 1].script != .thai { thaiStart = i; thaiHasVowel = false }
                if (0xE30...0xE3A).contains(p.scalar) || (0xE40...0xE44).contains(p.scalar) || (0xE47...0xE4E).contains(p.scalar) { thaiHasVowel = true }
            } else if i > 0, properties[i - 1].script == .thai { finishThai(i) }
        }
        if properties.last?.script == .thai { finishThai(properties.count) }
        return result
    }

    // 日本語の伏字・選択記号は「第○話」「と○○と」のように和文の間に置く。
    // 罫線・ブロックはこの記法に含めず、幾何図形だけを CJK の位置規則で扱う。
    static func cjkGeometricNotation(_ properties: [Traits], at offset: Int) -> Bool {
        guard (0x25A0...0x25FF).contains(properties[offset].scalar) else { return false }
        var left = offset
        var right = offset
        while left > 0, (0x25A0...0x25FF).contains(properties[left - 1].scalar) { left -= 1 }
        while right + 1 < properties.count, (0x25A0...0x25FF).contains(properties[right + 1].scalar) { right += 1 }
        func cjkLetter(_ p: Traits) -> Bool { p.letter && (p.script == .han || p.script == .kana || p.script == .hangul) }
        return left > 0 && right + 1 < properties.count && cjkLetter(properties[left - 1]) && cjkLetter(properties[right + 1])
    }

    static func prior(for candidate: Candidate) -> Double {
        // 候補を追加するときは family 内の順序を明示し、種別だけの既定値で同点にしない。
        Tuning.priors[candidate.name]!
    }
    static func ranked(_ results: [Result], likelyLanguage: String?, fromWindows: Bool = false) -> [Result] {
        let lang = language(likelyLanguage)
        let adjusted = results.map { result in
            let candidate = NameEncodingCandidates.all[result.candidateIndex]
            var prior = prior(for: candidate)
            if let lang, candidate.languages.contains(lang) { prior += Tuning.languagePriorBonus }
            if fromWindows, candidate.isMac { prior -= 0.3 }
            let n = Double(result.byteCount)
            return Result(candidateIndex: result.candidateIndex, string: result.string,
                          score: (n * result.score + Tuning.priorWeight * prior) / (n + Tuning.priorWeight),
                          hanOnly: result.hanOnly, scalarCount: result.scalarCount, byteCount: result.byteCount)
        }
        var sorted = adjusted.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            let ca = NameEncodingCandidates.all[a.candidateIndex]
            let cb = NameEncodingCandidates.all[b.candidateIndex]
            if let lang, ca.languages.contains(lang) != cb.languages.contains(lang) { return ca.languages.contains(lang) }
            return a.candidateIndex < b.candidateIndex
        }
        if let top = sorted.first, top.hanOnly, let lang, ["ja", "zh", "zh-Hant"].contains(lang),
           let preferred = sorted.firstIndex(where: {
               $0.hanOnly && top.score - $0.score < Tuning.hanTieThreshold && NameEncodingCandidates.all[$0.candidateIndex].languages.contains(lang)
           }), preferred > 0 {
            let chosen = sorted.remove(at: preferred)
            sorted.insert(chosen, at: 0)
        }
        return sorted
    }
    static func confidence(_ ranked: [Result]) -> Double {
        guard let first = ranked.first else { return 0.2 }
        guard ranked.count > 1 else { return 0.95 }
        return 0.5 + 0.45 * min(1, max(0, first.score - ranked[1].score))
    }
}
