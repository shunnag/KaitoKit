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
}
