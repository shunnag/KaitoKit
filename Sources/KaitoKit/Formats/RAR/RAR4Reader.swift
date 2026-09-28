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
/// Implements the RAR 2.9/3.x (unpack version 29) container and data paths:
/// stored and LZ/PPMd-H streams, native standard filters, solid groups, SFX,
/// old/new multi-volume sets, and data/header encryption. Older compressed
/// unpack versions and custom RAR VM programs fail explicitly.
final class RAR4Reader: FormatReader {
    static let signature: [UInt8] = [
        0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00,
    ]

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let sourceURL: URL?
    private let options: ReaderOptions
    private let records: [RAR4EntryRecord]
    private let solidGroupMembers: [Int: [Int]]
    private let firstEncryptedSolidMembers: [Int: Int]
    private let keyCache: RAR3KeyCache
    private var password: String?
    private var solidCoordinators: [Int: RARSolidCoordinator<RAR29Decoder.SolidState>] = [:]
    private var activeSolidGroup: Int?
    /// Which RAR3 password encoding the writer used, once a CRC has decided it.
    final class PasswordEncodingSelection {
        var unixScalars: Bool?
    }
    private let passwordEncodings: PasswordEncodingSelection
    private var isPasswordProbe = false

    var resolvedPassword: String? { password }

    init(
        source: any ByteSource,
        options: ReaderOptions,
        sourceURL: URL? = nil,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor? = nil,
        signatureOffset: UInt64? = nil
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        let resolvedSignatureOffset: UInt64
        if let signatureOffset {
            resolvedSignatureOffset = signatureOffset
        } else {
            guard let match = try RARSignatureScanner.find(source: source),
                  match.version == .rar4 else {
                throw KaitoError.unsupportedFormat
            }
            resolvedSignatureOffset = match.offset
        }
        let keyCache = RAR3KeyCache()
        let passwordEncodings = PasswordEncodingSelection()
        self.keyCache = keyCache
        self.passwordEncodings = passwordEncodings
        let parsed = try RAR4EntryPublisher.parse(
            source: source,
            sourceURL: sourceURL,
            sourceDirectoryAnchor: sourceDirectoryAnchor,
            options: options,
            signatureOffset: resolvedSignatureOffset,
            headerKeyCache: keyCache,
            passwordEncodings: passwordEncodings
        )
        self.entries = parsed.entries
        self.records = parsed.records
        let groups = Self.indexSolidGroups(parsed.entries)
        self.solidGroupMembers = groups
        self.firstEncryptedSolidMembers = Self.indexPasswordProbes(groups, records: parsed.records)
        self.nameEncoding = parsed.nameEncoding
        self.password = parsed.resolvedPassword
    }

    private init(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        entries: [ArchiveEntry],
        records: [RAR4EntryRecord],
        nameEncoding: String.Encoding?,
        keyCache: RAR3KeyCache = RAR3KeyCache(),
        unixScalars: Bool? = nil
    ) {
        self.keyCache = keyCache
        self.passwordEncodings = PasswordEncodingSelection()
        self.passwordEncodings.unixScalars = unixScalars
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.entries = entries
        self.records = records
        let groups = Self.indexSolidGroups(entries)
        self.solidGroupMembers = groups
        self.firstEncryptedSolidMembers = Self.indexPasswordProbes(groups, records: records)
        self.nameEncoding = nameEncoding
        self.password = options.password
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        RAR4Reader(
            source: source,
            sourceURL: sourceURL,
            options: options,
            entries: entries,
            records: records,
            nameEncoding: nameEncoding,
            unixScalars: options.password == password ? passwordEncodings.unixScalars : nil
        )
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
        passwordEncodings.unixScalars = nil
        for coordinator in solidCoordinators.values {
            coordinator.invalidateAndRelease()
        }
        solidCoordinators.removeAll(keepingCapacity: false)
        activeSolidGroup = nil
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0,
              entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("RAR4 entry index \(entry.index)")
        }

