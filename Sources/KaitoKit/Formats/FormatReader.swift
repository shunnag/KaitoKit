import Foundation

// 形式実装と公開 Reader 層の間だけで使う最小契約。
protocol FormatReader: AnyObject {
    var format: ArchiveFormat { get }
    var entries: [ArchiveEntry] { get }
    var nameEncoding: String.Encoding? { get }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream
    func setPassword(_ password: String?)
}

extension FormatReader {
    // 名前 encoding を持たない形式向けの既定値。
    var nameEncoding: String.Encoding? { nil }

    // 暗号を持たない形式は password 更新を無視する。
    func setPassword(_ password: String?) {}
}
