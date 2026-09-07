import Foundation

/// Reader for the independent-member LHA/LZH container.
final class LHAReader: FormatReader {
    let format: ArchiveFormat = ArchiveFormat.lha
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let records: [LHAEntryRecord]

    init(source: any ByteSource, options: ReaderOptions) throws {
        let parsed = try LHAHeaderParser.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits
        )
        self.source = source
        self.entries = parsed.entries
        self.nameEncoding = parsed.nameEncoding
        self.records = parsed.records
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0,
              entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("LHA entry index \(entry.index)")
        }
        let record = records[entry.index]
        let decompressor = try makeDecompressor(record: record, limits: limits)
        return try EntryStream(
            decompressor: decompressor,
            length: record.uncompressedSize,
            expectedCRC32: nil,
            // LHA directory records carry no data, and established readers
            // ignore the nominal data-CRC field even when it is nonzero.
            expectedCRC16: record.method == "-lhd-" ? nil : record.crc16,
            entryIndex: entry.index,
            limits: limits
        )
    }

    // Kept in one place so adding another documented LHA method does not
    // entangle header traversal with codec state.
    private func makeDecompressor(
        record: LHAEntryRecord,
        limits: ReadLimits
    ) throws -> any Decompressor {
        switch record.method {
        case "-lh0-", "-lz4-", "-pm0-", "-lhd-":
            return try CopyDecompressor(
                source: source,
                offset: record.dataOffset,
                compressedSize: record.compressedSize
            )
        case "-lh1-":
            return try LZHUFDecoder(
                source: source,
                offset: record.dataOffset,
                compressedSize: record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                limits: limits
            )
        case "-lh4-", "-lh5-", "-lh6-", "-lh7-":
            return try LZSStaticHuffmanDecoder(
                method: record.method,
                source: source,
                offset: record.dataOffset,
                compressedSize: record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                limits: limits
            )
        case "-lz5-", "-lzs-":
            return try LArcDecoder(
                source: source,
                offset: record.dataOffset,
                compressedSize: record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                method: record.method,
                limits: limits
            )
        case "-pm2-":
            throw KaitoError.unsupportedMethod("-pm2-")
        default:
            throw KaitoError.unsupportedMethod(record.method)
        }
    }
}
