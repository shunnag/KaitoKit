import CoreFoundation
import Foundation

// Clean-room container parser based on Masaru Oki's public LHa for UNIX
// `header.doc` (translated by Koji Arai), the same project's public README
// extension notes, and the task's clean-room grammar. These define levels 0-3,
// the portable/Unix extension chain, and the interoperable Windows-time and
// 64-bit-size extensions. Lhasa was used only as a black-box oracle.

struct LHAEntryRecord {
    let method: String
    let dataOffset: UInt64
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc16: UInt16
    let headerLevel: UInt8

    init(
        method: String,
        dataOffset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        crc16: UInt16,
        headerLevel: UInt8
    ) {
        self.method = method
        self.dataOffset = dataOffset
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.crc16 = crc16
        self.headerLevel = headerLevel
    }
}

struct LHAParsedArchive {
    let entries: [ArchiveEntry]
    let records: [LHAEntryRecord]
    let nameEncoding: String.Encoding?

    init(
        entries: [ArchiveEntry],
        records: [LHAEntryRecord],
        nameEncoding: String.Encoding?
    ) {
        self.entries = entries
        self.records = records
        self.nameEncoding = nameEncoding
    }
}

enum LHAHeaderParser {
    private static let minimumCommonPrefixSize = 21
    private static let level0MinimumHeaderSize = 24
    private static let level1MinimumHeaderSize = 27
    private static let level2MinimumHeaderSize = 26
    private static let level3MinimumHeaderSize = 32
    private static let larcMethods: Set<String> = ["-lzs-", "-lz4-", "-lz5-"]

    private struct ExtendedFields {
        var headerCRC16: UInt16?
        var headerCRCFieldOffset: Int?
        var filename: [UInt8]?
        var directory: [UInt8]?
        var comment: [UInt8]?
        var dosAttributes: UInt16?
        var windowsCreationDate: Date?
        var windowsModificationDate: Date?
        var windowsAccessDate: Date?
        var compressedSize64: UInt64?
        var uncompressedSize64: UInt64?
        var codePage: UInt32?
        var unixMode: UInt16?
        var gid: UInt16?
        var uid: UInt16?
        var group: [UInt8]?
        var user: [UInt8]?
        var unixModificationDate: Date?

        init() {}
    }

    private struct ParsedHeader {
        let pending: PendingEntry
        let record: LHAEntryRecord
        let nextOffset: UInt64
        let extensionRecordCount: Int

        init(
            pending: PendingEntry,
            record: LHAEntryRecord,
            nextOffset: UInt64,
            extensionRecordCount: Int
        ) {
            self.pending = pending
            self.record = record
            self.nextOffset = nextOffset
            self.extensionRecordCount = extensionRecordCount
        }
    }

    private struct PendingEntry {
        let rawName: [UInt8]
        let declaredEncoding: String.Encoding?
        let method: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let modificationDate: Date?
        let permissions: UInt16?
        let crc16: UInt16
        let headerLevel: UInt8
        let osID: UInt8?
        let fromWindows: Bool
        let attribute: UInt8
        let directoryHint: Bool
        let extended: ExtendedFields
        let headerOffset: UInt64
        let dataOffset: UInt64

        init(
            rawName: [UInt8],
            declaredEncoding: String.Encoding?,
            method: String,
            compressedSize: UInt64,
            uncompressedSize: UInt64,
            modificationDate: Date?,
            permissions: UInt16?,
            crc16: UInt16,
            headerLevel: UInt8,
            osID: UInt8?,
            fromWindows: Bool,
            attribute: UInt8,
            directoryHint: Bool,
            extended: ExtendedFields,
            headerOffset: UInt64,
            dataOffset: UInt64
        ) {
            self.rawName = rawName
            self.declaredEncoding = declaredEncoding
            self.method = method
            self.compressedSize = compressedSize
            self.uncompressedSize = uncompressedSize
            self.modificationDate = modificationDate
            self.permissions = permissions
            self.crc16 = crc16
            self.headerLevel = headerLevel
            self.osID = osID
            self.fromWindows = fromWindows
            self.attribute = attribute
            self.directoryHint = directoryHint
            self.extended = extended
            self.headerOffset = headerOffset
            self.dataOffset = dataOffset
        }
    }

