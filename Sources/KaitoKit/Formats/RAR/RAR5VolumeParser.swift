import Foundation

// Format reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// This is a clean-room implementation of the published format description.
// RARLab/UnRAR, 7-Zip, XADMaster, and The Unarchiver source code were not used.

/// Parses the headers of one RAR5 volume: the optional archive-encryption
/// envelope, then CRC-checked main, file, service and end headers with their
/// extra records. File headers become `RAR5PendingEntry` fragments; joining
/// fragments across volumes is `RAR5EntryPublisher`'s job.
enum RAR5VolumeParser {
    static func parseVolume(
        source: any ByteSource,
        volumeNumber: UInt64,
        options: ReaderOptions,
        password: inout String?,
        keyCache: RAR5KeyCache,
        expectedHeaderEncryption: Bool?,
        headerKDFBudget: inout RAR5HeaderKDFWorkBudget
    ) throws -> RAR5VolumeParseState {
        // Recovery applies to the first volume only; a later volume that ends
        // early reports truncation.
        let recoverDamagedArchives = options.recoverDamagedArchives && volumeNumber == 0
        var state = RAR5VolumeParseState()
        var offset = UInt64(RAR5Reader.signature.count)
        var archiveEncryption: RAR5ArchiveEncryptionContext?
        var headerBodyWasVerified = false
        // One bounded ByteReader per volume seeks across payloads and keeps its
        // read-ahead when the next header is still cached. Its capacity depends
        // only on caller limits, never on header sizes.
        var headerReader = try ByteReader(
            source: source,
            bufferCapacity: Int(min(16 * 1_024, options.limits.maxMetadataSize))
        )

        if offset < source.length {
            let firstBlock = try readBlock(
                source: source,
                reader: &headerReader,
                offset: offset,
                limits: options.limits,
                recoverDamagedArchives: recoverDamagedArchives,
                headerBodyWasVerified: &headerBodyWasVerified
            )
            let headersEncrypted = firstBlock.typeValue
                == RAR5HeaderType.encryption.rawValue
            if let expectedHeaderEncryption,
               headersEncrypted != expectedHeaderEncryption {
                throw KaitoError.malformed(
                    "RAR5 header encryption mode changes between volumes"
                )
            }
            state.headersEncrypted = headersEncrypted
            if headersEncrypted {
                archiveEncryption = try parseArchiveEncryptionHeader(
                    firstBlock,
                    options: options,
                    password: &password,
                    keyCache: keyCache,
                    headerKDFBudget: &headerKDFBudget
                )
                offset = firstBlock.nextOffset
            }
        }

        var blockCount = 0
        while offset < source.length, !state.sawEndHeader {
            try checkCancellation(every: blockCount)
            blockCount &+= 1
            let block: RAR5Block
            headerBodyWasVerified = false
            do {
                if let archiveEncryption {
                    block = try readEncryptedBlock(
                        source: source,
                        offset: offset,
                        key: archiveEncryption.key,
                        limits: options.limits,
                        recoverDamagedArchives: recoverDamagedArchives,
                        headerBodyWasVerified: &headerBodyWasVerified
                    )
                } else {
                    block = try readBlock(
                        source: source,
                        reader: &headerReader,
                        offset: offset,
                        limits: options.limits,
                        recoverDamagedArchives: recoverDamagedArchives,
                        headerBodyWasVerified: &headerBodyWasVerified
                    )
                }
            } catch {
                if let archiveEncryption,
                   !archiveEncryption.passwordWasVerified,
                   !state.sawMainHeader {
                    throw KaitoError.wrongPassword
                }
                // Keep the entries read so far only when the header itself is cut
                // by EOF. A CRC-verified but inconsistent header is not recovered.
                if recoverDamagedArchives,
                   state.sawMainHeader,
                   !headerBodyWasVerified,
                   case KaitoError.truncated = error {
                    break
                }
                throw error
            }
            guard block.nextOffset > offset else {
                throw KaitoError.malformed("RAR5 block did not advance")
            }

            switch RAR5HeaderType(rawValue: block.typeValue) {
            case .main:
                guard !state.sawMainHeader else {
                    throw KaitoError.malformed("duplicate RAR5 main header")
                }
                guard state.pending.isEmpty else {
                    throw KaitoError.malformed("RAR5 main header follows a file header")
                }
                try parseMainHeader(block, state: &state, limits: options.limits)
                state.sawMainHeader = true

            case .file:
                guard state.sawMainHeader else {
                    throw KaitoError.malformed("RAR5 file header precedes main header")
                }
                guard state.pending.count < options.limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("RAR5 entry count")
                }
                let pending = try parseFileHeader(
                    block,
                    source: source,
                    volumeNumber: volumeNumber,
                    options: options,
                    state: &state
                )
                state.pending.append(pending)

            case .service:
                guard state.sawMainHeader else {
                    throw KaitoError.malformed("RAR5 service header precedes main header")
                }
                state.serviceHeaderCount += 1
                guard state.serviceHeaderCount <= options.limits.maxMetadataRecordCount else {
                    throw KaitoError.limitExceeded("RAR5 service header count")
                }
                try validateServiceHeader(block, limits: options.limits)

            case .encryption:
                throw KaitoError.malformed(
                    "RAR5 archive encryption header is not first"
                )

            case .end:
                guard state.sawMainHeader else {
                    throw KaitoError.malformed("RAR5 end header precedes main header")
                }
                var cursor = block.specific
                state.endFlags = RAR5EndFlags(rawValue: try cursor.readVInt())
                guard cursor.isAtEnd else {
                    throw KaitoError.malformed("RAR5 end header has trailing fields")
                }
                try validateExtraArea(block.extra, limits: options.limits)
                guard block.dataSize == 0 else {
                    throw KaitoError.malformed("RAR5 end header has a data area")
                }
                state.sawEndHeader = true

            case nil:
                guard block.flags.contains(.skipIfUnknown) else {
                    throw KaitoError.unsupportedMethod("RAR5 header type \(block.typeValue)")
                }
                try validateExtraArea(block.extra, limits: options.limits)
            }
            offset = block.nextOffset
        }

