import Foundation

/// UDF 専用 image（ISO 9660 構造を持たない）の reader。ISO 9660 との hybrid は `ISOReader` が同じ
/// `UDFFileSystem` を使う。
final class UDFReader: FormatReader {
    let format: ArchiveFormat = .udf
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = .utf8
    private let fileSystem: UDFFileSystem

    init(source: any ByteSource, options: ReaderOptions) throws {
        let source = try RawSectorByteSource.wrapUnlessPlainImage(source) ?? source
        fileSystem = try UDFFileSystem(source: source, options: options)
        entries = fileSystem.entries
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        try fileSystem.stream(for: entry, limits: limits)
    }
}