    static func parse(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits,
        startOffset: UInt64 = 0
    ) throws -> LHAParsedArchive {
        var pendingEntries: [PendingEntry?] = []
        var records: [LHAEntryRecord] = []
        guard startOffset <= source.length else { throw KaitoError.truncated }
        var offset = startOffset
        var foundEndMarker = false
        var sawAnonymousRegularMember = false
        var totalExtensionRecords = 0
        var retainedPendingMetadataSize: UInt64 = 0
        var reader = try ByteReader(source: source)

        while offset < source.length {
            try reader.seek(to: offset)
            let firstByte = try reader.readUInt8()
            if firstByte == 0 {
                foundEndMarker = true
                break
            }

            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= UInt64(minimumCommonPrefixSize) else {
                throw KaitoError.truncated
            }
            let prefixCount = try Checked.toInt(min(remaining, 26))
            let prefix = try readByteRange(
                source: source,
                offset: offset,
                count: prefixCount
            )
            let level = prefix[20]
            let parsed: ParsedHeader
            switch level {
            case 0:
                parsed = try parseLevel0(
                    source: source,
                    offset: offset,
                    firstByte: firstByte,
                    limits: limits
                )
            case 1:
                parsed = try parseLevel1(
                    source: source,
                    offset: offset,
                    firstByte: firstByte,
                    limits: limits
                )
            case 2:
                parsed = try parseLevel2(
                    source: source,
                    offset: offset,
                    limits: limits
                )
            case 3:
                parsed = try parseLevel3(
                    source: source,
                    offset: offset,
                    limits: limits
                )
            default:
                throw KaitoError.malformed("unsupported LHA header level \(level)")
            }

            // Legacy readers treat an empty-name -lhd- member as a benign
            // archive terminator. Two historical writers emitted such a root
            // record before otherwise unreachable bytes; matching that rule
            // avoids inventing a filesystem name or exposing the tail.
            if parsed.pending.method == "-lhd-", parsed.pending.rawName.isEmpty {
                foundEndMarker = true
                break
            }
            if parsed.pending.rawName.isEmpty {
                sawAnonymousRegularMember = true
            }

            guard pendingEntries.count < limits.maxEntryCount else {
                throw KaitoError.limitExceeded("archive entry count")
            }
            let (newRecordCount, recordCountOverflow) = totalExtensionRecords
                .addingReportingOverflow(parsed.extensionRecordCount)
            guard !recordCountOverflow,
                  newRecordCount <= limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            totalExtensionRecords = newRecordCount

            guard parsed.nextOffset > offset else {
                throw KaitoError.malformed("LHA member made no forward progress")
            }
            retainedPendingMetadataSize = try Checked.add(
                retainedPendingMetadataSize,
                pendingMetadataCost(parsed.pending)
            )
            try Checked.size(
                retainedPendingMetadataSize,
                limit: limits.maxTotalMetadataSize
            )
            pendingEntries.append(parsed.pending)
            records.append(parsed.record)
            offset = parsed.nextOffset
        }

        // The documented LArc methods may end exactly after their final
        // bounded payload instead of appending LHA's conventional zero byte.
        // One historical compatibility archive also contains structurally
        // valid, anonymous regular members that are deliberately omitted from
        // publication and ends at a named non-LArc payload; preserve that
        // narrow shape without accepting an ordinary unterminated LHA archive.
        if offset == source.length,
           let finalMethod = records.last?.method,
           larcMethods.contains(finalMethod) || sawAnonymousRegularMember {
            foundEndMarker = true
        }
        guard foundEndMarker else { throw KaitoError.truncated }
        return try publish(
            pendingEntries: &pendingEntries,
            records: records,
            policy: policy,
            limits: limits
        )
    }

    private static func parseLevel0(
        source: any ByteSource,
        offset: UInt64,
        firstByte: UInt8,
        limits: ReadLimits
    ) throws -> ParsedHeader {
        let totalHeaderSize = try Checked.add(UInt64(firstByte), 2)
        guard totalHeaderSize >= UInt64(level0MinimumHeaderSize) else {
            throw KaitoError.malformed("LHA level-0 header is too short")
        }
        try Checked.size(totalHeaderSize, limit: limits.maxMetadataSize)
        let header = try readHeaderBytes(
            source: source,
            offset: offset,
            size: totalHeaderSize
        )
        try validateByteChecksum(header, level: 0)
        guard header[20] == 0 else {
            throw KaitoError.malformed("LHA header level changed inside its base header")
        }

        let method = try parseMethod(header)
        let packedSize = UInt64(littleUInt32(header, at: 7))
        let originalSize = UInt64(littleUInt32(header, at: 11))
        try validateEntrySizes(
            compressed: packedSize,
            uncompressed: originalSize,
            limits: limits
        )

        let nameLength = Int(header[21])
        let crcOffset = 22 + nameLength
        guard crcOffset >= 22, crcOffset <= header.count - 2 else {
            throw KaitoError.malformed("LHA level-0 name overruns its header")
        }
        let rawName = Array(header[22..<crcOffset])
        let crc16 = littleUInt16(header, at: crcOffset)
        let osOffset = crcOffset + 2
        // In a level-0 header, any byte following the data CRC is the creator
        // OS ID. Preserve unknown and less-common IDs instead of discarding
        // the encoding hint and diagnostic metadata.
        let osID: UInt8? = osOffset < header.count ? header[osOffset] : nil
        let canonicalName = try canonicalRawName(
            filename: rawName,
            directory: nil
        )
        let modificationDate = try dosDate(littleUInt32(header, at: 15))
        let dataOffset = try Checked.add(offset, totalHeaderSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: packedSize,
            sourceLength: source.length
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: packedSize,
            uncompressedSize: originalSize
        )

        let extended = ExtendedFields()
        let pending = PendingEntry(
            rawName: canonicalName,
            declaredEncoding: nil,
            method: method,
            compressedSize: packedSize,
            uncompressedSize: originalSize,
            modificationDate: modificationDate,
            permissions: nil,
            crc16: crc16,
            headerLevel: 0,
            osID: osID,
            fromWindows: osID.map(isWindowsLikeOS) ?? true,
            attribute: header[19],
            directoryHint: method == "-lhd-" || (header[19] & 0x10) != 0,
            extended: extended,
            headerOffset: offset,
            dataOffset: dataOffset
        )
        return ParsedHeader(
            pending: pending,
            record: LHAEntryRecord(
                method: method,
                dataOffset: dataOffset,
                compressedSize: packedSize,
                uncompressedSize: originalSize,
                crc16: crc16,
                headerLevel: 0
            ),
            nextOffset: nextOffset,
            extensionRecordCount: 0
        )
    }

