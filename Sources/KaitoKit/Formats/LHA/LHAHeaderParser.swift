import CoreFoundation
import Foundation

// Clean-room container parser based on Masaru Oki's public LHa for UNIX
// `header.doc` (translated by Koji Arai), the same project's public README
// extension notes, and the task's clean-room grammar. These define levels 0-3,
// the portable/Unix extension chain, and the interoperable Windows-time and
// 64-bit-size extensions. Lhasa was used only as a black-box oracle.

struct LHAEntryRecord: Sendable {
    let method: String
    let dataOffset: UInt64
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc16: UInt16
    let headerLevel: UInt8
    let osID: UInt8?
}

struct LHAUnpublishedMember: Sendable {
    let position: Int
    let record: LHAEntryRecord
}

struct LHAParsedArchive {
    let entries: [ArchiveEntry]
    let records: [LHAEntryRecord]
    let nameEncoding: String.Encoding?
    let firstHeaderOffset: UInt64
    let terminator: LHAArchiveTerminator?
    let unpublishedMembers: [LHAUnpublishedMember]
}

enum LHAHeaderParser {
    private static let minimumCommonPrefixSize = 21
    // Smallest valid base header per level, in bytes. LHASignatureScanner
    // applies the same bounds to candidates, and levels 2 and 3 start their
    // extension chains at these offsets (LHAExtendedHeader).
    static let level0MinimumHeaderSize = 24
    static let level1MinimumHeaderSize = 27
    static let level2MinimumHeaderSize = 26
    static let level3MinimumHeaderSize = 32
    private static let larcMethods: Set<String> = ["-lzs-", "-lz4-", "-lz5-"]

    private struct ParsedHeader {
        let pending: PendingEntry
        let record: LHAEntryRecord
        let nextOffset: UInt64
        let extensionRecordCount: Int
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
        let extended: LHAExtendedHeader
        let headerOffset: UInt64
        let dataOffset: UInt64
    }

