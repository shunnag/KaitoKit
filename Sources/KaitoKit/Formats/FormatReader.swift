import Foundation

// 形式実装と公開 Reader 層の間だけで使う最小契約。
protocol FormatReader: AnyObject {
    var format: ArchiveFormat { get }
    var entries: [ArchiveEntry] { get }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream
}
