import Foundation

/// 書庫内 path の `/` 区切り。空 component（連続する `/`、先頭・末尾の `/`）は数えず、残さない。
enum ArchivePath {
    /// component 数が `limit` を超えれば `.limitExceeded(label)`。分割せずに数えるので、
    /// 超過する path に配列を割り当てない。
    static func validateComponentCount(of path: String, limit: Int, label: String) throws {
        var count = 0
        var insideComponent = false
        for byte in path.utf8 {
            if byte == 0x2F {
                insideComponent = false
            } else if !insideComponent {
                guard count < limit else { throw KaitoError.limitExceeded(label) }
                count += 1
                insideComponent = true
            }
        }
    }

    /// 数を検査してから component に分ける。
    static func components(of path: String, limit: Int, label: String) throws -> [String] {
        try validateComponentCount(of: path, limit: limit, label: label)
        return path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
    /// hard link / file copy の照合用の相対 path。NUL・絶対 path・`..` は拒否し、
    /// `.` と重複する `/` だけを除く。OS 固有の名前変換は呼出側で先に行う。
    static func normalizedExtractionPath(_ path: String, components: [String]? = nil) -> String? {
        guard !path.isEmpty, path.utf8.first != 0x2F else { return nil }
        var previousWasSlash = false
        var repeatedSlash = false
        for byte in path.utf8 {
            guard byte != 0 else { return nil }
            let slash = byte == 0x2F
            repeatedSlash = repeatedSlash || (slash && previousWasSlash)
            previousWasSlash = slash
        }
        let rawComponents = components ?? path.utf8
            .split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !rawComponents.isEmpty, !rawComponents.contains("..") else { return nil }
        let hasDot = rawComponents.contains(".")
        // Ordinary member names already are the lookup key. Share their String
        // storage instead of allocating a second split/filter/join result.
        if !hasDot, !repeatedSlash, !previousWasSlash { return path }
        let normalized = rawComponents.lazy.filter { $0 != "." }.joined(separator: "/")
        return normalized.isEmpty ? nil : normalized
    }
}
