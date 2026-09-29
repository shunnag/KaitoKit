import Foundation

// 言語ごとの正書法と位置の証拠（設計書「採点 4」）: 西欧ラテンの強勢と ç、韓国語の助詞、タイ語の分布と記号、
// fr / is / el / he / ar / fa とキリル各言語の追加規則、ベトナム語の声調。違反の規則名は CLI の
// --check-orthography と Tests/Measurement/name-encoding/ の測定器が読むため変えない。
extension NameEncodingScorer {
    // イタリア語の語末強勢の grave と、仏・葡語で後舌母音前の ç は位置を伴う綴りの証拠。
    // 借用語に別の綴りもあるため、欠如は罰せず適合だけを加点する。
    static func westernEvidence(_ properties: [Traits]) -> SIMD2<Double> {
        guard properties.contains(where: { [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9, 0xE7, 0xC7].contains($0.scalar) }) else { return .zero }
        var score = SIMD2<Double>.zero
        var italianWord = true
        var hasConsonant = false
        var length = 0
        var last: UInt32 = 0
        let italian = UInt64(1) << exemplarLanguages.firstIndex(of: "it")!
        for p in properties {
            if p.letter {
                length += 1
                italianWord = italianWord && p.mainMask & italian != 0
                hasConsonant = hasConsonant || !p.vowel
            } else {
                if italianWord, length >= 2, hasConsonant, [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9].contains(last) { score[0] += 0.5 }
                length = 0; italianWord = true; hasConsonant = false
            }
            if last == 0xE7 || last == 0xC7,
               [UInt32(0x61), 0x6F, 0x75, 0x41, 0x4F, 0x55, 0xE3, 0xF5].contains(p.scalar) { score[1] += 0.5 }
            last = p.scalar
        }
        if italianWord, length >= 2, hasConsonant, [UInt32(0xE0), 0xE8, 0xEC, 0xF2, 0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9].contains(last) { score[0] += 0.5 }
        return score
    }

    // 西・葡語の acute は母音の強勢を表し、独語の ß は長母音・二重母音の後に置く。
    // 綴りの欠如や借用語を禁止せず、位置が確認できる正の証拠だけを加える。
    static let acuteVowels = Set("áéíóúÁÉÍÓÚ".unicodeScalars.map(\.value))
    static func latinStressEvidence(_ properties: [Traits], at i: Int) -> Double {
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
        var recordViolations = true
        // 設計書「採点 7」: 適合の反復だけで長い交差復号が文字得点を圧倒しないよう、有効な証拠を平均する。
        func boundedScore(scalarCount: Int) -> Double { score - positive + positive / Double(max(1, scalarCount)) }
        mutating func reject(_ rule: String, _ index: Int, _ scalar: UInt32, penalty: Double) {
            if recordViolations { violations.append(Violation(rule: rule, offset: index, scalar: scalar)) }
            score -= penalty
        }
    }
    static func isVietnameseTone(_ value: UInt32) -> Bool {
        value == 0x300 || value == 0x301 || value == 0x303 || value == 0x309 || value == 0x323
    }
    static let vietnameseVowels = Set("aăâeêioôơuưyAĂÂEÊIOÔƠUƯY".unicodeScalars.map(\.value))

    // タイ文字の main はほぼ全文字を含むため、通常の分布と語中の稀な表記を別の証拠にする。
    // 分布だけ15字へ広げ、通常の名前の子音も数える。文字得点の頻出 bonus は変更しない。
    // 集合の出典と比較: Documentation/verification/2026-09-14-name-encoding-thai-rule.md。
    static let thaiFrequentFlags: [Bool] = {
        let letters = frequent["th"]!.union("สทดคง".unicodeScalars.map(\.value))
        return (UInt32(0xE00)...0xE7F).map { letters.contains($0) }
    }()
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

    static let greekTonos = Set("άέήίόύώΐΰΆΈΉΊΌΎΏ".unicodeScalars.map(\.value))

    private static func cyrillicLowercase(_ value: UInt32) -> UInt32 {
        if (0x410...0x42F).contains(value) { return value + 0x20 }
        return value == 0x401 ? 0x451 : value
    }