    static func parse(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits,
        startOffset: UInt64 = 0,
        recoverDamagedArchives: Bool = false
    ) throws -> LHAParsedArchive {
        var pendingEntries: [PendingEntry?] = []
        var records: [LHAEntryRecord] = []
        guard startOffset <= source.length else { throw KaitoError.truncated }
        var offset = startOffset
        var foundEndMarker = false
        var terminator: LHAArchiveTerminator?
        var sawAnonymousRegularMember = false
        var retainedPendingMetadataSize: UInt64 = 0
        var reader = try ByteReader(source: source)

        while offset < source.length {
            try checkCancellation(every: pendingEntries.count)
            try reader.seek(to: offset)
            let firstByte = try reader.readUInt8()
            if firstByte == 0 {
                foundEndMarker = true
                if !recoverDamagedArchives { terminator = .zeroByte(offset: offset) }
                break
            }

            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= UInt64(minimumCommonPrefixSize) else {
                if recoverDamagedArchives { break }
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
            do {
                switch level {
                case 0:
                    parsed = try parseLevel0(
                        source: source,
                        offset: offset,
                        firstByte: firstByte,
                        limits: limits,
                        recoverDamagedArchives: recoverDamagedArchives
                    )
                case 1:
                    parsed = try parseLevel1(
                        source: source,
                        offset: offset,
                        firstByte: firstByte,
                        limits: limits,
                        recoverDamagedArchives: recoverDamagedArchives
                    )
                case 2:
                    parsed = try parseLevel2(
                        source: source,
                        offset: offset,
                        limits: limits,
                        recoverDamagedArchives: recoverDamagedArchives
                    )
                case 3:
                    parsed = try parseLevel3(
                        source: source,
                        offset: offset,
                        limits: limits,
                        recoverDamagedArchives: recoverDamagedArchives
                    )
                default:
                    throw KaitoError.malformed("unsupported LHA header level \(level)")
                }
            } catch KaitoError.truncated where recoverDamagedArchives {
                break
            }

            // Legacy readers treat an empty-name -lhd- member as a benign
            // archive terminator. Two historical writers emitted such a root
            // record before otherwise unreachable bytes; matching that rule
            // avoids inventing a filesystem name or exposing the tail.
            if parsed.pending.method == "-lhd-", parsed.pending.rawName.isEmpty {
                foundEndMarker = true
                if !recoverDamagedArchives {
                    terminator = .emptyNameDirectoryMember(offset..<parsed.nextOffset)
                }
                break
            }
            if parsed.pending.rawName.isEmpty {
                sawAnonymousRegularMember = true
            }

            guard pendingEntries.count < limits.maxEntryCount else {
                throw KaitoError.limitExceeded("archive entry count")
            }

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
            let record = parsed.record
            records.append(LHAEntryRecord(
                method: record.method,
                dataOffset: record.dataOffset,
                compressedSize: recoverDamagedArchives
                    ? min(record.compressedSize, source.length - record.dataOffset)
                    : record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                crc16: record.crc16,
                headerLevel: record.headerLevel,
                osID: record.osID
            ))
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
            if !recoverDamagedArchives { terminator = .endOfFile }
        }
        guard foundEndMarker || recoverDamagedArchives else { throw KaitoError.truncated }
        return try publish(
            pendingEntries: &pendingEntries,
            records: records,
            policy: policy,
            limits: limits,
            firstHeaderOffset: startOffset,
            terminator: terminator
        )
    }

    private static func parseLevel0(
        source: any ByteSource,
        offset: UInt64,
        firstByte: UInt8,
        limits: ReadLimits,
        recoverDamagedArchives: Bool
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
        let packedSize = UInt64(LittleEndian.uint32(header, at: 7))
        let originalSize = UInt64(LittleEndian.uint32(header, at: 11))
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
        let crc16 = LittleEndian.uint16(header, at: crcOffset)
        let osOffset = crcOffset + 2
        // In a level-0 header, any byte following the data CRC is the creator
        // OS ID. Preserve unknown and less-common IDs instead of discarding
        // the encoding hint and diagnostic metadata.
        let osID: UInt8? = osOffset < header.count ? header[osOffset] : nil
        let canonicalName = try canonicalRawName(
            filename: rawName,
            directory: nil
        )
        var modificationDate = try dosDate(LittleEndian.uint32(header, at: 15))
        var extended = LHAExtendedHeader()
        // LHa for UNIX places a fixed-length 'U' extension after the level-0
        // data CRC. Only a complete 12-byte version-0 extension is interpreted;
        // trailing bytes from other creators are not retained.
        if osID == 0x55, header.count - osOffset >= 12, header[osOffset + 1] == 0 {
            let timestamp = LittleEndian.uint32(header, at: osOffset + 2)
            modificationDate = Date(timeIntervalSince1970: Double(timestamp))
            extended.unixMode = LittleEndian.uint16(header, at: osOffset + 6)
            extended.uid = LittleEndian.uint16(header, at: osOffset + 8)
            extended.gid = LittleEndian.uint16(header, at: osOffset + 10)
        }
        let dataOffset = try Checked.add(offset, totalHeaderSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: packedSize,
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: packedSize,
            uncompressedSize: originalSize
        )

        return makeParsedHeader(
            level: 0,
            method: method,
            compressedSize: packedSize,
            uncompressedSize: originalSize,
            rawName: canonicalName,
            declaredEncoding: nil,
            modificationDate: modificationDate,
            permissions: osID.flatMap { posixPermissions(extended.unixMode, osID: $0) },
            crc16: crc16,
            osID: osID,
            attribute: header[19],
            directoryHint: method == "-lhd-" || (header[19] & 0x10) != 0,
            fields: extended,
            headerOffset: offset,
            dataOffset: dataOffset,
            nextOffset: nextOffset,
            extensionRecordCount: 0
        )
    }

    private static func parseLevel1(
        source: any ByteSource,
        offset: UInt64,
        firstByte: UInt8,
        limits: ReadLimits,
        recoverDamagedArchives: Bool
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
        let skipSize = UInt64(LittleEndian.uint32(base, at: 7))
        let originalSize32 = UInt64(LittleEndian.uint32(base, at: 11))
        let nameLength = Int(base[21])
        let crcOffset = 22 + nameLength
        // CRC16, OS ID, and the first two-byte extension length must all fit.
        guard crcOffset >= 22, crcOffset <= base.count - 5 else {
            throw KaitoError.malformed("LHA level-1 name overruns its base header")
        }
        let baseFilename = Array(base[22..<crcOffset])
        let crc16 = LittleEndian.uint16(base, at: crcOffset)
        let osID = base[crcOffset + 2]
        let firstExtensionSize = LittleEndian.uint16(base, at: base.count - 2)

        let baseEnd = try Checked.add(offset, baseHeaderSize)
        var fields = LHAExtendedHeader()
        let extensionResult = try fields.readLevel1Chain(
            source: source,
            offset: baseEnd,
            firstSize: firstExtensionSize,
            skipSize: skipSize,
            base: base,
            limits: limits
        )
        try fields.validateHeaderCRCIfPresent(extensionResult.headerBytes)

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
        let baseModificationDate = try dosDate(LittleEndian.uint32(base, at: 15))
        let modificationDate = fields.unixModificationDate
            ?? fields.windowsModificationDate
            ?? baseModificationDate
        let permissions = posixPermissions(fields.unixMode, osID: osID)
        let dataOffset = try Checked.add(baseEnd, extensionResult.totalSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: compressedSize,
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        return makeParsedHeader(
            level: 1,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            rawName: canonicalName,
            declaredEncoding: declaredEncoding,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            osID: osID,
            attribute: base[19],
            directoryHint: method == "-lhd-"
                || (base[19] & 0x10) != 0
                || fields.hasDOSDirectoryAttribute,
            fields: fields,
            headerOffset: offset,
            dataOffset: dataOffset,
            nextOffset: nextOffset,
            extensionRecordCount: extensionResult.recordCount
        )
    }

    private static func parseLevel2(
        source: any ByteSource,
        offset: UInt64,
        limits: ReadLimits,
        recoverDamagedArchives: Bool
    ) throws -> ParsedHeader {
        let sizeBytes = try readByteRange(source: source, offset: offset, count: 2)
        let declaredHeaderSize = UInt64(LittleEndian.uint16(sizeBytes, at: 0))
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
        let packedSize32 = UInt64(LittleEndian.uint32(declaredHeader, at: 7))
        let originalSize32 = UInt64(LittleEndian.uint32(declaredHeader, at: 11))
        let crc16 = LittleEndian.uint16(declaredHeader, at: 21)
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
        var fields = LHAExtendedHeader()
        let extensionResult = try fields.parseLevel2Chain(
            candidate,
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
        try fields.validateHeaderCRCIfPresent(authenticatedHeader)

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
            timeIntervalSince1970: Double(LittleEndian.uint32(candidate, at: 15))
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
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        return makeParsedHeader(
            level: 2,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            rawName: canonicalName,
            declaredEncoding: declaredEncoding,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            osID: osID,
            attribute: declaredHeader[19],
            directoryHint: method == "-lhd-"
                || (declaredHeader[19] & 0x10) != 0
                || fields.hasDOSDirectoryAttribute,
            fields: fields,
            headerOffset: offset,
            dataOffset: dataOffset,
            nextOffset: nextOffset,
            extensionRecordCount: extensionResult.recordCount
        )
    }

    private static func parseLevel3(
        source: any ByteSource,
        offset: UInt64,
        limits: ReadLimits,
        recoverDamagedArchives: Bool
    ) throws -> ParsedHeader {
        let base = try readHeaderBytes(
            source: source,
            offset: offset,
            size: UInt64(level3MinimumHeaderSize)
        )
        guard LittleEndian.uint16(base, at: 0) == 4 else {
            throw KaitoError.malformed("invalid LHA level-3 size-field width")
        }
        guard base[20] == 3 else {
            throw KaitoError.malformed("LHA header level changed inside its base header")
        }
        let totalHeaderSize = UInt64(LittleEndian.uint32(base, at: 24))
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
        let packedSize32 = UInt64(LittleEndian.uint32(header, at: 7))
        let originalSize32 = UInt64(LittleEndian.uint32(header, at: 11))
        let crc16 = LittleEndian.uint16(header, at: 21)
        let osID = header[23]
        var fields = LHAExtendedHeader()
        let extensionRecordCount = try fields.parseLevel3Chain(
            header,
            limits: limits
        )
        try fields.validateHeaderCRCIfPresent(header)

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
            timeIntervalSince1970: Double(LittleEndian.uint32(header, at: 15))
        )
        let permissions = posixPermissions(fields.unixMode, osID: osID)
        let dataOffset = try Checked.add(offset, totalHeaderSize)
        let nextOffset = try checkedPayloadEnd(
            dataOffset: dataOffset,
            compressedSize: compressedSize,
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
        try validateDirectorySizes(
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )

        return makeParsedHeader(
            level: 3,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            rawName: canonicalName,
            declaredEncoding: declaredEncoding(for: fields.codePage),
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            osID: osID,
            attribute: header[19],
            directoryHint: method == "-lhd-"
                || (header[19] & 0x10) != 0
                || fields.hasDOSDirectoryAttribute,
            fields: fields,
            headerOffset: offset,
            dataOffset: dataOffset,
            nextOffset: nextOffset,
            extensionRecordCount: extensionRecordCount
        )
    }

    /// Builds the pending entry and the stream record from the values each
    /// level parser located. Only a level-0 header can end before its OS ID;
    /// such a member counts as Windows-like for name decoding.
    private static func makeParsedHeader(
        level: UInt8,
        method: String,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        rawName: [UInt8],
        declaredEncoding: String.Encoding?,
        modificationDate: Date?,
        permissions: UInt16?,
        crc16: UInt16,
        osID: UInt8?,
        attribute: UInt8,
        directoryHint: Bool,
        fields: LHAExtendedHeader,
        headerOffset: UInt64,
        dataOffset: UInt64,
        nextOffset: UInt64,
        extensionRecordCount: Int
    ) -> ParsedHeader {
        let pending = PendingEntry(
            rawName: rawName,
            declaredEncoding: declaredEncoding,
            method: method,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            crc16: crc16,
            headerLevel: level,
            osID: osID,
            fromWindows: osID.map(isWindowsLikeOS) ?? true,
            attribute: attribute,
            directoryHint: directoryHint,
            extended: fields,
            headerOffset: headerOffset,
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
                headerLevel: level,
                osID: osID
            ),
            nextOffset: nextOffset,
            extensionRecordCount: extensionRecordCount
        )
    }

    private static func publish(
        pendingEntries: inout [PendingEntry?],
        records: [LHAEntryRecord],
        policy: EncodingPolicy,
        limits: ReadLimits,
        firstHeaderOffset: UInt64,
        terminator: LHAArchiveTerminator?
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
        var unpublishedMembers: [LHAUnpublishedMember] = []
        var retainedMetadataSize: UInt64 = 0

        for index in pendingEntries.indices {
            try checkCancellation(every: index)
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
            let (name, linkPath, kind) = normalizeName(decoded: decodedName, pending: pending)
            if name.isEmpty {
                // Some legacy archives contain unaddressable regular members
                // with a zero-length filename. Lhasa ignores these on
                // extraction; skip their public entry while retaining the
                // already-validated member boundary for traversal.
                if terminator != nil {
                    unpublishedMembers.append(LHAUnpublishedMember(position: index, record: records[index]))
                }
                continue
            }
            guard !name.utf8.contains(0) else {
                throw KaitoError.malformed("LHA entry name cannot be decoded safely")
            }
            let pathComponents = try ArchivePath.components(
                of: name,
                limit: limits.maxPathComponentCount,
                label: "LHA path component count"
            )
            guard !pathComponents.isEmpty else {
                throw KaitoError.malformed("LHA entry has no path component")
            }

            let specific = makeFormatSpecific(
                pending: pending,
                linkPath: linkPath,
                policy: policy,
                archiveEncoding: archiveEncoding
            )

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
                formatSpecific: specific,
                isIncomplete: records[index].compressedSize < pending.compressedSize
            ))
            publishedRecords.append(records[index])
        }
        guard !entries.isEmpty || records.isEmpty else {
            throw KaitoError.malformed("LHA file member has an empty filename")
        }
        return LHAParsedArchive(
            entries: entries,
            records: publishedRecords,
            nameEncoding: archiveEncoding,
            firstHeaderOffset: firstHeaderOffset,
            terminator: terminator,
            unpublishedMembers: unpublishedMembers
        )
    }