    private static func parseLevel1(
        source: any ByteSource,
        offset: UInt64,
        firstByte: UInt8,
        limits: ReadLimits
    ) throws -> ParsedHeader {
        let baseHeaderSize = try Checked.add(UInt64(firstByte), 2)
        guard baseHeaderSize >= UInt64(level1MinimumHeaderSize) else {
            throw KaitoError.malformed("LHA level-1 base header is too short")
        }
        try Checked.size(baseHeaderSize, limit: limits.maxMetadataSize)
        let base = try readHeaderBytes(
            source: source,
            offset: offset,
            size: baseHeaderSize
        )
        try validateByteChecksum(base, level: 1)
        guard base[20] == 1 else {
            throw KaitoError.malformed("LHA header level changed inside its base header")
        }

        let method = try parseMethod(base)
        let skipSize = UInt64(littleUInt32(base, at: 7))
        let originalSize32 = UInt64(littleUInt32(base, at: 11))
        let nameLength = Int(base[21])
        let crcOffset = 22 + nameLength
        // CRC16, OS ID, and the first two-byte extension length must all fit.
        guard crcOffset >= 22, crcOffset <= base.count - 5 else {
            throw KaitoError.malformed("LHA level-1 name overruns its base header")
        }
        let baseFilename = Array(base[22..<crcOffset])
        let crc16 = littleUInt16(base, at: crcOffset)
        let osID = base[crcOffset + 2]
        let firstExtensionSize = littleUInt16(base, at: base.count - 2)

        let baseEnd = try Checked.add(offset, baseHeaderSize)
        var fields = ExtendedFields()
        let extensionResult = try readLevel1Extensions(
            source: source,
            offset: baseEnd,
            firstSize: firstExtensionSize,
            skipSize: skipSize,
            base: base,
            fields: &fields,
            limits: limits
        )
        try validateHeaderCRCIfPresent(
            extensionResult.headerBytes,
            fields: fields
        )

        let compressedSize: UInt64
        if let extendedSize = fields.compressedSize64 {
            compressedSize = extendedSize
        } else {
            guard extensionResult.totalSize <= skipSize else {
                throw KaitoError.malformed("LHA level-1 extensions exceed the skip size")
            }
            compressedSize = try Checked.sub(skipSize, extensionResult.totalSize)
        }
        let uncompressedSize = fields.uncompressedSize64 ?? originalSize32
        try validateEntrySizes(
            compressed: compressedSize,
            uncompressed: uncompressedSize,
            limits: limits
        )

        let filename = fields.filename ?? baseFilename
        let canonicalName = try canonicalRawName(
            filename: filename,
            directory: fields.directory
        )
        let declaredEncoding = declaredEncoding(for: fields.codePage)
        let baseModificationDate = try dosDate(littleUInt32(base, at: 15))
        let modificationDate = fields.unixModificationDate
            ?? fields.windowsModificationDate
            ?? baseModificationDate
        let permissions = posixPermissions(fields.unixMode, osID: osID)
        let dataOffset = try Checked.add(baseEnd, extensionResult.totalSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: compressedSize,
            sourceLength: source.length
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        let pending = PendingEntry(
            rawName: canonicalName,
            declaredEncoding: declaredEncoding,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            headerLevel: 1,
            osID: osID,
            fromWindows: isWindowsLikeOS(osID),
            attribute: base[19],
            directoryHint: method == "-lhd-"
                || (base[19] & 0x10) != 0
                || hasDOSDirectoryAttribute(fields),
            extended: fields,
            headerOffset: offset,
            dataOffset: dataOffset
        )
        return ParsedHeader(
            pending: pending,
            record: LHAEntryRecord(
                method: method,
                dataOffset: dataOffset,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc16: crc16,
                headerLevel: 1
            ),
            nextOffset: nextOffset,
            extensionRecordCount: extensionResult.recordCount
        )
    }

    private static func parseLevel2(
        source: any ByteSource,
        offset: UInt64,
        limits: ReadLimits
    ) throws -> ParsedHeader {
        let sizeBytes = try readByteRange(source: source, offset: offset, count: 2)
        let declaredHeaderSize = UInt64(littleUInt16(sizeBytes, at: 0))
        guard declaredHeaderSize >= UInt64(level2MinimumHeaderSize) else {
            throw KaitoError.malformed("LHA level-2 header is too short")
        }
        try Checked.size(declaredHeaderSize, limit: limits.maxMetadataSize)
        let available = try Checked.sub(source.length, offset)
        guard declaredHeaderSize <= available else { throw KaitoError.truncated }
        let declaredHeader = try readHeaderBytes(
            source: source,
            offset: offset,
            size: declaredHeaderSize
        )
        guard declaredHeader[20] == 2 else {
            throw KaitoError.malformed("LHA header level changed inside its base header")
        }

        let method = try parseMethod(declaredHeader)
        let packedSize32 = UInt64(littleUInt32(declaredHeader, at: 7))
        let originalSize32 = UInt64(littleUInt32(declaredHeader, at: 11))
        let crc16 = littleUInt16(declaredHeader, at: 21)
        let osID = declaredHeader[23]
        let toleratedHeaderSize = try Checked.add(declaredHeaderSize, 2)
        let candidate: [UInt8]
        if osID == 0x4B, toleratedHeaderSize <= available {
            candidate = try readHeaderBytes(
                source: source,
                offset: offset,
                size: toleratedHeaderSize
            )
        } else {
            candidate = declaredHeader
        }
        var fields = ExtendedFields()
        let extensionResult = try parseLevel2Extensions(
            candidate,
            fields: &fields,
            limits: limits
        )
        let effectiveHeaderSize: UInt64
        if UInt64(extensionResult.endOffset) <= declaredHeaderSize {
            effectiveHeaderSize = declaredHeaderSize
        } else {
            // The supplied OS-9 LHA 2.01 archives use creator ID 'K' (0x4B,
            // conventionally labeled OS/68K) and omit the terminating two-byte
            // next-size field from level 2's declared total while writing it.
            // Accept only that exact signature and boundary.
            let declaredEnd = try Checked.toInt(declaredHeaderSize)
            guard osID == 0x4B,
                  UInt64(candidate.count) == toleratedHeaderSize,
                  UInt64(extensionResult.endOffset) == toleratedHeaderSize,
                  candidate[declaredEnd] == 0,
                  candidate[declaredEnd + 1] == 0 else {
                throw KaitoError.malformed(
                    "LHA level-2 extension overruns the total header"
                )
            }
            effectiveHeaderSize = toleratedHeaderSize
            try Checked.size(effectiveHeaderSize, limit: limits.maxMetadataSize)
        }
        let authenticatedHeader = Array(
            candidate.prefix(try Checked.toInt(effectiveHeaderSize))
        )
        try validateHeaderCRCIfPresent(
            authenticatedHeader,
            fields: fields
        )

        let compressedSize = fields.compressedSize64 ?? packedSize32
        let uncompressedSize = fields.uncompressedSize64 ?? originalSize32
        try validateEntrySizes(
            compressed: compressedSize,
            uncompressed: uncompressedSize,
            limits: limits
        )
        let canonicalName = try canonicalRawName(
            filename: fields.filename ?? [],
            directory: fields.directory
        )
        let declaredEncoding = declaredEncoding(for: fields.codePage)
        let baseModificationDate = Date(
            timeIntervalSince1970: Double(littleUInt32(candidate, at: 15))
        )
        // The Windows-time extension is defined as a level-1 override. At
        // level 2 the base field is already Unix time, so retain 0x41's
        // creation/access metadata but do not replace that modification time.
        let modificationDate = fields.unixModificationDate
            ?? baseModificationDate
        let permissions = posixPermissions(fields.unixMode, osID: osID)
        let dataOffset = try Checked.add(offset, effectiveHeaderSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: compressedSize,
            sourceLength: source.length
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        let pending = PendingEntry(
            rawName: canonicalName,
            declaredEncoding: declaredEncoding,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            headerLevel: 2,
            osID: osID,
            fromWindows: isWindowsLikeOS(osID),
            attribute: declaredHeader[19],
            directoryHint: method == "-lhd-"
                || (declaredHeader[19] & 0x10) != 0
                || hasDOSDirectoryAttribute(fields),
            extended: fields,
            headerOffset: offset,
            dataOffset: dataOffset
        )
        return ParsedHeader(
            pending: pending,
            record: LHAEntryRecord(
                method: method,
                dataOffset: dataOffset,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc16: crc16,
                headerLevel: 2
            ),
            nextOffset: nextOffset,
            extensionRecordCount: extensionResult.recordCount
        )
    }

    private static func parseLevel3(
        source: any ByteSource,
        offset: UInt64,
        limits: ReadLimits
    ) throws -> ParsedHeader {
        let base = try readHeaderBytes(
            source: source,
            offset: offset,
            size: UInt64(level3MinimumHeaderSize)
        )
        guard littleUInt16(base, at: 0) == 4 else {
            throw KaitoError.malformed("invalid LHA level-3 size-field width")
        }
        guard base[20] == 3 else {
            throw KaitoError.malformed("LHA header level changed inside its base header")
        }
        let totalHeaderSize = UInt64(littleUInt32(base, at: 24))
        guard totalHeaderSize >= UInt64(level3MinimumHeaderSize) else {
            throw KaitoError.malformed("LHA level-3 header is too short")
        }
        try Checked.size(totalHeaderSize, limit: limits.maxMetadataSize)
        let header = try readHeaderBytes(
            source: source,
            offset: offset,
            size: totalHeaderSize
        )

        let method = try parseMethod(header)
        let packedSize32 = UInt64(littleUInt32(header, at: 7))
        let originalSize32 = UInt64(littleUInt32(header, at: 11))
        let crc16 = littleUInt16(header, at: 21)
        let osID = header[23]
        var fields = ExtendedFields()
        let extensionRecordCount = try parseLevel3Extensions(
            header,
            fields: &fields,
            limits: limits
        )
        try validateHeaderCRCIfPresent(header, fields: fields)

        let compressedSize = fields.compressedSize64 ?? packedSize32
        let uncompressedSize = fields.uncompressedSize64 ?? originalSize32
        try validateEntrySizes(
            compressed: compressedSize,
            uncompressed: uncompressedSize,
            limits: limits
        )
        let canonicalName = try canonicalRawName(
            filename: fields.filename ?? [],
            directory: fields.directory
        )
        let modificationDate = fields.unixModificationDate ?? Date(
            timeIntervalSince1970: Double(littleUInt32(header, at: 15))
        )
        let permissions = posixPermissions(fields.unixMode, osID: osID)
        let dataOffset = try Checked.add(offset, totalHeaderSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: compressedSize,
            sourceLength: source.length
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        let pending = PendingEntry(
            rawName: canonicalName,
            declaredEncoding: declaredEncoding(for: fields.codePage),
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            headerLevel: 3,
            osID: osID,
            fromWindows: isWindowsLikeOS(osID),
            attribute: header[19],
            directoryHint: method == "-lhd-"
                || (header[19] & 0x10) != 0
                || hasDOSDirectoryAttribute(fields),
            extended: fields,
            headerOffset: offset,
            dataOffset: dataOffset
        )
        return ParsedHeader(
            pending: pending,
            record: LHAEntryRecord(
                method: method,
                dataOffset: dataOffset,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc16: crc16,
                headerLevel: 3
            ),
            nextOffset: nextOffset,
            extensionRecordCount: extensionRecordCount
        )
    }

    private static func readLevel1Extensions(
        source: any ByteSource,
        offset: UInt64,
        firstSize: UInt16,
        skipSize: UInt64,
        base: [UInt8],
        fields: inout ExtendedFields,
        limits: ReadLimits
    ) throws -> (totalSize: UInt64, recordCount: Int, headerBytes: [UInt8]) {
        var currentSize = UInt64(firstSize)
        var currentOffset = offset
        var totalSize: UInt64 = 0
        var recordCount = 0
        var fullHeader = base

        while currentSize != 0 {
            guard currentSize >= 3 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            let nextTotalSize = try Checked.add(totalSize, currentSize)
            let fullMetadataSize = try Checked.add(UInt64(base.count), nextTotalSize)
            try Checked.size(fullMetadataSize, limit: limits.maxMetadataSize)
            guard nextTotalSize <= skipSize else {
                throw KaitoError.malformed("LHA level-1 extension chain exceeds the skip size")
            }
            let chunk = try readHeaderBytes(
                source: source,
                offset: currentOffset,
                size: currentSize
            )
            let size = chunk.count
            let type = chunk[0]
            let data = Array(chunk[1..<(size - 2)])
            let crcFieldOffset = fullHeader.count + 1
            try parseExtension(
                type: type,
                data: data,
                crcFieldOffset: crcFieldOffset,
                fields: &fields
            )
            let nextSize = littleUInt16(chunk, at: size - 2)
            fullHeader.append(contentsOf: chunk)

            let nextOffset = try Checked.add(currentOffset, currentSize)
            guard nextOffset > currentOffset else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            currentOffset = nextOffset
            totalSize = nextTotalSize
            currentSize = UInt64(nextSize)
            recordCount += 1
        }
        return (totalSize, recordCount, fullHeader)
    }

    private static func parseLevel2Extensions(
        _ header: [UInt8],
        fields: inout ExtendedFields,
        limits: ReadLimits
    ) throws -> (recordCount: Int, endOffset: Int) {
        var currentSize = Int(littleUInt16(header, at: 24))
        var cursor = level2MinimumHeaderSize
        var recordCount = 0

        while currentSize != 0 {
            guard currentSize >= 3 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            guard cursor <= header.count, currentSize <= header.count - cursor else {
                throw KaitoError.malformed("LHA level-2 extension overruns the total header")
            }
            let end = cursor + currentSize
            let type = header[cursor]
            let data = Array(header[(cursor + 1)..<(end - 2)])
            try parseExtension(
                type: type,
                data: data,
                crcFieldOffset: cursor + 1,
                fields: &fields
            )
            let nextSize = littleUInt16(header, at: end - 2)
            guard end > cursor else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            cursor = end
            currentSize = Int(nextSize)
            recordCount += 1
        }
        // Some writers pad the remainder of a level-2 header after the
        // terminating next-size value.  The bytes are bounded by the declared
        // total header size (and maxMetadataSize), and are authenticated when
        // the optional common-header CRC is present, so leave them
        // uninterpreted for compatibility.
        return (recordCount, cursor)
    }

    private static func parseLevel3Extensions(
        _ header: [UInt8],
        fields: inout ExtendedFields,
        limits: ReadLimits
    ) throws -> Int {
        var currentSize = UInt64(littleUInt32(header, at: 28))
        var cursor = level3MinimumHeaderSize
        var recordCount = 0

        while currentSize != 0 {
            guard currentSize >= 5 else {
                throw KaitoError.malformed("LHA extended header is smaller than its envelope")
            }
            guard recordCount < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("LHA extended-header count")
            }
            let size = try Checked.toInt(currentSize)
            guard cursor <= header.count, size <= header.count - cursor else {
                throw KaitoError.malformed("LHA level-3 extension overruns the total header")
            }
            let end = cursor + size
            let type = header[cursor]
            let data = Array(header[(cursor + 1)..<(end - 4)])
            try parseExtension(
                type: type,
                data: data,
                crcFieldOffset: cursor + 1,
                fields: &fields
            )
            let nextSize = littleUInt32(header, at: end - 4)
            guard end > cursor else {
                throw KaitoError.malformed("LHA extended-header loop made no progress")
            }
            cursor = end
            currentSize = UInt64(nextSize)
            recordCount += 1
        }
        return recordCount
    }

    private static func parseExtension(
        type: UInt8,
        data: [UInt8],
        crcFieldOffset: Int,
        fields: inout ExtendedFields
    ) throws {
        switch type {
        case 0x00:
            guard data.count >= 2 else {
                throw KaitoError.malformed("LHA common extension lacks its CRC16")
            }
            guard fields.headerCRC16 == nil else {
                throw KaitoError.malformed("duplicate LHA common extension")
            }
            fields.headerCRC16 = littleUInt16(data, at: 0)
            fields.headerCRCFieldOffset = crcFieldOffset
        case 0x01:
            if !data.isEmpty { fields.filename = data }
        case 0x02:
            if !data.isEmpty { fields.directory = data }
        case 0x3F:
            fields.comment = data
        case 0x40:
            guard data.count == 2 else {
                throw KaitoError.malformed("invalid LHA MS-DOS attribute extension")
            }
            fields.dosAttributes = littleUInt16(data, at: 0)
        case 0x41:
            guard data.count == 24 else {
                throw KaitoError.malformed("invalid LHA Windows timestamp extension")
            }
            fields.windowsCreationDate = try windowsFileTime(littleUInt64(data, at: 0))
            fields.windowsModificationDate = try windowsFileTime(littleUInt64(data, at: 8))
            fields.windowsAccessDate = try windowsFileTime(littleUInt64(data, at: 16))
        case 0x42:
            guard data.count == 16 else {
                throw KaitoError.malformed("invalid LHA 64-bit size extension")
            }
            guard fields.uncompressedSize64 == nil,
                  fields.compressedSize64 == nil else {
                throw KaitoError.malformed("duplicate LHA 64-bit size extension")
            }
            // UNLHA32 records packed (compressed) size first, then original size.
            fields.compressedSize64 = littleUInt64(data, at: 0)
            fields.uncompressedSize64 = littleUInt64(data, at: 8)
        case 0x46:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA code-page extension")
            }
            guard fields.codePage == nil else {
                throw KaitoError.malformed("duplicate LHA code-page extension")
            }
            fields.codePage = littleUInt32(data, at: 0)
        case 0x50:
            guard data.count == 2 else {
                throw KaitoError.malformed("invalid LHA Unix permission extension")
            }
            fields.unixMode = littleUInt16(data, at: 0)
        case 0x51:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA Unix uid/gid extension")
            }
            // header.doc stores GID before UID.
            fields.gid = littleUInt16(data, at: 0)
            fields.uid = littleUInt16(data, at: 2)
        case 0x52:
            fields.group = data
        case 0x53:
            fields.user = data
        case 0x54:
            guard data.count == 4 else {
                throw KaitoError.malformed("invalid LHA Unix timestamp extension")
            }
            fields.unixModificationDate = Date(
                timeIntervalSince1970: Double(littleUInt32(data, at: 0))
            )
        case 0x7F, 0xFF:
            break
        default:
            // Unknown extensions remain skippable by construction: their size is
            // authenticated/bounded by the surrounding chain.
            break
        }
    }

