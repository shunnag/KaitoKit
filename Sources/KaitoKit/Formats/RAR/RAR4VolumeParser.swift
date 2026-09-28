import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for format behaviour (block traversal, optional-field order, Unicode-name
//   decoding, and extended timestamps), not for code or structure:
//   https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar.c
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// Parses the headers of one RAR4 volume: the marker, CRC-checked (and, for
/// `-hp` archives, decrypted) blocks, the main header, and file headers with
/// their names and timestamps. File headers become `RAR4PendingEntry` /
/// `RAR4EntryRecord` fragments; joining them across volumes is
/// `RAR4EntryPublisher`'s job.
enum RAR4VolumeParser {
    static func parseVolume(
        source: any ByteSource,
        limits: ReadLimits,
        password: inout String?,
        passwordProvider: (any PasswordProvider)?,
        headerKeyCache: RAR3KeyCache,
        passwordEncodings: RAR4Reader.PasswordEncodingSelection,
        signatureOffset: UInt64
    ) throws -> RAR4ParsedVolume {
        let markerEnd = try Checked.add(signatureOffset, UInt64(RAR4Reader.signature.count))
        guard source.length >= markerEnd else {
            throw KaitoError.truncated
        }
        let marker = try readByteRange(
            source: source,
            offset: signatureOffset,
            count: RAR4Reader.signature.count
        )
        guard marker == RAR4Reader.signature else { throw KaitoError.unsupportedFormat }

        var offset = markerEnd
        var mainHeader: RAR4MainHeader?
        var pendingEntries: [RAR4PendingEntry] = []
        var records: [RAR4EntryRecord] = []
        var retainedMetadataSize: UInt64 = 0
        var encryptedHeaderWasValidated = false
        var blockCount = 0
        var timestamps = DOSTimestampDecoder()

        while offset < source.length {
            try checkCancellation(every: blockCount)
            blockCount &+= 1
            let encryptedHeader = mainHeader?.hasEncryptedHeaders == true
            let encryptedHeaderEnvelopeIsShort = encryptedHeader
                && source.length - offset < 24
            let parsedHeader: RAR4ParsedHeader
            do {
                parsedHeader = try readHeader(
                    source: source,
                    offset: offset,
                    encrypted: encryptedHeader,
                    password: password,
                    keyCache: headerKeyCache,
                    passwordEncodings: passwordEncodings,
                    limits: limits
                )
                if encryptedHeader { encryptedHeaderWasValidated = true }
            } catch let error as KaitoError where encryptedHeader {
                switch error {
                case .passwordRequired, .limitExceeded:
                    throw error
                case .truncated where encryptedHeaderWasValidated
                    || encryptedHeaderEnvelopeIsShort:
                    // A salt plus one AES block needs 24 bytes. That physical
                    // shortage is unambiguous even before a header CRC passes;
                    // after one CRC passes, later short ranges are truncation.
                    throw error
                default:
                    // RAR3 has no independent password-check field for archive
                    // headers. A bad first decrypted CRC is its password oracle.
                    throw KaitoError.wrongPassword
                }
            }

            let header = parsedHeader.bytes
            let common = header
            let typeByte = common[2]
            let flags = LittleEndian.uint16(common, at: 3)
            let headerEnd = parsedHeader.physicalEnd

            var dataSize: UInt64 = 0
            if flags & RAR4FileFlag.additionalSize != 0 {
                guard header.count >= 11 else {
                    throw KaitoError.malformed(
                        "RAR4 ADD_SIZE flag is set in a short header"
                    )
                }
                dataSize = UInt64(LittleEndian.uint32(header, at: 7))
            }

            guard let type = RAR4HeaderType(rawValue: typeByte) else {
                guard flags & RAR4CommonFlag.skipIfUnknown != 0 else {
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
                guard offset == markerEnd else {
                    throw KaitoError.malformed("RAR4 main header is not first")
                }
                guard header.count >= 13 else {
                    throw KaitoError.malformed("short RAR4 main header")
                }
                if flags & RAR4MainFlag.encryptionVersion != 0, header.count < 14 {
                    throw KaitoError.malformed(
                        "RAR4 main header lacks its encryption version"
                    )
                }
                if flags & RAR4MainFlag.encryptedHeaders != 0 {
                    if password == nil {
                        password = try passwordProvider?.password(for: .rar)
                    }
                    guard password != nil else {
                        throw KaitoError.passwordRequired
                    }
                }
                mainHeader = RAR4MainHeader(flags: flags)
                dataSize = 0

            case .file:
                guard let mainHeader else {
                    throw KaitoError.malformed("RAR4 file precedes the main header")
                }
                let parsed = try parseFileHeader(
                    header,
                    source: source,
                    headerOffset: offset,
                    dataOffset: headerEnd,
                    mainHeader: mainHeader,
                    limits: limits,
                    timestamps: &timestamps
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
                if flags & RAR4FileFlag.large != 0 {
                    guard header.count >= 40 else {
                        throw KaitoError.malformed(
                            "short large RAR4 new-subblock header"
                        )
                    }
                    dataSize = UInt64(LittleEndian.uint32(header, at: 7))
                        | UInt64(LittleEndian.uint32(header, at: 32)) << 32
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
                return RAR4ParsedVolume(
                    pendingEntries: pendingEntries,
                    records: records,
                    mainHeader: mainHeader!,
                    requestsNextVolume: flags & RAR4EndFlag.nextVolume != 0
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
        return RAR4ParsedVolume(
            pendingEntries: pendingEntries,
            records: records,
            mainHeader: mainHeader,
            requestsNextVolume: false
        )
    }

    /// Reads one plaintext or archive-password-encrypted header and returns the
    /// first physical byte after its padded representation. In `-hp` archives
    /// every post-main header is independently prefixed by an 8-byte RAR3 salt.
    private static func readHeader(
        source: any ByteSource,
        offset: UInt64,
        encrypted: Bool,
        password: String?,
        keyCache: RAR3KeyCache,
        passwordEncodings: RAR4Reader.PasswordEncodingSelection,
        limits: ReadLimits
    ) throws -> RAR4ParsedHeader {
        if !encrypted {
            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= 7 else { throw KaitoError.truncated }
            let common = try readByteRange(
                source: source,
                offset: offset,
                count: 7
            )
            let headerSize = UInt64(LittleEndian.uint16(common, at: 5))
            guard headerSize >= 7 else {
                throw KaitoError.malformed("RAR4 header size is smaller than 7")
            }
            try Checked.size(headerSize, limit: limits.maxMetadataSize)
            let end = try Checked.add(offset, headerSize)
            guard end <= source.length else { throw KaitoError.truncated }
            let bytes = try readByteRange(
                source: source,
                offset: offset,
                count: try Checked.toInt(headerSize)
            )
            try validateHeaderCRC(bytes, offset: offset)
            return RAR4ParsedHeader(bytes: bytes, physicalEnd: end)
        }

        guard let password else { throw KaitoError.passwordRequired }
        let remaining = try Checked.sub(source.length, offset)
        guard remaining >= 24 else { throw KaitoError.truncated }
        let salt = try readByteRange(
            source: source,
            offset: offset,
            count: 8
        )
        let ciphertextOffset = try Checked.add(offset, 8)
        // The writer's OS, which decides the password encoding, is itself inside
        // the encrypted header. Only a password with non-BMP characters has two
        // candidate encodings; the header CRC selects one. At most two are tried.
        let encodings = passwordEncodings.unixScalars.map { [$0] }
            ?? (password.unicodeScalars.contains { $0.value > 0xFFFF } ? [false, true] : [false])
        var firstError: (any Error)?
        for unixScalars in encodings {
            do {
                let derived = try keyCache.key(password: password, salt: salt, unixScalars: unixScalars)
                let header = try readEncryptedHeader(
                    source: source, offset: offset, ciphertextOffset: ciphertextOffset,
                    derived: derived, limits: limits
                )
                passwordEncodings.unixScalars = unixScalars
                return header
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? KaitoError.wrongPassword
    }

    private static func readEncryptedHeader(
        source: any ByteSource, offset: UInt64, ciphertextOffset: UInt64,
        derived: RAR3DerivedKey, limits: ReadLimits
    ) throws -> RAR4ParsedHeader {
        let commonSource = try RARAESCBCByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: 16,
            plaintextSize: 16,
            key: derived.key,
            initializationVector: derived.initializationVector
        )
        let common = try readByteRange(source: commonSource, offset: 0, count: 7)
        let headerSize = UInt64(LittleEndian.uint16(common, at: 5))
        guard headerSize >= 7 else {
            throw KaitoError.malformed("RAR4 header size is smaller than 7")
        }
        try Checked.size(headerSize, limit: limits.maxMetadataSize)
        let paddedSize = try Checked.add(headerSize, 15) & ~UInt64(15)
        let end = try Checked.add(ciphertextOffset, paddedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        let decrypted = try RARAESCBCByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: paddedSize,
            plaintextSize: headerSize,
            key: derived.key,
            initializationVector: derived.initializationVector
        )
        let bytes = try readByteRange(
            source: decrypted,
            offset: 0,
            count: try Checked.toInt(headerSize)
        )
        try validateHeaderCRC(bytes, offset: offset)
        return RAR4ParsedHeader(bytes: bytes, physicalEnd: end)
    }

    private static func validateHeaderCRC(
        _ header: [UInt8],
        offset: UInt64
    ) throws {
        guard header.count >= 7 else {
            throw KaitoError.malformed("short RAR4 common header")
        }
        let expected = LittleEndian.uint16(header, at: 0)
        let actual = UInt16(truncatingIfNeeded: CRC32.checksum(Array(header.dropFirst(2))))
        guard actual == expected else {
            throw KaitoError.malformed(
                "RAR4 header CRC mismatch at offset \(offset)"
            )
        }
    }

    private static func parseFileHeader(
        _ header: [UInt8],
        source: any ByteSource,
        headerOffset: UInt64,
        dataOffset: UInt64,
        mainHeader: RAR4MainHeader,
        limits: ReadLimits,
        timestamps: inout DOSTimestampDecoder
    ) throws -> (entry: RAR4PendingEntry, record: RAR4EntryRecord) {
        guard header.count >= 32 else {
            throw KaitoError.malformed("short RAR4 file header")
        }
        let flags = LittleEndian.uint16(header, at: 3)
        guard flags & RAR4FileFlag.additionalSize != 0 else {
            throw KaitoError.malformed("RAR4 file header lacks ADD_SIZE")
        }

        let packedLow = LittleEndian.uint32(header, at: 7)
        let unpackedLow = LittleEndian.uint32(header, at: 11)
        let hostOS = header[15]
        let fileCRC = LittleEndian.uint32(header, at: 16)
        let dosTime = LittleEndian.uint32(header, at: 20)
        let unpackVersion = header[24]
        let method = header[25]
        let nameSize = Int(LittleEndian.uint16(header, at: 26))
        let attributes = LittleEndian.uint32(header, at: 28)

        var cursor = 32
        let packedSize: UInt64
        let unpackedSize: UInt64
        if flags & RAR4FileFlag.large != 0 {
            guard header.count - cursor >= 8 else {
                throw KaitoError.malformed("short large RAR4 file header")
            }
            let packedHigh = LittleEndian.uint32(header, at: cursor)
            let unpackedHigh = LittleEndian.uint32(header, at: cursor + 4)
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
        if flags & RAR4FileFlag.salt != 0 {
            guard header.count - cursor >= 8 else {
                throw KaitoError.malformed("RAR4 file header lacks its salt")
            }
            salt = Array(header[cursor..<(cursor + 8)])
            cursor += 8
        } else {
            salt = nil
        }

        var modificationDate = try dosDate(dosTime, decoder: &timestamps)
        if flags & RAR4FileFlag.extendedTime != 0 {
            modificationDate = try parseExtendedTimes(
                header,
                cursor: &cursor,
                baseModificationDate: modificationDate,
                timestamps: &timestamps
            )
        }

        let dictionaryTag = flags & RAR4FileFlag.dictionaryMask
        let isDirectory = dictionaryTag == RAR4FileFlag.dictionaryMask
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

        let windowsDirectory = RAR4HostOS.usesDOSAttributes(hostOS) && attributes & 0x10 != 0
        let unixType = attributes & 0o170000
        let kind: EntryKind
        if isDirectory || windowsDirectory {
            kind = .directory
        } else if RAR4HostOS.usesUnixMode(hostOS),
                  unixType == 0o120000 {
            kind = .symlink
        } else {
            kind = .file
        }
        let permissions: UInt16?
        if RAR4HostOS.usesUnixMode(hostOS) {
            permissions = UInt16(truncatingIfNeeded: attributes) & 0o7777
        } else {
            permissions = nil
        }

        // Unknown methods remain listable, and fail explicitly when read.
        // This is intentionally not a parse failure.
        return makePendingAndRecord(
            RAR4FileHeaderFields(
                headerOffset: headerOffset,
                dataOffset: dataOffset,
                flags: flags,
                rawName: rawName,
                decodedName: decodedName,
                kind: kind,
                packedSize: packedSize,
                unpackedSize: unpackedSize,
                modificationDate: modificationDate,
                permissions: permissions,
                hostOS: hostOS,
                attributes: attributes,
                unpackVersion: unpackVersion,
                method: method,
                dictionarySize: dictionarySize,
                salt: salt,
                fileCRC: fileCRC
            ),
            source: source,
            mainHeader: mainHeader
        )
    }

    private static func makePendingAndRecord(
        _ fields: RAR4FileHeaderFields,
        source: any ByteSource,
        mainHeader: RAR4MainHeader
    ) -> (entry: RAR4PendingEntry, record: RAR4EntryRecord) {
        let flags = fields.flags
        let methodName = methodDescription(fields.method)
        var specific: [String: String] = [
            "attributes": String(format: "0x%08x", fields.attributes),
            "dictionarySize": String(fields.dictionarySize),
            "flags": String(format: "0x%04x", flags),
            "headerOffset": String(fields.headerOffset),
            "hostOS": hostDescription(fields.hostOS),
            "mainSolid": mainHeader.isSolid ? "true" : "false",
            "method": String(format: "0x%02x", fields.method),
            "newVolumeNumbering": mainHeader.flags & RAR4MainFlag.newNumbering != 0
                ? "true" : "false",
            "splitAfter": flags & RAR4FileFlag.splitAfter != 0 ? "true" : "false",
            "splitBefore": flags & RAR4FileFlag.splitBefore != 0 ? "true" : "false",
            "unpackVersion": String(fields.unpackVersion),
            "volume": mainHeader.isVolume ? "true" : "false",
            "firstVolume": mainHeader.flags & RAR4MainFlag.firstVolume != 0
                ? "true" : "false",
            "versionedName": flags & RAR4FileFlag.version != 0 ? "true" : "false",
        ]
        if fields.kind == .symlink {
            specific["linkTargetStoredAsData"] = "true"
        }
        let pending = RAR4PendingEntry(
            rawName: fields.rawName,
            fallbackName: fields.decodedName.fallback,
            decodedUnicodeName: fields.decodedName.unicode,
            declaredEncoding: fields.decodedName.declared,
            kind: fields.kind,
            unpackedSize: fields.unpackedSize,
            packedSize: fields.packedSize,
            modificationDate: fields.modificationDate,
            permissions: fields.permissions,
            isEncrypted: flags & RAR4FileFlag.encrypted != 0,
            crc32: fields.fileCRC,
            methodDescription: methodName,
            formatSpecific: specific
        )
        let record = RAR4EntryRecord(
            packedSegments: [SourceSegment(
                source: source,
                offset: fields.dataOffset,
                length: fields.packedSize
            )],
            packedPartCRC32: [flags & RAR4FileFlag.splitAfter != 0 ? fields.fileCRC : nil],
            packedSize: fields.packedSize,
            unpackedSize: fields.unpackedSize,
            crc32: fields.fileCRC,
            firstFlags: flags,
            lastFlags: flags,
            unpackVersion: fields.unpackVersion,
            method: fields.method,
            dictionarySize: fields.dictionarySize,
            salt: fields.salt
        )
        return (pending, record)
    }

    private static func decodeName(
        _ field: [UInt8],
        flags: UInt16
    ) -> (fallback: [UInt8], unicode: String?, declared: String.Encoding?) {
        guard flags & RAR4FileFlag.unicode != 0 else {
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
        baseModificationDate: Date?,
        timestamps: inout DOSTimestampDecoder
    ) throws -> Date? {
        guard header.count - cursor >= 2 else {
            throw KaitoError.malformed("truncated RAR4 extended-time flags")
        }
        let flags = LittleEndian.uint16(header, at: cursor)
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
                date = try dosDate(LittleEndian.uint32(header, at: cursor), decoder: &timestamps)
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

    /// Decodes a packed DOS timestamp (date in the high word). Zero means the
    /// field is unset. The shared decoder treats a zero date word as unset as
    /// well, but RAR4 rejects a zero date carrying a nonzero time (day 0).
    private static func dosDate(
        _ packed: UInt32,
        decoder: inout DOSTimestampDecoder
    ) throws -> Date? {
        guard packed != 0 else { return nil }
        let date = UInt16(truncatingIfNeeded: packed >> 16)
        guard date != 0 else {
            throw KaitoError.malformed("invalid DOS timestamp")
        }
        return try decoder.modificationDate(
            date: date,
            time: UInt16(truncatingIfNeeded: packed)
        )
    }

    static func pendingMetadataCost(_ entry: RAR4PendingEntry) throws -> UInt64 {
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
        case RAR4Method.stored: "stored"
        case RAR4Method.fastest: "RAR4 fastest"
        case RAR4Method.fast: "RAR4 fast"
        case RAR4Method.normal: "RAR4 normal"
        case RAR4Method.good: "RAR4 good"
        case RAR4Method.best: "RAR4 best"
        default: String(format: "RAR4 method 0x%02x", method)
        }
    }

    private static func hostDescription(_ host: UInt8) -> String {
        switch host {
        case RAR4HostOS.msDOS: "MS-DOS"
        case RAR4HostOS.os2: "OS/2"
        case RAR4HostOS.windows: "Windows"
        case RAR4HostOS.unix: "Unix"
        case RAR4HostOS.macOS: "Mac OS"
        case RAR4HostOS.beOS: "BeOS"
        case RAR4HostOS.winCE: "WinCE"
        default: "unknown \(host)"
        }
    }
}