    /// Turns a decoded member name into its published path, splitting the
    /// target off a Unix symbolic link stored as `name|target` in a `-lhd-`
    /// member. The name is empty when the member has no addressable path.
    private static func normalizeName(
        decoded decodedName: String,
        pending: PendingEntry
    ) -> (name: String, linkPath: String?, kind: EntryKind) {
        // The caller decodes first: in CP932/CP936, 0x5c can be the trail byte
        // of a multibyte character and must not be rewritten as a raw byte.
        // Old DOS writers put backslash separators even in level-2 filename
        // extensions.
        let separatorNormalizedName = decodedName.replacingOccurrences(of: "\\", with: "/")
        let unixFileType = pending.extended.unixMode.map { $0 & 0o170000 }
        let isUnixSymbolicLink = pending.method == "-lhd-"
            && unixFileType == 0o120000
        var storedName = separatorNormalizedName
        var linkPath: String?
        if isUnixSymbolicLink,
           let separator = storedName.firstIndex(of: "|") {
            linkPath = String(storedName[storedName.index(after: separator)...])
            storedName = String(storedName[..<separator])
        }
        let isDirectory = !isUnixSymbolicLink
            && (pending.directoryHint || storedName.hasSuffix("/"))
        var name = relativeArchivePath(storedName)
        if name.isEmpty, isDirectory {
            // Empty -lhd- names denote the archive root. Keeping a dot
            // entry lets extraction drain/authenticate the member without
            // inventing a filesystem leaf.
            name = "."
        }
        let kind: EntryKind
        if isUnixSymbolicLink {
            kind = .symlink
        } else {
            kind = isDirectory ? .directory : .file
        }
        return (name, linkPath, kind)
    }