    private static func publish(
        pendingEntries: inout [PendingEntry?],
        records: [LHAEntryRecord],
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> LHAParsedArchive {
        guard pendingEntries.count == records.count else {
            throw KaitoError.malformed("LHA entry index is inconsistent")
        }
        let batchLimit = try Checked.toInt(min(limits.maxMetadataSize, UInt64(Int.max)))
        let archiveEncoding: String.Encoding?
        do {
            // Keep this temporary array in a narrow scope. Once archive-wide
            // detection is complete, pending entries are released one by one
            // as their public entries are built.
            let undeclaredNames = pendingEntries.compactMap { pending -> [UInt8]? in
                guard let pending,
                      pending.declaredEncoding == nil,
                      !pending.rawName.isEmpty else {
                    return nil
                }
                return pending.rawName
            }
            let windowsCount = pendingEntries.reduce(into: 0) { count, pending in
                if let pending,
                   pending.declaredEncoding == nil,
                   !pending.rawName.isEmpty,
                   pending.fromWindows {
                    count += 1
                }
            }
            let fromWindows = !undeclaredNames.isEmpty
                && windowsCount >= undeclaredNames.count - windowsCount
            archiveEncoding = EncodingDetector.detectArchiveEncoding(
                names: undeclaredNames,
                policy: policy,
                fromWindows: fromWindows,
                maximumBatchByteCount: batchLimit
            )
        }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(pendingEntries.count)
        var publishedRecords: [LHAEntryRecord] = []
        publishedRecords.reserveCapacity(records.count)
        var retainedMetadataSize: UInt64 = 0

        for index in pendingEntries.indices {
            guard let pending = pendingEntries[index] else {
                throw KaitoError.malformed("LHA pending entry is missing")
            }
            pendingEntries[index] = nil
            let decodedName: String
            if let declaredEncoding = pending.declaredEncoding {
                guard let decoded = EncodingDetector.decode(
                    bytes: pending.rawName,
                    as: declaredEncoding
                ) else {
                    throw KaitoError.malformed("LHA declared name encoding is invalid")
                }
                decodedName = decoded
            } else {
                decodedName = EncodingDetector.resolveUndeclaredName(
                    bytes: pending.rawName,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: pending.fromWindows
                ).string
            }
            // Decode first: in CP932/CP936, 0x5c can be the trail byte of a
            // multibyte character and must not be rewritten as a raw byte.
            // Only level 0/1 define backslash as a path separator. Level 2
            // carries directory boundaries as 0xFF in extension 0x02.
            let separatorNormalizedName = pending.headerLevel <= 1
                ? decodedName.replacingOccurrences(of: "\\", with: "/")
                : decodedName
            let isDirectory = pending.directoryHint
                || separatorNormalizedName.hasSuffix("/")
            var name = relativeArchivePath(separatorNormalizedName)
            if name.isEmpty, isDirectory {
                // Empty -lhd- names denote the archive root. Keeping a dot
                // entry lets extraction drain/authenticate the member without
                // inventing a filesystem leaf.
                name = "."
            }
            if name.isEmpty {
                // Some legacy archives contain unaddressable regular members
                // with a zero-length filename. Lhasa ignores these on
                // extraction; skip their public entry while retaining the
                // already-validated member boundary for traversal.
                continue
            }
            guard !name.utf8.contains(0) else {
                throw KaitoError.malformed("LHA entry name cannot be decoded safely")
            }
            var componentCount = 0
            var insideComponent = false
            for byte in name.utf8 {
                if byte == 0x2F {
                    insideComponent = false
                } else if !insideComponent {
                    componentCount += 1
                    guard componentCount <= limits.maxPathComponentCount else {
                        throw KaitoError.limitExceeded("LHA path component count")
                    }
                    insideComponent = true
                }
            }
            let pathComponents = name
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !pathComponents.isEmpty else {
                throw KaitoError.malformed("LHA entry has no path component")
            }
            assert(pathComponents.count == componentCount)

            let kind: EntryKind = isDirectory ? .directory : .file
            var specific: [String: String] = [
                "attribute": String(format: "0x%02x", pending.attribute),
                "dataCRC16": String(format: "%04x", pending.crc16),
                "dataOffset": String(pending.dataOffset),
                "headerLevel": String(pending.headerLevel),
                "headerOffset": String(pending.headerOffset),
                "method": pending.method,
                "os": osDescription(pending.osID),
            ]
            if let osID = pending.osID {
                specific["osID"] = printableOSID(osID)
            }
            if let value = pending.extended.dosAttributes {
                specific["dosAttributes"] = String(format: "0x%04x", value)
            }
            if let value = pending.extended.codePage {
                specific["codePage"] = String(value)
            }
            if let value = pending.extended.uid {
                specific["uid"] = String(value)
            }
            if let value = pending.extended.gid {
                specific["gid"] = String(value)
            }
            if let value = pending.extended.windowsCreationDate {
                specific["creationTime"] = unixTimeDescription(value)
            }
            if let value = pending.extended.windowsAccessDate {
                specific["accessTime"] = unixTimeDescription(value)
            }
            if let value = pending.extended.comment {
                specific["comment"] = decodeAuxiliaryText(
                    value,
                    declaredEncoding: pending.declaredEncoding,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: pending.fromWindows
                )
            }
            if let value = pending.extended.group {
                specific["group"] = decodeAuxiliaryText(
                    value,
                    declaredEncoding: pending.declaredEncoding,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: pending.fromWindows
                )
            }
            if let value = pending.extended.user {
                specific["user"] = decodeAuxiliaryText(
                    value,
                    declaredEncoding: pending.declaredEncoding,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: pending.fromWindows
                )
            }

            let metadataCost = try retainedMetadataCost(
                rawName: pending.rawName,
                name: name,
                pathComponents: pathComponents,
                formatSpecific: specific
            )
            retainedMetadataSize = try Checked.add(retainedMetadataSize, metadataCost)
            try Checked.size(retainedMetadataSize, limit: limits.maxTotalMetadataSize)

            let publishedIndex = entries.count
            entries.append(ArchiveEntry(
                index: publishedIndex,
                rawName: RawName(
                    bytes: pending.rawName,
                    declaredEncoding: pending.declaredEncoding,
                    isDirectoryHint: kind == EntryKind.directory
                ),
                name: name,
                pathComponents: pathComponents,
                kind: kind,
                uncompressedSize: pending.uncompressedSize,
                compressedSize: pending.compressedSize,
                modificationDate: pending.modificationDate,
                posixPermissions: pending.permissions,
                isEncrypted: false,
                solidGroup: -1,
                crc32: nil,
                methodDescription: pending.method,
                formatSpecific: specific
            ))
            publishedRecords.append(records[index])
        }
        guard !entries.isEmpty || records.isEmpty else {
            throw KaitoError.malformed("LHA file member has an empty filename")
        }
        return LHAParsedArchive(
            entries: entries,
            records: publishedRecords,
            nameEncoding: archiveEncoding
        )
    }

    private static func readHeaderBytes(
        source: any ByteSource,
        offset: UInt64,
        size: UInt64
    ) throws -> [UInt8] {
        let end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        return try readByteRange(
            source: source,
            offset: offset,
            count: Checked.toInt(size)
        )
    }

    private static func validateByteChecksum(_ header: [UInt8], level: UInt8) throws {
        guard header.count >= 2 else { throw KaitoError.truncated }
        var sum: UInt8 = 0
        for byte in header.dropFirst(2) {
            sum &+= byte
        }
        guard sum == header[1] else {
            throw KaitoError.malformed("LHA level-\(level) header checksum mismatch")
        }
    }

    private static func validateHeaderCRCIfPresent(
        _ header: [UInt8],
        fields: ExtendedFields
    ) throws {
        guard let expected = fields.headerCRC16,
              let crcOffset = fields.headerCRCFieldOffset else {
            return
        }
        guard crcOffset >= 0, crcOffset <= header.count - 2 else {
            throw KaitoError.malformed("LHA common CRC lies outside its header")
        }
        var authenticated = header
        authenticated[crcOffset] = 0
        authenticated[crcOffset + 1] = 0
        guard CRC16.checksum(authenticated) == expected else {
            throw KaitoError.malformed("LHA header CRC mismatch")
        }
    }

    private static func parseMethod(_ header: [UInt8]) throws -> String {
        guard header.count >= 7 else { throw KaitoError.truncated }
        let bytes = Array(header[2..<7])
        guard bytes[0] == 0x2D, bytes[4] == 0x2D,
              bytes[1...3].allSatisfy({
                  (0x30...0x39).contains($0)
                      || (0x41...0x5A).contains($0)
                      || (0x61...0x7A).contains($0)
              }) else {
            throw KaitoError.malformed("invalid LHA method identifier")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func canonicalRawName(
        filename: [UInt8],
        directory: [UInt8]?
    ) throws -> [UInt8] {
        guard directory?.contains(0) != true else {
            throw KaitoError.malformed("LHA entry directory contains NUL")
        }
        // MorphOS appends creator metadata after a NUL inside level-0/1 name
        // fields. The pathname is the prefix, as in established readers.
        let pathnameBytes = Array(filename.prefix { $0 != 0 })
        let normalizedFilename = normalizeFilenameSeparators(pathnameBytes)
        let normalizedDirectory = directory.map(normalizeDirectorySeparators) ?? []
        var result = normalizedDirectory
        if !result.isEmpty, !normalizedFilename.isEmpty, result.last != 0x2F {
            result.append(0x2F)
        }
        result.append(contentsOf: normalizedFilename)
        return result
    }

    /// Makes absolute-looking legacy member names relative without resolving
    /// any components. In particular, `..` remains present so Extractor's
    /// existing traversal check still rejects it.
    private static func relativeArchivePath(_ path: String) -> String {
        let bytes = path.utf8
        var start = bytes.startIndex

        while start != bytes.endIndex, bytes[start] == 0x2F {
            start = bytes.index(after: start)
        }

        if start != bytes.endIndex {
            let colon = bytes.index(after: start)
            if colon != bytes.endIndex {
                let first = bytes[start]
                let isDriveLetter = (0x41...0x5A).contains(first)
                    || (0x61...0x7A).contains(first)
                if isDriveLetter, bytes[colon] == 0x3A {
                    start = bytes.index(after: colon)
                    while start != bytes.endIndex, bytes[start] == 0x2F {
                        start = bytes.index(after: start)
                    }
                }
            }
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private static func normalizeFilenameSeparators(_ bytes: [UInt8]) -> [UInt8] {
        bytes
    }

    private static func normalizeDirectorySeparators(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { byte in
            byte == 0xFF ? 0x2F : byte
        }
    }

    private static func declaredEncoding(for codePage: UInt32?) -> String.Encoding? {
        guard let codePage else { return nil }
        switch codePage {
        case 932:
            return String.Encoding.shiftJIS
        case 65001:
            return String.Encoding.utf8
        case 936:
            // Core Foundation's public extended-encoding value 0x0421 is DOS
            // Simplified Chinese / Windows code page 936. The C enum spelling
            // is not imported by every supported Swift toolchain.
            let cfEncoding = CFStringEncoding(0x0421)
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            )
        default:
            return nil
        }
    }

    private static func posixPermissions(_ mode: UInt16?, osID: UInt8) -> UInt16? {
        // Extension type 0x50 is OS-dependent. Its payload is a POSIX mode for
        // Unix ('U'), while OS-9/OS-68K uses a different permission bitfield.
        // Do not apply those foreign bits as a host mode during extraction.
        guard osID == 0x55 else { return nil }
        return mode.map { $0 & 0o7777 }
    }

    private static func hasDOSDirectoryAttribute(_ fields: ExtendedFields) -> Bool {
        // Extension type 0x40 carries the standard MS-DOS attribute word;
        // bit 0x10 marks a directory even when the base attribute does not.
        fields.dosAttributes.map { ($0 & 0x10) != 0 } ?? false
    }

    private static func validateEntrySizes(
        compressed: UInt64,
        uncompressed: UInt64,
        limits: ReadLimits
    ) throws {
        try Checked.size(compressed, limit: limits.maxEntrySize)
        try Checked.size(uncompressed, limit: limits.maxEntrySize)
    }

    private static func validateDirectorySizes(
        method: String,
        compressedSize: UInt64,
        uncompressedSize: UInt64
    ) throws {
        guard method != "-lhd-" || (compressedSize == 0 && uncompressedSize == 0) else {
            throw KaitoError.malformed("LHA directory member has data")
        }
    }

    private static func checkedPayloadEnd(
        dataOffset: UInt64,
        compressedSize: UInt64,
        sourceLength: UInt64
    ) throws -> UInt64 {
        let end = try Checked.add(dataOffset, compressedSize)
        guard end <= sourceLength else { throw KaitoError.truncated }
        return end
    }

    private static func dosDate(_ packed: UInt32) throws -> Date? {
        guard packed != 0 else { return nil }
        let time = UInt16(truncatingIfNeeded: packed)
        let date = UInt16(truncatingIfNeeded: packed >> 16)
        let day = Int(date & 0x001F)
        let month = Int((date >> 5) & 0x000F)
        let year = Int((date >> 9) & 0x007F) + 1980
        let second = Int(time & 0x001F) * 2
        let minute = Int((time >> 5) & 0x003F)
        let hour = Int((time >> 11) & 0x001F)
        guard (1...31).contains(day),
              (1...12).contains(month),
              (0...59).contains(second),
              (0...59).contains(minute),
              (0...23).contains(hour) else {
            return nil
        }
        var calendar = Calendar(identifier: Calendar.Identifier.gregorian)
        calendar.timeZone = TimeZone.current
        guard let monthStart = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1
        )),
            let validDays = calendar.range(
                of: Calendar.Component.day,
                in: Calendar.Component.month,
                for: monthStart
            ),
            validDays.contains(day),
            let result = calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )) else {
            return nil
        }
        return result
    }

