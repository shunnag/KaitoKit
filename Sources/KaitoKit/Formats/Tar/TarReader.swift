import Foundation

// POSIX ustar/pax と GNU tar 拡張の公開仕様だけを参照したクリーンルーム実装。
final class TarReader: FormatReader {
    let format: ArchiveFormat = .tar
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    private let records: [TarEntryRecord]
    private let source: any ByteSource
    let layoutStorage: TarLayoutStorage?

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        let parsed = try TarParser.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits,
            recoverDamagedArchives: options.recoverDamagedArchives,
            recordsLayout: options.recordsTarEditLayout
        )
        entries = parsed.entries
        nameEncoding = parsed.nameEncoding
        records = parsed.records
        layoutStorage = parsed.layout
    }

    private init(source: any ByteSource, entries: [ArchiveEntry],
                 nameEncoding: String.Encoding?, records: [TarEntryRecord], layoutStorage: TarLayoutStorage?) {
        self.source = source
        self.entries = entries
        self.nameEncoding = nameEncoding
        self.records = records
        self.layoutStorage = layoutStorage
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        TarReader(source: source, entries: entries, nameEncoding: nameEncoding, records: records, layoutStorage: layoutStorage)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        // entries と records は parse が同じ順に一つずつ積むので、entries の index で records も引ける。
        let record = records[try recordIndex(of: entry, label: "tar")]
        if let sparse = record.sparse {
            return try EntryStream(
                decompressor: TarSparseDecompressor(source: source, dataOffset: record.dataOffset, map: sparse),
                length: sparse.realSize, expectedCRC32: nil, entryIndex: entry.index, limits: limits
            )
        }
        return try EntryStream(
            source: source,
            offset: record.dataOffset,
            length: record.size,
            limits: limits
        )
    }
}