    // 正書法は候補の union ではなく、書庫で選ばれる個々の言語に結び付ける（Documentation/verification/2026-09-14-name-encoding-languages.md）。
    // Unicode Standard §9: 同じ基底字母に複数の結合記号が付くことは許す。
    static func additionalOrthography(_ properties: [Traits], language: String, context suppliedContext: LanguageRuleContext? = nil,
                                      recordViolations: Bool = true) -> Orthography {
        switch language {
        case "fr": return frenchOrthography(properties, recordViolations: recordViolations)
        case "is": return icelandicOrthography(properties, context: suppliedContext, recordViolations: recordViolations)
        case "el": return greekOrthography(properties, recordViolations: recordViolations)
        case "he", "ar", "fa", "ru", "uk", "be", "bg", "sr", "mk":
            return semiticAndCyrillicOrthography(properties, language: language, context: suppliedContext,
                                                 recordViolations: recordViolations)
        default: return Orthography(recordViolations: recordViolations)
        }
    }

    private static func frenchOrthography(_ properties: [Traits], recordViolations: Bool) -> Orthography {
        var result = Orthography(recordViolations: recordViolations)
        // French の通常の élision は前の語の末尾母音を apostrophe に置く。
        // 口語の省略や借用表記もあるため、字母の前の孤立した語頭形は弱い証拠にとどめる。
        for (i, p) in properties.enumerated() where p.scalar == 0x2019 {
            if (i == 0 || !properties[i - 1].letter), i + 1 < properties.count,
               properties[i + 1].script == .latin, properties[i + 1].letter {
                result.reject("fr-initial-apostrophe", i, p.scalar, penalty: 1)
            }
        }
        return result
    }

    private static func icelandicOrthography(_ properties: [Traits], context suppliedContext: LanguageRuleContext?,
                                             recordViolations: Bool) -> Orthography {
        var result = Orthography(recordViolations: recordViolations)
        let context = suppliedContext ?? LanguageRuleContext(properties)
        guard !context.flags.isDisjoint(with: .icelandic) else { return result }
        var yAcute = 0
        for (i, p) in properties.enumerated() where !p.alphabetFlags.isDisjoint(with: .icelandic) {
            let previous = i > 0 ? properties[i - 1] : nil
            let next = i + 1 < properties.count ? properties[i + 1] : nil
            if p.scalar == 0xFD || p.scalar == 0xDD {
                yAcute += 1
                if p.scalar == 0xFD, next?.letter != true { result.reject("is-y-acute-final", i, p.scalar, penalty: 2) }
                if p.scalar == 0xDD, previous?.letter != true { result.reject("is-y-acute-initial-upper", i, p.scalar, penalty: 1) }
                if yAcute >= 2 { result.reject("is-y-acute-repeated", i, p.scalar, penalty: 1.5) }
            } else if p.scalar == 0xF0 || p.scalar == 0xD0 {
                if previous?.letter != true, next?.letter == true { result.reject("is-eth-initial", i, p.scalar, penalty: 3) }
            } else if previous?.letter == true, next?.letter != true {
                result.reject("is-thorn-final", i, p.scalar, penalty: 3)
            } else if let next, next.script == .latin, next.letter, !next.vowel,
                      ![UInt32(0x6A), 0x72, 0x76].contains(next.scalar | 0x20) {
                // 複合語の途中の þ は許し、語頭子音群の不整合だけを弱く減点する。
                result.reject("is-thorn-cluster", i, p.scalar, penalty: 1)
            }
        }
        return result
    }