    /// The `formatSpecific` values published for one member. Auxiliary text
    /// (comment, group, user) is decoded like the member name.
    private static func makeFormatSpecific(
        pending: PendingEntry,
        linkPath: String?,
        policy: EncodingPolicy,
        archiveEncoding: String.Encoding?
    ) -> [String: String] {
        var specific: [String: String] = [
            "attribute": String(format: "0x%02x", pending.attribute),
            "dataCRC16": String(format: "%04x", pending.crc16),
            "dataOffset": String(pending.dataOffset),
            "headerLevel": String(pending.headerLevel),
            "headerOffset": String(pending.headerOffset),
            "method": pending.method,
            "os": osDescription(pending.osID),
        ]
        if let linkPath {
            specific["linkPath"] = linkPath
        }
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
        return specific
    }

    /// Reads `size` header bytes at `offset`, or `.truncated` if they run past
    /// the source.
    static func readHeaderBytes(
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
        // 0xFF is not a character byte in CP932, EUC-JP, or UTF-8, so it is a
        // separator inside the basic name as well.
        normalizeDirectorySeparators(bytes)
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
        sourceLength: UInt64,
        recoverDamagedArchives: Bool
    ) throws -> UInt64 {
        let end = try Checked.add(dataOffset, compressedSize)
        guard end <= sourceLength || recoverDamagedArchives else { throw KaitoError.truncated }
        return end
    }

    private static func dosDate(_ packed: UInt32) throws -> Date? {
        guard packed != 0 else { return nil }
        let dos = DOSDateTime(packed: packed)
        let year = dos.year, month = dos.month, day = dos.day
        let hour = dos.hour, minute = dos.minute, second = dos.second
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
}
