import Foundation

// 設計書「採点 2〜7」: 復号の証拠と減衰する事前確率を分離し、言語で候補を除外しない。
enum NameEncodingScorer {
    typealias Candidate = NameEncodingCandidates.Candidate
    struct Result {
        let candidateIndex: Int
        let string: String
        let score: Double
        let hanOnly: Bool
        let scalarCount: Int
        let byteCount: Int
        let languageScores: SIMD8<Double>

        init(candidateIndex: Int, string: String, score: Double, hanOnly: Bool, scalarCount: Int = 1, byteCount: Int = 1,
             languageScores: SIMD8<Double>? = nil) {
            self.candidateIndex = candidateIndex; self.string = string; self.score = score
            self.hanOnly = hanOnly; self.scalarCount = scalarCount; self.byteCount = byteCount
            self.languageScores = languageScores ?? SIMD8(repeating: score)
        }
    }

    struct Exemplars: Sendable {
        let main: [UInt32]
        let auxiliary: [UInt32]
    }
    static let exemplars: [String: Exemplars] = Dictionary(uniqueKeysWithValues:
        LanguageExemplars.table.map { ($0.language.replacingOccurrences(of: "_", with: "-"),
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
        let value = String(primary)
        return ["ja", "ko", "th", "vi", "uk", "ru", "el", "tr", "es", "pt", "fr", "de", "it", "pl", "cs", "hu", "en"].contains(value) ? value : nil
    }

    // 設計書「採点 5」: 公知の短い頻出・識別文字リスト。コーパスから集計しない。
    static let frequent: [String: Set<UInt32>] = Dictionary(uniqueKeysWithValues: [
        "ja": "のにるとはをたがでて", "zh": "的一是不了在人有我他", "zh-Hant": "的一是不了在人有我他",
        "ko": "이다의는에가을를지기하고도로한어서스자리아나사대시인수있게라부정상국년일전제주그여소화원요마성동보등", "th": "านรกเอยมลว", "vi": "aăâeêioôơuưyđ",
        "uk": "оаинвітеірїєґ", "ru": "оеаинтсрвлыэъё", "el": "αεοιτνσρη",
        "es": "eaosrnidlctñ¿¡", "pt": "aeosridmntãõç", "fr": "esaitnruloçœ",
        "de": "enisratdhußäöü", "it": "eaionlrtsc", "en": "etaoinshrd",
        "pl": "aioeznrwstłąćęńśźż", "cs": "oeanitsvrlčřěů", "hu": "eatlnskomziőű", "tr": "aeinrlıkduğş",
    ].map { lang, text in
        var values = Set((text + text.uppercased()).unicodeScalars.map(\.value))
        // 設計書「採点 5」: 同じ母音のアクセント違いも扱い、á が ß に一律に負ける誤判定を避ける。
        for entry in LanguageExemplars.table where entry.language == lang {
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
        case 0xAA, 0xBA, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x400...0x52F: return .cyrillic
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0xE00...0xE7F: return .thai
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return .han
        case 0x3040...0x30FF, 0xFF61...0xFF9F: return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7A3: return .hangul
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF: return .arabic
        default: return .other
        }
    }

    struct Traits: Sendable {
        let scalar: UInt32
        let category: Unicode.GeneralCategory
        let mainMask: UInt32
        let auxiliaryMask: UInt32
        let script: Script
        let letter: Bool
        let number: Bool
        let mark: Bool
        let upper: Bool
        let lower: Bool
        let vowel: Bool
        let bad: Bool
        let acute: Bool
        let cyrillicAlphabet: UInt8
    }
    static let vowels = Set("aeiouyæœøıAEIOUYÆŒØаеиоуыэюяёіїєАЕИОУЫЭЮЯЁІЇЄαεηιουωΑΕΗΙΟΥΩ".unicodeScalars.map(\.value))
    // 第4回レビュー E2: 言語名の解決は一度だけ。BMP の所属マスクは候補をまたいで共有する。
    static let exemplarLanguages = exemplars.keys.sorted()
    static let exemplarSets = exemplarLanguages.map { exemplars[$0]! }
    static let basicTraits: [Traits] = (0...0xFFFF).map { makeTraits(UInt32($0)) }
    static func traits(_ value: UInt32) -> Traits {
        value <= 0xFFFF ? basicTraits[Int(value)] : makeTraits(value)
    }
    private static func makeTraits(_ value: UInt32) -> Traits {
        if (0xD800...0xDFFF).contains(value) {
            return Traits(scalar: value, category: .surrogate, mainMask: 0, auxiliaryMask: 0, script: .other, letter: false, number: false, mark: false, upper: false, lower: false, vowel: false, bad: true, acute: false, cyrillicAlphabet: 0)
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
        var mainMask: UInt32 = 0
        var auxiliaryMask: UInt32 = 0
        for (i, set) in exemplarSets.enumerated() {
            if contains(value, ranges: set.main) { mainMask |= 1 << i }
            if contains(value, ranges: set.auxiliary) { auxiliaryMask |= 1 << i }
        }
        return Traits(scalar: value, category: category, mainMask: mainMask, auxiliaryMask: auxiliaryMask, script: script(value), letter: letter, number: number, mark: mark,
                      upper: p.isUppercase, lower: p.isLowercase, vowel: vowel, bad: bad,
                      acute: acuteVowels.contains(value),
                      cyrillicAlphabet: (southSlavicLetters.contains(value) ? 1 : 0) | (eastSlavicLetters.contains(value) ? 2 : 0))
    }
    // 設計書「性能」: 1 byte 候補の文字属性も初期化時に確定し、名前ごとの Unicode 問合せを避ける。
    static let byteTraits: [[[Traits]?]] = NameEncodingCandidates.all.map { candidate in
        candidate.singleByteTable.map { $0?.map { traits($0) } }
    }

    static let singleByteTraits: [[Traits]] = byteTraits.map { entries in
        entries.map { $0?.first ?? basicTraits[0] }
    }

    // 第4回レビュー A、E2: byte 数と、1対1復号で不変の反復区間は候補をまたいで一度だけ調べる。
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
            repeated = repeatedMask(Array(bytes.prefix(256)))
            var run = 0
            var longest = 0
            for byte in bytes.prefix(256) {
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
        var byCandidate = [Result?](repeating: nil, count: NameEncodingCandidates.all.count)
        var nonBMP: [UInt32: Traits] = [:]
        let byteEvidence = ByteEvidence(bytes)
        var cp950Decoded = false
        for index in NameEncodingCandidates.all.indices {
            let candidate = NameEncodingCandidates.all[index]
            if candidate.name == "big5-hkscs", cp950Decoded, !includeHKSCS { continue }
            let text: String
            if archive, candidate.form == .single, candidate.name != "windows-1258", candidate.name != "cp874" {
                guard candidate.structurallyValid(bytes) else { continue }
                // 書庫集計では採点に使わない文字列を生成せず、全 byte の厳密性と表引きだけを行う。
                text = ""
            } else {
                guard let decoded = candidate.decode(bytes) else { continue }
                text = decoded
            }
            if candidate.name == "cp950" { cp950Decoded = true }
            if let previous = equivalentTables[index].first(where: {
                ($0.differences & byteEvidence.present) == .zero && byCandidate[$0.candidateIndex] != nil
            }), let same = byCandidate[previous.candidateIndex] {
                let result = Result(candidateIndex: index, string: text, score: same.score,
                                    hanOnly: same.hanOnly, scalarCount: same.scalarCount, byteCount: same.byteCount,
                                    languageScores: same.languageScores)
                results.append(result)
                byCandidate[index] = result
                continue
            }
            if let result = score(text, bytes: bytes, candidateIndex: index, fromWindows: fromWindows, requireVietnameseEvidence: !archive, nonBMP: &nonBMP, byteEvidence: byteEvidence, collectLanguages: archive) {
                results.append(result)
                byCandidate[index] = result
            }
        }
        return results
    }

    struct LanguageData: Sendable {
        let masks: [UInt32]
        let unionMask: UInt32
        let scripts: Set<Script>
        let bonuses: [Set<UInt32>]
        init(_ languages: [String]) {
            masks = languages.map { language in
                exemplarLanguages.firstIndex(of: language).map { UInt32(1) << $0 } ?? 0
            }
            unionMask = masks.reduce(0, |)
            scripts = Set(languages.flatMap { language -> [Script] in
                switch language {
                case "ja": return [.han, .kana]
                case "zh", "zh-Hant": return [.han]
                case "ko": return [.hangul, .han]
                case "ru", "uk": return [.cyrillic]
                case "th": return [.thai]
                case "el": return [.greek]
                case "he": return [.hebrew]
                case "ar": return [.arabic]
                default: return [.latin]
                }
            })
            bonuses = languages.map { frequent[$0] ?? [] }
        }
    }
    static let languageData = NameEncodingCandidates.all.map { LanguageData($0.languages) }
    static let hanLanguageData = LanguageData(["ja", "zh", "zh-Hant"])
    struct ScalarScore: Sendable {
        let values: SIMD8<Int16>
        let bonuses: SIMD8<Int16>
        let count: Int
        var value: Double { Double((0..<count).reduce(Int16.min) { max($0, values[$1]) }) / 2 }
    }
    static func scalarScore(_ p: Traits, language: LanguageData) -> ScalarScore {
        func uniform(_ value: Double) -> ScalarScore {
            ScalarScore(values: SIMD8(repeating: Int16(value * 2)), bonuses: .zero, count: language.masks.count)
        }
        if p.scalar < 128 { return uniform(0) }
        if p.bad { return uniform(-4) }
        if p.number { return uniform(0.5) }
        if p.scalar == 0xE03 || p.scalar == 0xE05 { return uniform(-2) }
        // 第4回レビュー B: 記号・修飾文字の値は位置規則に任せ、文字集合や頻度と重ねない。
        if !p.letter && !p.mark || p.category == .modifierLetter { return uniform(0) }
        let union = (p.mainMask | p.auxiliaryMask) & language.unionMask != 0
        var values = SIMD8<Int16>.zero
        var bonuses = SIMD8<Int16>.zero
        for (i, mask) in language.masks.enumerated() {
            if p.mainMask & mask != 0 { values[i] = 4 }
            else if p.auxiliaryMask & mask != 0 { values[i] = 2 }
            else if union { values[i] = 1 }
            else { values[i] = language.scripts.contains(p.script) ? -2 : -4 }
            bonuses[i] = language.bonuses[i].contains(p.scalar) ? 1 : 0
        }
        return ScalarScore(values: values, bonuses: bonuses, count: language.masks.count)
    }
    static let singleScalarTables: [Bool] = NameEncodingCandidates.all.map { candidate in
        candidate.singleByteTable.allSatisfy { $0 == nil || $0?.count == 1 }
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
        let vietnamese = candidate.name == "windows-1258"
        if vietnamese, requireVietnameseEvidence, !vietnameseEvidence(text) { return nil }
        // 設計書変更履歴と Task B: 採点だけ NFC、呼出側へ返す scalar 列は保存する。
        let scoringText = vietnamese ? String(text.unicodeScalars.prefix(256)).precomposedStringWithCanonicalMapping : text
        let single = candidate.form == .single && !vietnamese
        let properties: [Traits]
        if single {
            if singleScalarTables[candidateIndex] {
                let table = singleByteTraits[candidateIndex]
                properties = bytes.prefix(256).map { table[Int($0)] }
            } else {
                properties = Array(bytes.prefix(256).flatMap { byteTraits[candidateIndex][Int($0)] ?? [] }.prefix(256))
            }
        } else {
            properties = scoringText.unicodeScalars.prefix(256).map { scalar in
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
        var bonuses = SIMD8<Int16>.zero
        var totals = SIMD8<Int16>.zero
        var total = 0.0
        var count = 0
        let repeated = single && oneToOneTables[candidateIndex] ? byteEvidence.repeated : repeatedScalars(properties)
        let ruleProperties = repeated.contains(true) ? properties.enumerated().map { repeated[$0.offset] ? basicTraits[32] : $0.element } : properties
        let ruleText = repeated.contains(true) ? String(String.UnicodeScalarView(ruleProperties.map { Unicode.Scalar($0.scalar)! })) : scoringText
        let excessive = byteEvidence.possibleLongWord || properties.contains(where: { $0.script == .thai }) ? excessiveLetters(ruleProperties) : []
        var rules = LetterRuleState()
        var hanOnly = true
        var sawHan = false
        let halfWidth = candidate.isJapanese && properties.contains { (0xFF61...0xFF9F).contains($0.scalar) }
            && EncodingDetector.nameIsLikelyHalfWidth(text)
        let scores: [ScalarScore]
        if single, !singleScalarTables[candidateIndex] {
            scores = Array(bytes.prefix(256).flatMap { byteScores[candidateIndex][Int($0)] ?? [] }.prefix(256))
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
            if single, singleScalarTables[candidateIndex] {
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
                    // 設計書「採点 2」と第4回レビュー C: 漢字の集合と区分類は同じ文字の妥当性を測る。
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
            // 第5回レビュー: ハングル main は重ねず、公知の頻出音節だけを他言語と同じ頻度証拠にする。
            if !tooLong {
                bonuses &+= contribution.bonuses
            }
        }
        let membership = Double((0..<candidate.languages.count).reduce(Int16.min) { max($0, totals[$1]) }) / 2
        let frequency = Double(bonuses.max()) / 2
        total += membership + frequency
        rules.finish()
        var value = total / Double(max(1, count)) + rules.penalty
        if properties.contains(where: { $0.script == .latin && $0.scalar > 127 }) { value += westernOrthographicEvidence(ruleProperties) }
        if candidate.languages.contains("th") {
            value += orthography(ruleText, language: "th", maximumScalars: 256).boundedScore(scalarCount: count)
            value += thaiDistribution(ruleProperties).score
        }
        // 頻度と同じ正の証拠として平均し、助詞に見える偶然の語末一つで文字全体の証拠を覆さない。
        if candidate.form == .cp949 { value += koreanGrammar(ruleProperties) / Double(max(1, count)) }
        if vietnamese { value += orthography(ruleText, language: "vi", maximumScalars: 256).boundedScore(scalarCount: count) }
        var languageScores = SIMD8<Double>(repeating: value)
        if collectLanguages, candidate.languages.count > 1 {
            // 第5回レビュー: 書庫で言語を一つに固定できるよう、名前ごとの最大を取る前の証拠を渡す。
            // 文字集合と頻度の両方に同じ言語を使い、外来名ごとの言語切替を防ぐ。
            let common = value - (membership + frequency) / Double(max(1, count))
            for i in candidate.languages.indices {
                languageScores[i] = common + Double(totals[i] + bonuses[i]) / (2 * Double(max(1, count)))
            }
        }
        return Result(candidateIndex: candidateIndex, string: text, score: value,
                      hanOnly: sawHan && hanOnly, scalarCount: count, byteCount: byteEvidence.count, languageScores: languageScores)
    }

    // 第4回レビュー追補: 1〜3 scalar の20回以上の反復は言語的証拠を持たず、区間外だけを通常採点する。
    static func repeatedScalars(_ properties: [Traits]) -> [Bool] { repeatedMask(properties.map(\.scalar)) }
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

    // 第4回レビュー B: 開き引用符・分離アクセント・演算記号を一般カテゴリと隣接文字で区別する。
    static func symbolScore(_ properties: [Traits], at offset: Int) -> Double? {
        let p = properties[offset]
        // 第4回レビュー E2: 通常の文字と句読点は隣接 scalar を読む前に確定する。
        if p.scalar < 128 {
            switch p.scalar {
            case 0x60, 0x7E, 0x5E, 0x7C, 0x5C, 0x2B, 0x3D, 0x3C, 0x3E, 0x24, 0x25, 0x26, 0x40, 0x23, 0x2A: break
            default: return nil
            }
        } else {
            switch p.category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return nil
            case .modifierLetter, .otherNumber: return 0
            case .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation,
                 .otherPunctuation, .dashPunctuation, .connectorPunctuation:
                if p.scalar != 0x201A && p.scalar != 0x201E { return 0 }
            default: break
            }
        }

        let left = offset > 0 ? properties[offset - 1] : nil
        let right = offset + 1 < properties.count ? properties[offset + 1] : nil
        let beside = left?.letter == true || right?.letter == true
        let between = left?.letter == true && right?.letter == true
        if p.scalar < 128 {
            if between, let left, let right,
               alphabetic(left.script), alphabetic(right.script), left.scalar > 127 || right.scalar > 127 { return -2 }
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
            if between, let left, let right, alphabetic(left.script), alphabetic(right.script) { return -2 }
            return 0
        case .otherNumber, .modifierLetter: return 0
        default: return nil
        }
    }

    // 第4回レビュー E: 分かち書きする文字体系の語長と、タイ文字の無母音 run を別に扱う。
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

    static let southSlavicLetters = Set("ђјљњћџѓќѕЂЈЉЊЋЏЃЌЅ".unicodeScalars.map(\.value))
    static let eastSlavicLetters = Set("ёыэюяїєґЁЫЭЮЯЇЄҐ".unicodeScalars.map(\.value))
    struct LetterRuleState {
        var penalty = 0.0
        var length = 0
        var lowercase = false
        var allUpper = true
        var innerUpper = 0
        var vowels = 0
        var letters = 0
        var consonants = 0
        var longConsonants = 0
        var previous = Script.other
        var southSlavic = false
        var eastSlavic = false
        @inline(__always) mutating func finish() {
            if lowercase { penalty -= 1.5 * Double(innerUpper) }
            else if length >= 4, allUpper { penalty -= 0.3 }
            // 音韻は ASCII を含む語全体の性質。短語は比率を推定せず、略語の子音連続は罰しない。
            if letters >= 4 {
                let ratio = Double(vowels) / Double(letters)
                if ratio < 0.20 || ratio > 0.80 { penalty -= 1 }
                if lowercase { penalty -= Double(longConsonants) }
            }
            // セルビア・マケドニアの専用字と東スラブの専用字は同一語の綴りを作らない。
            // 他言語の固有名そのものは許し、排他的な字の共存だけを弱く減点する。
            if southSlavic && eastSlavic { penalty -= 1 }
            southSlavic = false; eastSlavic = false
            length = 0; lowercase = false; allUpper = true; innerUpper = 0
            vowels = 0; letters = 0; consonants = 0; longConsonants = 0; previous = .other
        }
        @inline(__always) mutating func append(_ p: Traits) {
            guard p.letter else {
                // 結合声調は同じ語に属し、語境界を作らない。
                if p.mark { return }
                finish(); return
            }
            let a = previous
            let b = p.script
            if b == .cyrillic {
                southSlavic = southSlavic || p.cyrillicAlphabet & 1 != 0
                eastSlavic = eastSlavic || p.cyrillicAlphabet & 2 != 0
            }
            if a != b, (a == .latin && (b == .cyrillic || b == .greek || b == .thai))
                || (b == .latin && (a == .cyrillic || a == .greek || a == .thai))
                || (a == .cyrillic && b == .greek) || (a == .greek && b == .cyrillic) { penalty -= 2.5 }
            if letters > 0, p.upper { innerUpper += 1 }
            length += 1
            lowercase = lowercase || p.lower
            allUpper = allUpper && p.upper
            if b == .latin || b == .cyrillic || b == .greek {
                letters += 1
                if p.vowel { vowels += 1; consonants = 0 }
                else { consonants += 1; if consonants == 5 { longConsonants += 1 } }
            }
            previous = b
        }
    }

    static func letterRules(_ properties: [Traits]) -> Double {
        var state = LetterRuleState()
        for (offset, p) in properties.enumerated() {
            if (0x2500...0x25FF).contains(p.scalar), !cjkGeometricNotation(properties, at: offset) { state.penalty -= 3 }
            state.append(p)
        }
        state.finish()
        return state.penalty
    }

    // イタリア語の語末強勢の grave と、仏・葡語で後舌母音前の ç は位置を伴う綴りの証拠。
    // 借用語に別の綴りもあるため、欠如は罰せず適合だけを加点する。
    static func westernOrthographicEvidence(_ properties: [Traits]) -> Double {
        guard properties.contains(where: { [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9, 0xE7, 0xC7].contains($0.scalar) }) else { return 0 }
        var score = 0.0
        var italianWord = true
        var hasConsonant = false
        var length = 0
        var last: UInt32 = 0
        let italian = UInt32(1) << exemplarLanguages.firstIndex(of: "it")!
        for p in properties {
            if p.letter {
                length += 1
                italianWord = italianWord && p.mainMask & italian != 0
                hasConsonant = hasConsonant || !p.vowel
            } else {
                if italianWord, length >= 2, hasConsonant, [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9].contains(last) { score += 0.5 }
                length = 0; italianWord = true; hasConsonant = false
            }
            if last == 0xE7 || last == 0xC7,
               [UInt32(0x61), 0x6F, 0x75, 0x41, 0x4F, 0x55, 0xE3, 0xF5].contains(p.scalar) { score += 0.5 }
            last = p.scalar
        }
        if italianWord, length >= 2, hasConsonant, [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9].contains(last) { score += 0.5 }
        return score
    }

    // 西・葡語の acute は母音の強勢を表し、独語の ß は長母音・二重母音の後に置く。
    // 綴りの欠如や借用語を禁止せず、位置が確認できる正の証拠だけを加える。
    static let acuteVowels = Set("áéíóúÁÉÍÓÚ".unicodeScalars.map(\.value))
    static func latinStressEvidence(_ properties: [Traits]) -> Double {
        properties.indices.reduce(0) { $0 + latinStressEvidence(properties, at: $1) }
    }
    private static func latinStressEvidence(_ properties: [Traits], at i: Int) -> Double {
        let p = properties[i]
        if p.acute {
            let left = i > 0 ? properties[i - 1] : nil
            let right = i + 1 < properties.count ? properties[i + 1] : nil
            // 母音連続の acute は hiatus の表示にも使うため、単純な強勢の証拠には加えない。
            let adjacentLetter = left?.letter == true || right?.letter == true
            return adjacentLetter && left?.vowel != true && right?.vowel != true ? 0.5 : 0
        }
        if p.scalar == 0xDF, i > 0, properties[i - 1].vowel {
            let previous = properties[i - 1].scalar | 0x20
            let before = i >= 2 ? properties[i - 2].scalar | 0x20 : 0
            return (before == 0x65 && (previous == 0x69 || previous == 0x75))
                || (before == 0x69 && previous == 0x65) || ((before == 0x61 || before == 0xE4) && previous == 0x75) ? 1 : 0.5
        }
        return 0
    }

    // 韓国語は助詞を語末に付け、年月日の単位を数字の後に置く。区分類とは独立した文法上の証拠。
    static let koreanParticles = Set("은는이가을를의에와과도만로".unicodeScalars.map(\.value))
    static let koreanParticlePairs: Set<UInt64> = Set(["에서", "에게", "으로", "부터", "까지", "처럼", "보다"].map {
        let s = Array($0.unicodeScalars); return UInt64(s[0].value) << 32 | UInt64(s[1].value)
    })
    static let koreanUnits = Set("년월일".unicodeScalars.map(\.value))
    static func koreanGrammar(_ properties: [Traits]) -> Double {
        var score = 0.0
        var length = 0
        var previous: UInt32 = 0
        var penultimate: UInt32 = 0
        var wholeHangulWord = true
        func finish(_ end: Int) {
            guard length >= 2, wholeHangulWord else { length = 0; return }
            let pair = UInt64(penultimate) << 32 | UInt64(previous)
            if koreanParticles.contains(previous) || koreanParticlePairs.contains(pair) { score += 0.5 }
            else if (0xAC00...0xD7A3).contains(previous) {
                // 韓国語の連体形は ㄴ / ㄹ 終声を取り、分かち書きした後続語を修飾する。
                // 音節だけでは断定せず、後続のハングル語がある場合の弱い正の証拠とする。
                let ending = (previous - 0xAC00) % 28
                var next = end
                while next < properties.count, properties[next].category == .spaceSeparator { next += 1 }
                if (ending == 4 || ending == 8), next > end, next < properties.count,
                   properties[next].script == .hangul, properties[next].letter { score += 0.5 }
            }
            length = 0
        }
        for (i, p) in properties.enumerated() {
            if p.script == .hangul, p.letter {
                if koreanUnits.contains(p.scalar), (0x30...0x39).contains(previous) { score += 0.5 }
                length += 1
            } else {
                if p.letter { wholeHangulWord = false }
                finish(i)
                if !p.letter { wholeHangulWord = true }
            }
            penultimate = previous; previous = p.scalar
        }
        finish(properties.count)
        return score
    }

    struct Violation: Sendable {
        let rule: String
        let offset: Int
        let scalar: UInt32
    }
    struct Orthography {
        var score = 0.0
        var violations: [Violation] = []
        var positive = 0.0
        // 設計書「採点 7」: 適合の反復だけで長い交差復号が文字得点を圧倒しないよう、有効な証拠を平均する。
        func boundedScore(scalarCount: Int) -> Double { score - positive + positive / Double(max(1, scalarCount)) }
        mutating func reject(_ rule: String, _ index: Int, _ scalar: UInt32, penalty: Double) {
            violations.append(Violation(rule: rule, offset: index, scalar: scalar))
            score -= penalty
        }
    }
    static func isVietnameseTone(_ value: UInt32) -> Bool {
        value == 0x300 || value == 0x301 || value == 0x303 || value == 0x309 || value == 0x323
    }
    static let vietnameseVowels = Set("aăâeêioôơuưyAĂÂEÊIOÔƠUƯY".unicodeScalars.map(\.value))

    // 訂正6: タイ文字の main はほぼ全文字を含むため、通常の分布と語中の稀な表記を別の証拠にする。
    // 頻出集合は既存の公知リストから一度だけ表にし、候補内の走査では表引きだけを行う。
    static let thaiFrequentFlags: [Bool] = (UInt32(0xE00)...0xE7F).map { frequent["th"]!.contains($0) }
    static func thaiDistribution(_ properties: [Traits]) -> Orthography {
        var result = Orthography()
        var start = 0
        var length = 0
        var runScalars = 0
        var common = 0
        func isThaiText(_ p: Traits) -> Bool { p.script == .thai && (p.letter || p.mark) }
        func finish() {
            // 数字・句読点・他スクリプトで切る。最低長は scalar、頻度の分母は独立した字母で数える。
            // 結合記号は run に属するが、声調・母音記号が多い正しい名前を低頻度と誤認しない。
            let deficit = 0.35 * Double(length) - Double(common)
            if runScalars >= 8, deficit > 0 {
                result.reject("th-common-ratio", start, properties[start].scalar, penalty: 1.5 * deficit)
            }
            length = 0; runScalars = 0; common = 0
        }
        for (index, p) in properties.enumerated() {
            let value = p.scalar
            if isThaiText(p) {
                if runScalars == 0 { start = index }
                runScalars += 1
                if p.letter {
                    length += 1
                    if thaiFrequentFlags[Int(value - 0xE00)] { common += 1 }
                }
            } else { finish() }
            guard p.script == .thai else { continue }
            let next = index + 1 < properties.count ? properties[index + 1].scalar : 0
            let between = index > 0 && index + 1 < properties.count
                && isThaiText(properties[index - 1]) && isThaiText(properties[index + 1])
            if value == 0xE3A || value == 0xE4E || value == 0xE4D && next != 0xE32 {
                result.reject("th-rare-mark", index, value, penalty: 2)
            } else if between, value == 0xE4F || value == 0xE5A || value == 0xE5B {
                result.reject("th-internal-punctuation", index, value, penalty: 2)
            } else if between, (0xE50...0xE59).contains(value) {
                result.reject("th-internal-digit", index, value, penalty: 3)
            }
        }
        finish()
        return result
    }

    static func orthography(_ text: String, language: String, maximumScalars: Int = Int.max) -> Orthography {
        let values = Array(text.unicodeScalars.prefix(maximumScalars).map(\.value))
        if language == "vi" { return vietnameseOrthography(values) }
        var result = Orthography()
        for (index, value) in values.enumerated() {
            let previous: UInt32 = index > 0 ? values[index - 1] : 0
            if language == "th" {
                let consonant = (0xE01...0xE2E).contains(previous)
                let upper = previous == 0xE31 || (0xE34...0xE3A).contains(previous) || previous == 0xE47 || previous == 0xE4D
                if value == 0xE31 || (0xE34...0xE3A).contains(value) || (0xE47...0xE4E).contains(value) {
                    if consonant || upper || (value == 0xE4D && (0xE48...0xE4B).contains(previous)) { result.score += 0.25; result.positive += 0.25 }
                    else { result.reject("th-mark-base", index, value, penalty: 2) }
                } else if (0xE40...0xE44).contains(value) {
                    if index + 1 < values.count, (0xE01...0xE2E).contains(values[index + 1]) { result.score += 0.25; result.positive += 0.25 }
                    else if index + 1 < values.count { result.reject("th-leading-vowel", index, value, penalty: 2) }
                } else if value == 0xE33 {
                    if consonant || (0xE48...0xE4B).contains(previous) { result.score += 0.25; result.positive += 0.25 }
                    else { result.reject("th-sara-am", index, value, penalty: 2) }
                }
            }
        }
        return result
    }

    // CP1258 と NFC の出力域は一度だけ分解し、ASCII はそのまま処理する。
    static let vietnameseDecompositions: [UInt32: [UInt32]] = Dictionary(uniqueKeysWithValues: (0x80..<0x2200).compactMap { raw in
        let value = UInt32(raw)
        let parts = String(Unicode.Scalar(value)!).decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
        return parts == [value] ? nil : (value, parts)
    })
    private static func vietnameseOrthography(_ values: [UInt32]) -> Orthography {
        var result = Orthography()
        var tones = 0
        var base: UInt32 = 0
        func part(_ value: UInt32, original: UInt32, index: Int) {
            if isVietnameseTone(value) {
                if !vietnameseVowels.contains(base) { result.reject("vi-tone-base", index, original, penalty: 3) }
                else if tones > 0 { result.reject("vi-one-tone", index, original, penalty: 3) }
                else { result.score += 1; result.positive += 1 }
                tones += 1; base = 0
            } else if value != 0x302 && value != 0x306 && value != 0x31B {
                base = value
                let letter = value < 128 ? (65...90).contains(value) || (97...122).contains(value) : Unicode.Scalar(value)!.properties.isAlphabetic
                if !letter { tones = 0 }
            }
        }
        for (index, value) in values.enumerated() {
            if value < 128 { part(value, original: value, index: index) }
            else if let parts = vietnameseDecompositions[value] {
                for valuePart in parts { part(valuePart, original: value, index: index) }
            } else if value < 0x2200 { part(value, original: value, index: index) }
            else {
                for scalar in String(Unicode.Scalar(value)!).decomposedStringWithCanonicalMapping.unicodeScalars { part(scalar.value, original: value, index: index) }
            }
        }
        return result
    }

    static func vietnameseEvidence(_ text: String) -> Bool {
        let values = Array(text.unicodeScalars.prefix(256).map(\.value))
        for (index, value) in values.enumerated() where index > 0 {
            if isVietnameseTone(value), vietnameseVowels.contains(values[index - 1]) { return true }
        }
        // 設計書「採点 6」: 識別字がなければ音節への分割・正規化も不要。
        guard values.contains(where: { [UInt32(0x111), 0x103, 0x1A1, 0x1B0, 0x110, 0x102, 0x1A0, 0x1AF].contains($0) }) else { return false }
        let syllables = String(text.unicodeScalars.prefix(256)).lowercased().split { !$0.isLetter }
        for syllable in syllables {
            let s = String(syllable)
            if s.unicodeScalars.contains(where: { [UInt32(0x111), 0x103, 0x1A1, 0x1B0].contains($0.value) }),
               isVietnameseSyllable(s) { return true }
        }
        return false
    }

    // ベトナム語の音節は頭子音・連続した母音核・末子音からなる。借用語全体を一音節とは扱わない。
    static let vietnameseOnsets: Set<String> = ["", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh", "nh", "p", "ph", "q", "qu", "r", "s", "t", "th", "tr", "v", "x"]
    static let vietnameseCodas: Set<String> = ["", "c", "ch", "m", "n", "ng", "nh", "p", "t"]
    static func isVietnameseSyllable(_ text: String) -> Bool {
        let plain = String(String.UnicodeScalarView(text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.filter { !isVietnameseTone($0.value) }))
            .precomposedStringWithCanonicalMapping
        let chars = Array(plain)
        guard !chars.isEmpty else { return false }
        for start in 0..<min(4, chars.count) {
            guard vietnameseOnsets.contains(String(chars.prefix(start))) else { continue }
            var end = start
            while end < chars.count, chars[end].unicodeScalars.allSatisfy({ vietnameseVowels.contains($0.value) }) { end += 1 }
            guard end > start, end - start <= 3, vietnameseCodas.contains(String(chars.dropFirst(end))) else { continue }
            let nucleus = Array(chars[start..<end])
            // 短母音 ă は単独の母音核で、末子音を伴う。São → Săo はこの条件を満たさない。
            if nucleus.contains("ă"), (nucleus.count != 1 || end == chars.count) { continue }
            return true
        }
        return false
    }

    // 設計書「採点 2」と変更履歴 c: 小差の Han 候補は言語で一度だけ決め、その後日本語経路へ委ねる。
    static let secondTierScore = 0.5
    static let hanTieThreshold = 0.4
    // 第3回レビュー: 非 ASCII の証拠が増えるにつれて事前確率の重みを減らす。
    static let priorWeight = 3.5
    static let languagePriorBonus = 1.0
    static let priors: [String: Double] = [
        "windows-1252": 1, "cp932": 0.8, "euc-jp": 0.8,
        "windows-1250": 0.6, "windows-1251": 0.6, "gb18030": 0.6,
        "cp950": 0.5, "cp949": 0.5, "cp874": 0.4, "iso-8859-15": 0.4,
        "koi8-u": 0.3, "koi8-r": 0.3, "windows-1253": 0.3, "windows-1254": 0.3,
        "iso-8859-2": 0.3, "windows-1258": 0.3, "cp866": 0.2, "cp850": 0.2,
        "macintosh": 0.2, "windows-1255": 0.2, "windows-1256": 0.2, "windows-1257": 0.2,
        "iso-8859-5": 0.1, "x-mac-centraleurroman": 0.1, "x-mac-cyrillic": 0.1, "big5-hkscs": 0.1,
    ]
    static func ranked(_ results: [Result], likelyLanguage: String?, fromWindows: Bool = false) -> [Result] {
        let lang = language(likelyLanguage)
        let adjusted = results.map { result in
            let candidate = NameEncodingCandidates.all[result.candidateIndex]
            var prior = priors[candidate.name] ?? 0
            if let lang, candidate.languages.contains(lang) { prior += languagePriorBonus }
            if fromWindows, candidate.isMac { prior -= 0.3 }
            let n = Double(result.byteCount)
            return Result(candidateIndex: result.candidateIndex, string: result.string,
                          score: (n * result.score + priorWeight * prior) / (n + priorWeight),
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
               $0.hanOnly && top.score - $0.score < hanTieThreshold && NameEncodingCandidates.all[$0.candidateIndex].languages.contains(lang)
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
