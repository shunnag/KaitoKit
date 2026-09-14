import CoreFoundation
import Foundation
import KaitoKit

private struct NameDetectionError: Error, CustomStringConvertible {
    let description: String
}

private func ianaName(_ encoding: String.Encoding) throws -> String {
    // Foundation の別名をコーパスの表記に揃える。
    switch encoding {
    case .shiftJIS: return "cp932"
    case .japaneseEUC: return "euc-jp"
    case .isoLatin1: return "iso-8859-1"
    case .windowsCP1252: return "windows-1252"
    default:
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard let name = CFStringConvertEncodingToIANACharSetName(cfEncoding) else {
            throw NameDetectionError(description: "IANA name unavailable: \(encoding.rawValue)")
        }
        return (name as String).lowercased()
    }
}

private func encodingForIANA(_ name: String) throws -> String.Encoding {
    let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard value != kCFStringEncodingInvalidId else {
        throw NameDetectionError(description: "unknown IANA charset: \(name)")
    }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
}

private func nameDetectionEscape(_ text: String) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x5C: output += "\\\\"
        case 0x09: output += "\\t"
        case 0x0A: output += "\\n"
        case 0x0D: output += "\\r"
        case 0x7C: output += "\\|"
        case 0...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
            output += "\\u{\(String(scalar.value, radix: 16))}"
        default: output.unicodeScalars.append(scalar)
        }
    }
    return output
}

private func nameDetectionBytes(_ hex: Substring, line: Int) throws -> [UInt8] {
    let digits = Array(hex.utf8)
    func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
    guard digits.count.isMultiple(of: 2) else {
        throw NameDetectionError(description: "line \(line): odd-length hex")
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
        guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
            throw NameDetectionError(description: "line \(line): invalid hex")
        }
        bytes.append(high * 16 + low)
    }
    return bytes
}

func runDetectEncoding(_ arguments: [String]) throws {
    var archive = false
    var checkOrthography = false
    var language: String? = "ja"
    var hasLanguage = false
    var fromWindows = false
    var decodeEncoding: String.Encoding?
    var path: String?
    var index = 0
    let usage = "detect-encoding [--archive | --check-orthography] [--language <code> | --no-language] [--from-windows] [--decode <iana>] <tsv>"
    func invalid() -> NameDetectionError { NameDetectionError(description: usage) }
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        switch argument {
        case "--check-orthography":
            guard !checkOrthography else { throw invalid() }
            checkOrthography = true
        case "--archive":
            guard !archive else { throw invalid() }
            archive = true
        case "--language":
            guard !hasLanguage, index < arguments.count,
                  !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else { throw invalid() }
            hasLanguage = true
            language = arguments[index]
            index += 1
        case "--no-language":
            guard !hasLanguage else { throw invalid() }
            hasLanguage = true
            language = nil
        case "--from-windows":
            guard !fromWindows else { throw invalid() }
            fromWindows = true
        case "--decode":
            guard decodeEncoding == nil, index < arguments.count else { throw invalid() }
            decodeEncoding = try encodingForIANA(arguments[index])
            index += 1
        default:
            guard path == nil, !argument.hasPrefix("-") else { throw invalid() }
            path = argument
        }
    }
    guard let path, !(archive && decodeEncoding != nil),
          !(checkOrthography && (archive || decodeEncoding != nil)) else { throw invalid() }
    let policy = EncodingPolicy.automatic(likelyLanguage: language)
    let input = try String(contentsOfFile: path, encoding: .utf8)
    // TSV は引用符の特別扱いをしない。末尾の空の text も一つの欄として保持する。
    for (offset, rawLine) in input.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
        if line.isEmpty { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if offset == 0,
           line == (archive ? "group\tlang\ttruth_iana\tk\thex1,hex2,..." : "id\tlang\ttruth_iana\thex\ttext") {
            continue
        }
        guard fields.count == 5, !fields[0].isEmpty else {
            throw NameDetectionError(description: "line \(offset + 1): expected five TSV fields")
        }
        if checkOrthography {
            for violation in EncodingDetector.checkNameOrthography(String(fields[4]), language: String(fields[1])) {
                print("\(fields[0])\t\(violation.rule)\t\(violation.offset)\tU+\(String(violation.scalar, radix: 16, uppercase: true))\t\(nameDetectionEscape(String(fields[4])))")
            }
        } else if archive {
            guard let k = Int(fields[3]), k > 0 else {
                throw NameDetectionError(description: "line \(offset + 1): invalid k")
            }
            let names = try fields[4].split(separator: ",", omittingEmptySubsequences: false).map {
                try nameDetectionBytes($0, line: offset + 1)
            }
            // k は非 ASCII 名の数。混ぜた ASCII 名は追加の構成員として扱う。
            guard names.count >= k else {
                throw NameDetectionError(description: "line \(offset + 1): fewer names than k")
            }
            let encoding = EncodingDetector.detectArchiveEncoding(names: names, policy: policy, fromWindows: fromWindows)
            var fallbackCount = 0
            let decoded = names.map { bytes in
                let isUTF8 = EncodingDetector.decode(bytes: bytes, as: .utf8) != nil
                if !isUTF8, encoding.flatMap({ EncodingDetector.decode(bytes: bytes, as: $0) }) == nil {
                    fallbackCount += 1
                }
                return nameDetectionEscape(EncodingDetector.resolveUndeclaredNameForMeasurement(
                    bytes: bytes, policy: policy, archiveEncoding: encoding, fromWindows: fromWindows
                ).string)
            }
            print("\(fields[0])\t\(try ianaName(encoding ?? .utf8))\t\(fallbackCount)\t\(decoded.joined(separator: "|"))")
        } else {
            let bytes = try nameDetectionBytes(fields[3], line: offset + 1)
            if let decodeEncoding {
                if let decoded = EncodingDetector.decode(bytes: bytes, as: decodeEncoding) {
                    // Swift の正準等価比較を避け、測定側と同じ scalar の完全一致で判定する。
                    let equal = decoded.unicodeScalars.elementsEqual(fields[4].unicodeScalars)
                    print("\(fields[0])\t\(equal ? "OK" : "MISMATCH")\t\(nameDetectionEscape(decoded))")
                } else {
                    print("\(fields[0])\tFAIL\t")
                }
            } else {
                let result = EncodingDetector.detect(bytes: bytes, policy: policy, fromWindows: fromWindows)
                let confidence = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), result.confidence)
                print("\(fields[0])\t\(try ianaName(result.encoding))\t\(confidence)\t\(nameDetectionEscape(result.string))")
            }
        }
    }
}
