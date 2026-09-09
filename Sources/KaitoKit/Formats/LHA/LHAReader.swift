import Foundation

/// Reader for the independent-member LHA/LZH container.
final class LHAReader: FormatReader {
    let format: ArchiveFormat = ArchiveFormat.lha
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let records: [LHAEntryRecord]

    init(
        source: any ByteSource,
        options: ReaderOptions,
        headerOffset: UInt64 = 0
    ) throws {
        let parsed = try LHAHeaderParser.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits,
            startOffset: headerOffset,
            recoverDamagedArchives: options.recoverDamagedArchives
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
        let rawDecoded = try makeDecompressor(
            record: record,
            entry: entry,
            limits: limits
        )
        let decoded: any Decompressor = entry.isIncomplete ? RecoveryDecompressor(
            rawDecoded, maximumOutputSize: record.uncompressedSize
        ) : rawDecoded
        let decompressor: any Decompressor
        let outputSize: UInt64
        let expectedCRC16: UInt16?
        if (record.headerLevel == 1 || record.headerLevel == 2),
           entry.kind != .directory,
           entry.formatSpecific["osID"] == "m" {
            // MacLHA marks level-1/2 members with the Macintosh OS ID. Its
            // normal mode wraps the body in MacBinary, while its `nm` mode
            // stores plain data under the same OS marker; the filter validates
            // the decoded prefix before deciding whether to unwrap it.
            let macBinary = try MacBinaryDataForkDecompressor(
                input: decoded,
                inputSize: record.uncompressedSize,
                expectedCRC16: entry.isIncomplete ? nil : record.crc16,
                entryIndex: entry.index,
                allowIncomplete: entry.isIncomplete
            )
            decompressor = entry.isIncomplete ? RecoveryDecompressor(
                macBinary, maximumOutputSize: macBinary.outputSize
            ) : macBinary
            outputSize = macBinary.outputSize
            // The LHA CRC covers the complete MacBinary envelope, not only the
            // exposed data fork, so the filter verifies it while draining.
            expectedCRC16 = nil
        } else {
            decompressor = decoded
            outputSize = record.uncompressedSize
            // LHA directory records carry no data, and established readers
            // ignore the nominal data-CRC field even when it is nonzero.
            expectedCRC16 = record.method == "-lhd-" ? nil : record.crc16
        }
        return try EntryStream(
            decompressor: decompressor,
            length: entry.isIncomplete ? nil : outputSize,
            expectedCRC32: nil,
            expectedCRC16: entry.isIncomplete ? nil : expectedCRC16,
            entryIndex: entry.index,
            limits: limits
        )
    }

    // Kept in one place so adding another documented LHA method does not
    // entangle header traversal with codec state.
    private func makeDecompressor(
        record: LHAEntryRecord,
        entry: ArchiveEntry,
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
        case "-lh4-", "-lh5-", "-lh6-", "-lh7-", "-lhx-":
            return try LZSStaticHuffmanDecoder(
                method: record.method,
                source: source,
                offset: record.dataOffset,
                compressedSize: record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                lhark: record.method == "-lh7-"
                    && entry.formatSpecific["os"] == "LHARK",
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