        guard state.sawMainHeader else {
            throw KaitoError.malformed("RAR5 main header is missing")
        }
        guard recoverDamagedArchives || state.sawEndHeader else {
            throw KaitoError.truncated
        }
        if state.endFlags.contains(RAR5EndFlags.moreVolumes),
           !state.archiveFlags.contains(RAR5ArchiveFlags.volume) {
            throw KaitoError.malformed(
                "RAR5 non-volume requests a continuation volume"
            )
        }
        return state
    }

    private static func parseArchiveEncryptionHeader(
        _ block: RAR5Block,
        options: ReaderOptions,
        password: inout String?,
        keyCache: RAR5KeyCache,
        headerKDFBudget: inout RAR5HeaderKDFWorkBudget
    ) throws -> RAR5ArchiveEncryptionContext {
        guard block.flags.rawValue == 0,
              block.extra.isAtEnd,
              block.dataSize == 0 else {
            throw KaitoError.malformed(
                "RAR5 archive encryption header has invalid common flags"
            )
        }

        var cursor = block.specific
        let version = try cursor.readVInt()
        guard version == 0 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 archive encryption version \(version)"
            )
        }
        let flags = try cursor.readVInt()
        guard flags & ~UInt64(0x0001) == 0 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 archive encryption flags 0x\(String(flags, radix: 16))"
            )
        }
        let kdfCount = try cursor.readUInt8()
        guard kdfCount <= options.maxRAR5KDFCountPower else {
            throw KaitoError.unsupportedMethod(
                "RAR5 KDF count \(kdfCount)"
            )
        }
        let salt = try cursor.readBytes(16)
        let checkValue = flags & 0x0001 != 0
            ? try cursor.readBytes(12)
            : nil
        guard cursor.isAtEnd else {
            throw KaitoError.malformed(
                "RAR5 archive encryption header has trailing fields"
            )
        }

        if password == nil, let provider = options.passwordProvider {
            password = try provider.password(for: .rar)
        }
        guard let password else { throw KaitoError.passwordRequired }
        let (keys, passwordWasVerified) = try keyCache.checkedKey(
            password: password,
            salt: salt,
            count: kdfCount,
            checkValue: checkValue
        ) { candidate in
            try headerKDFBudget.charge(passwordUTF8: candidate, salt: salt, count: kdfCount)
        }
        return RAR5ArchiveEncryptionContext(
            key: keys.encryptionKey,
            passwordWasVerified: passwordWasVerified
        )
    }

    private static func readEncryptedBlock(
        source: any ByteSource,
        offset: UInt64,
        key: Data,
        limits: ReadLimits,
        recoverDamagedArchives: Bool,
        headerBodyWasVerified: inout Bool
    ) throws -> RAR5Block {
        guard offset <= source.length,
              try Checked.sub(source.length, offset) >= 32 else {
            throw KaitoError.truncated
        }
        let initializationVector = Data(try readByteRange(
            source: source,
            offset: offset,
            count: 16
        ))
        let ciphertextOffset = try Checked.add(offset, 16)
        let firstBlockSource = try RARAESCBCByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: 16,
            plaintextSize: 16,
            key: key,
            initializationVector: initializationVector
        )
        let firstPlaintext = try readByteRange(
            source: firstBlockSource,
            offset: 0,
            count: 16
        )

        var sizeReader = try ByteReader(
            source: DataByteSource(data: Data(firstPlaintext)),
            offset: 4
        )
        let headerSize = try RAR5VInt.read(from: &sizeReader)
        guard headerSize.bytes.count <= 3 else {
            throw KaitoError.malformed(
                "RAR5 encrypted header-size vint exceeds 3 bytes"
            )
        }
        guard headerSize.value >= 2 else {
            throw KaitoError.malformed("RAR5 encrypted header size is too small")
        }
        try Checked.size(headerSize.value, limit: limits.maxMetadataSize)

        var logicalSize = try Checked.add(4, UInt64(headerSize.bytes.count))
        logicalSize = try Checked.add(logicalSize, headerSize.value)
        let paddedSize = try Checked.add(logicalSize, 15) & ~UInt64(15)
        guard paddedSize >= 16 else {
            throw KaitoError.malformed("RAR5 encrypted header size is invalid")
        }
        let ciphertextEnd = try Checked.add(ciphertextOffset, paddedSize)
        guard ciphertextEnd <= source.length else { throw KaitoError.truncated }

        let plaintextSource = try RARAESCBCByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: paddedSize,
            plaintextSize: paddedSize,
            key: key,
            initializationVector: initializationVector
        )
        let plaintext = try readByteRange(
            source: plaintextSource,
            offset: 0,
            count: try Checked.toInt(paddedSize)
        )
        let logicalCount = try Checked.toInt(logicalSize)

        let recordedCRC = LittleEndian.uint32(plaintext, at: 0)
        let bodyStart = 4 + headerSize.bytes.count
        let body = Array(plaintext[bodyStart..<logicalCount])
        var crc = CRC32()
        crc.update(headerSize.bytes)
        crc.update(body)
        guard crc.value == recordedCRC else {
            throw KaitoError.malformed(
                "RAR5 encrypted header CRC mismatch at offset \(offset)"
            )
        }
        headerBodyWasVerified = true
        return try makeBlock(
            offset: offset,
            body: body,
            dataOffset: ciphertextEnd,
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
    }

    private static func readBlock(
        source: any ByteSource,
        reader: inout ByteReader,
        offset: UInt64,
        limits: ReadLimits,
        recoverDamagedArchives: Bool,
        headerBodyWasVerified: inout Bool
    ) throws -> RAR5Block {
        try reader.seek(to: offset)
        guard reader.remaining >= 5 else { throw KaitoError.truncated }
        let recordedCRC = try reader.readUInt32LE()
        let headerSize = try RAR5VInt.read(from: &reader)
        guard headerSize.bytes.count <= 3 else {
            throw KaitoError.malformed("RAR5 header-size vint exceeds 3 bytes")
        }
        guard headerSize.value >= 2 else {
            throw KaitoError.malformed("RAR5 header size is too small")
        }
        try Checked.size(headerSize.value, limit: limits.maxMetadataSize)
        guard headerSize.value <= reader.remaining else { throw KaitoError.truncated }
        let body = [UInt8](try reader.readBytes(try Checked.toInt(headerSize.value)))

        var crc = CRC32()
        crc.update(headerSize.bytes)
        crc.update(body)
        guard crc.value == recordedCRC else {
            throw KaitoError.malformed("RAR5 header CRC mismatch at offset \(offset)")
        }

        headerBodyWasVerified = true
        return try makeBlock(
            offset: offset,
            body: body,
            dataOffset: reader.offset,
            sourceLength: source.length,
            recoverDamagedArchives: recoverDamagedArchives
        )
    }

    private static func makeBlock(
        offset: UInt64,
        body: [UInt8],
        dataOffset: UInt64,
        sourceLength: UInt64,
        recoverDamagedArchives: Bool
    ) throws -> RAR5Block {
        var cursor = RAR5ByteCursor(body)
        let type = try cursor.readVInt()
        let flags = RAR5HeaderFlags(rawValue: try cursor.readVInt())
        let extraSize = flags.contains(.extraArea) ? try cursor.readVInt() : 0
        let dataSize = flags.contains(.dataArea) ? try cursor.readVInt() : 0
        guard extraSize <= UInt64(cursor.remaining) else {
            throw KaitoError.malformed("RAR5 extra area exceeds its header")
        }
        let extraCount = try Checked.toInt(extraSize)
        let specificSize = cursor.remaining - extraCount
        let specific = try cursor.readSubcursor(specificSize)
        let extra = try cursor.readSubcursor(extraCount)
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("RAR5 header cursor is inconsistent")
        }

        let declaredEnd = try Checked.add(dataOffset, dataSize)
        let availableDataSize: UInt64
        let isDataTruncated: Bool
        let nextOffset: UInt64
        if declaredEnd <= sourceLength {
            availableDataSize = dataSize
            isDataTruncated = false
            nextOffset = declaredEnd
        } else {
            // Keep the declared size; only recovery limits the readable range to EOF.
            guard recoverDamagedArchives else { throw KaitoError.truncated }
            availableDataSize = try Checked.sub(sourceLength, dataOffset)
            isDataTruncated = true
            nextOffset = sourceLength
        }
        guard nextOffset > offset else {
            throw KaitoError.malformed("RAR5 block did not advance")
        }
        return RAR5Block(
            offset: offset,
            typeValue: type,
            flags: flags,
            specific: specific,
            extra: extra,
            dataOffset: dataOffset,
            dataSize: dataSize,
            availableDataSize: availableDataSize,
            isDataTruncated: isDataTruncated,
            nextOffset: nextOffset
        )
    }

    private static func parseMainHeader(
        _ block: RAR5Block,
        state: inout RAR5VolumeParseState,
        limits: ReadLimits
    ) throws {
        var cursor = block.specific
        let archiveFlags = RAR5ArchiveFlags(rawValue: try cursor.readVInt())
        let volumeNumber = archiveFlags.contains(RAR5ArchiveFlags.volumeNumber) ? try cursor.readVInt() : 0
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("RAR5 main header has trailing fields")
        }
        guard block.dataSize == 0 else {
            throw KaitoError.malformed("RAR5 main header has a data area")
        }
        if archiveFlags.contains(RAR5ArchiveFlags.volumeNumber), !archiveFlags.contains(RAR5ArchiveFlags.volume) {
            throw KaitoError.malformed("RAR5 non-volume has a volume number")
        }
        state.archiveFlags = archiveFlags
        state.volumeNumber = volumeNumber
        try validateExtraArea(block.extra, limits: limits)
    }

    private static func parseFileHeader(
        _ block: RAR5Block,
        source: any ByteSource,
        volumeNumber: UInt64,
        options: ReaderOptions,
        state: inout RAR5VolumeParseState
    ) throws -> RAR5PendingEntry {
        var cursor = block.specific
        let fileFlags = RAR5FileFlags(rawValue: try cursor.readVInt())
        let storedUnpackedSize = try cursor.readVInt()
        let unpackedSize: UInt64? = fileFlags.contains(.unpackedSizeUnknown)
            ? nil
            : storedUnpackedSize
        let attributes = try cursor.readVInt()
        let basicModificationDate: Date?
        if fileFlags.contains(.unixTime) {
            basicModificationDate = Date(timeIntervalSince1970: TimeInterval(try cursor.readUInt32LE()))
        } else {
            basicModificationDate = nil
        }
        let dataCRC = fileFlags.contains(.crc32) ? try cursor.readUInt32LE() : nil
        let compression = try RAR5CompressionInfo(rawValue: cursor.readVInt())
        let hostOS = try cursor.readVInt()
        let nameLength = try cursor.readVInt()
        try Checked.size(nameLength, limit: options.limits.maxMetadataSize)
        guard nameLength <= UInt64(cursor.remaining) else { throw KaitoError.truncated }
        let rawName = try cursor.readBytes(try Checked.toInt(nameLength))
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("RAR5 file header has trailing fields")
        }

        guard EncodingDetector.isStrictUTF8(rawName) else {
            throw KaitoError.malformed("RAR5 file name is not valid UTF-8")
        }
        let name = String(decoding: rawName, as: UTF8.self)
        guard !name.isEmpty, name.utf8.first != 0x2F, !name.utf8.contains(0) else {
            throw KaitoError.malformed("RAR5 file name is unsafe")
        }
        if hostOS == RAR5HostOS.windows, name.contains("\\") {
            throw KaitoError.malformed("RAR5 Windows file name contains a backslash")
        }
        let components = name
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !components.isEmpty else {
            throw KaitoError.malformed("RAR5 file name has no path components")
        }
        guard components.count <= options.limits.maxPathComponentCount else {
            throw KaitoError.limitExceeded("RAR5 path component count")
        }

        var extraCursor = block.extra
        var extras = RAR5FileExtras()
        var singletonExtraTypes: Set<UInt64> = []
        try parseExtraRecords(&extraCursor, limits: options.limits) {
            type, record in
            try rejectDuplicateSingletonExtra(
                type,
                seen: &singletonExtraTypes,
                headerKind: "file"
            )
            switch type {
            case RAR5ExtraRecordType.encryption:
                extras.encryption = try parseEncryptionRecord(&record)
            case RAR5ExtraRecordType.hash:
                extras.hash = try parseHashRecord(&record)
            case RAR5ExtraRecordType.time:
                try parseTimeRecord(&record, extras: &extras)
            case RAR5ExtraRecordType.version:
                _ = try record.readVInt() // reserved flags
                extras.version = try record.readVInt()
            case RAR5ExtraRecordType.redirection:
                extras.redirection = try parseRedirectionRecord(&record)
            case RAR5ExtraRecordType.owner:
                try parseOwnerRecord(&record, extras: &extras)
            case RAR5ExtraRecordType.serviceData:
                break // service-data record; bounded by its enclosing record
            default:
                break // extensions are explicitly skippable
            }
        }

        var kind: EntryKind
        let isUnixHost = hostOS == RAR5HostOS.unix
        let unixMode = isUnixHost ? UInt16(truncatingIfNeeded: attributes) : 0
        if fileFlags.contains(.directory) || (isUnixHost && unixMode & 0o170000 == 0o040000) {
            kind = .directory
        } else if isUnixHost && unixMode & 0o170000 == 0o120000 {
            kind = .symlink
        } else {
            kind = .file
        }
        if let redirection = extras.redirection {
            switch redirection.type {
            case RAR5RedirectionType.symbolicLinks: kind = .symlink
            case RAR5RedirectionType.hardLink: kind = .hardlink
            default: kind = .other
            }
        }

        let permissions: UInt16? = isUnixHost ? unixMode & 0o7777 : nil
        let retained = try retainedMetadataCost(
            rawName: rawName,
            name: name,
            components: components,
            extras: extras
        )
        state.retainedMetadataSize = try Checked.add(state.retainedMetadataSize, retained)
        try Checked.size(
            state.retainedMetadataSize,
            limit: options.limits.maxTotalMetadataSize
        )

        let isIncomplete = options.recoverDamagedArchives && block.isDataTruncated
        let availablePackedSize = isIncomplete ? block.availableDataSize : nil
        let splitAfter = block.flags.contains(.splitAfter)
        return RAR5PendingEntry(
            rawName: rawName,
            name: name,
            pathComponents: components,
            kind: kind,
            unpackedSize: unpackedSize,
            packedSize: block.dataSize,
            availablePackedSize: availablePackedSize,
            isIncomplete: isIncomplete,
            modificationDate: extras.modificationDate ?? basicModificationDate,
            permissions: permissions,
            crc32: splitAfter ? nil : dataCRC,
            compression: compression,
            firstHeaderFlags: block.flags,
            lastHeaderFlags: block.flags,
            packedSegments: [SourceSegment(
                source: source,
                offset: block.dataOffset,
                length: availablePackedSize ?? block.dataSize
            )],
            packedPartIntegrity: [RAR5PackedPartIntegrity(
                crc32: splitAfter ? dataCRC : nil,
                hash: splitAfter ? extras.hash : nil,
                usesTweakedChecksums: extras.encryption?.usesTweakedChecksums
                    ?? false
            )],
            firstVolumeNumber: volumeNumber,
            lastVolumeNumber: volumeNumber,
            attributes: attributes,
            hostOS: hostOS,
            extras: extras
        )
    }

    private static func validateServiceHeader(
        _ block: RAR5Block,
        limits: ReadLimits
    ) throws {
        // Parse with the file-header layout so quick-open, comment and future
        // service records cannot desynchronize scanning. The three leading
        // fields are read before the directory check, as their errors win.
        var cursor = block.specific
        let flags = RAR5FileFlags(rawValue: try cursor.readVInt())
        _ = try cursor.readVInt() // unpacked size
        _ = try cursor.readVInt() // reserved attributes
        guard !flags.contains(.directory) else {
            throw KaitoError.malformed("RAR5 service header has the directory flag")
        }
        if flags.contains(.unixTime) { _ = try cursor.readUInt32LE() }
        if flags.contains(.crc32) { _ = try cursor.readUInt32LE() }
        let compression = try RAR5CompressionInfo(rawValue: cursor.readVInt())
        guard !compression.isSolid else {
            throw KaitoError.malformed("RAR5 service header has the solid flag")
        }
        _ = try cursor.readVInt() // host OS
        let nameSize = try cursor.readVInt()
        guard nameSize <= UInt64(cursor.remaining) else { throw KaitoError.truncated }
        _ = try cursor.readBytes(try Checked.toInt(nameSize))
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("RAR5 service header has trailing fields")
        }
        var extra = block.extra
        var singletonExtraTypes: Set<UInt64> = []
        try parseExtraRecords(&extra, limits: limits) { type, _ in
            try rejectDuplicateSingletonExtra(
                type,
                seen: &singletonExtraTypes,
                headerKind: "service"
            )
        }
    }

    private static func validateExtraArea(
        _ input: RAR5ByteCursor,
        limits: ReadLimits
    ) throws {
        var cursor = input
        try parseExtraRecords(&cursor, limits: limits) { _, _ in }
    }

    private static func parseExtraRecords(
        _ cursor: inout RAR5ByteCursor,
        limits: ReadLimits,
        body: (UInt64, inout RAR5ByteCursor) throws -> Void
    ) throws {
        var recordCount = 0
        while !cursor.isAtEnd {
            recordCount += 1
            guard recordCount <= limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("RAR5 extra record count")
            }
            let size = try cursor.readVInt()
            guard size > 0, size <= UInt64(cursor.remaining) else {
                throw KaitoError.malformed("RAR5 extra record exceeds its area")
            }
            var record = try cursor.readSubcursor(try Checked.toInt(size))
            let type = try record.readVInt()
            try body(type, &record)
            if record.remaining > 0 { try record.skip(record.remaining) }
        }
    }

    private static func rejectDuplicateSingletonExtra(
        _ type: UInt64,
        seen: inout Set<UInt64>,
        headerKind: String
    ) throws {
        guard (RAR5ExtraRecordType.encryption...RAR5ExtraRecordType.owner).contains(type) else { return }
        guard seen.insert(type).inserted else {
            throw KaitoError.malformed(
                "duplicate RAR5 \(headerKind) extra record type \(type)"
            )
        }
    }

    private static func parseEncryptionRecord(
        _ cursor: inout RAR5ByteCursor
    ) throws -> RAR5EncryptionRecord {
        let version = try cursor.readVInt()
        guard version == 0 else {
            return RAR5EncryptionRecord(
                version: version,
                flags: 0,
                kdfCount: 0,
                salt: [],
                initializationVector: [],
                checkValue: nil
            )
        }
        let flags = try cursor.readVInt()
        let kdfCount = try cursor.readUInt8()
        let salt = try cursor.readBytes(16)
        let iv = try cursor.readBytes(16)
        let check = flags & 0x0001 != 0 ? try cursor.readBytes(12) : nil
        return RAR5EncryptionRecord(
            version: version,
            flags: flags,
            kdfCount: kdfCount,
            salt: salt,
            initializationVector: iv,
            checkValue: check
        )
    }

    private static func parseHashRecord(
        _ cursor: inout RAR5ByteCursor
    ) throws -> RAR5HashRecord {
        let type = try cursor.readVInt()
        if type == 0 {
            return RAR5HashRecord(type: type, digest: try cursor.readBytes(32))
        }
        return RAR5HashRecord(type: type, digest: try cursor.readBytes(cursor.remaining))
    }

    private static func parseTimeRecord(
        _ cursor: inout RAR5ByteCursor,
        extras: inout RAR5FileExtras
    ) throws {
        let flags = try cursor.readVInt()
        let unix = flags & 0x0001 != 0
        let hasMTime = flags & 0x0002 != 0
        let hasCTime = flags & 0x0004 != 0
        let hasATime = flags & 0x0008 != 0
        let hasNanoseconds = unix && flags & 0x0010 != 0

        var mtime: Date?
        var ctime: Date?
        var atime: Date?
        if hasMTime { mtime = try readTime(&cursor, unix: unix) }
        if hasCTime { ctime = try readTime(&cursor, unix: unix) }
        if hasATime { atime = try readTime(&cursor, unix: unix) }
        if hasNanoseconds {
            if hasMTime { mtime = try addNanoseconds(try cursor.readUInt32LE(), to: mtime) }
            if hasCTime { ctime = try addNanoseconds(try cursor.readUInt32LE(), to: ctime) }
            if hasATime { atime = try addNanoseconds(try cursor.readUInt32LE(), to: atime) }
        }
        if let mtime { extras.modificationDate = mtime }
        if let ctime { extras.creationDate = ctime }
        if let atime { extras.accessDate = atime }
    }

    private static func readTime(
        _ cursor: inout RAR5ByteCursor,
        unix: Bool
    ) throws -> Date {
        if unix {
            return Date(timeIntervalSince1970: TimeInterval(try cursor.readUInt32LE()))
        }
        return WindowsFileTime.date(ticks: try cursor.readUInt64LE())
    }

    private static func addNanoseconds(
        _ nanos: UInt32,
        to date: Date?
    ) throws -> Date? {
        guard nanos < 1_000_000_000 else {
            throw KaitoError.malformed("RAR5 nanosecond field is out of range")
        }
        guard let date else { return nil }
        return date.addingTimeInterval(TimeInterval(nanos) / 1_000_000_000)
    }

    private static func parseRedirectionRecord(
        _ cursor: inout RAR5ByteCursor
    ) throws -> RAR5RedirectionRecord {
        let type = try cursor.readVInt()
        let flags = try cursor.readVInt()
        let length = try cursor.readVInt()
        guard length <= UInt64(cursor.remaining) else { throw KaitoError.truncated }
        let bytes = try cursor.readBytes(try Checked.toInt(length))
        guard EncodingDetector.isStrictUTF8(bytes) else {
            throw KaitoError.malformed("RAR5 redirection target is not valid UTF-8")
        }
        let target = String(decoding: bytes, as: UTF8.self)
        guard !target.utf8.contains(0) else {
            throw KaitoError.malformed("RAR5 redirection target contains NUL")
        }
        return RAR5RedirectionRecord(type: type, flags: flags, target: target)
    }

    private static func parseOwnerRecord(
        _ cursor: inout RAR5ByteCursor,
        extras: inout RAR5FileExtras
    ) throws {
        let flags = try cursor.readVInt()
        if flags & 0x0001 != 0 {
            let count = try cursor.readVInt()
            guard count <= UInt64(cursor.remaining) else { throw KaitoError.truncated }
            extras.ownerName = String(
                decoding: try cursor.readBytes(try Checked.toInt(count)),
                as: UTF8.self
            )
        }
        if flags & 0x0002 != 0 {
            let count = try cursor.readVInt()
            guard count <= UInt64(cursor.remaining) else { throw KaitoError.truncated }
            extras.groupName = String(
                decoding: try cursor.readBytes(try Checked.toInt(count)),
                as: UTF8.self
            )
        }
        if flags & 0x0004 != 0 { extras.ownerID = try cursor.readVInt() }
        if flags & 0x0008 != 0 { extras.groupID = try cursor.readVInt() }
    }

    private static func retainedMetadataCost(
        rawName: [UInt8],
        name: String,
        components: [String],
        extras: RAR5FileExtras
    ) throws -> UInt64 {
        var size = try Checked.add(UInt64(rawName.count), UInt64(name.utf8.count))
        size = try Checked.add(
            size,
            try Checked.mul(UInt64(components.count), UInt64(MemoryLayout<String>.stride))
        )
        for component in components {
            size = try Checked.add(size, UInt64(component.utf8.count))
        }
        for string in [
            extras.redirection?.target,
            extras.ownerName,
            extras.groupName,
        ].compactMap({ $0 }) {
            size = try Checked.add(size, UInt64(string.utf8.count))
        }
        if let digest = extras.hash?.digest {
            size = try Checked.add(size, UInt64(digest.count))
        }
        return try Checked.add(size, 256)
    }
}
