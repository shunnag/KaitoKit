import Foundation

// Format reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// This is a clean-room implementation of the published format description.
// RARLab/UnRAR, 7-Zip, XADMaster, and The Unarchiver source code were not used.

final class RAR5Reader: FormatReader {
    static let signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]

    private struct Block {
        let offset: UInt64
        let typeValue: UInt64
        let flags: RAR5HeaderFlags
        let specific: RAR5ByteCursor
        let extra: RAR5ByteCursor
        let dataOffset: UInt64
        let dataSize: UInt64
        let nextOffset: UInt64
    }

    private struct FileExtras {
        var encryption: RAR5EncryptionRecord?
        var hash: RAR5HashRecord?
        var modificationDate: Date?
        var creationDate: Date?
        var accessDate: Date?
        var version: UInt64?
        var redirection: RAR5RedirectionRecord?
        var ownerName: String?
        var groupName: String?
        var ownerID: UInt64?
        var groupID: UInt64?
    }

    /// Integrity values attached to one packed range. RAR5 defines CRC32 and
    /// BLAKE2sp in every non-final split header over that header's packed data;
    /// the final header carries the checksum/hash of the complete unpacked file.
    private struct PackedPartIntegrity {
        let crc32: UInt32?
        let hash: RAR5HashRecord?
    }

    private struct PendingEntry {
        let rawName: [UInt8]
        let name: String
        let pathComponents: [String]
        let kind: EntryKind
        let unpackedSize: UInt64?
        let packedSize: UInt64
        let modificationDate: Date?
        let permissions: UInt16?
        let crc32: UInt32?
        let compression: RAR5CompressionInfo
        let firstHeaderFlags: RAR5HeaderFlags
        let lastHeaderFlags: RAR5HeaderFlags
        let packedSegments: [RARSourceSegment]
        let packedPartIntegrity: [PackedPartIntegrity]
        let firstVolumeNumber: UInt64
        let lastVolumeNumber: UInt64
        let attributes: UInt64
        let hostOS: UInt64
        let extras: FileExtras

        var splitBefore: Bool { firstHeaderFlags.contains(.splitBefore) }
        var splitAfter: Bool { lastHeaderFlags.contains(.splitAfter) }
        var isMultiVolume: Bool {
            packedSegments.count > 1 || splitBefore || splitAfter
        }
    }

    private struct Record {
        let packedSegments: [RARSourceSegment]
        let packedPartIntegrity: [PackedPartIntegrity]
        let packedSize: UInt64
        let unpackedSize: UInt64?
        let compression: RAR5CompressionInfo
        let encryption: RAR5EncryptionRecord?
        let hash: RAR5HashRecord?
        let requiresPreviousVolume: Bool
        let requiresNextVolume: Bool
    }

    private struct ParseState {
        var pending: [PendingEntry] = []
        var archiveFlags = RAR5ArchiveFlags()
        var volumeNumber: UInt64 = 0
        var sawMainHeader = false
        var sawEndHeader = false
        var endFlags = RAR5EndFlags()
        var serviceHeaderCount = 0
        var extraRecordCount = 0
        var retainedMetadataSize: UInt64 = 0
    }

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = nil

    private let source: any ByteSource
    private let sourceURL: URL?
    private let options: ReaderOptions
    private let records: [Record]
    private let keyCache = RAR5KeyCache()
    private var password: String?

    var resolvedPassword: String? { password }

    init(
        source: any ByteSource,
        options: ReaderOptions,
        sourceURL: URL? = nil,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor? = nil
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.password = options.password

        guard source.length >= UInt64(Self.signature.count) else {
            throw KaitoError.truncated
        }
        let signature = try readByteRange(source: source, offset: 0, count: Self.signature.count)
        guard signature == Self.signature else { throw KaitoError.unsupportedFormat }

        let parsed = try Self.parse(
            source: source,
            sourceURL: sourceURL,
            sourceDirectoryAnchor: sourceDirectoryAnchor,
            options: options
        )
        self.entries = parsed.entries
        self.records = parsed.records
    }

    /// Returns an independent mutable reader while retaining the exact source
    /// handles authenticated during the original parse. In particular, a
    /// reopened multi-volume reader never resolves sibling paths a second time.
    func reopened(options: ReaderOptions) -> RAR5Reader {
        RAR5Reader(
            source: source,
            sourceURL: sourceURL,
            options: options,
            entries: entries,
            records: records
        )
    }

    private init(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        entries: [ArchiveEntry],
        records: [Record]
    ) {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.entries = entries
        self.records = records
        self.password = options.password
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
            throw KaitoError.notFound("RAR5 entry index \(entry.index)")
        }
        let record = records[entry.index]

        if record.requiresPreviousVolume || record.requiresNextVolume {
            if sourceURL == nil {
                throw KaitoError.unsupportedMethod("multi-volume from Data")
            }
            throw KaitoError.truncated
        }

        if record.encryption != nil, record.packedSegments.count > 1 {
            throw KaitoError.unsupportedMethod(
                "RAR5 encrypted multi-volume entry"
            )
        }
        // Apply the packed-byte work/allocation ceiling before the optional
        // per-part integrity pass performs any attacker-sized I/O.
        try Checked.size(record.packedSize, limit: limits.maxEntrySize)
        try validatePackedParts(record, entryIndex: entry.index)

        let packedSource: any ByteSource
        let packedOffset: UInt64
        if record.packedSegments.count == 1,
           let segment = record.packedSegments.first {
            packedSource = segment.source
            packedOffset = segment.offset
        } else if record.packedSize == 0 {
            packedSource = DataByteSource(data: Data())
            packedOffset = 0
        } else {
            packedSource = try RARConcatenatedByteSource(
                segments: record.packedSegments,
                maximumLength: record.packedSize,
                maximumSegmentCount: limits.maxVolumeCount
            )
            packedOffset = 0
        }

        var compressedSource: any ByteSource = packedSource
        var compressedOffset = packedOffset
        var hashKey: Data?
        if let encryption = record.encryption {
            guard let password else { throw KaitoError.passwordRequired }
            let keys = try keyCache.key(
                password: password,
                salt: encryption.salt,
                count: encryption.kdfCount
            )
            if let checkValue = encryption.checkValue {
                try keys.verify(passwordCheckValue: checkValue)
            }
            compressedSource = try RARAESCBCByteSource(
                source: packedSource,
                ciphertextOffset: packedOffset,
                ciphertextSize: record.packedSize,
                // Compression blocks carry their own authenticated logical
                // end. Stored entries below use the declared unpacked length,
                // so AES padding is never exposed in either case.
                plaintextSize: record.packedSize,
                key: keys.encryptionKey,
                initializationVector: Data(encryption.initializationVector)
            )
            compressedOffset = 0
            if encryption.usesTweakedChecksums {
                hashKey = keys.hashKey
            }
        }

        let outputLength: UInt64? = record.unpackedSize
        let expectedCRC = entry.crc32
        var decompressor: any Decompressor
        if record.compression.method == 0 {
            if record.encryption == nil, let outputLength,
               outputLength != record.packedSize {
                throw KaitoError.malformed("RAR5 stored sizes differ")
            }
            if record.encryption != nil, outputLength == nil {
                throw KaitoError.unsupportedMethod(
                    "RAR5 encrypted stored entry with unknown unpacked size"
                )
            }
            let logicalStoredSize = outputLength ?? record.packedSize
            guard logicalStoredSize <= record.packedSize else {
                throw KaitoError.malformed(
                    "RAR5 encrypted stored entry exceeds its ciphertext"
                )
            }
            decompressor = try CopyDecompressor(
                source: compressedSource,
                offset: compressedOffset,
                compressedSize: logicalStoredSize
            )
        } else {
            guard record.compression.usesVersionZeroAlgorithm else {
                throw KaitoError.unsupportedMethod("RAR compression algorithm version 1")
            }
            guard !record.compression.isSolid else {
                throw KaitoError.unsupportedMethod("RAR5 solid compressed stream")
            }
            decompressor = try RAR5Decoder(
                source: compressedSource,
                offset: compressedOffset,
                compressedSize: record.packedSize,
                unpackedSize: outputLength,
                dictionarySize: record.compression.dictionarySize,
                limits: limits
            )
        }

        var completionCheck: (() throws -> Void)?
        // A successfully verified password-check value disambiguates a later
        // payload digest failure: it is corruption, not a bad password. Older
        // records without that independent check necessarily remain ambiguous.
        let mismatchIsWrongPassword = record.encryption.map {
            $0.checkValue == nil
        } ?? false
        if options.verifyRAR5Blake2sp,
           let recordHash = record.hash,
           recordHash.type == 0 {
            let hashing = try RAR5Blake2spDecompressor(
                base: decompressor,
                expected: recordHash.digest,
                hashKey: hashKey,
                entryIndex: entry.index,
                mismatchIsWrongPassword: mismatchIsWrongPassword
            )
            decompressor = hashing
            completionCheck = { try hashing.verify() }
        }
        let crc32Transform: ((UInt32) -> UInt32)? = hashKey.map { key in
            { checksum in RAR5ChecksumMAC.crc32(checksum, hashKey: key) }
        }
        return try EntryStream(
            decompressor: decompressor,
            length: outputLength,
            expectedCRC32: expectedCRC,
            entryIndex: entry.index,
            limits: limits,
            completionCheck: completionCheck,
            checksumMismatchIsWrongPassword: mismatchIsWrongPassword,
            crc32Transform: crc32Transform
        )
    }

    /// Authenticates each non-final volume range before a decoder observes any
    /// of the concatenated stream. This is deliberately chunked: packed sizes
    /// are attacker-controlled and must never become a temporary allocation.
    private func validatePackedParts(
        _ record: Record,
        entryIndex: Int
    ) throws {
        guard record.packedPartIntegrity.count == record.packedSegments.count else {
            throw KaitoError.malformed("RAR5 split integrity metadata is inconsistent")
        }
        guard record.packedPartIntegrity.contains(where: {
            $0.crc32 != nil || (options.verifyRAR5Blake2sp && $0.hash?.type == 0)
        }) else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        for (segment, integrity) in zip(
            record.packedSegments,
            record.packedPartIntegrity
        ) {
            let verifyHash = options.verifyRAR5Blake2sp && integrity.hash?.type == 0
            guard integrity.crc32 != nil || verifyHash else { continue }
            let end = try Checked.add(segment.offset, segment.length)
            guard end <= segment.source.length else { throw KaitoError.truncated }

            var crc = CRC32()
            var hash = verifyHash ? Blake2sp() : nil
            var consumed: UInt64 = 0
            while consumed < segment.length {
                let wanted = try Checked.toInt(min(
                    UInt64(buffer.count),
                    try Checked.sub(segment.length, consumed)
                ))
                let count = try buffer.withUnsafeMutableBytes { storage in
                    try segment.source.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: storage[..<wanted]),
                        at: try Checked.add(segment.offset, consumed)
                    )
                }
                guard count > 0, count <= wanted else { throw KaitoError.truncated }
                buffer.withUnsafeBytes { storage in
                    let bytes = UnsafeRawBufferPointer(rebasing: storage[..<count])
                    if integrity.crc32 != nil { crc.update(bytes) }
                    hash?.update(bytes)
                }
                consumed = try Checked.add(consumed, UInt64(count))
            }

            if let expectedCRC = integrity.crc32, crc.value != expectedCRC {
                throw KaitoError.checksumMismatch(entry: entryIndex)
            }
            if let expectedHash = integrity.hash,
               expectedHash.type == 0,
               verifyHash {
                guard expectedHash.digest.count == 32 else {
                    throw KaitoError.malformed("RAR5 BLAKE2sp digest is not 32 bytes")
                }
                guard let actualHash = hash?.finalize(),
                      RARConstantTime.equals(actualHash, Data(expectedHash.digest)) else {
                    throw KaitoError.checksumMismatch(entry: entryIndex)
                }
            }
        }
    }

    private static func parse(
        source: any ByteSource,
        sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?,
        options: ReaderOptions
    ) throws -> (entries: [ArchiveEntry], records: [Record]) {
        let first = try parseVolume(
            source: source,
            volumeNumber: 0,
            options: options
        )
        guard sourceURL != nil || first.volumeNumber == 0 else {
            throw KaitoError.malformed(
                "RAR5 volume number \(first.volumeNumber) does not match expected 0"
            )
        }
        if first.archiveFlags.contains(.volumeNumber), first.volumeNumber == 0 {
            throw KaitoError.malformed(
                "RAR5 first volume has an explicit volume number"
            )
        }

        guard first.archiveFlags.contains(.volume), let sourceURL else {
            if first.endFlags.contains(.moreVolumes),
               !first.archiveFlags.contains(.volume) {
                throw KaitoError.malformed(
                    "RAR5 non-volume requests a continuation volume"
                )
            }
            return try publish(first.pending, archiveFlags: first.archiveFlags)
        }

        // Constructing the locator authenticates the first volume's signature,
        // main-header CRC, volume marker and zero-based number. Later lookups do
        // the same before any file headers or packed ranges are accepted.
        let locator = try RARVolumeLocator(
            firstVolumeURL: sourceURL,
            firstVolumeSource: source,
            firstVolumeDirectory: sourceDirectoryAnchor,
            naming: .rar5,
            maxMetadataSize: options.limits.maxMetadataSize,
            maxVolumeCount: options.limits.maxVolumeCount
        )
        var merged: [PendingEntry] = []
        var activeSplit: PendingEntry?
        var current = first
        var volumeNumber: UInt64 = 0
        var totalRetainedMetadata = current.retainedMetadataSize
        var totalExtraRecords = current.extraRecordCount
        var totalServiceHeaders = current.serviceHeaderCount

        try mergeFragments(
            current.pending,
            into: &merged,
            activeSplit: &activeSplit,
            limits: options.limits
        )

        while current.endFlags.contains(.moreVolumes) {
            let nextNumber = try Checked.add(volumeNumber, 1)
            guard nextNumber < UInt64(options.limits.maxVolumeCount) else {
                throw KaitoError.limitExceeded("RAR5 volume count")
            }
            let located = try locator.locate(volumeNumber: nextNumber)
            let next = try parseVolume(
                source: located.source,
                volumeNumber: nextNumber,
                options: options
            )
            guard next.archiveFlags.contains(.volume) else {
                throw KaitoError.malformed(
                    "RAR5 continuation is not marked as a volume"
                )
            }
            guard next.volumeNumber == nextNumber else {
                throw KaitoError.malformed(
                    "RAR5 volume number \(next.volumeNumber) does not match expected \(nextNumber)"
                )
            }
            guard next.archiveFlags.contains(.solid) ==
                    first.archiveFlags.contains(.solid) else {
                throw KaitoError.malformed(
                    "RAR5 solid archive flag changes between volumes"
                )
            }

            totalRetainedMetadata = try Checked.add(
                totalRetainedMetadata,
                next.retainedMetadataSize
            )
            try Checked.size(
                totalRetainedMetadata,
                limit: options.limits.maxTotalMetadataSize
            )
            totalExtraRecords = try checkedMetadataRecordSum(
                totalExtraRecords,
                next.extraRecordCount,
                limit: options.limits.maxMetadataRecordCount,
                label: "RAR5 extra record count"
            )
            totalServiceHeaders = try checkedMetadataRecordSum(
                totalServiceHeaders,
                next.serviceHeaderCount,
                limit: options.limits.maxMetadataRecordCount,
                label: "RAR5 service header count"
            )

            try mergeFragments(
                next.pending,
                into: &merged,
                activeSplit: &activeSplit,
                limits: options.limits
            )
            current = next
            volumeNumber = nextNumber
        }

        guard activeSplit == nil else { throw KaitoError.truncated }
        guard merged.count <= options.limits.maxEntryCount else {
            throw KaitoError.limitExceeded("RAR5 entry count")
        }
        return try publish(merged, archiveFlags: first.archiveFlags)
    }

    private static func checkedMetadataRecordSum(
        _ lhs: Int,
        _ rhs: Int,
        limit: Int,
        label: String
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= limit else {
            throw KaitoError.limitExceeded(label)
        }
        return sum
    }

    private static func parseVolume(
        source: any ByteSource,
        volumeNumber: UInt64,
        options: ReaderOptions
    ) throws -> ParseState {
        var state = ParseState()
        var offset = UInt64(signature.count)

        while offset < source.length, !state.sawEndHeader {
            let block = try readBlock(source: source, offset: offset, limits: options.limits)
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
                try validateServiceHeader(block, limits: options.limits, state: &state)

            case .encryption:
                throw KaitoError.unsupportedMethod("RAR5 encrypted headers")

            case .end:
                guard state.sawMainHeader else {
                    throw KaitoError.malformed("RAR5 end header precedes main header")
                }
                var cursor = block.specific
                state.endFlags = RAR5EndFlags(rawValue: try cursor.readVInt())
                guard cursor.isAtEnd else {
                    throw KaitoError.malformed("RAR5 end header has trailing fields")
                }
                try validateExtraArea(block.extra, state: &state, limits: options.limits)
                guard block.dataSize == 0 else {
                    throw KaitoError.malformed("RAR5 end header has a data area")
                }
                state.sawEndHeader = true

            case nil:
                guard block.flags.contains(.skipIfUnknown) else {
                    throw KaitoError.unsupportedMethod("RAR5 header type \(block.typeValue)")
                }
                try validateExtraArea(block.extra, state: &state, limits: options.limits)
            }
            offset = block.nextOffset
        }

        guard state.sawMainHeader else {
            throw KaitoError.malformed("RAR5 main header is missing")
        }
        guard state.sawEndHeader else {
            throw KaitoError.truncated
        }
        if state.endFlags.contains(.moreVolumes),
           !state.archiveFlags.contains(.volume) {
            throw KaitoError.malformed(
                "RAR5 non-volume requests a continuation volume"
            )
        }
        return state
    }

    private static func readBlock(
        source: any ByteSource,
        offset: UInt64,
        limits: ReadLimits
    ) throws -> Block {
        var reader = try ByteReader(source: source, offset: offset)
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

        let dataOffset = reader.offset
        let nextOffset = try Checked.add(dataOffset, dataSize)
        guard nextOffset <= source.length else { throw KaitoError.truncated }
        guard nextOffset > offset else {
            throw KaitoError.malformed("RAR5 block did not advance")
        }
        return Block(
            offset: offset,
            typeValue: type,
            flags: flags,
            specific: specific,
            extra: extra,
            dataOffset: dataOffset,
            dataSize: dataSize,
            nextOffset: nextOffset
        )
    }

    private static func parseMainHeader(
        _ block: Block,
        state: inout ParseState,
        limits: ReadLimits
    ) throws {
        var cursor = block.specific
        let archiveFlags = RAR5ArchiveFlags(rawValue: try cursor.readVInt())
        let volumeNumber = archiveFlags.contains(.volumeNumber) ? try cursor.readVInt() : 0
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("RAR5 main header has trailing fields")
        }
        guard block.dataSize == 0 else {
            throw KaitoError.malformed("RAR5 main header has a data area")
        }
        if archiveFlags.contains(.volumeNumber), !archiveFlags.contains(.volume) {
            throw KaitoError.malformed("RAR5 non-volume has a volume number")
        }
        state.archiveFlags = archiveFlags
        state.volumeNumber = volumeNumber
        try validateExtraArea(block.extra, state: &state, limits: limits)
    }

    private static func parseFileHeader(
        _ block: Block,
        source: any ByteSource,
        volumeNumber: UInt64,
        options: ReaderOptions,
        state: inout ParseState
    ) throws -> PendingEntry {
        var cursor = block.specific
        let fileFlags = RAR5FileFlags(rawValue: try cursor.readVInt())
        let storedUnpackedSize = try cursor.readVInt()
        let unpackedSize: UInt64? = fileFlags.contains(.unpackedSizeUnknown)
            ? nil
            : storedUnpackedSize
        if let unpackedSize {
            try Checked.size(unpackedSize, limit: options.limits.maxEntrySize)
        }
        let attributes = try cursor.readVInt()
        let basicModificationDate: Date?
        if fileFlags.contains(.unixTime) {
            basicModificationDate = Date(timeIntervalSince1970: TimeInterval(try cursor.readUInt32LE()))
        } else {
            basicModificationDate = nil
        }
        let dataCRC = fileFlags.contains(.crc32) ? try cursor.readUInt32LE() : nil
        let compression = try RAR5CompressionInfo(
            rawValue: try cursor.readVInt(),
            limits: options.limits
        )
        guard compression.method <= 5 else {
            throw KaitoError.unsupportedMethod("RAR5 compression method \(compression.method)")
        }
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
        guard !name.isEmpty, !name.hasPrefix("/"), !name.utf8.contains(0) else {
            throw KaitoError.malformed("RAR5 file name is unsafe")
        }
        if hostOS == 0, name.contains("\\") {
            throw KaitoError.malformed("RAR5 Windows file name contains a backslash")
        }
        let components = name
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else {
            throw KaitoError.malformed("RAR5 file name has no path components")
        }
        guard components.count <= options.limits.maxPathComponentCount else {
            throw KaitoError.limitExceeded("RAR5 path component count")
        }

        var extraCursor = block.extra
        var extras = FileExtras()
        var singletonExtraTypes: Set<UInt64> = []
        try parseExtraRecords(&extraCursor, state: &state, limits: options.limits) {
            type, record in
            try rejectDuplicateSingletonExtra(
                type,
                seen: &singletonExtraTypes,
                headerKind: "file"
            )
            switch type {
            case 0x01:
                extras.encryption = try parseEncryptionRecord(
                    &record,
                    maximumKDFCount: options.maxRAR5KDFCountPower
                )
            case 0x02:
                extras.hash = try parseHashRecord(&record)
            case 0x03:
                try parseTimeRecord(&record, extras: &extras)
            case 0x04:
                _ = try record.readVInt() // reserved flags
                extras.version = try record.readVInt()
            case 0x05:
                extras.redirection = try parseRedirectionRecord(&record)
            case 0x06:
                try parseOwnerRecord(&record, extras: &extras)
            case 0x07:
                break // service-data record; bounded by its enclosing record
            default:
                break // extensions are explicitly skippable
            }
        }

        var kind: EntryKind
        let unixMode = hostOS == 1 ? UInt16(truncatingIfNeeded: attributes) : 0
        if fileFlags.contains(.directory) || (hostOS == 1 && unixMode & 0o170000 == 0o040000) {
            kind = .directory
        } else if hostOS == 1 && unixMode & 0o170000 == 0o120000 {
            kind = .symlink
        } else {
            kind = .file
        }
        if let redirection = extras.redirection {
            switch redirection.type {
            case 1, 2, 3: kind = .symlink
            case 4: kind = .hardlink
            default: kind = .other
            }
        }

        let permissions: UInt16? = hostOS == 1 ? unixMode & 0o7777 : nil
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

        let splitAfter = block.flags.contains(.splitAfter)
        return PendingEntry(
            rawName: rawName,
            name: name,
            pathComponents: components,
            kind: kind,
            unpackedSize: unpackedSize,
            packedSize: block.dataSize,
            modificationDate: extras.modificationDate ?? basicModificationDate,
            permissions: permissions,
            crc32: splitAfter ? nil : dataCRC,
            compression: compression,
            firstHeaderFlags: block.flags,
            lastHeaderFlags: block.flags,
            packedSegments: [RARSourceSegment(
                source: source,
                offset: block.dataOffset,
                length: block.dataSize
            )],
            packedPartIntegrity: [PackedPartIntegrity(
                crc32: splitAfter ? dataCRC : nil,
                hash: splitAfter ? extras.hash : nil
            )],
            firstVolumeNumber: volumeNumber,
            lastVolumeNumber: volumeNumber,
            attributes: attributes,
            hostOS: hostOS,
            extras: extras
        )
    }

    private static func validateServiceHeader(
        _ block: Block,
        limits: ReadLimits,
        state: inout ParseState
    ) throws {
        var cursor = block.specific
        _ = try cursor.readVInt() // service file flags
        _ = try cursor.readVInt() // unpacked size
        _ = try cursor.readVInt() // reserved attributes
        // Remaining optional fields depend on flags. Reparse with the file layout
        // so quick-open, comments and future services cannot desynchronize scanning.
        cursor = block.specific
        let flags = RAR5FileFlags(rawValue: try cursor.readVInt())
        guard !flags.contains(.directory) else {
            throw KaitoError.malformed("RAR5 service header has the directory flag")
        }
        _ = try cursor.readVInt()
        _ = try cursor.readVInt()
        if flags.contains(.unixTime) { _ = try cursor.readUInt32LE() }
        if flags.contains(.crc32) { _ = try cursor.readUInt32LE() }
        let compression = try RAR5CompressionInfo(
            rawValue: cursor.readVInt(),
            limits: limits
        )
        guard !compression.isSolid else {
            throw KaitoError.malformed("RAR5 service header has the solid flag")
        }
        guard compression.method <= 5 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 service compression method \(compression.method)"
            )
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
        try parseExtraRecords(&extra, state: &state, limits: limits) { type, _ in
            try rejectDuplicateSingletonExtra(
                type,
                seen: &singletonExtraTypes,
                headerKind: "service"
            )
        }
    }

    private static func validateExtraArea(
        _ input: RAR5ByteCursor,
        state: inout ParseState,
        limits: ReadLimits
    ) throws {
        var cursor = input
        try parseExtraRecords(&cursor, state: &state, limits: limits) { _, _ in }
    }

    private static func parseExtraRecords(
        _ cursor: inout RAR5ByteCursor,
        state: inout ParseState,
        limits: ReadLimits,
        body: (UInt64, inout RAR5ByteCursor) throws -> Void
    ) throws {
        while !cursor.isAtEnd {
            state.extraRecordCount += 1
            guard state.extraRecordCount <= limits.maxMetadataRecordCount else {
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
        guard (0x01...0x06).contains(type) else { return }
        guard seen.insert(type).inserted else {
            throw KaitoError.malformed(
                "duplicate RAR5 \(headerKind) extra record type \(type)"
            )
        }
    }

    private static func parseEncryptionRecord(
        _ cursor: inout RAR5ByteCursor,
        maximumKDFCount: UInt8
    ) throws -> RAR5EncryptionRecord {
        let version = try cursor.readVInt()
        guard version == 0 else {
            throw KaitoError.unsupportedMethod("RAR5 file encryption version \(version)")
        }
        let flags = try cursor.readVInt()
        let kdfCount = try cursor.readUInt8()
        guard kdfCount <= min(maximumKDFCount, 24) else {
            throw KaitoError.unsupportedMethod("RAR5 KDF count \(kdfCount)")
        }
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
        extras: inout FileExtras
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
        let fileTime = try cursor.readUInt64LE()
        let seconds = TimeInterval(fileTime) / 10_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: seconds)
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
        extras: inout FileExtras
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
        extras: FileExtras
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

    private static func mergeFragments(
        _ fragments: [PendingEntry],
        into completed: inout [PendingEntry],
        activeSplit: inout PendingEntry?,
        limits: ReadLimits
    ) throws {
        for fragment in fragments {
            if fragment.splitBefore {
                guard let active = activeSplit, active.splitAfter else {
                    throw KaitoError.malformed(
                        "RAR5 split continuation has no preceding file part"
                    )
                }
                activeSplit = try mergeSplitParts(active, fragment)
            } else {
                guard activeSplit == nil else {
                    throw KaitoError.malformed(
                        "RAR5 split continuation is missing"
                    )
                }
                activeSplit = fragment
            }

            if let active = activeSplit, !active.splitAfter {
                guard completed.count < limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("RAR5 entry count")
                }
                completed.append(active)
                activeSplit = nil
            }
        }
    }

    private static func mergeSplitParts(
        _ first: PendingEntry,
        _ continuation: PendingEntry
    ) throws -> PendingEntry {
        let expectedVolume = try Checked.add(first.lastVolumeNumber, 1)
        guard continuation.firstVolumeNumber == expectedVolume,
              continuation.lastVolumeNumber == expectedVolume else {
            throw KaitoError.malformed(
                "RAR5 split file parts are not in consecutive volumes"
            )
        }
        guard first.rawName == continuation.rawName,
              first.name == continuation.name,
              first.pathComponents == continuation.pathComponents,
              first.kind == continuation.kind,
              first.compression == continuation.compression,
              first.attributes == continuation.attributes,
              first.hostOS == continuation.hostOS,
              first.permissions == continuation.permissions,
              first.modificationDate == continuation.modificationDate else {
            throw KaitoError.malformed(
                "RAR5 split file metadata changes between volumes"
            )
        }
        guard (first.extras.encryption == nil) ==
                (continuation.extras.encryption == nil),
              first.extras.creationDate == continuation.extras.creationDate,
              first.extras.accessDate == continuation.extras.accessDate,
              first.extras.version == continuation.extras.version,
              first.extras.redirection == continuation.extras.redirection,
              first.extras.ownerName == continuation.extras.ownerName,
              first.extras.groupName == continuation.extras.groupName,
              first.extras.ownerID == continuation.extras.ownerID,
              first.extras.groupID == continuation.extras.groupID else {
            throw KaitoError.malformed(
                "RAR5 split file extra metadata changes between volumes"
            )
        }

        let unpackedSize: UInt64?
        switch (first.unpackedSize, continuation.unpackedSize) {
        case let (lhs?, rhs?):
            guard lhs == rhs else {
                throw KaitoError.malformed(
                    "RAR5 split file unpacked size changes between volumes"
                )
            }
            unpackedSize = lhs
        case let (lhs?, nil):
            unpackedSize = lhs
        case let (nil, rhs?):
            unpackedSize = rhs
        case (nil, nil):
            unpackedSize = nil
        }

        let segmentCount = try Checked.add(
            UInt64(first.packedSegments.count),
            UInt64(continuation.packedSegments.count)
        )
        guard segmentCount <= 65_536 else {
            throw KaitoError.limitExceeded("RAR5 split stream has too many segments")
        }
        let packedSize = try Checked.add(first.packedSize, continuation.packedSize)
        var extras = first.extras
        // Non-final parts authenticate their packed slice. Only the final part's
        // hash and CRC describe the unpacked logical file published to callers.
        extras.hash = continuation.extras.hash

        return PendingEntry(
            rawName: first.rawName,
            name: first.name,
            pathComponents: first.pathComponents,
            kind: first.kind,
            unpackedSize: unpackedSize,
            packedSize: packedSize,
            modificationDate: first.modificationDate,
            permissions: first.permissions,
            crc32: continuation.crc32,
            compression: first.compression,
            firstHeaderFlags: first.firstHeaderFlags,
            lastHeaderFlags: continuation.lastHeaderFlags,
            packedSegments: first.packedSegments + continuation.packedSegments,
            packedPartIntegrity: first.packedPartIntegrity
                + continuation.packedPartIntegrity,
            firstVolumeNumber: first.firstVolumeNumber,
            lastVolumeNumber: continuation.lastVolumeNumber,
            attributes: first.attributes,
            hostOS: first.hostOS,
            extras: extras
        )
    }

    private static func publish(
        _ pending: [PendingEntry],
        archiveFlags: RAR5ArchiveFlags
    ) throws -> (entries: [ArchiveEntry], records: [Record]) {
        var solidGroups = [Int](repeating: -1, count: pending.count)
        if archiveFlags.contains(.solid) {
            var previousFileIndex: Int?
            for index in pending.indices where pending[index].kind != .directory {
                if pending[index].compression.isSolid {
                    guard let predecessor = previousFileIndex else {
                        throw KaitoError.malformed(
                            "first RAR5 file cannot continue a solid stream"
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
        } else if pending.contains(where: { $0.compression.isSolid }) {
            throw KaitoError.malformed("RAR5 solid file is not in a solid archive")
        }

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        var lastEntryByNormalizedPath: [String: Int] = [:]
        entries.reserveCapacity(pending.count)
        records.reserveCapacity(pending.count)

        for (index, item) in pending.enumerated() {
            var specific: [String: String] = [
                "rarVersion": item.compression.version == 0 ? "5" : "7",
                "compressionInfo": String(format: "0x%llx", item.compression.rawValue),
                "method": String(item.compression.method),
                "dictionarySize": String(item.compression.dictionarySize),
                "hostOS": String(item.hostOS),
                "attributes": String(format: "0x%llx", item.attributes),
                "solid": item.compression.isSolid ? "true" : "false",
                "splitBefore": item.splitBefore ? "true" : "false",
                "splitAfter": item.splitAfter ? "true" : "false",
                "multiVolume": item.isMultiVolume ? "true" : "false",
                "volumeSegmentCount": String(item.packedSegments.count),
                "unpackedSizeUnknown": item.unpackedSize == nil ? "true" : "false",
                "encryption": item.extras.encryption == nil ? "none" : "RAR5 AES-256",
            ]
            if let hash = item.extras.hash {
                specific["hashType"] = hash.type == 0 ? "BLAKE2sp" : String(hash.type)
                specific["hash"] = hash.digest.map { String(format: "%02x", $0) }.joined()
            }
            if let version = item.extras.version { specific["fileVersion"] = String(version) }
            if let redirection = item.extras.redirection {
                specific["linkPath"] = redirection.target
                specific["redirectionType"] = String(redirection.type)
                specific["redirectionTargetIsDirectory"] = redirection.flags & 1 != 0 ? "true" : "false"
                if redirection.type == 4,
                   let normalizedTarget = normalizedExtractionPath(redirection.target),
                   let targetIndex = lastEntryByNormalizedPath[normalizedTarget],
                   entries.indices.contains(targetIndex) {
                    let target = entries[targetIndex]
                    if target.kind == .file ||
                        (target.kind == .hardlink &&
                            target.formatSpecific["hardLinkTargetIndex"] != nil) {
                        specific["hardLinkTargetIndex"] = String(targetIndex)
                    }
                }
            }
            if let date = item.extras.creationDate {
                specific["creationTime"] = String(date.timeIntervalSince1970)
            }
            if let date = item.extras.accessDate {
                specific["accessTime"] = String(date.timeIntervalSince1970)
            }
            if let owner = item.extras.ownerName { specific["owner"] = owner }
            if let group = item.extras.groupName { specific["group"] = group }
            if let ownerID = item.extras.ownerID { specific["uid"] = String(ownerID) }
            if let groupID = item.extras.groupID { specific["gid"] = String(groupID) }

            let methodDescription = item.compression.method == 0
                ? "RAR5 stored"
                : "RAR5 method \(item.compression.method)"
            let entry = ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: item.rawName,
                    declaredEncoding: .utf8,
                    isDirectoryHint: item.kind == .directory
                ),
                name: item.name,
                pathComponents: item.pathComponents,
                kind: item.kind,
                uncompressedSize: item.unpackedSize,
                compressedSize: item.packedSize,
                modificationDate: item.modificationDate,
                posixPermissions: item.permissions,
                isEncrypted: item.extras.encryption != nil,
                solidGroup: solidGroups[index],
                crc32: item.crc32,
                methodDescription: methodDescription,
                formatSpecific: specific
            )
            entries.append(entry)
            if let normalizedName = normalizedExtractionPath(item.name) {
                // Resolve hard links before insertion so targets are always
                // earlier archive members and cannot form forward cycles.
                lastEntryByNormalizedPath[normalizedName] = entry.index
            }
            records.append(Record(
                packedSegments: item.packedSegments,
                packedPartIntegrity: item.packedPartIntegrity,
                packedSize: item.packedSize,
                unpackedSize: item.unpackedSize,
                compression: item.compression,
                encryption: item.extras.encryption,
                hash: item.extras.hash,
                requiresPreviousVolume: item.splitBefore,
                requiresNextVolume: item.splitAfter
            ))
        }
        return (entries, records)
    }

    private static func normalizedExtractionPath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            return nil
        }
        let rawComponents = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !rawComponents.contains("..") else { return nil }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
