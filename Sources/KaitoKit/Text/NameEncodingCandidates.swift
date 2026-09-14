import CoreFoundation
import Foundation

// 設計書「候補 encoding」「採点 1」: 外部推測器を使わず、厳密復号可能な候補だけを採点する。
enum NameEncodingCandidates {
    enum Form: Sendable { case single, cp932, eucJP, gb18030, big5, cp949 }

    struct Candidate: Sendable {
        let name: String
        let encoding: String.Encoding
        let languages: [String]
        let form: Form
        let isMac: Bool
        let singleByteTable: [[UInt32]?]
        let undefinedBytes: SIMD4<UInt64>

        var isJapanese: Bool { form == .cp932 || form == .eucJP }
        var isCJK: Bool { form != .single }

        init(_ name: String, _ languages: [String], _ form: Form = .single) {
            self.name = name
            self.languages = languages
            self.form = form
            isMac = name.contains("mac")
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            precondition(cf != kCFStringEncodingInvalidId)
            encoding = name == "cp932" ? .shiftJIS : String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cf)
            )
            // 設計書「採点 1」: static let の初期化時だけ CF に問い合わせる。
            // Mac の往復用タグのような複数 scalar も切り捨てない。
            singleByteTable = form == .single ? (0...255).map { value in
                if name.hasPrefix("iso-"), (0x80...0x9F).contains(value) { return nil }
                // CP1256 の CF 欠落8位置は Microsoft 表で採点だけを補う。reader の復号は変更しない。
                if name == "windows-1256", let scalar = NameEncodingCandidates.cp1256Supplement[UInt8(value)] { return [scalar] }
                var byte = UInt8(value)
                guard let decoded = CFStringCreateWithBytes(nil, &byte, 1, cf, false) else { return nil }
                let scalars = (decoded as String).unicodeScalars.map(\.value)
                // Mac Arabic/Farsi の CF が挿入する方向制御は文字の証拠に含めない。
                return name == "x-mac-arabic" || name == "x-mac-farsi"
                    ? scalars.filter { !(0x202A...0x202E).contains($0) && !(0x2066...0x2069).contains($0) } : scalars
            } : []
            var undefined = SIMD4<UInt64>.zero
            for byte in singleByteTable.indices where singleByteTable[byte] == nil {
                undefined[byte / 64] |= UInt64(1) << (byte % 64)
            }
            undefinedBytes = undefined
        }

        func decode(_ bytes: [UInt8]) -> String? {
            if form == .single {
                var output = String.UnicodeScalarView()
                output.reserveCapacity(bytes.count)
                for byte in bytes {
                    guard let scalars = singleByteTable[Int(byte)] else { return nil }
                    for scalar in scalars { output.append(Unicode.Scalar(scalar)!) }
                }
                return String(output)
            }
            guard structurallyValid(bytes) else { return nil }
            return EncodingDetector.decode(bytes: bytes, as: encoding)
        }

        func structurallyValid(_ bytes: [UInt8]) -> Bool {
            if form == .cp932 { return EncodingDetector.nameIsStructurallyJapanese(bytes, euc: false) }
            if form == .eucJP { return EncodingDetector.nameIsStructurallyJapanese(bytes, euc: true) }
            if form == .single { return bytes.allSatisfy { singleByteTable[Int($0)] != nil } }
            var index = 0
            while index < bytes.count {
                let lead = bytes[index]
                if lead < 0x80 { index += 1; continue }
                guard (0x81...0xFE).contains(lead), index + 1 < bytes.count else { return false }
                let trail = bytes[index + 1]
                switch form {
                case .gb18030:
                    if (0x30...0x39).contains(trail) {
                        guard index + 3 < bytes.count,
                              (0x81...0xFE).contains(bytes[index + 2]),
                              (0x30...0x39).contains(bytes[index + 3]) else { return false }
                        index += 4
                        continue
                    }
                    guard (0x40...0xFE).contains(trail), trail != 0x7F else { return false }
                case .big5:
                    guard (0x40...0x7E).contains(trail) || (0xA1...0xFE).contains(trail) else { return false }
                case .cp949:
                    guard (0x41...0x5A).contains(trail) || (0x61...0x7A).contains(trail)
                        || (0x81...0xFE).contains(trail) else { return false }
                default: return false
                }
                index += 2
            }
            return true
        }

        // 第4回レビュー D: ASCII の綴りに lead/trail が食い込む交差復号を byte 境界で検出する。
        func latinIntrusions(_ bytes: [UInt8]) -> [Double] { zones(bytes).map(\.latinIntrusion) }

        // 設計書「採点 2」: 区点配置だけを使い、記事名由来の統計は持たない。
        struct Zone {
            let score: Double
            let vendorIdeograph: Bool
            var latinIntrusion: Double = 0
        }
        func zoneScores(_ bytes: [UInt8]) -> [Double] { zones(bytes).map(\.score) }
        func zones(_ bytes: [UInt8]) -> [Zone] {
            var result: [Zone] = []
            var index = 0
            var previousASCII = false
            func asciiLetter(_ byte: Int) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
            while index < bytes.count, result.count < 256 {
                let lead = Int(bytes[index])
                if lead < 128 { result.append(Zone(score: 0, vendorIdeograph: false)); previousASCII = asciiLetter(lead); index += 1; continue }
                if form == .cp932, (0xA1...0xDF).contains(lead) {
                    result.append(Zone(score: 0, vendorIdeograph: false)); previousASCII = false; index += 1; continue
                }
                guard index + 1 < bytes.count else { break }
                let trail = Int(bytes[index + 1])
                var score = 0.0
                var length = 2
                switch form {
                case .cp932:
                    let row = (lead < 0xA0 ? lead - 0x81 : lead - 0xC1) * 2 + 1 + (trail >= 0x9F ? 1 : 0)
                    score = (16...47).contains(row) ? 2 : row >= 48 ? NameEncodingScorer.secondTierScore : 0
                case .eucJP:
                    if lead == 0x8E { score = 0 }
                    else if lead == 0x8F { score = NameEncodingScorer.secondTierScore; length = 3 }
                    else { score = (0xB0...0xCF).contains(lead) ? 2 : lead >= 0xD0 ? NameEncodingScorer.secondTierScore : 0 }
                case .gb18030:
                    if (0x30...0x39).contains(trail) { score = NameEncodingScorer.secondTierScore; length = 4 }
                    else { score = (0xB0...0xD7).contains(lead) && trail >= 0xA1 ? 2 : lead >= 0xA1 && lead <= 0xA9 && trail >= 0xA1 ? 0 : NameEncodingScorer.secondTierScore }
                case .big5:
                    let pair = lead * 256 + trail
                    score = (0xA440...0xC67E).contains(pair) ? 2 : (0xA140...0xA3BF).contains(pair) ? 0 : NameEncodingScorer.secondTierScore
                case .cp949:
                    if (0xB0...0xC8).contains(lead), trail >= 0xA1 { score = 2 }
                    else if (0xCA...0xFD).contains(lead), trail >= 0xA1 { score = NameEncodingScorer.secondTierScore }
                    else { score = 0.25 }
                case .single: break
                }
                // CP932 の NEC 選定 IBM・IBM 拡張漢字は JIS 第2水準ではなく、人名異体字を含む別の集合。
                // かな・数字・私用字は採点器の Unicode 分類が優先する。
                let vendor = form == .cp932 && ((0xED...0xEE).contains(lead) || (0xFA...0xFC).contains(lead))
                result.append(Zone(score: vendor ? 2 : score, vendorIdeograph: vendor, latinIntrusion: length == 2 && previousASCII && asciiLetter(trail) ? -2 : 0))
                previousASCII = false
                index += length
            }
            return result
        }
    }

    // Microsoft CP1256 の公開配置。CF 復号に適用する表ではない。
    static let cp1256Supplement: [UInt8: UInt32] = [
        0x8A: 0x0679, 0x8F: 0x0688, 0x98: 0x06A9, 0x9A: 0x0691,
        0x9F: 0x06BA, 0xAA: 0x06BE, 0xC0: 0x06C1, 0xFF: 0x06D2,
    ]

    // 設計書「採点 6」と変更履歴 c: 同点時の既定順位。HKSCS は CP950 復号失敗時だけ参加する。
    static let all: [Candidate] = [
        Candidate("cp932", ["ja"], .cp932), Candidate("euc-jp", ["ja"], .eucJP),
        Candidate("gb18030", ["zh"], .gb18030), Candidate("cp950", ["zh-Hant"], .big5),
        Candidate("cp949", ["ko"], .cp949), Candidate("big5-hkscs", ["zh-Hant"], .big5),
        Candidate("windows-1251", ["uk", "ru", "bg", "sr", "mk", "be"]), Candidate("koi8-u", ["uk", "ru", "bg", "sr", "mk", "be"]),
        Candidate("koi8-r", ["uk", "ru", "bg", "sr", "mk", "be"]), Candidate("cp866", ["uk", "ru", "bg", "sr", "mk", "be"]),
        Candidate("iso-8859-5", ["uk", "ru", "bg", "sr", "mk", "be"]), Candidate("x-mac-cyrillic", ["uk", "ru", "bg", "sr", "mk", "be"]),
        Candidate("windows-1252", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("windows-1250", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("iso-8859-15", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("macintosh", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("cp850", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("windows-1258", ["vi"]), Candidate("iso-8859-2", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("x-mac-centraleurroman", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]), Candidate("cp874", ["th"]),
        Candidate("windows-1253", ["el"]), Candidate("windows-1254", ["tr"]),
        Candidate("windows-1255", ["he"]), Candidate("windows-1256", ["ar", "fa"]),
        Candidate("windows-1257", ["lt", "lv", "et"]),
        // C-B: CF で扱える候補のみ。CP861 は CF の表が CP775 と同じため除外。
        Candidate("iso-8859-8", ["he"]),
        Candidate("cp862", ["he"]),
        Candidate("x-mac-hebrew", ["he"]),
        Candidate("iso-8859-6", ["ar", "fa"]),
        Candidate("cp864", ["ar", "fa"]),
        Candidate("x-mac-arabic", ["ar", "fa"]),
        Candidate("x-mac-farsi", ["ar", "fa"]),
        Candidate("iso-8859-4", ["lt", "lv", "et"]),
        Candidate("iso-8859-13", ["lt", "lv", "et"]),
        Candidate("cp775", ["lt", "lv", "et"]),
        Candidate("cp865", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("x-mac-icelandic", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("iso-8859-10", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("cp437", ["es", "pt", "fr", "de", "it", "en", "da", "nb", "sv", "fi", "is", "nl"]),
        Candidate("iso-8859-16", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("x-mac-romanian", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("cp852", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("x-mac-croatian", ["pl", "cs", "hu", "ro", "hr", "sl", "sk", "sr-Latn"]),
        Candidate("cp855", ["uk", "ru", "bg", "sr", "mk", "be"]),
        Candidate("x-mac-ukrainian", ["uk", "ru", "bg", "sr", "mk", "be"]),
        Candidate("iso-8859-7", ["el"]),
        Candidate("cp737", ["el"]),
        Candidate("cp869", ["el"]),
        Candidate("x-mac-greek", ["el"]),
        Candidate("iso-8859-9", ["tr"]),
        Candidate("cp857", ["tr"]),
        Candidate("x-mac-turkish", ["tr"]),
        Candidate("x-mac-thai", ["th"]),
    ]
}
