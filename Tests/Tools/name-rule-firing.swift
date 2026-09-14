import Foundation
import CoreFoundation

// 採点器と同じソースを単独コンパイルして使う、tune 発火率用の観測器。公開APIは増やさない。
// 引数: names.tsv。出力: ID、言語、発火した規則、未定義byteで除外される候補数。
@main struct NameRuleFiring {
    static func main() throws {
        let args = CommandLine.arguments
            let input = try String(contentsOfFile: args[1], encoding: .utf8)
            for line in input.split(separator: "\n").dropFirst() {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let properties = f[4].unicodeScalars.prefix(256).map { NameEncodingScorer.traits($0.value) }
                let repeated = NameEncodingScorer.repeatedScalars(properties)
                let filtered = properties.enumerated().map { repeated[$0.offset] ? NameEncodingScorer.traits(32) : $0.element }
                let orthography = NameEncodingScorer.additionalOrthography(filtered, language: f[1])
                var events = Set(orthography.violations.map(\.rule))
                if f[1] == "he", orthography.positive > 0 { events.insert("he-final-form-evidence") }
                if f[1] == "el", filtered.indices.contains(where: { $0 > 0 && filtered[$0 - 1].scalar == 0x3C2 && filtered[$0].script == .greek && filtered[$0].upper }) {
                    events.insert("el-compound-component-boundary")
                }
                for i in filtered.indices where filtered[i].scalar == 0x5E {
                    if NameEncodingScorer.symbolScore(filtered, at: i) == -5 { events.insert("caret-beside-letter") }
                }
                for i in filtered.indices where i > 0 && i + 1 < filtered.count {
                    let p = filtered[i]
                    if filtered[i - 1].letter, filtered[i + 1].letter,
                       p.category == .currencySymbol || p.category == .mathSymbol || p.category == .otherSymbol {
                        let a = filtered[i - 1].script, b = filtered[i + 1].script
                        let alphabet: [NameEncodingScorer.Script] = [.latin, .cyrillic, .greek, .thai, .hebrew, .arabic]
                        if a != b, alphabet.contains(a), alphabet.contains(b),
                           a == .latin || b == .latin || a == .cyrillic && b == .greek || a == .greek && b == .cyrillic
                            || a == .hebrew || b == .hebrew || a == .arabic || b == .arabic {
                            events.insert("symbol-bridged-script-mixture")
                        }
                    }
                    if filtered[i - 1].letter, filtered[i + 1].letter,
                       p.category == .openPunctuation || p.category == .closePunctuation { events.insert("bracket-between-letters") }
                    if filtered[i - 1].script == .hebrew || filtered[i - 1].script == .arabic || filtered[i + 1].script == .hebrew || filtered[i + 1].script == .arabic,
                       p.category != .openPunctuation, p.category != .closePunctuation,
                       NameEncodingScorer.symbolScore(filtered, at: i) == -2 { events.insert("semitic-symbol-between-letters") }
                }
                var wordLength = 0
                var latinLength = 0
                var nonASCIILatin = 0
                for p in filtered + [NameEncodingScorer.traits(32)] {
                    if p.letter {
                        wordLength += 1
                        if p.script == .latin { latinLength += 1; if p.scalar > 127 { nonASCIILatin += 1 } }
                    } else if !p.mark {
                        if f[1] != "vi", latinLength == wordLength, latinLength >= 6, nonASCIILatin * 3 > latinLength * 2 { events.insert("latin-diacritic-density") }
                        wordLength = 0; latinLength = 0; nonASCIILatin = 0
                    }
                }
                if f[1] == "bg", NameEncodingScorer.letterRules(filtered, language: "bg") != NameEncodingScorer.letterRules(filtered) { events.insert("bg-hard-sign-vowel") }
                if ["he", "ar", "fa"].contains(f[1]), filtered.contains(where: { NameEncodingScorer.frequent[f[1]]?.contains($0.scalar) == true }) { events.insert("semitic-frequent-bonus") }
                if f[1] == "ru", filtered.contains(where: { $0.scalar == 0x434 || $0.scalar == 0x414 }) { events.insert("ru-de-frequency-bonus") }
                if f[1] == "fa", filtered.contains(where: { $0.scalar == 0x64A || $0.scalar == 0x643 }) { events.insert("fa-compatible-main") }
                if f[1] == "ro", filtered.contains(where: { [UInt32(0x15E),0x15F,0x162,0x163].contains($0.scalar) }) { events.insert("ro-compatible-main") }
                if ["lt", "lv", "et", "ro", "hr", "sl", "sk", "da", "nb", "sv", "fi", "is", "nl", "sr-Latn", "bg", "sr", "mk", "be"].contains(f[1]),
                   filtered.contains(where: { $0.scalar > 127 && NameEncodingScorer.frequent[f[1]]?.contains($0.scalar) == true }) {
                    events.insert("identifying-letter-bonus-\(f[1])")
                }
                if ["es", "pt"].contains(f[1]), filtered.contains(where: { $0.scalar == 0xAA || $0.scalar == 0xBA }) { events.insert("ordinal-main") }
                if f[1] == "th" { events.formUnion(NameEncodingScorer.orthography(f[4], language: "th", maximumScalars: 256).violations.map(\.rule)) }
                for i in filtered.indices where i > 0 && filtered[i].scalar > 127 && filtered[i].script == .latin && filtered[i].upper && filtered[i - 1].lower && (i + 1 == filtered.count || !filtered[i + 1].letter) { events.insert("latin-terminal-uppercase") }
                var south = false
                var east = false
                for p in filtered + [NameEncodingScorer.traits(32)] {
                    if p.letter { south = south || p.alphabetFlags & 1 != 0; east = east || p.alphabetFlags & 2 != 0 }
                    else if !p.mark { if south && east { events.insert("cyrillic-south-east-mixture") }; south = false; east = false }
                }
                var letters = 0
                var cyrillic = 0
                var vowels = 0
                var lowercase = false
                for p in filtered + [NameEncodingScorer.traits(32)] {
                    if p.letter {
                        if [.latin, .cyrillic, .greek].contains(p.script) { letters += 1 }
                        if p.script == .cyrillic { cyrillic += 1 }
                        if p.vowel || f[1] == "bg" && (p.scalar == 0x44A || p.scalar == 0x42A) { vowels += 1 }
                        lowercase = lowercase || p.lower
                    } else if !p.mark {
                        if letters == 2 && cyrillic == 2 && vowels == 0 && lowercase { events.insert("cyrillic-two-consonants") }
                        letters = 0; cyrillic = 0; vowels = 0; lowercase = false
                    }
                }
                var previous = NameEncodingScorer.Script.other
                for p in filtered {
                    if p.letter {
                        if p.script != previous, previous != .other,
                           p.script == .hebrew || p.script == .arabic || previous == .hebrew || previous == .arabic {
                            if [.latin,.cyrillic,.greek,.thai,.hebrew,.arabic].contains(p.script),
                               [.latin,.cyrillic,.greek,.thai,.hebrew,.arabic].contains(previous) { events.insert("semitic-script-mixture") }
                        }
                        previous = p.script
                    } else if p.mark {
                        if previous == .latin, p.script == .hebrew || p.script == .arabic { events.insert("semitic-mark-after-latin") }
                    } else { previous = .other }
                }
                let chars = Array(f[3]); let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
                let present = NameEncodingScorer.ByteEvidence(bytes).present
                let excluded = NameEncodingCandidates.all.filter { $0.form == .single && ($0.undefinedBytes & present) != .zero }.count
                print("\(f[0])\t\(f[1])\t\(events.sorted().joined(separator: ","))\t\(excluded)")
            }
    }
}