    private static func windowsFileTime(_ ticks: UInt64) throws -> Date? {
        // A zero FILETIME denotes an unavailable timestamp in this extension;
        // it must not turn a valid DOS base time into 1601-01-01.
        guard ticks != 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds.isFinite else {
            throw KaitoError.malformed("LHA Windows timestamp is out of range")
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func decodeAuxiliaryText(
        _ bytes: [UInt8],
        declaredEncoding: String.Encoding?,
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?,
        fromWindows: Bool
    ) -> String {
        if let declaredEncoding,
           let decoded = EncodingDetector.decode(bytes: bytes, as: declaredEncoding) {
            return decoded
        }
        return EncodingDetector.resolveUndeclaredName(
            bytes: bytes,
            policy: policy,
            archiveEncoding: archiveEncoding,
            fromWindows: fromWindows
        ).string
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        name: String,
        pathComponents: [String],
        formatSpecific: [String: String]
    ) throws -> UInt64 {
        var total: UInt64 = 256
        total = try Checked.add(total, UInt64(rawName.count))
        total = try Checked.add(total, UInt64(name.utf8.count))
        for component in pathComponents {
            total = try Checked.add(total, UInt64(component.utf8.count))
        }
        for (key, value) in formatSpecific {
            total = try Checked.add(total, UInt64(key.utf8.count))
            total = try Checked.add(total, UInt64(value.utf8.count))
        }
        return total
    }

    private static func pendingMetadataCost(_ pending: PendingEntry) throws -> UInt64 {
        // This conservative logical charge is applied before retaining the
        // entry, so a large archive cannot defer the aggregate limit until
        // archive-wide name decoding. It includes arrays duplicated between
        // the canonical name and parsed extension fields.
        var total: UInt64 = 256
        total = try Checked.add(total, UInt64(pending.rawName.count))
        for bytes in [
            pending.extended.filename,
            pending.extended.directory,
            pending.extended.comment,
            pending.extended.group,
            pending.extended.user,
        ].compactMap({ $0 }) {
            total = try Checked.add(total, UInt64(bytes.count))
        }
        return total
    }

    private static func isWindowsLikeOS(_ value: UInt8) -> Bool {
        value == 0 || value == 0x32 || value == 0x48 || value == 0x4D
            || value == 0x57 || value == 0x77
    }

    private static func osDescription(_ value: UInt8?) -> String {
        guard let value else { return "unspecified" }
        switch value {
        case 0: return "generic"
        case 0x20: return "LHARK"
        case 0x32: return "OS/2"
        case 0x33: return "OS/386"
        case 0x39: return "OS-9"
        case 0x41: return "Amiga"
        case 0x43: return "CP/M"
        case 0x46: return "FLEX"
        case 0x48: return "Human68k"
        case 0x4A: return "Java"
        case 0x4B: return "OS/68K"
        case 0x4D: return "MS-DOS"
        case 0x52: return "Runser"
        case 0x54: return "TownsOS"
        case 0x55: return "Unix"
        case 0x58: return "X-OSK"
        case 0x57: return "Windows NT"
        case 0x61: return "Atari"
        case 0x6D: return "Macintosh"
        case 0x77: return "Windows 95"
        default: return String(format: "0x%02x", value)
        }
    }

    private static func printableOSID(_ value: UInt8) -> String {
        if (0x20...0x7E).contains(value) {
            return String(UnicodeScalar(value))
        }
        return String(format: "0x%02x", value)
    }

    private static func unixTimeDescription(_ date: Date) -> String {
        String(format: "%.7f", date.timeIntervalSince1970)
    }

    private static func littleUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func littleUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