        let record = records[entry.index]
        guard !record.isSplit else {
            if sourceURL == nil {
                throw KaitoError.unsupportedMethod("multi-volume from Data")
            }
            throw KaitoError.truncated
        }
        guard record.unpackVersion >= 15 else {
            throw KaitoError.unsupportedMethod(
                "RAR4 unpack version \(record.unpackVersion)"
            )
        }
        if !isPasswordProbe, passwordEncodings.unixScalars == nil, let password,
           password.unicodeScalars.contains(where: { $0.value > 0xffff }) {
            // The encoding is a writer property. Resolve it once, at the first
            // nonempty encrypted member of the solid prefix, even for random
            // access. An empty member's CRC cannot distinguish the candidates.
            let probeIndex = entry.solidGroup >= 0
                ? firstEncryptedSolidMembers[entry.solidGroup]
                : (record.isEncrypted && record.unpackedSize > 0 ? entry.index : nil)
            if let probeIndex, probeIndex <= entry.index {
                try resolvePasswordEncoding(for: probeIndex, limits: limits)
            }
        }
        if entry.solidGroup >= 0 {
            return try streamSolidEntry(
                entry,
                group: entry.solidGroup,
                limits: limits
            )
        }
        let payload = try Self.preparePayload(
            record,
            entryIndex: entry.index,
            limits: limits,
            password: password,
            keyCache: keyCache,
            unixScalars: passwordEncodings.unixScalars ?? false
        )