    private static func greekOrthography(_ properties: [Traits], recordViolations: Bool) -> Orthography {
        var result = Orthography(recordViolations: recordViolations)
        var accents = 0
        for (i, p) in properties.enumerated() {
            // dialytika は直前の母音と別の音節に分ける記号で、子音直後や語頭には置かない。
            if [UInt32(0x3CA), 0x3CB, 0x390, 0x3B0, 0x3AA, 0x3AB].contains(p.scalar) {
                if i == 0 || properties[i - 1].script != .greek || !properties[i - 1].vowel {
                    result.reject("el-diaeresis-without-vowel", i, p.scalar, penalty: 2)
                }
            }
            // 母音脱落の apostrophe は字母の境界を示す。母音の前の孤立した語頭形は弱く減点する。
            if p.scalar == 0x2019, (i == 0 || !properties[i - 1].letter), i + 1 < properties.count,
               properties[i + 1].script == .greek, properties[i + 1].vowel {
                result.reject("el-initial-apostrophe-vowel", i, p.scalar, penalty: 1)
            }
            if !p.letter && !p.mark { accents = 0; continue }
            if i > 0, properties[i - 1].scalar == 0x3C2, p.script == .greek, p.upper { accents = 0 }
            if greekTonos.contains(p.scalar) {
                accents += 1
                if accents >= 2 { result.reject("el-multiple-tonos", i, p.scalar, penalty: 2) }
            }
            if p.scalar == 0x3C2 || p.scalar == 0x3C3 {
                var end = i + 1
                while end < properties.count, properties[end].mark { end += 1 }
                let internalLetter = end < properties.count && properties[end].letter && properties[end].script == .greek
                    && !(p.scalar == 0x3C2 && properties[end].upper)
                if p.scalar == 0x3C2, internalLetter { result.reject("el-final-sigma-internal", i, p.scalar, penalty: 2) }
                if p.scalar == 0x3C3, !internalLetter { result.reject("el-sigma-final", i, p.scalar, penalty: 1) }
            }
        }
        return result
    }

    private static func semiticAndCyrillicOrthography(_ properties: [Traits], language: String,
                                                      context suppliedContext: LanguageRuleContext?,
                                                      recordViolations: Bool) -> Orthography {
        var result = Orthography(recordViolations: recordViolations)
        let native: Script = language == "he" ? .hebrew : language == "ar" || language == "fa" ? .arabic : .cyrillic
        let context = suppliedContext ?? LanguageRuleContext(properties)
        let nativeCount = native == .hebrew ? context.hebrew : native == .arabic ? context.arabic : context.cyrillic
        let latinCount = context.latin
        if nativeCount == 1, latinCount >= 4 {
            let index = properties.firstIndex { $0.letter && $0.script == native }!
            result.reject("alphabet-singleton-in-latin", index, properties[index].scalar, penalty: 1)
        }
        if native == .cyrillic {
            let relevant: AlphabetFlags = language == "be" ? [.hardSign, .shcha, .shortU, .shortI]
                : language == "ru" || language == "uk" ? [.hardSign, .shcha, .shortI] : [.shcha, .shortI]
            guard !context.flags.isDisjoint(with: relevant) else { return result }
        }

        var base = Script.other
        var cyrillicCount = 0
        var hardSigns = 0
        var shcha = 0
        var firstHardSign = 0
        var firstShcha = 0
        var shortI = 0
        var firstShortI = 0
        for (i, p) in properties.enumerated() {
            let value = p.scalar
            var nextIndex = i + 1
            if p.script == .hebrew || p.script == .arabic {
                while nextIndex < properties.count, properties[nextIndex].mark { nextIndex += 1 }
            }
            let next = nextIndex < properties.count ? properties[nextIndex] : nil
            if language == "he" {
                if p.mark, (0x5B0...0x5C7).contains(value), base != .hebrew {
                    result.reject("he-mark-base", i, value, penalty: 3)
                }
                if p.letter, p.script == .hebrew {
                    let internalLetter = next?.letter == true && next?.script == .hebrew
                    if [UInt32(0x5DA), 0x5DD, 0x5DF, 0x5E3, 0x5E5].contains(value) {
                        if internalLetter { result.reject("he-final-internal", i, value, penalty: 3) }
                        // 孤立した字形は語末適合の証拠にせず、先行する字母（結合記号を許す）がある語だけ加点する。
                        else if base == .hebrew { result.score += 0.5; result.positive += 0.5 }
                    } else if [UInt32(0x5DB), 0x5DE, 0x5E0, 0x5E4, 0x5E6].contains(value), !internalLetter {
                        // 外来語や略語では通常形も語末に現れるので、弱い証拠にとどめる。
                        result.reject("he-nominal-final", i, value, penalty: 1)
                    }
                }
            } else if language == "ar" || language == "fa" {
                if (0x64B...0x652).contains(value), base != .arabic {
                    result.reject("arabic-mark-base", i, value, penalty: 3)
                }
                if next?.letter == true, next?.script == .arabic {
                    if value == 0x629 { result.reject("arabic-teh-marbuta-internal", i, value, penalty: 3) }
                    // Persian の字中の alef maksura / yeh は Arabic の語末制約を受けない。
                    if value == 0x649, language == "ar" { result.reject("ar-alef-maksura-internal", i, value, penalty: 3) }
                    if value == 0x621, language == "ar", base != .arabic {
                        result.reject("ar-hamza-initial", i, value, penalty: 1)
                    }
                }
            } else if native == .cyrillic, p.script == .cyrillic, p.letter {
                cyrillicCount += 1
                if language == "be", value == 0x45E || value == 0x40E {
                    var before = i
                    while before > 0, properties[before - 1].category == .spaceSeparator { before -= 1 }
                    if before == 0 || !properties[before - 1].vowel {
                        result.reject("be-short-u-after-vowel", i, value, penalty: 1)
                    }
                }
                let lower = cyrillicLowercase(value)
                if lower == 0x44A {
                    if hardSigns == 0 { firstHardSign = i }
                    hardSigns += 1
                    let previous = i > 0 ? properties[i - 1] : nil
                    let consonant = previous?.script == .cyrillic && previous?.letter == true
                        && previous?.vowel == false && previous?.scalar != 0x44C && previous?.scalar != 0x42C
                        && previous?.scalar != 0x44A && previous?.scalar != 0x42A
                    let beforeIotated = next.map { [UInt32(0x435), 0x451, 0x44E, 0x44F].contains(cyrillicLowercase($0.scalar)) } ?? false
                    if (language == "ru" || language == "uk" || language == "be"), !consonant || language == "ru" && !beforeIotated {
                        result.reject("\(language)-hard-sign-position", i, value, penalty: 1)
                    }
                }
                if lower == 0x439 { if shortI == 0 { firstShortI = i }; shortI += 1 }
                if lower == 0x449 { if shcha == 0 { firstShcha = i }; shcha += 1 }
            }
            if p.letter { base = p.script }
            else if !p.mark { base = .other }
        }
        // й / щ の比率はキリル各言語で観測する。ъ は母音として使う bg を含めず、短名には比率を推定しない。
        if native == .cyrillic, cyrillicCount >= 12 {
            let shortIDeficit = Double(shortI) - 0.10 * Double(cyrillicCount)
            if shortIDeficit > 0 {
                result.reject("\(language)-short-i-ratio", firstShortI, properties[firstShortI].scalar, penalty: shortIDeficit)
            }
            let hardDeficit = Double(hardSigns) - 0.03 * Double(cyrillicCount)
            if hardDeficit > 0, language == "ru" || language == "uk" || language == "be" {
                result.reject("\(language)-hard-sign-ratio", firstHardSign, properties[firstHardSign].scalar, penalty: hardDeficit)
            }
            let shchaDeficit = Double(shcha) - 0.08 * Double(cyrillicCount)
            if shchaDeficit > 0 {
                result.reject("\(language)-shcha-ratio", firstShcha, properties[firstShcha].scalar, penalty: shchaDeficit)
            }
        }
        return result
    }

