// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表に基づくクリーンルーム実装。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。
import Foundation

final class XarXMLParser {
    enum Event {
        case start(String, [String: String])
        case end(String)
        case text(String)
    }
    private let bytes: [UInt8]
    private var position = 0
    private var stack: [String] = []
    private var pendingEnd: String?
    private var rootSeen = false
    private var declarationAllowed = true

    init(bytes: [UInt8]) throws {
        guard let string = String(bytes: bytes, encoding: .utf8),
              string.unicodeScalars.allSatisfy({ Self.validCharacter($0.value) }) else {
            throw KaitoError.malformed("xar toc UTF-8")
        }
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
    }

    func next() throws -> Event? {
        if let name = pendingEnd {
            pendingEnd = nil
            stack.removeLast()
            return .end(name)
        }
        while position < bytes.count {
            if bytes[position] != 60 {
                let start = position
                while position < bytes.count, bytes[position] != 60 { position += 1 }
                let raw = Array(bytes[start..<position])
                guard !raw.windowsContain(Array("]]>".utf8)) else { throw malformed() }
                let text = try decode(raw)
                if stack.isEmpty {
                    guard text.utf8.allSatisfy(Self.space) else { throw malformed() }
                }
                declarationAllowed = false
                return .text(text)
            }
            if consume("<!DOCTYPE") { throw KaitoError.malformed("xar toc doctype") }
            if consume("<!--") {
                let content = try until("-->")
                guard !content.windowsContain([45, 45]), content.last != 45 else { throw malformed() }
                declarationAllowed = false
                continue
            }
            if consume("<![CDATA[") {
                guard !stack.isEmpty else { throw malformed() }
                return .text(String(decoding: try until("]]>") , as: UTF8.self))
            }
            if consume("<?") {
                let target = try name()
                if target.lowercased() == "xml" {
                    guard target == "xml", declarationAllowed else { throw malformed() }
                    let attributes = try attributes(terminator: "?>")
                    if let encoding = attributes["encoding"], encoding.lowercased() != "utf-8" {
                        throw KaitoError.unsupportedFormat
                    }
                } else {
                    guard matches("?>") || (position < bytes.count && Self.space(bytes[position])) else { throw malformed() }
                    _ = try until("?>")
                }
                declarationAllowed = false
                continue
            }
            declarationAllowed = false
            if consume("</") {
                let name = try name()
                whitespace()
                guard consume(">"), stack.last == name else { throw malformed() }
                stack.removeLast()
                return .end(name)
            }
            guard consume("<") else { throw malformed() }
            let tag = try name()
            guard stack.count < 256 else { throw KaitoError.limitExceeded("xar toc depth") }
            if stack.isEmpty {
                guard !rootSeen else { throw malformed() }
                rootSeen = true
            }
            let attrs = try attributes(terminator: ">", allowsEmpty: true)
            stack.append(tag)
            if emptyTag { pendingEnd = tag }
            return .start(tag, attrs)
        }
        guard stack.isEmpty, rootSeen else { throw malformed() }
        return nil
    }

    // 未知要素も token 化して構文検証することで、subdoc 経由の DTD や偽 member を遮断する。
    func skip() throws {
        var depth = 1
        while let event = try next() {
            switch event {
            case .start: depth += 1
            case .end:
                depth -= 1
                if depth == 0 { return }
            case .text: break
            }
        }
        throw malformed()
    }

    func text() throws -> String {
        var value = ""
        while let event = try next() {
            switch event {
            case .text(let part): value += part
            case .end: return value
            case .start: throw malformed()
            }
        }
        throw malformed()
    }

    private var emptyTag = false
    private func attributes(terminator: String, allowsEmpty: Bool = false) throws -> [String: String] {
        var result: [String: String] = [:]
        emptyTag = false
        while true {
            let before = position
            whitespace()
            if consume(terminator) { return result }
            if allowsEmpty, consume("/>") { emptyTag = true; return result }
            guard position > before else { throw malformed() }
            let key = try name()
            whitespace()
            guard consume("=") else { throw malformed() }
            whitespace()
            guard position < bytes.count, bytes[position] == 34 || bytes[position] == 39 else { throw malformed() }
            let quote = bytes[position]
            position += 1
            let start = position
            while position < bytes.count, bytes[position] != quote {
                guard bytes[position] != 60 else { throw malformed() }
                position += 1
            }
            guard position < bytes.count, result[key] == nil else { throw malformed() }
            result[key] = try decode(Array(bytes[start..<position]))
            position += 1
        }
    }

