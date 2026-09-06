import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour (block traversal, optional-field order, Unicode-name
//   decoding, and extended timestamps), not for code or structure:
//   https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar.c
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// Reader for the RAR 1.5-4.x container (normally called "RAR4").
///
/// Header parsing and the stored method are complete here. The RAR 2.9/3.x
/// compressed-data path is kept behind `RAR29Decoder`, so an archive using a
/// method that is not bit-exact never silently produces bytes.
final class RAR4Reader: FormatReader {
    static let signature: [UInt8] = [
        0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00,
    ]

    private enum HeaderType: UInt8 {
        case main = 0x73
        case file = 0x74
        case comment = 0x75
        case authenticity = 0x76
        case subblock = 0x77
        case recovery = 0x78
        case signature = 0x79
        case newSubblock = 0x7a
        case end = 0x7b
    }

    private enum MainFlag {
        static let volume: UInt16 = 0x0001
        static let solid: UInt16 = 0x0008
        static let newNumbering: UInt16 = 0x0010
        static let encryptedHeaders: UInt16 = 0x0080
        static let firstVolume: UInt16 = 0x0100
        static let encryptionVersion: UInt16 = 0x0200
    }

    private enum FileFlag {
        static let splitBefore: UInt16 = 0x0001
        static let splitAfter: UInt16 = 0x0002
        static let encrypted: UInt16 = 0x0004
        static let solid: UInt16 = 0x0010
        static let dictionaryMask: UInt16 = 0x00e0
        static let large: UInt16 = 0x0100
        static let unicode: UInt16 = 0x0200
        static let salt: UInt16 = 0x0400
        static let version: UInt16 = 0x0800
        static let extendedTime: UInt16 = 0x1000
        static let additionalSize: UInt16 = 0x8000
    }

    private enum CommonFlag {
        static let skipIfUnknown: UInt16 = 0x4000
    }

    private struct MainHeader {
        let flags: UInt16

        var isVolume: Bool { flags & MainFlag.volume != 0 }
        var isSolid: Bool { flags & MainFlag.solid != 0 }
    }

    private struct Record {
        let dataOffset: UInt64
        let packedSize: UInt64
        let unpackedSize: UInt64
        let crc32: UInt32
        let flags: UInt16
        let unpackVersion: UInt8
        let method: UInt8
        let dictionarySize: UInt64
        let salt: [UInt8]?

        var isEncrypted: Bool { flags & FileFlag.encrypted != 0 }
        var isSplit: Bool {
            flags & (FileFlag.splitBefore | FileFlag.splitAfter) != 0
        }
    }

    private struct PendingEntry {
        let rawName: [UInt8]
        let fallbackName: [UInt8]
        let decodedUnicodeName: String?
        let declaredEncoding: String.Encoding?
        let kind: EntryKind
        let unpackedSize: UInt64
        let packedSize: UInt64
        let modificationDate: Date?
        let permissions: UInt16?
        let isEncrypted: Bool
        let crc32: UInt32
        let methodDescription: String
        let formatSpecific: [String: String]
    }

    private struct ParsedArchive {
        let entries: [ArchiveEntry]
        let records: [Record]
        let nameEncoding: String.Encoding?
    }

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let records: [Record]
    private let keyCache = RAR3KeyCache()
    private var password: String?

    init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
        self.password = options.password
        let parsed = try Self.parse(
            source: source,
            policy: options.encodingPolicy,
            limits: options.limits
        )
        self.entries = parsed.entries
        self.records = parsed.records
        self.nameEncoding = parsed.nameEncoding
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0,
              entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("RAR4 entry index \(entry.index)")
        }

        let record = records[entry.index]
        guard !record.isSplit else {
            throw KaitoError.unsupportedMethod("RAR4 multi-volume continuation")
        }
        guard record.unpackVersion >= 15 else {
            throw KaitoError.unsupportedMethod(
                "RAR4 unpack version \(record.unpackVersion)"
            )
        }
        let compressedSource: any ByteSource
        let compressedOffset: UInt64
        if record.isEncrypted {
            guard let password else { throw KaitoError.passwordRequired }
            guard let salt = record.salt else {
                throw KaitoError.unsupportedMethod(
                    "RAR4 encrypted file data without a RAR3 salt"
                )
            }
            let derived = try keyCache.key(password: password, salt: salt)
            compressedSource = try RARAESCBCByteSource(
                source: source,
                ciphertextOffset: record.dataOffset,
                ciphertextSize: record.packedSize,
                // RAR does not retain the pre-padding packed byte count.  The
                // compression end marker (or stored logical size below) keeps
                // consumers from observing decrypted AES padding.
                plaintextSize: record.packedSize,
                key: derived.key,
                initializationVector: derived.initializationVector
            )
            compressedOffset = 0
        } else {
            compressedSource = source
            compressedOffset = record.dataOffset
        }

        let decompressor: any Decompressor
        switch record.method {
        case 0x30:
            guard record.isEncrypted || record.packedSize == record.unpackedSize else {
                throw KaitoError.malformed(
                    "RAR4 stored entry has unequal packed and unpacked sizes"
                )
            }
            guard !record.isEncrypted || record.unpackedSize <= record.packedSize else {
                throw KaitoError.malformed(
                    "RAR4 encrypted stored entry exceeds its ciphertext"
                )
            }
            decompressor = try CopyDecompressor(
                source: compressedSource,
                offset: compressedOffset,
                compressedSize: record.unpackedSize
            )
        case 0x31...0x35:
            decompressor = try RAR29Decoder(
                source: compressedSource,
                offset: compressedOffset,
                compressedSize: record.packedSize,
                uncompressedSize: record.unpackedSize,
                unpackVersion: record.unpackVersion,
                method: record.method,
                dictionarySize: record.dictionarySize,
                isSolid: record.flags & FileFlag.solid != 0,
                limits: limits
            )
        default:
            throw KaitoError.unsupportedMethod(
                String(format: "RAR4 method 0x%02x", record.method)
            )
        }

        return try EntryStream(
            decompressor: decompressor,
            length: record.unpackedSize,
            expectedCRC32: record.crc32,
            entryIndex: entry.index,
            limits: limits,
            checksumMismatchIsWrongPassword: record.isEncrypted
        )
    }

    private static func parse(
        source: any ByteSource,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> ParsedArchive {
        guard source.length >= UInt64(signature.count) else {
            throw KaitoError.truncated
        }
        let marker = try readByteRange(source: source, offset: 0, count: signature.count)
        guard marker == signature else { throw KaitoError.unsupportedFormat }

        var offset = UInt64(signature.count)
        var mainHeader: MainHeader?
        var pendingEntries: [PendingEntry] = []
        var records: [Record] = []
        var retainedMetadataSize: UInt64 = 0

        while offset < source.length {
            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= 7 else { throw KaitoError.truncated }

            let common = try readByteRange(source: source, offset: offset, count: 7)
            let typeByte = common[2]
            let flags = littleUInt16(common, at: 3)
            let headerSize = UInt64(littleUInt16(common, at: 5))
            guard headerSize >= 7 else {
                throw KaitoError.malformed("RAR4 header size is smaller than 7")
            }
            try Checked.size(headerSize, limit: limits.maxMetadataSize)
            let headerEnd = try Checked.add(offset, headerSize)
            guard headerEnd <= source.length else { throw KaitoError.truncated }

            let header = try readByteRange(
                source: source,
                offset: offset,
                count: try Checked.toInt(headerSize)
            )
            try validateHeaderCRC(header, offset: offset)

            var dataSize: UInt64 = 0
            if flags & FileFlag.additionalSize != 0 {
                guard header.count >= 11 else {
                    throw KaitoError.malformed(
                        "RAR4 ADD_SIZE flag is set in a short header"
                    )
                }
                dataSize = UInt64(littleUInt32(header, at: 7))
            }

            guard let type = HeaderType(rawValue: typeByte) else {
                guard flags & CommonFlag.skipIfUnknown != 0 else {
                    throw KaitoError.unsupportedMethod(
                        String(format: "RAR4 block type 0x%02x", typeByte)
                    )
                }
                let nextOffset = try Checked.add(headerEnd, dataSize)
                guard nextOffset <= source.length else { throw KaitoError.truncated }
                guard nextOffset > offset else {
                    throw KaitoError.malformed("RAR4 block does not advance")
                }
                offset = nextOffset
                continue
            }

            switch type {
            case .main:
                guard mainHeader == nil else {
                    throw KaitoError.malformed("duplicate RAR4 main header")
                }
                guard offset == UInt64(signature.count) else {
                    throw KaitoError.malformed("RAR4 main header is not first")
                }
                guard header.count >= 13 else {
                    throw KaitoError.malformed("short RAR4 main header")
                }
                if flags & MainFlag.encryptionVersion != 0, header.count < 14 {
                    throw KaitoError.malformed(
                        "RAR4 main header lacks its encryption version"
                    )
                }
                if flags & MainFlag.encryptedHeaders != 0 {
                    throw KaitoError.unsupportedMethod("RAR4 encrypted headers")
                }
                mainHeader = MainHeader(flags: flags)
                dataSize = 0

            case .file:
                guard let mainHeader else {
                    throw KaitoError.malformed("RAR4 file precedes the main header")
                }
                let parsed = try parseFileHeader(
                    header,
                    headerOffset: offset,
                    dataOffset: headerEnd,
                    mainHeader: mainHeader,
                    limits: limits
                )
                dataSize = parsed.record.packedSize
                guard pendingEntries.count < limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("archive entry count")
                }
                let metadataCost = try pendingMetadataCost(parsed.entry)
                retainedMetadataSize = try Checked.add(
                    retainedMetadataSize,
                    metadataCost
                )
                try Checked.size(
                    retainedMetadataSize,
                    limit: limits.maxTotalMetadataSize
                )
                pendingEntries.append(parsed.entry)
                records.append(parsed.record)

            case .newSubblock:
                // NEWSUB uses the FILE_HEAD fixed prefix, including the 64-bit
                // high packed-size word. It is metadata and is never published.
                guard header.count >= 32 else {
                    throw KaitoError.malformed("short RAR4 new-subblock header")
                }
                if flags & FileFlag.large != 0 {
                    guard header.count >= 40 else {
                        throw KaitoError.malformed(
                            "short large RAR4 new-subblock header"
                        )
                    }
                    dataSize = UInt64(littleUInt32(header, at: 7))
                        | UInt64(littleUInt32(header, at: 32)) << 32
                }

            case .end:
                guard mainHeader != nil else {
                    throw KaitoError.malformed("RAR4 end header precedes main header")
                }
                // ENDARC normally has no data area, but an attacker can set
                // LONG_BLOCK just like on any other common header. Validate
                // that claimed range before publishing the already-parsed
                // entries; returning here must not bypass physical bounds.
                let endOffset = try Checked.add(headerEnd, dataSize)
                guard endOffset <= source.length else { throw KaitoError.truncated }
                guard endOffset > offset else {
                    throw KaitoError.malformed("RAR4 end block does not advance")
                }
                return try publish(
                    pendingEntries: pendingEntries,
                    records: records,
                    mainHeader: mainHeader!,
                    policy: policy,
                    limits: limits
                )

            case .comment, .authenticity, .subblock, .recovery, .signature:
                // The common header has already bounded and authenticated both
                // HEAD_SIZE and ADD_SIZE, so these extraction-irrelevant blocks
                // can be skipped without interpreting their private payloads.
                break
            }

            let nextOffset = try Checked.add(headerEnd, dataSize)
            guard nextOffset <= source.length else { throw KaitoError.truncated }
            guard nextOffset > offset else {
                throw KaitoError.malformed("RAR4 block does not advance")
            }
            offset = nextOffset
        }

        guard let mainHeader else {
            throw KaitoError.malformed("RAR4 main header is missing")
        }
        // ENDARC was historically optional. Physical EOF immediately after a
        // validated block is therefore an accepted terminator.
        return try publish(
            pendingEntries: pendingEntries,
            records: records,
            mainHeader: mainHeader,
            policy: policy,
            limits: limits
        )
    }

    private static func parseFileHeader(
        _ header: [UInt8],
        headerOffset: UInt64,
        dataOffset: UInt64,
        mainHeader: MainHeader,
        limits: ReadLimits
    ) throws -> (entry: PendingEntry, record: Record) {
        guard header.count >= 32 else {
            throw KaitoError.malformed("short RAR4 file header")
        }
        let flags = littleUInt16(header, at: 3)
        guard flags & FileFlag.additionalSize != 0 else {
            throw KaitoError.malformed("RAR4 file header lacks ADD_SIZE")
        }

        let packedLow = littleUInt32(header, at: 7)
        let unpackedLow = littleUInt32(header, at: 11)
        let hostOS = header[15]
        let fileCRC = littleUInt32(header, at: 16)
        let dosTime = littleUInt32(header, at: 20)
        let unpackVersion = header[24]
        let method = header[25]
        let nameSize = Int(littleUInt16(header, at: 26))
        let attributes = littleUInt32(header, at: 28)

        var cursor = 32
        let packedSize: UInt64
        let unpackedSize: UInt64
        if flags & FileFlag.large != 0 {
            guard header.count - cursor >= 8 else {
                throw KaitoError.malformed("short large RAR4 file header")
            }
            let packedHigh = littleUInt32(header, at: cursor)
            let unpackedHigh = littleUInt32(header, at: cursor + 4)
            cursor += 8
            packedSize = UInt64(packedLow) | UInt64(packedHigh) << 32
            unpackedSize = UInt64(unpackedLow) | UInt64(unpackedHigh) << 32
        } else {
            packedSize = UInt64(packedLow)
            unpackedSize = UInt64(unpackedLow)
        }

        try Checked.size(unpackedSize, limit: limits.maxEntrySize)
        guard nameSize > 0, nameSize <= header.count - cursor else {
            throw KaitoError.malformed("RAR4 file name overruns its header")
        }
        let rawName = Array(header[cursor..<(cursor + nameSize)])
        cursor += nameSize

        let salt: [UInt8]?
        if flags & FileFlag.salt != 0 {
            guard header.count - cursor >= 8 else {
                throw KaitoError.malformed("RAR4 file header lacks its salt")
            }
            salt = Array(header[cursor..<(cursor + 8)])
            cursor += 8
        } else {
            salt = nil
        }

        var modificationDate = try dosDate(dosTime)
        if flags & FileFlag.extendedTime != 0 {
            modificationDate = try parseExtendedTimes(
                header,
                cursor: &cursor,
                baseModificationDate: modificationDate
            )
        }

        let dictionaryTag = flags & FileFlag.dictionaryMask
        let isDirectory = dictionaryTag == FileFlag.dictionaryMask
        let dictionarySize: UInt64
        if isDirectory {
            dictionarySize = 0
        } else {
            let exponent = Int(dictionaryTag >> 5)
            dictionarySize = UInt64(64 * 1_024) << exponent
            try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        }

        let decodedName = decodeName(rawName, flags: flags)
        guard !decodedName.fallback.isEmpty else {
            throw KaitoError.malformed("RAR4 entry has an empty name")
        }

        let windowsDirectory = hostOS <= 2 && attributes & 0x10 != 0
        let unixType = attributes & 0o170000
        let kind: EntryKind
        if isDirectory || windowsDirectory {
            kind = .directory
        } else if (hostOS == 3 || hostOS == 4 || hostOS == 5),
                  unixType == 0o120000 {
            kind = .symlink
        } else {
            kind = .file
        }
        let permissions: UInt16?
        if hostOS == 3 || hostOS == 4 || hostOS == 5 {
            permissions = UInt16(truncatingIfNeeded: attributes) & 0o7777
        } else {
            permissions = nil
        }

        guard method == 0x30 || (0x31...0x35).contains(method) else {
            // Unknown methods remain listable, and fail explicitly when read.
            // This is intentionally not a parse failure.
            return makePendingAndRecord(
                rawName: rawName,
                decodedName: decodedName,
                kind: kind,
                packedSize: packedSize,
                unpackedSize: unpackedSize,
                modificationDate: modificationDate,
                permissions: permissions,
                hostOS: hostOS,
                attributes: attributes,
                flags: flags,
                unpackVersion: unpackVersion,
                method: method,
                dictionarySize: dictionarySize,
                salt: salt,
                fileCRC: fileCRC,
                dataOffset: dataOffset,
                headerOffset: headerOffset,
                mainHeader: mainHeader
            )
        }

        return makePendingAndRecord(
            rawName: rawName,
            decodedName: decodedName,
            kind: kind,
            packedSize: packedSize,
            unpackedSize: unpackedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            hostOS: hostOS,
            attributes: attributes,
            flags: flags,
            unpackVersion: unpackVersion,
            method: method,
            dictionarySize: dictionarySize,
            salt: salt,
            fileCRC: fileCRC,
            dataOffset: dataOffset,
            headerOffset: headerOffset,
            mainHeader: mainHeader
        )
    }

    private static func makePendingAndRecord(
        rawName: [UInt8],
        decodedName: (fallback: [UInt8], unicode: String?, declared: String.Encoding?),
        kind: EntryKind,
        packedSize: UInt64,
        unpackedSize: UInt64,
        modificationDate: Date?,
        permissions: UInt16?,
        hostOS: UInt8,
        attributes: UInt32,
        flags: UInt16,
        unpackVersion: UInt8,
        method: UInt8,
        dictionarySize: UInt64,
        salt: [UInt8]?,
        fileCRC: UInt32,
        dataOffset: UInt64,
        headerOffset: UInt64,
        mainHeader: MainHeader
    ) -> (entry: PendingEntry, record: Record) {
        let methodName = methodDescription(method)
        let specific: [String: String] = [
            "attributes": String(format: "0x%08x", attributes),
            "dictionarySize": String(dictionarySize),
            "flags": String(format: "0x%04x", flags),
            "headerOffset": String(headerOffset),
            "hostOS": hostDescription(hostOS),
            "mainSolid": mainHeader.isSolid ? "true" : "false",
            "method": String(format: "0x%02x", method),
            "newVolumeNumbering": mainHeader.flags & MainFlag.newNumbering != 0
                ? "true" : "false",
            "splitAfter": flags & FileFlag.splitAfter != 0 ? "true" : "false",
            "splitBefore": flags & FileFlag.splitBefore != 0 ? "true" : "false",
            "unpackVersion": String(unpackVersion),
            "volume": mainHeader.isVolume ? "true" : "false",
            "firstVolume": mainHeader.flags & MainFlag.firstVolume != 0
                ? "true" : "false",
            "versionedName": flags & FileFlag.version != 0 ? "true" : "false",
        ]
        let pending = PendingEntry(
            rawName: rawName,
            fallbackName: decodedName.fallback,
            decodedUnicodeName: decodedName.unicode,
            declaredEncoding: decodedName.declared,
            kind: kind,
            unpackedSize: unpackedSize,
            packedSize: packedSize,
            modificationDate: modificationDate,
            permissions: permissions,
            isEncrypted: flags & FileFlag.encrypted != 0,
            crc32: fileCRC,
            methodDescription: methodName,
            formatSpecific: specific
        )
        let record = Record(
            dataOffset: dataOffset,
            packedSize: packedSize,
            unpackedSize: unpackedSize,
            crc32: fileCRC,
            flags: flags,
            unpackVersion: unpackVersion,
            method: method,
            dictionarySize: dictionarySize,
            salt: salt
        )
        return (pending, record)
    }

    private static func publish(
        pendingEntries: [PendingEntry],
        records: [Record],
        mainHeader: MainHeader,
        policy: EncodingPolicy,
        limits: ReadLimits
    ) throws -> ParsedArchive {
        guard pendingEntries.count == records.count else {
            throw KaitoError.malformed("RAR4 entry index is inconsistent")
        }
        let undecoratedNames = pendingEntries.compactMap { pending -> [UInt8]? in
            pending.decodedUnicodeName == nil ? pending.fallbackName : nil
        }
        let batchLimit = try Checked.toInt(min(
            limits.maxMetadataSize,
            UInt64(Int.max)
        ))
        let archiveEncoding = EncodingDetector.detectArchiveEncoding(
            names: undecoratedNames,
            policy: policy,
            fromWindows: true,
            maximumBatchByteCount: batchLimit
        )

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(pendingEntries.count)

        // FHD_SOLID marks a file as continuing the dictionary of the previous
        // data-bearing file. Consequently a group becomes observable only at
        // the first continuation: its independent predecessor is then the
        // group leader. Directory records never join or break the data run.
        var solidGroups = [Int](repeating: -1, count: pendingEntries.count)
        var previousFileIndex: Int?
        for index in pendingEntries.indices where pendingEntries[index].kind != .directory {
            let continuesSolidStream = records[index].flags & FileFlag.solid != 0
            if continuesSolidStream {
                guard mainHeader.isSolid else {
                    throw KaitoError.malformed(
                        "RAR4 solid file is not in a solid archive"
                    )
                }
                guard let predecessor = previousFileIndex else {
                    throw KaitoError.malformed(
                        "first RAR4 file cannot continue a solid stream"
                    )
                }
                let group = solidGroups[predecessor] >= 0
                    ? solidGroups[predecessor]
                    : predecessor
                solidGroups[predecessor] = group
                solidGroups[index] = group
            }
            previousFileIndex = index
        }

        for (index, pending) in pendingEntries.enumerated() {
            let unresolved = pending.decodedUnicodeName == nil
            let decoded = pending.decodedUnicodeName ??
                EncodingDetector.resolveUndeclaredName(
                    bytes: pending.fallbackName,
                    policy: policy,
                    archiveEncoding: archiveEncoding,
                    fromWindows: true
                ).string
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            guard !name.isEmpty, !name.utf8.contains(0) else {
                throw KaitoError.malformed("RAR4 entry name cannot be decoded safely")
            }
            let components = name
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard components.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("RAR4 path component count")
            }

            entries.append(ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: pending.rawName,
                    declaredEncoding: pending.declaredEncoding,
                    isDirectoryHint: pending.kind == .directory
                ),
                name: name,
                pathComponents: components,
                kind: pending.kind,
                uncompressedSize: pending.unpackedSize,
                compressedSize: pending.packedSize,
                modificationDate: pending.modificationDate,
                posixPermissions: pending.permissions,
                isEncrypted: pending.isEncrypted,
                solidGroup: solidGroups[index],
                crc32: pending.crc32,
                methodDescription: pending.methodDescription,
                formatSpecific: pending.formatSpecific.merging(
                    ["nameSource": unresolved ? "legacy" : "unicode"],
                    uniquingKeysWith: { current, _ in current }
                )
            ))
        }
        return ParsedArchive(
            entries: entries,
            records: records,
            nameEncoding: archiveEncoding
        )
    }

    private static func validateHeaderCRC(
        _ header: [UInt8],
        offset: UInt64
    ) throws {
        guard header.count >= 7 else {
            throw KaitoError.malformed("short RAR4 common header")
        }
        let expected = littleUInt16(header, at: 0)
        let actual = UInt16(truncatingIfNeeded: CRC32.checksum(Array(header.dropFirst(2))))
        guard actual == expected else {
            throw KaitoError.malformed(
                "RAR4 header CRC mismatch at offset \(offset)"
            )
        }
    }

    private static func decodeName(
        _ field: [UInt8],
        flags: UInt16
    ) -> (fallback: [UInt8], unicode: String?, declared: String.Encoding?) {
        guard flags & FileFlag.unicode != 0 else {
            return (field, nil, nil)
        }
        guard let separator = field.firstIndex(of: 0) else {
            if let utf8 = EncodingDetector.decode(bytes: field, as: .utf8) {
                return (field, utf8, .utf8)
            }
            return (field, nil, nil)
        }

        let fallback = Array(field[..<separator])
        guard separator + 1 < field.count else {
            return (fallback, nil, nil)
        }
        let highByte = field[separator + 1]
        var position = separator + 2
        var flagByte: UInt8 = 0
        var flagBits = 0
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(min(fallback.count, field.count))

        while position < field.count {
            if flagBits == 0 {
                flagByte = field[position]
                position += 1
                flagBits = 8
            }
            flagBits -= 2
            let mode = (flagByte >> flagBits) & 0x03
            switch mode {
            case 0:
                guard position < field.count else { return (fallback, nil, nil) }
                codeUnits.append(UInt16(field[position]))
                position += 1
            case 1:
                guard position < field.count else { return (fallback, nil, nil) }
                codeUnits.append(UInt16(highByte) << 8 | UInt16(field[position]))
                position += 1
            case 2:
                guard field.count - position >= 2 else {
                    return (fallback, nil, nil)
                }
                let low = field[position]
                let high = field[position + 1]
                codeUnits.append(UInt16(high) << 8 | UInt16(low))
                position += 2
            default:
                guard position < field.count else { return (fallback, nil, nil) }
                let lengthByte = field[position]
                position += 1
                let hasCorrection = lengthByte & 0x80 != 0
                let correction: UInt8
                if hasCorrection {
                    guard position < field.count else {
                        return (fallback, nil, nil)
                    }
                    correction = field[position]
                    position += 1
                } else {
                    correction = 0
                }
                let count = Int(lengthByte & 0x7f) + 2
                guard codeUnits.count <= fallback.count,
                      count <= fallback.count - codeUnits.count else {
                    return (fallback, nil, nil)
                }
                for _ in 0..<count {
                    let base = fallback[codeUnits.count]
                    let low = base &+ correction
                    let high = hasCorrection ? highByte : 0
                    codeUnits.append(UInt16(high) << 8 | UInt16(low))
                }
            }
            // RAR's reference format bounds decoded units by NAME_SIZE. This
            // prevents a tiny run stream from becoming a metadata allocation.
            guard codeUnits.count <= field.count else {
                return (fallback, nil, nil)
            }
        }

        guard !codeUnits.isEmpty,
              isStrictUTF16(codeUnits) else {
            return (fallback, nil, nil)
        }
        let decoded = String(decoding: codeUnits, as: UTF16.self)
        guard !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return (fallback, nil, nil)
        }
        // The stream is a RAR-specific transform into UTF-16 code units, not a
        // byte string in a Foundation encoding, so RawName keeps no misleading
        // declaredEncoding value.
        return (fallback, decoded, nil)
    }

    private static func isStrictUTF16(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0xd800...0xdbff:
                guard index + 1 < units.count,
                      (0xdc00...0xdfff).contains(units[index + 1]) else {
                    return false
                }
                index += 2
            case 0xdc00...0xdfff:
                return false
            default:
                index += 1
            }
        }
        return true
    }

    private static func parseExtendedTimes(
        _ header: [UInt8],
        cursor: inout Int,
        baseModificationDate: Date?
    ) throws -> Date? {
        guard header.count - cursor >= 2 else {
            throw KaitoError.malformed("truncated RAR4 extended-time flags")
        }
        let flags = littleUInt16(header, at: cursor)
        cursor += 2
        var modificationDate = baseModificationDate

        for timeIndex in stride(from: 3, through: 0, by: -1) {
            let mode = UInt8(truncatingIfNeeded: flags >> (timeIndex * 4)) & 0x0f
            guard mode & 0x08 != 0 else { continue }

            var date: Date?
            if timeIndex == 3 {
                date = baseModificationDate
            }
            if date == nil {
                guard header.count - cursor >= 4 else {
                    throw KaitoError.malformed("truncated RAR4 extended timestamp")
                }
                date = try dosDate(littleUInt32(header, at: cursor))
                cursor += 4
            }

            let precisionByteCount = Int(mode & 0x03)
            guard precisionByteCount <= header.count - cursor else {
                throw KaitoError.malformed("truncated RAR4 timestamp precision")
            }
            var remainder: UInt32 = 0
            for _ in 0..<precisionByteCount {
                remainder = UInt32(header[cursor]) << 16 | remainder >> 8
                cursor += 1
            }
            if timeIndex == 3, let date {
                let oddSecond = mode & 0x04 != 0 ? 1.0 : 0.0
                let fractional = Double(remainder) / 10_000_000.0
                modificationDate = date.addingTimeInterval(oddSecond + fractional)
            }
        }
        return modificationDate
    }

    private static func dosDate(_ packed: UInt32) throws -> Date? {
        guard packed != 0 else { return nil }
        let time = UInt16(truncatingIfNeeded: packed)
        let date = UInt16(truncatingIfNeeded: packed >> 16)
        let day = Int(date & 0x001f)
        let month = Int((date >> 5) & 0x000f)
        let year = Int((date >> 9) & 0x007f) + 1980
        let second = Int(time & 0x001f) * 2
        let minute = Int((time >> 5) & 0x003f)
        let hour = Int((time >> 11) & 0x001f)
        guard (1...31).contains(day),
              (1...12).contains(month),
              (0...59).contains(second),
              (0...59).contains(minute),
              (0...23).contains(hour) else {
            throw KaitoError.malformed("invalid RAR4 DOS timestamp")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let monthStart = calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: 1
        )),
            let validDays = calendar.range(of: .day, in: .month, for: monthStart),
            validDays.contains(day),
            let result = calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )) else {
            throw KaitoError.malformed("invalid RAR4 DOS timestamp")
        }
        return result
    }

    private static func pendingMetadataCost(_ entry: PendingEntry) throws -> UInt64 {
        var total: UInt64 = 256
        total = try Checked.add(total, UInt64(entry.rawName.count))
        total = try Checked.add(total, UInt64(entry.fallbackName.count))
        if let decoded = entry.decodedUnicodeName {
            total = try Checked.add(total, UInt64(decoded.utf8.count))
        }
        for (key, value) in entry.formatSpecific {
            total = try Checked.add(total, UInt64(key.utf8.count))
            total = try Checked.add(total, UInt64(value.utf8.count))
        }
        return total
    }

    private static func methodDescription(_ method: UInt8) -> String {
        switch method {
        case 0x30: "stored"
        case 0x31: "RAR4 fastest"
        case 0x32: "RAR4 fast"
        case 0x33: "RAR4 normal"
        case 0x34: "RAR4 good"
        case 0x35: "RAR4 best"
        default: String(format: "RAR4 method 0x%02x", method)
        }
    }

    private static func hostDescription(_ host: UInt8) -> String {
        switch host {
        case 0: "MS-DOS"
        case 1: "OS/2"
        case 2: "Windows"
        case 3: "Unix"
        case 4: "Mac OS"
        case 5: "BeOS"
        case 6: "WinCE"
        default: "unknown \(host)"
        }
    }

    private static func littleUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