    static func orthography(_ text: String, language: String, maximumScalars: Int = Int.max) -> Orthography {
        orthography(Array(text.unicodeScalars.prefix(maximumScalars).map(\.value)), language: language)
    }
    static func orthography(_ values: [UInt32], language: String) -> Orthography {
        if language == "vi" { return vietnameseOrthography(values) }
        var result = additionalOrthography(values.map { traits($0) }, language: language)
        for (index, value) in values.enumerated() {
            let previous: UInt32 = index > 0 ? values[index - 1] : 0
            if language == "th" {
                if value == 0x201D, index + 1 < values.count, (0xE01...0xE2E).contains(values[index + 1]),
                   index == 0 || !(0xE01...0xE5B).contains(previous) {
                    result.reject("th-closing-quote-initial", index, value, penalty: 2)
                }
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
        let values = Array(text.unicodeScalars.prefix(Tuning.scoringScalarLimit).map(\.value))
        for (index, value) in values.enumerated() where index > 0 {
            if isVietnameseTone(value), vietnameseVowels.contains(values[index - 1]) { return true }
        }
        // 設計書「採点 6」: 識別字がなければ音節への分割・正規化も不要。
        guard values.contains(where: { [UInt32(0x111), 0x103, 0x1A1, 0x1B0, 0x110, 0x102, 0x1A0, 0x1AF].contains($0) }) else { return false }
        let syllables = String(text.unicodeScalars.prefix(Tuning.scoringScalarLimit)).lowercased().split { !$0.isLetter }
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
}