    private func name() throws -> String {
        let start = position
        while position < bytes.count {
            let b = bytes[position]
            if b >= 128 || (65...90).contains(b) || (97...122).contains(b) || b == 95 || b == 58
                || (position > start && ((48...57).contains(b) || b == 45 || b == 46)) {
                position += 1
            } else { break }
        }
        guard position > start else { throw malformed() }
        let value = String(decoding: bytes[start..<position], as: UTF8.self)
        for (index, scalar) in value.unicodeScalars.enumerated() {
            let v = scalar.value
            let initial = v == 58 || v == 95 || (65...90).contains(v) || (97...122).contains(v)
                || (0xC0...0xD6).contains(v) || (0xD8...0xF6).contains(v) || (0xF8...0x2FF).contains(v)
                || (0x370...0x37D).contains(v) || (0x37F...0x1FFF).contains(v) || (0x200C...0x200D).contains(v)
                || (0x2070...0x218F).contains(v) || (0x2C00...0x2FEF).contains(v) || (0x3001...0xD7FF).contains(v)
                || (0xF900...0xFDCF).contains(v) || (0xFDF0...0xFFFD).contains(v) || (0x10000...0xEFFFF).contains(v)
            guard initial || (index > 0 && (v == 45 || v == 46 || (48...57).contains(v) || v == 0xB7
                || (0x300...0x36F).contains(v) || (0x203F...0x2040).contains(v))) else { throw malformed() }
        }
        return value
    }

    private func decode(_ raw: [UInt8]) throws -> String {
        var output: [UInt8] = []
        var i = 0
        while i < raw.count {
            if raw[i] != 38 { output.append(raw[i]); i += 1; continue }
            i += 1
            let start = i
            while i < raw.count, raw[i] != 59 { i += 1 }
            guard i < raw.count else { throw KaitoError.malformed("xar toc entity") }
            let entity = String(decoding: raw[start..<i], as: UTF8.self)
            let scalar: Unicode.Scalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                let hex = entity.hasPrefix("#x")
                let digits = entity.dropFirst(hex ? 2 : 1)
                guard entity.hasPrefix("#"), !digits.isEmpty,
                      digits.utf8.allSatisfy({ (48...57).contains($0) || (hex && ((65...70).contains($0) || (97...102).contains($0))) }),
                      let value = UInt32(digits, radix: hex ? 16 : 10), Self.validCharacter(value) else {
                    throw KaitoError.malformed("xar toc entity")
                }
                scalar = Unicode.Scalar(value)
            }
            guard let scalar else { throw KaitoError.malformed("xar toc entity") }
            output.append(contentsOf: String(scalar).utf8)
            i += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func validCharacter(_ value: UInt32) -> Bool {
        value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
    }
    private static func space(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    private func whitespace() { while position < bytes.count, Self.space(bytes[position]) { position += 1 } }
    private func matches(_ value: String) -> Bool { bytes[position...].starts(with: value.utf8) }
    private func consume(_ value: String) -> Bool {
        guard matches(value) else { return false }
        position += value.utf8.count
        return true
    }
    private func until(_ marker: String) throws -> [UInt8] {
        let start = position
        while position < bytes.count {
            if matches(marker) {
                let value = Array(bytes[start..<position])
                position += marker.utf8.count
                return value
            }
            position += 1
        }
        throw malformed()
    }
    private func malformed() -> KaitoError { .malformed("xar toc markup") }
}

private extension Array where Element == UInt8 {
    func windowsContain(_ sequence: [UInt8]) -> Bool {
        guard count >= sequence.count else { return false }
        return (0...(count - sequence.count)).contains { self[$0..<$0 + sequence.count].elementsEqual(sequence) }
    }
}
