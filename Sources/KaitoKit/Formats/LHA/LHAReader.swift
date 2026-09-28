import Foundation

/// Reader for the independent-member LHA/LZH container.
final class LHAReader: FormatReader {
    let format: ArchiveFormat = ArchiveFormat.lha
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let records: [LHAEntryRecord]
    private let firstHeaderOffset: UInt64
    private let terminator: LHAArchiveTerminator?
    private let unpublishedMembers: [LHAUnpublishedMember]

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
        self.firstHeaderOffset = parsed.firstHeaderOffset
        self.terminator = parsed.terminator
        self.unpublishedMembers = parsed.unpublishedMembers
    }

    private init(source: any ByteSource, entries: [ArchiveEntry],
                 nameEncoding: String.Encoding?, records: [LHAEntryRecord],
                 firstHeaderOffset: UInt64, terminator: LHAArchiveTerminator?,
                 unpublishedMembers: [LHAUnpublishedMember]) {
        self.source = source
        self.entries = entries
        self.nameEncoding = nameEncoding
        self.records = records
        self.firstHeaderOffset = firstHeaderOffset
        self.terminator = terminator
        self.unpublishedMembers = unpublishedMembers
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        LHAReader(source: source, entries: entries, nameEncoding: nameEncoding, records: records,
                  firstHeaderOffset: firstHeaderOffset, terminator: terminator,
                  unpublishedMembers: unpublishedMembers)
    }

    func rawLayout() throws -> LHAArchiveLayout? {
        guard let terminator else { return nil }
        let trailingBytes: LHATrailingBytes
        if case let .zeroByte(offset) = terminator {
            let tailOffset = try Checked.add(offset, 1)
            let count = try Checked.sub(source.length, tailOffset)
            if count == 0 {
                trailingBytes = .none
            } else if count > 65_536 {
                trailingBytes = .unchecked(count: count)
            } else {
                let bytes: [UInt8]
                // KaitoError passes through unchanged; any other error thrown by a
                // ByteSource implementation is reported as EIO. The first clause is
                // what keeps KaitoError out of the generic conversion below.
                do {
                    bytes = try readByteRange(source: source, offset: tailOffset, count: Int(count))
                } catch let error as KaitoError {
                    throw error
                } catch {
                    throw KaitoError.io(EIO)
                }
                trailingBytes = bytes.allSatisfy { $0 == 0 } ? .zeros(count: count) : .nonZero(count: count)
            }
        } else {
            trailingBytes = .notApplicable
        }
        return LHAArchiveLayout(
            archiveLength: source.length, firstHeaderOffset: firstHeaderOffset,
            terminator: terminator, trailingBytes: trailingBytes,
            records: records, unpublishedMembers: unpublishedMembers
        )
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        // The parser publishes entries and records in lockstep, so an entry
        // index also selects its record.
        let record = records[try recordIndex(of: entry, label: "LHA")]
        let rawDecoded = try makeDecompressor(
            record: record,
            entry: entry,
            limits: limits
        )
        // The parser clips recovered packed sizes to available source bytes, so
        // the -lh0- CopyDecompressor can read in bulk without recovery wrapping.
        let decoded: any Decompressor = entry.isIncomplete && record.method != "-lh0-"
            ? RecoveryDecompressor(rawDecoded, maximumOutputSize: record.uncompressedSize)
            : rawDecoded
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
