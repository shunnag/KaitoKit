// xar の公開形式説明・xar(1)、RFC 1950/1951、LZMA SDK lzma-specification.txt、
// XZ file-format spec に対応する利用者提供の実測 byte 表に基づくクリーンルーム実装。
// xar / libarchive / 7-Zip / XADMaster / The Unarchiver 等、他の archiver の source は参照していない。
import Foundation

enum XarChecksumStyle: String {
    case sha1, md5, sha256, sha512
}

enum XarEncoding: String {
    case stored = "application/octet-stream"
    case zlib = "application/x-gzip"
    case rfc6713Zlib = "application/zlib"
    case bzip2 = "application/x-bzip2"
    case lzma = "application/x-lzma"
    case xz = "application/x-xz"

    var description: String {
        switch self {
        case .stored: "xar (stored)"
        case .zlib, .rfc6713Zlib: "xar (zlib)"
        case .bzip2: "xar (bzip2)"
        case .lzma: "xar (lzma)"
        case .xz: "xar (xz)"
        }
    }
}

struct XarData {
    var offset: UInt64 = 0
    var length: UInt64 = 0
    var size: UInt64 = 0
    var encoding: String?
    var checksum: String?
    var checksumStyle: String?
}

struct XarFileNode {
    let parent: Int?
    var name: [UInt8] = []
    var type = "file"
    var hardlink: String?
    var symlink: String?
    var data: XarData?
    var fields: [String: String] = [:]
}

final class XarTOC {
    struct Checksum {
        let style: String?
        let offset: UInt64
        let size: UInt64
    }
    private(set) var files: [XarFileNode] = []
    private(set) var checksum: Checksum?
    private(set) var metadataSize: UInt64 = 0
    private let parser: XarXMLParser
    private let limits: ReadLimits

    init(bytes: [UInt8], limits: ReadLimits) throws {
        self.limits = limits
        parser = try XarXMLParser(bytes: bytes)
        var foundRoot = false
        while let event = try parser.next() {
            switch event {
            case .start(let tag, _):
                guard tag == "xar", !foundRoot else { throw KaitoError.malformed("xar toc root") }
                foundRoot = true
                var foundTOC = false
                try children { tag, _ in
                    if tag == "toc" {
                        guard !foundTOC else { throw KaitoError.malformed("xar duplicate toc") }
                        foundTOC = true
                        try self.readTOC()
                    } else { try self.parser.skip() }
                }
                guard foundTOC else { throw KaitoError.malformed("xar missing toc") }
            case .text: break
            case .end: throw KaitoError.malformed("xar toc root")
            }
        }
    }

    private func charge(_ size: UInt64) throws {
        metadataSize = try Checked.add(metadataSize, size)
        try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
    }

    private func children(_ body: (String, [String: String]) throws -> Void) throws {
        while let event = try parser.next() {
            switch event {
            case .start(let tag, let attrs): try body(tag, attrs)
            case .end: return
            case .text(let text):
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw KaitoError.malformed("xar toc unexpected text")
                }
            }
        }
        throw KaitoError.malformed("xar toc missing end")
    }

    private func readTOC() throws {
        try children { tag, attrs in
            switch tag {
            case "file": try self.readFile(parent: nil, attributes: attrs)
            case "checksum":
                guard self.checksum == nil else { throw KaitoError.malformed("xar duplicate checksum") }
                guard let style = attrs["style"], XarChecksumStyle(rawValue: style.lowercased()) != nil else {
                    try self.parser.skip(); return
                }
                var fields: [String: String] = [:]
                try self.children { child, _ in
                    if child == "offset" || child == "size" {
                        guard fields[child] == nil else { throw KaitoError.malformed("xar duplicate checksum field") }
                        fields[child] = try self.parser.text()
                    } else { try self.parser.skip() }
                }
                self.checksum = try Checksum(style: attrs["style"], offset: Self.number(fields["offset"]), size: Self.number(fields["size"]))
                try self.charge(UInt64(64 + (attrs["style"]?.utf8.count ?? 0)))
            default: try self.parser.skip()
            }
        }
    }

    private func readFile(parent: Int?, attributes: [String: String]) throws {
        guard files.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("xar entry count") }
        try charge(256)
        let index = files.count
        var node = XarFileNode(parent: parent)
        if let id = attributes["id"] { node.fields["fileID"] = id; try charge(UInt64(id.utf8.count)) }
        files.append(node)
        var seen = Set<String>()
        try children { tag, attrs in
            if tag == "file" {
                try self.readFile(parent: index, attributes: attrs)
                return
            }
            let known = ["name", "type", "link", "data", "mode", "mtime", "uid", "gid", "user", "group"]
            guard known.contains(tag) else { try self.parser.skip(); return }
            guard seen.insert(tag).inserted else { throw KaitoError.malformed("xar duplicate file field") }
            if tag == "data" { node.data = try self.readData(); return }
            let text = try self.parser.text()
            try self.charge(UInt64(text.utf8.count))
            switch tag {
            case "name":
                if attrs["enctype"] == "base64" {
                    let compact = text.filter { !$0.isWhitespace }
                    guard let decoded = Data(base64Encoded: compact) else { throw KaitoError.malformed("xar base64 name") }
                    node.name = Array(decoded)
                } else { node.name = Array(text.utf8) }
            case "type":
                node.type = text.trimmingCharacters(in: .whitespacesAndNewlines)
                node.hardlink = attrs["link"]
                try self.charge(UInt64(node.hardlink?.utf8.count ?? 0))
            case "link": node.symlink = text
            default: node.fields[tag] = text
            }
        }
        guard seen.contains("name"), !node.name.isEmpty, !node.name.contains(0) else { throw KaitoError.malformed("xar file name") }
        files[index] = node
    }

    private func readData() throws -> XarData {
        var data = XarData()
        var seen = Set<String>()
        try children { tag, attrs in
            guard ["offset", "length", "size", "encoding", "extracted-checksum"].contains(tag) else {
                try self.parser.skip(); return
            }
            guard seen.insert(tag).inserted else { throw KaitoError.malformed("xar duplicate data field") }
            let text = try self.parser.text()
            switch tag {
            case "offset": data.offset = try Self.number(text)
            case "length": data.length = try Self.number(text)
            case "size":
                data.size = try Self.number(text)
                guard data.size <= self.limits.maxEntrySize else { throw KaitoError.limitExceeded("xar entry size") }
            case "encoding": data.encoding = attrs["style"]
            case "extracted-checksum":
                data.checksum = text.trimmingCharacters(in: .whitespacesAndNewlines)
                data.checksumStyle = attrs["style"]
            default: break
            }
        }
        guard seen.isSuperset(of: ["offset", "length", "size"]) else { throw KaitoError.malformed("xar missing data field") }
        try charge(UInt64(96 + (data.encoding?.utf8.count ?? 0) + (data.checksum?.utf8.count ?? 0) + (data.checksumStyle?.utf8.count ?? 0)))
        return data
    }

    private static func number(_ text: String?) throws -> UInt64 {
        guard let text else { throw KaitoError.malformed("xar missing number") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(trimmed) else {
            throw KaitoError.malformed("xar decimal number")
        }
        return number
    }
}