        let decompressor: any Decompressor
        switch record.method {
        case RAR4Method.stored:
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
                source: payload.source,
                offset: payload.offset,
                compressedSize: record.unpackedSize
            )
        case RAR4Method.compressed:
            decompressor = try Self.makeCompressedDecompressor(
                source: payload.source,
                offset: payload.offset,
                compressedSize: record.packedSize,
                uncompressedSize: record.unpackedSize,
                unpackVersion: record.unpackVersion,
                method: record.method,
                dictionarySize: record.dictionarySize,
                isSolid: record.firstFlags & RAR4FileFlag.solid != 0,
                limits: limits,
                mismatchIsWrongPassword: record.isEncrypted
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

    private func streamSolidEntry(
        _ entry: ArchiveEntry,
        group: Int,
        limits: ReadLimits
    ) throws -> EntryStream {
        if let activeSolidGroup, activeSolidGroup != group {
            solidCoordinators[activeSolidGroup]?.invalidateAndRelease()
        }
        activeSolidGroup = group

        let coordinator: RARSolidCoordinator<RAR29Decoder.SolidState>
        if let existing = solidCoordinators[group] {
            coordinator = existing
        } else {
            guard let groupIndices = solidGroupMembers[group],
                  !groupIndices.isEmpty,
                  groupIndices.first == group,
                  groupIndices.contains(entry.index) else {
                throw KaitoError.malformed(
                    "RAR4 solid group membership is inconsistent"
                )
            }

            let dictionarySize = records[groupIndices[0]].dictionarySize
            for index in groupIndices {
                let member = records[index]
                guard RAR4Method.compressed.contains(member.method) else {
                    throw KaitoError.unsupportedMethod(
                        "RAR4 solid group containing a stored entry"
                    )
                }
                guard member.unpackVersion == 29 else {
                    throw KaitoError.unsupportedMethod(
                        "RAR4 solid unpack version \(member.unpackVersion)"
                    )
                }
                guard member.dictionarySize == dictionarySize else {
                    throw KaitoError.malformed(
                        "RAR4 solid dictionary size changes within a group"
                    )
                }
                guard !member.isSplit else {
                    if sourceURL == nil {
                        throw KaitoError.unsupportedMethod(
                            "multi-volume from Data"
                        )
                    }
                    throw KaitoError.truncated
                }
            }

            let capturedEntries = entries
            let capturedRecords = records
            let capturedPassword = password
            let capturedKeyCache = keyCache
            // Later sequential reads may verify additional members after this
            // coordinator is created. Share the selection box, not a snapshot.
            let capturedEncodings = passwordEncodings
            coordinator = RARSolidCoordinator<RAR29Decoder.SolidState>(
                formatLabel: "RAR4",
                entryIndices: groupIndices,
                dictionarySize: dictionarySize,
                limits: limits
            ) { index, state in
                guard capturedEntries.indices.contains(index),
                      capturedRecords.indices.contains(index) else {
                    throw KaitoError.malformed(
                        "RAR4 solid coordinator references an invalid entry"
                    )
                }
                return try Self.makeSolidVerifiedStream(
                    entry: capturedEntries[index],
                    record: capturedRecords[index],
                    limits: limits,
                    state: state,
                    password: capturedPassword,
                    keyCache: capturedKeyCache,
                    unixScalars: capturedEncodings.unixScalars ?? false
                )
            }
            solidCoordinators[group] = coordinator
        }

        let range = try coordinator.stream(
            entryIndex: entry.index,
            unpackedSize: records[entry.index].unpackedSize
        )
        // The retained inner stream verifies every skipped member and the
        // requested member.  The outer stream only enforces caller-facing size
        // semantics, avoiding a duplicate CRC pass.
        return try EntryStream(
            decompressor: range,
            length: records[entry.index].unpackedSize,
            expectedCRC32: nil,
            entryIndex: entry.index,
            limits: limits
        )
    }

    /// CRC verification is streamed through a small scratch buffer. Failed
    /// candidates never change the caller's solid coordinator or emit bytes.
    private func resolvePasswordEncoding(for index: Int, limits: ReadLimits) throws {
        guard passwordEncodings.unixScalars == nil else { return }
        var firstError: (any Error)?
        for unixScalars in [false, true] {
            let probe = RAR4Reader(
                source: source, sourceURL: sourceURL, options: options,
                entries: entries, records: records, nameEncoding: nameEncoding,
                keyCache: keyCache, unixScalars: unixScalars
            )
            probe.password = password
            probe.isPasswordProbe = true
            do {
                let stream = try probe.stream(for: entries[index], limits: limits)
                var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
                while try buffer.withUnsafeMutableBytes({ try stream.read(into: $0) }) > 0 {}
                passwordEncodings.unixScalars = unixScalars
                return
            } catch {
                // Garbage plaintext can also look like an unsupported VM filter
                // or an excessive PPMd allocation. Try the other bounded candidate.
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? KaitoError.wrongPassword
    }

    private static func indexSolidGroups(
        _ entries: [ArchiveEntry]
    ) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for index in entries.indices where entries[index].solidGroup >= 0 {
            result[entries[index].solidGroup, default: []].append(index)
        }
        return result
    }

    private static func indexPasswordProbes(
        _ groups: [Int: [Int]], records: [RAR4EntryRecord]
    ) -> [Int: Int] {
        // Precompute once so an unencrypted or empty solid prefix does not
        // trigger an O(N) member search for every entry.
        groups.compactMapValues { members in
            members.first { records[$0].isEncrypted && records[$0].unpackedSize > 0 }
        }
    }

    private static func makeSolidVerifiedStream(
        entry: ArchiveEntry,
        record: RAR4EntryRecord,
        limits: ReadLimits,
        state: RAR29Decoder.SolidState,
        password: String?,
        keyCache: RAR3KeyCache,
        unixScalars: Bool
    ) throws -> EntryStream {
        guard RAR4Method.compressed.contains(record.method),
              record.unpackVersion == 29 else {
            throw KaitoError.unsupportedMethod("RAR4 unsupported solid stream member")
        }
        let payload = try preparePayload(
            record,
            entryIndex: entry.index,
            limits: limits,
            password: password,
            keyCache: keyCache,
            unixScalars: unixScalars
        )
        let decompressor = try makeCompressedDecompressor(
            source: payload.source,
            offset: payload.offset,
            compressedSize: record.packedSize,
            uncompressedSize: record.unpackedSize,
            unpackVersion: record.unpackVersion,
            method: record.method,
            dictionarySize: record.dictionarySize,
            isSolid: record.firstFlags & RAR4FileFlag.solid != 0,
            limits: limits,
            solidState: state,
            mismatchIsWrongPassword: record.isEncrypted
        )
        return try EntryStream(
            decompressor: decompressor,
            length: record.unpackedSize,
            expectedCRC32: record.crc32,
            entryIndex: entry.index,
            limits: limits,
            checksumMismatchIsWrongPassword: record.isEncrypted
        )
    }

    /// Builds the bounded packed view shared by independent and solid decoders.
    /// The declared packed size is limit-checked and every split part's CRC is
    /// verified before a decoder reads; encrypted data becomes one AES-CBC view.
    private static func preparePayload(
        _ record: RAR4EntryRecord,
        entryIndex: Int,
        limits: ReadLimits,
        password: String?,
        keyCache: RAR3KeyCache,
        unixScalars: Bool
    ) throws -> (source: any ByteSource, offset: UInt64) {
        try Checked.size(record.packedSize, limit: limits.maxEntrySize)
        try validatePackedParts(record, entryIndex: entryIndex)

        let packed: (source: any ByteSource, offset: UInt64)
        if record.packedSegments.count == 1,
           let segment = record.packedSegments.first {
            packed = (segment.source, segment.offset)
        } else if record.packedSize == 0 {
            packed = (DataByteSource(data: Data()), 0)
        } else {
            packed = (
                try ConcatenatedByteSource(
                    segments: record.packedSegments,
                    maximumLength: record.packedSize,
                    maximumSegmentCount: limits.maxVolumeCount,
                    label: "RAR split stream"
                ),
                0
            )
        }

        guard record.isEncrypted else { return packed }
        guard let password else { throw KaitoError.passwordRequired }
        guard let salt = record.salt else {
            throw KaitoError.unsupportedMethod(
                "RAR4 encrypted file data without a RAR3 salt"
            )
        }
        let derived = try keyCache.key(
            password: password, salt: salt,
            unixScalars: unixScalars
        )
        let decrypted = try RARAESCBCByteSource(
            source: packed.source,
            ciphertextOffset: packed.offset,
            ciphertextSize: record.packedSize,
            // RAR does not retain the pre-padding packed byte count. The
            // compression end marker (or a stored member's declared size)
            // keeps consumers from observing decrypted AES padding.
            plaintextSize: record.packedSize,
            key: derived.key,
            initializationVector: derived.initializationVector
        )
        return (decrypted, 0)
    }

    private static func makeCompressedDecompressor(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        unpackVersion: UInt8,
        method: UInt8,
        dictionarySize: UInt64,
        isSolid: Bool,
        limits: ReadLimits,
        solidState: RAR29Decoder.SolidState? = nil,
        mismatchIsWrongPassword: Bool
    ) throws -> any Decompressor {
        do {
            let decoder = try RAR29Decoder(
                source: source,
                offset: offset,
                compressedSize: compressedSize,
                expectedSize: uncompressedSize,
                unpackVersion: unpackVersion,
                method: method,
                dictionarySize: dictionarySize,
                isSolid: isSolid,
                limits: limits,
                solidState: solidState
            )
            guard mismatchIsWrongPassword else { return decoder }
            return RARPasswordAmbiguousDecompressor(
                base: decoder,
                expectedSize: uncompressedSize
            )
        } catch {
            guard mismatchIsWrongPassword else { throw error }
            try RARPasswordAmbiguousDecompressor.rethrowNormalized(error)
        }
    }

    private static func validatePackedParts(
        _ record: RAR4EntryRecord,
        entryIndex: Int
    ) throws {
        guard record.packedPartCRC32.count == record.packedSegments.count else {
            throw KaitoError.malformed("RAR4 split integrity metadata is inconsistent")
        }
        guard record.packedPartCRC32.contains(where: { $0 != nil }) else { return }

        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        for (segment, expected) in zip(
            record.packedSegments,
            record.packedPartCRC32
        ) {
            guard let expected else { continue }
            let end = try Checked.add(segment.offset, segment.length)
            guard end <= segment.source.length else { throw KaitoError.truncated }
            var crc = CRC32()
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
                    crc.update(UnsafeRawBufferPointer(rebasing: storage[..<count]))
                }
                consumed = try Checked.add(consumed, UInt64(count))
            }
            guard crc.value == expected else {
                throw KaitoError.checksumMismatch(entry: entryIndex)
            }
        }
    }

}
