import Foundation

/// CUE sheet（CDRWIN 系の text。`FILE "name" BINARY` と `TRACK nn MODE1/2352` などの行）。公開の正式な仕様は
/// 無いので、`FILE` / `TRACK` の 2 つの keyword だけを読み、最初の data track（型が `MODE` で始まる）が属する
/// `FILE` を開く。URL で開いたときだけ兄弟 file を辿れる。
enum CueSheet {
    /// これより大きい text は cue sheet と見なさない。
    static let maximumSize: UInt64 = 1 << 20

    /// cue sheet の本文から data track の file 名（生 byte）を返す。cue sheet でなければ nil。
    static func dataTrackFileName(in bytes: [UInt8]) -> [UInt8]? {
        // text であること: 先頭 4 KiB に NUL や制御文字（tab / CR / LF 以外）が無い。
        for byte in bytes.prefix(4096) where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { return nil }
        var start = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        var firstFile: [UInt8]?
        var currentFile: [UInt8]?
        for line in bytes[start...].split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 })
            guard let keywordEnd = trimmed.firstIndex(where: { $0 == 0x20 || $0 == 0x09 }) else { continue }
            let keyword = String(decoding: trimmed[..<keywordEnd], as: UTF8.self).uppercased()
            let rest = trimmed[keywordEnd...].drop(while: { $0 == 0x20 || $0 == 0x09 })
            switch keyword {
            case "FILE":
                let name: ArraySlice<UInt8>
                if rest.first == UInt8(ascii: "\""), let close = rest.dropFirst().firstIndex(of: UInt8(ascii: "\"")) {
                    name = rest[(rest.startIndex + 1)..<close]
                } else {
                    name = rest.prefix(while: { $0 != 0x20 && $0 != 0x09 })
                }
                guard !name.isEmpty else { return nil }
                currentFile = Array(name)
                if firstFile == nil { firstFile = currentFile }
            case "TRACK":
                // `TRACK 01 MODE1/2352`: 番号の後ろの型。
                let type = rest.drop(while: { $0 != 0x20 && $0 != 0x09 }).drop(while: { $0 == 0x20 || $0 == 0x09 })
                if String(decoding: type.prefix(4), as: UTF8.self).uppercased() == "MODE", let currentFile {
                    return currentFile
                }
            default:
                continue
            }
        }
        return firstFile
    }

    /// URL で開いた file が cue sheet なら、その data track の file を同じ directory から開いて返す。
    /// cue sheet でなければ nil。参照先が無ければ `notFound`。
    static func assemble(
        url: URL?,
        source: any ByteSource,
        directory: FileByteSource.DirectoryAnchor?,
        limits: ReadLimits
    ) throws -> (any ByteSource)? {
        guard let url, let directory, source.length > 0, source.length <= maximumSize,
              url.pathExtension.lowercased() == "cue" else { return nil }
        let bytes = try readByteRange(source: source, offset: 0, count: Int(source.length))
        guard let rawName = dataTrackFileName(in: bytes) else { return nil }
        // path が付いていれば最後の要素だけを使う（CDRWIN は絶対 path を書くことがある）。
        let leaf = rawName.split(whereSeparator: { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "\\") }).last.map(Array.init) ?? rawName
        guard !leaf.isEmpty, leaf != [UInt8(ascii: ".")], leaf != [UInt8(ascii: "."), UInt8(ascii: ".")] else {
            throw KaitoError.malformed("cue sheet FILE name")
        }
        var candidates: [String] = []
        for encoding in [String.Encoding.utf8, .shiftJIS, .windowsCP1252] {
            if let name = String(bytes: leaf, encoding: encoding), !candidates.contains(name) { candidates.append(name) }
        }
        for name in candidates where name != url.lastPathComponent {
            if let opened = try directory.openRegularFile(named: name, label: "cue sheet") { return opened }
        }
        throw KaitoError.notFound("cue sheet FILE \(candidates.first ?? "?")")
    }
}
