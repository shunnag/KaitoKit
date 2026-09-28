// 語ごとの字母の規則（設計書「採点 3」）: 大小文字の遷移、スクリプトの混在、音韻の妥当性、罫線、
// キリルの排他的な専用字。score の走査が LetterRuleState に一 scalar ずつ加え、語の境界の finish が減点を確定する。
extension NameEncodingScorer {
    static let southSlavicLetters = Set("ђјљњћџѓќѕЂЈЉЊЋЏЃЌЅ".unicodeScalars.map(\.value))
    static let eastSlavicLetters = Set("ёыэюяїєґьЁЫЭЮЯЇЄҐЬ".unicodeScalars.map(\.value))
    // 言語ごとの規則で同じ scalar 列を再走査せず、名前単位の属性を一度だけ集める。
    struct LanguageRuleContext {
        var latin = 0
        var cyrillic = 0
        var hebrew = 0
        var arabic = 0
        var flags: AlphabetFlags = []
        init() {}
        init(_ properties: [Traits]) {
            for p in properties { append(p) }
        }
        @inline(__always) mutating func append(_ p: Traits) {
            if p.letter {
                switch p.script {
                case .latin: latin += 1
                case .cyrillic: cyrillic += 1
                case .hebrew: hebrew += 1
                case .arabic: arabic += 1
                default: break
                }
            }
            flags.formUnion(p.alphabetFlags)
        }
    }
    struct LetterRuleState {
        var context = LanguageRuleContext()
        var penalty = 0.0
        var bulgarian = false
        var skipLatinDensity = false
        var greek = false
        var previousScalar: UInt32 = 0
        var latinLetters = 0
        var markedLatin = 0
        var length = 0
        var lowercase = false
        var allUpper = true
        var innerUpper = 0
        var vowels = 0
        var letters = 0
        var cyrillicLetters = 0
        var consonants = 0
        var longConsonants = 0
        var previous = Script.other
        var previousLower = false
        var terminalUpper = false
        var southSlavic = false
        var eastSlavic = false
        @inline(__always) mutating func finish() {
            if terminalUpper { penalty -= 1 }
            // 六字以上の Latin 語で 2/3 超が非 ASCII 字母なら、弱い密度の証拠とする。
            // ベトナム語は独立の正書法経路を使う。
            if !skipLatinDensity, latinLetters == length, latinLetters >= 6, markedLatin * 3 > latinLetters * 2 { penalty -= 2 }
            latinLetters = 0; markedLatin = 0
            if lowercase { penalty -= 1.5 * Double(innerUpper) }
            else if length >= 4, allUpper { penalty -= 0.3 }
            // 二字だけのキリル子音列は略記に多く、通常の語としての証拠は弱い。全大文字の略号は除く。
            if letters == 2, cyrillicLetters == 2, vowels == 0, lowercase { penalty -= 0.5 }
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
            vowels = 0; letters = 0; cyrillicLetters = 0; consonants = 0; longConsonants = 0; previous = .other
            previousLower = false; terminalUpper = false; previousScalar = 0
        }
        @inline(__always) mutating func append(_ p: Traits) {
            context.append(p)
            guard p.letter else {
                // 結合声調は同じ語に属し、語境界を作らない。
                if p.mark {
                    // Latin の直後の Arabic/Hebrew 結合記号も、同じ語のスクリプト混在。
                    if previous == .latin, p.script == .arabic || p.script == .hebrew { penalty -= 2.5 }
                    return
                }
                // 字母に接する演算・通貨・その他記号一つでは、両側の文字体系の混在を隠さない。
                // 語長や大小文字の状態は切り、次の字母との script 比較だけを持ち越す。
                let bridge = length > 0 && (p.category == .currencySymbol || p.category == .mathSymbol || p.category == .otherSymbol)
                let precedingScript = previous
                finish()
                if bridge { previous = precedingScript }
                return
            }
            // el の複合固有名では、語末形 ς の後の大文字が次の成分を始める。
            // 成分境界を大文字・sigma・tonos の各規則で共通に扱う。
            if greek, previousScalar == 0x3C2, p.script == .greek, p.upper { finish() }
            let a = previous
            let b = p.script
            if b == .latin { latinLetters += 1; if p.scalar > 127 { markedLatin += 1 } }
            if b == .cyrillic {
                cyrillicLetters += 1
                southSlavic = southSlavic || p.alphabetFlags.contains(.southSlavic)
                eastSlavic = eastSlavic || p.alphabetFlags.contains(.eastSlavic)
            }
            let aAlphabet = a == .latin || a == .cyrillic || a == .greek || a == .thai || a == .hebrew || a == .arabic
            let bAlphabet = b == .latin || b == .cyrillic || b == .greek || b == .thai || b == .hebrew || b == .arabic
            let existingPair = a == .latin || b == .latin || a == .cyrillic && b == .greek || a == .greek && b == .cyrillic
            let semiticPair = a == .hebrew || a == .arabic || b == .hebrew || b == .arabic
            if a != b, aAlphabet, bAlphabet, existingPair || semiticPair { penalty -= 2.5 }
            if letters > 0, p.upper { innerUpper += 1 }
            length += 1
            lowercase = lowercase || p.lower
            allUpper = allUpper && p.upper
            if b == .latin || b == .cyrillic || b == .greek {
                letters += 1
                if p.vowel || bulgarian && (p.scalar == 0x44A || p.scalar == 0x42A) { vowels += 1; consonants = 0 }
                else { consonants += 1; if consonants == 5 { longConsonants += 1 } }
            }
            terminalUpper = b == .latin && p.scalar > 127 && p.upper && previousLower
            previousLower = p.lower
            previous = b
            previousScalar = p.scalar
        }
    }

    static func letterRules(_ properties: [Traits], language: String? = nil) -> Double {
        var state = LetterRuleState(bulgarian: language == "bg", skipLatinDensity: language == "vi", greek: language == "el")
        for (offset, p) in properties.enumerated() {
            if (0x2500...0x25FF).contains(p.scalar), !cjkGeometricNotation(properties, at: offset) { state.penalty -= 3 }
            state.append(p)
        }
        state.finish()
        return state.penalty
    }
}
