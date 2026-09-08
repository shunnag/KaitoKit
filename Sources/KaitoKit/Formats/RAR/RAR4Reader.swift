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

    private enum EndFlag {
        static let nextVolume: UInt16 = 0x0001
    }

    private struct MainHeader {
        let flags: UInt16

        var isVolume: Bool { flags & MainFlag.volume != 0 }
        var isSolid: Bool { flags & MainFlag.solid != 0 }
        var hasEncryptedHeaders: Bool {
            flags & MainFlag.encryptedHeaders != 0
        }
    }

    private struct Record {
        let packedSegments: [RARSourceSegment]
        let packedPartCRC32: [UInt32?]
        let packedSize: UInt64
        let unpackedSize: UInt64
        let crc32: UInt32
        let firstFlags: UInt16
        let lastFlags: UInt16
        let unpackVersion: UInt8
        let method: UInt8
        let dictionarySize: UInt64
        let salt: [UInt8]?

        var isEncrypted: Bool { firstFlags & FileFlag.encrypted != 0 }
        var isSplit: Bool {
            firstFlags & FileFlag.splitBefore != 0 ||
                lastFlags & FileFlag.splitAfter != 0
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

    private struct ParsedVolume {
        let pendingEntries: [PendingEntry]
        let records: [Record]
        let mainHeader: MainHeader
        let requestsNextVolume: Bool
    }

    private struct ParsedArchive {
        let entries: [ArchiveEntry]
        let records: [Record]
        let nameEncoding: String.Encoding?
        let resolvedPassword: String?
    }

    private struct ParsedHeader {
        let bytes: [UInt8]
        let physicalEnd: UInt64
    }

    /// Structural decoder failures cannot distinguish malformed ciphertext
    /// from a wrong key when a file has no independent password check.
    private final class PasswordAmbiguousDecompressor: Decompressor {
        private let base: any Decompressor
        private let expectedSize: UInt64
        private var produced: UInt64 = 0

        init(base: any Decompressor, expectedSize: UInt64) {
            self.base = base
            self.expectedSize = expectedSize
        }

        var isFinished: Bool {
            base.isFinished && produced == expectedSize
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            do {
                let count = try base.read(into: buffer)
                guard count >= 0, count <= buffer.count else { return count }
                if count == 0, produced < expectedSize {
                    throw KaitoError.wrongPassword
                }
                let (total, overflow) = produced.addingReportingOverflow(UInt64(count))
                if overflow || total > expectedSize {
                    throw KaitoError.wrongPassword
                }
                produced = total
                return count
            } catch {
                try Self.rethrowNormalized(error)
            }
        }

        static func rethrowNormalized(_ error: Error) throws -> Never {
            if let kaitoError = error as? KaitoError {
                switch kaitoError {
                case .malformed, .truncated:
                    throw KaitoError.wrongPassword
                default:
                    break
                }
            }
            throw error
        }
    }

    /// Advances one RAR3 solid group in archive order.  Each caller receives
    /// a generation-checked view of the coordinator's retained, CRC-verifying
    /// entry stream.  Forward seeks drain predecessors; backward seeks replace
    /// the shared compression state and restart at the group leader.
    private final class SolidCoordinator {
        typealias StreamFactory = (
            Int,
            RAR29Decoder.SolidState
        ) throws -> EntryStream

        private let entryIndices: [Int]
        private let entryPositions: [Int: Int]
        private let dictionarySize: UInt64
        private let limits: ReadLimits
        private let factory: StreamFactory

        private var state: RAR29Decoder.SolidState?
        private var nextPosition = 0
        private var activePosition: Int?
        private var activeStream: EntryStream?
        private var generation: UInt64 = 0

        init(
            entryIndices: [Int],
            dictionarySize: UInt64,
            limits: ReadLimits,
            factory: @escaping StreamFactory
        ) {
            self.entryIndices = entryIndices
            self.entryPositions = Dictionary(uniqueKeysWithValues:
                entryIndices.enumerated().map { ($0.element, $0.offset) }
            )
            self.dictionarySize = dictionarySize
            self.limits = limits
            self.factory = factory
        }

        func stream(entryIndex: Int, unpackedSize: UInt64) throws -> any Decompressor {
            guard let requestedPosition = entryPositions[entryIndex] else {
                throw KaitoError.malformed(
                    "RAR4 solid entry is not in its published group"
                )
            }
            generation = try Checked.add(generation, 1)

            do {
                if state == nil || requestedPosition < nextPosition
                    || activePosition.map({ requestedPosition <= $0 }) == true {
                    try restart()
                }
                if activeStream != nil { try drainActiveStream() }
                while nextPosition < requestedPosition {
                    try openNextStream()
                    try drainActiveStream()
                }
                guard nextPosition == requestedPosition else {
                    throw KaitoError.malformed(
                        "RAR4 solid coordinator passed its requested entry"
                    )
                }
                try openNextStream()
                let initiallyFinished = activeStream?.remaining == 0
                if initiallyFinished { completeActiveStream(preserveState: true) }
                return SolidRangeDecompressor(
                    coordinator: self,
                    generation: generation,
                    entryIndex: entryIndex,
                    unpackedSize: unpackedSize,
                    initiallyFinished: initiallyFinished
                )
            } catch {
                abandonState()
                throw error
            }
        }

        fileprivate func read(
            generation expectedGeneration: UInt64,
            entryIndex: Int,
            remaining: inout UInt64,
            finished: inout Bool,
            into buffer: UnsafeMutableRawBufferPointer
        ) throws -> Int {
            guard expectedGeneration == generation else {
                throw KaitoError.malformed(
                    "a newer RAR4 solid stream invalidated this stream"
                )
            }
            guard !finished, !buffer.isEmpty else { return 0 }
            guard let activePosition,
                  entryIndices[activePosition] == entryIndex,
                  let activeStream else {
                throw KaitoError.malformed(
                    "RAR4 solid coordinator has no active entry stream"
                )
            }

            do {
                let actual = try activeStream.read(into: buffer)
                remaining = try Checked.sub(remaining, UInt64(actual))
                if activeStream.remaining == 0 {
                    finished = true
                    remaining = 0
                    completeActiveStream(preserveState: true)
                } else if actual == 0 {
                    throw KaitoError.truncated
                }
                return actual
            } catch {
                abandonState()
                throw error
            }
        }

        private func restart() throws {
            try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
            state = try RAR29Decoder.SolidState(dictionarySize: dictionarySize)
            nextPosition = 0
            activePosition = nil
            activeStream = nil
        }

        private func openNextStream() throws {
            guard activeStream == nil,
                  entryIndices.indices.contains(nextPosition),
                  let state else {
                throw KaitoError.malformed(
                    "RAR4 solid coordinator cannot open its next entry"
                )
            }
            let position = nextPosition
            activeStream = try factory(entryIndices[position], state)
            activePosition = position
        }

        private func drainActiveStream() throws {
            guard let activeStream else { return }
            var scratch = [UInt8](repeating: 0, count: 256 * 1_024)
            while activeStream.remaining != 0 {
                let count = try scratch.withUnsafeMutableBytes {
                    try activeStream.read(into: $0)
                }
                guard count > 0 || activeStream.remaining == 0 else {
                    throw KaitoError.truncated
                }
            }
            completeActiveStream(preserveState: true)
        }

        private func completeActiveStream(preserveState: Bool) {
            guard let position = activePosition else { return }
            nextPosition = position + 1
            activePosition = nil
            activeStream = nil
            if !preserveState || nextPosition == entryIndices.count {
                state = nil
            }
        }

        fileprivate func invalidateAndRelease() {
            generation &+= 1
            abandonState()
        }

        fileprivate func releaseAbandonedRange(
            generation expectedGeneration: UInt64,
            entryIndex: Int
        ) {
            guard expectedGeneration == generation,
                  let activePosition,
                  entryIndices[activePosition] == entryIndex else { return }
            invalidateAndRelease()
        }

        private func abandonState() {
            state = nil
            nextPosition = 0
            activePosition = nil
            activeStream = nil
        }
    }

    private final class SolidRangeDecompressor: Decompressor {
        private let coordinator: SolidCoordinator
        private let generation: UInt64
        private let entryIndex: Int
        private var remaining: UInt64
        private var finished: Bool

        init(
            coordinator: SolidCoordinator,
            generation: UInt64,
            entryIndex: Int,
            unpackedSize: UInt64,
            initiallyFinished: Bool
        ) {
            self.coordinator = coordinator
            self.generation = generation
            self.entryIndex = entryIndex
            self.remaining = unpackedSize
            self.finished = initiallyFinished
        }

        var isFinished: Bool { finished }

        deinit {
            coordinator.releaseAbandonedRange(
                generation: generation,
                entryIndex: entryIndex
            )
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            try coordinator.read(
                generation: generation,
                entryIndex: entryIndex,
                remaining: &remaining,
                finished: &finished,
                into: buffer
            )
        }
    }

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    private(set) var nameEncoding: String.Encoding?

    private let source: any ByteSource
    private let sourceURL: URL?
    private let options: ReaderOptions
    private let records: [Record]
    private let solidGroupMembers: [Int: [Int]]
    private let firstEncryptedSolidMembers: [Int: Int]
    private let keyCache: RAR3KeyCache
    private var password: String?
    private var solidCoordinators: [Int: SolidCoordinator] = [:]
    private var activeSolidGroup: Int?
    private final class PasswordEncodingSelection {
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
            guard let match = try FormatDetector.findRARSignature(source: source),
                  match.version == .rar4 else {
                throw KaitoError.unsupportedFormat
            }
            resolvedSignatureOffset = match.offset
        }
        let keyCache = RAR3KeyCache()
        let passwordEncodings = PasswordEncodingSelection()
        self.keyCache = keyCache
        self.passwordEncodings = passwordEncodings
        let parsed = try Self.parse(
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
        records: [Record],
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

    func reopened(options: ReaderOptions) -> RAR4Reader {
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
        try Checked.size(record.packedSize, limit: limits.maxEntrySize)
        try Self.validatePackedParts(record, entryIndex: entry.index)
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

        let compressedSource: any ByteSource
        let compressedOffset: UInt64
        if record.isEncrypted {
            guard let password else { throw KaitoError.passwordRequired }
            guard let salt = record.salt else {
                throw KaitoError.unsupportedMethod(
                    "RAR4 encrypted file data without a RAR3 salt"
                )
            }
            let derived = try keyCache.key(
                password: password, salt: salt,
                unixScalars: passwordEncodings.unixScalars ?? false
            )
            compressedSource = try RARAESCBCByteSource(
                source: packedSource,
                ciphertextOffset: packedOffset,
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
            compressedSource = packedSource
            compressedOffset = packedOffset
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
            decompressor = try Self.makeCompressedDecompressor(
                source: compressedSource,
                offset: compressedOffset,
                compressedSize: record.packedSize,
                uncompressedSize: record.unpackedSize,
                unpackVersion: record.unpackVersion,
                method: record.method,
                dictionarySize: record.dictionarySize,
                isSolid: record.firstFlags & FileFlag.solid != 0,
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

        let coordinator: SolidCoordinator
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
                guard (0x31...0x35).contains(member.method) else {
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
            coordinator = SolidCoordinator(
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
        _ groups: [Int: [Int]], records: [Record]
    ) -> [Int: Int] {
        // Precompute once so an unencrypted or empty solid prefix does not
        // trigger an O(N) member search for every entry.
        groups.compactMapValues { members in
            members.first { records[$0].isEncrypted && records[$0].unpackedSize > 0 }
        }
    }

    private static func makeSolidVerifiedStream(
        entry: ArchiveEntry,
        record: Record,
        limits: ReadLimits,
        state: RAR29Decoder.SolidState,
        password: String?,
        keyCache: RAR3KeyCache,
        unixScalars: Bool
    ) throws -> EntryStream {
        guard (0x31...0x35).contains(record.method),
              record.unpackVersion == 29 else {
            throw KaitoError.unsupportedMethod("RAR4 unsupported solid stream member")
        }
        try Checked.size(record.packedSize, limit: limits.maxEntrySize)
        try validatePackedParts(record, entryIndex: entry.index)

        let packed: (source: any ByteSource, offset: UInt64)
        if record.packedSegments.count == 1,
           let segment = record.packedSegments.first {
            packed = (segment.source, segment.offset)
        } else if record.packedSize == 0 {
            packed = (DataByteSource(data: Data()), 0)
        } else {
            packed = (
                try RARConcatenatedByteSource(
                    segments: record.packedSegments,
                    maximumLength: record.packedSize,
                    maximumSegmentCount: limits.maxVolumeCount
                ),
                0
            )
        }

        let compressed: (source: any ByteSource, offset: UInt64)
        if record.isEncrypted {
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
            compressed = (
                try RARAESCBCByteSource(
                    source: packed.source,
                    ciphertextOffset: packed.offset,
                    ciphertextSize: record.packedSize,
                    plaintextSize: record.packedSize,
                    key: derived.key,
                    initializationVector: derived.initializationVector
                ),
                0
            )
        } else {
            compressed = packed
        }

        let decompressor = try makeCompressedDecompressor(
            source: compressed.source,
            offset: compressed.offset,
            compressedSize: record.packedSize,
            uncompressedSize: record.unpackedSize,
            unpackVersion: record.unpackVersion,
            method: record.method,
            dictionarySize: record.dictionarySize,
            isSolid: record.firstFlags & FileFlag.solid != 0,
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
                uncompressedSize: uncompressedSize,
                unpackVersion: unpackVersion,
                method: method,
                dictionarySize: dictionarySize,
                isSolid: isSolid,
                limits: limits,
                solidState: solidState
            )
            guard mismatchIsWrongPassword else { return decoder }
            return PasswordAmbiguousDecompressor(
                base: decoder,
                expectedSize: uncompressedSize
            )
        } catch {
            guard mismatchIsWrongPassword else { throw error }
            try PasswordAmbiguousDecompressor.rethrowNormalized(error)
        }
    }

    private static func validatePackedParts(
        _ record: Record,
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

    private static func parse(
        source: any ByteSource,
        sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?,
        options: ReaderOptions,
        signatureOffset: UInt64,
        headerKeyCache: RAR3KeyCache,
        passwordEncodings: PasswordEncodingSelection
    ) throws -> ParsedArchive {
        var resolvedPassword = options.password
        let first = try parseVolume(
            source: source,
            limits: options.limits,
            password: &resolvedPassword,
            passwordProvider: options.passwordProvider,
            headerKeyCache: headerKeyCache,
            passwordEncodings: passwordEncodings,
            signatureOffset: signatureOffset
        )
        guard first.mainHeader.isVolume, let sourceURL else {
            return try publish(
                pendingEntries: first.pendingEntries,
                records: first.records,
                mainHeader: first.mainHeader,
                policy: options.encodingPolicy,
                limits: options.limits,
                resolvedPassword: resolvedPassword
            )
        }

        let naming: RARVolumeNaming = first.mainHeader.flags & MainFlag.newNumbering != 0
            ? .rar4New
            : .rar4Old
        let locator = try RARVolumeLocator(
            firstVolumeURL: sourceURL,
            firstVolumeSource: source,
            firstVolumeDirectory: sourceDirectoryAnchor,
            naming: naming,
            maxMetadataSize: options.limits.maxMetadataSize,
            maxVolumeCount: options.limits.maxVolumeCount
        )
        var mergedEntries: [PendingEntry] = []
        var mergedRecords: [Record] = []
        var activeEntry: PendingEntry?
        var activeRecord: Record?
        var retainedMetadataSize: UInt64 = 0
        try mergeFragments(
            entries: first.pendingEntries,
            records: first.records,
            into: &mergedEntries,
            mergedRecords: &mergedRecords,
            activeEntry: &activeEntry,
            activeRecord: &activeRecord,
            retainedMetadataSize: &retainedMetadataSize,
            limits: options.limits
        )

        var current = first
        var volumeNumber: UInt64 = 0
        while current.requestsNextVolume {
            let nextNumber = try Checked.add(volumeNumber, 1)
            guard nextNumber < UInt64(options.limits.maxVolumeCount) else {
                throw KaitoError.limitExceeded("RAR4 volume count")
            }
            let located = try locator.locate(volumeNumber: nextNumber)
            let next = try parseVolume(
                source: located.source,
                limits: options.limits,
                password: &resolvedPassword,
                passwordProvider: options.passwordProvider,
                headerKeyCache: headerKeyCache,
                passwordEncodings: passwordEncodings,
                signatureOffset: 0
            )
            guard next.mainHeader.isVolume else {
                throw KaitoError.malformed("RAR4 continuation is not marked as a volume")
            }
            guard next.mainHeader.isSolid == first.mainHeader.isSolid else {
                throw KaitoError.malformed("RAR4 solid flag changes between volumes")
            }
            guard (next.mainHeader.flags & MainFlag.newNumbering != 0) ==
                    (first.mainHeader.flags & MainFlag.newNumbering != 0) else {
                throw KaitoError.malformed("RAR4 numbering mode changes between volumes")
            }
            guard next.mainHeader.flags & MainFlag.firstVolume == 0 else {
                throw KaitoError.malformed("RAR4 continuation is marked as first volume")
            }
            try mergeFragments(
                entries: next.pendingEntries,
                records: next.records,
                into: &mergedEntries,
                mergedRecords: &mergedRecords,
                activeEntry: &activeEntry,
                activeRecord: &activeRecord,
                retainedMetadataSize: &retainedMetadataSize,
                limits: options.limits
            )
            current = next
            volumeNumber = nextNumber
        }
        guard activeEntry == nil, activeRecord == nil else { throw KaitoError.truncated }
        return try publish(
            pendingEntries: mergedEntries,
            records: mergedRecords,
            mainHeader: first.mainHeader,
            policy: options.encodingPolicy,
            limits: options.limits,
            resolvedPassword: resolvedPassword
        )
    }

    private static func mergeFragments(
        entries: [PendingEntry],
        records: [Record],
        into completedEntries: inout [PendingEntry],
        mergedRecords: inout [Record],
        activeEntry: inout PendingEntry?,
        activeRecord: inout Record?,
        retainedMetadataSize: inout UInt64,
        limits: ReadLimits
    ) throws {
        guard entries.count == records.count else {
            throw KaitoError.malformed("RAR4 volume entry records are inconsistent")
        }
        for (entry, record) in zip(entries, records) {
            if record.firstFlags & FileFlag.splitBefore != 0 {
                guard let precedingEntry = activeEntry,
                      let precedingRecord = activeRecord,
                      precedingRecord.lastFlags & FileFlag.splitAfter != 0 else {
                    throw KaitoError.malformed(
                        "RAR4 split continuation has no preceding file part"
                    )
                }
                let merged = try mergeSplitParts(
                    precedingEntry,
                    precedingRecord,
                    entry,
                    record
                )
                activeEntry = merged.entry
                activeRecord = merged.record
            } else {
                guard activeEntry == nil, activeRecord == nil else {
                    throw KaitoError.malformed("RAR4 split continuation is missing")
                }
                activeEntry = entry
                activeRecord = record
            }

            if let finishedEntry = activeEntry,
               let finishedRecord = activeRecord,
               finishedRecord.lastFlags & FileFlag.splitAfter == 0 {
                guard completedEntries.count < limits.maxEntryCount else {
                    throw KaitoError.limitExceeded("archive entry count")
                }
                let nextRetainedMetadataSize = try Checked.add(
                    retainedMetadataSize,
                    pendingMetadataCost(finishedEntry)
                )
                try Checked.size(
                    nextRetainedMetadataSize,
                    limit: limits.maxTotalMetadataSize
                )
                retainedMetadataSize = nextRetainedMetadataSize
                completedEntries.append(finishedEntry)
                mergedRecords.append(finishedRecord)
                activeEntry = nil
                activeRecord = nil
            }
        }
    }

    private static func mergeSplitParts(
        _ firstEntry: PendingEntry,
        _ firstRecord: Record,
        _ continuationEntry: PendingEntry,
        _ continuationRecord: Record
    ) throws -> (entry: PendingEntry, record: Record) {
        let splitMask = FileFlag.splitBefore | FileFlag.splitAfter
        guard firstEntry.rawName == continuationEntry.rawName,
              firstEntry.fallbackName == continuationEntry.fallbackName,
              firstEntry.decodedUnicodeName == continuationEntry.decodedUnicodeName,
              firstEntry.declaredEncoding == continuationEntry.declaredEncoding,
              firstEntry.kind == continuationEntry.kind,
              firstEntry.unpackedSize == continuationEntry.unpackedSize,
              firstEntry.modificationDate == continuationEntry.modificationDate,
              firstEntry.permissions == continuationEntry.permissions,
              firstEntry.isEncrypted == continuationEntry.isEncrypted,
              firstRecord.unpackVersion == continuationRecord.unpackVersion,
              firstRecord.method == continuationRecord.method,
              firstRecord.dictionarySize == continuationRecord.dictionarySize,
              firstRecord.salt == continuationRecord.salt,
              firstRecord.lastFlags & ~splitMask ==
                continuationRecord.firstFlags & ~splitMask else {
            throw KaitoError.malformed("RAR4 split file metadata changes between volumes")
        }

        let packedSize = try Checked.add(
            firstRecord.packedSize,
            continuationRecord.packedSize
        )
        let segmentCount = try Checked.add(
            UInt64(firstRecord.packedSegments.count),
            UInt64(continuationRecord.packedSegments.count)
        )
        guard segmentCount <= 65_536 else {
            throw KaitoError.limitExceeded("RAR4 split stream has too many segments")
        }
        var specific = firstEntry.formatSpecific
        specific["splitAfter"] = continuationRecord.lastFlags & FileFlag.splitAfter != 0
            ? "true"
            : "false"
        specific["volumeSegmentCount"] = String(segmentCount)
        specific["multiVolume"] = "true"

        return (
            PendingEntry(
                rawName: firstEntry.rawName,
                fallbackName: firstEntry.fallbackName,
                decodedUnicodeName: firstEntry.decodedUnicodeName,
                declaredEncoding: firstEntry.declaredEncoding,
                kind: firstEntry.kind,
                unpackedSize: firstEntry.unpackedSize,
                packedSize: packedSize,
                modificationDate: firstEntry.modificationDate,
                permissions: firstEntry.permissions,
                isEncrypted: firstEntry.isEncrypted,
                crc32: continuationEntry.crc32,
                methodDescription: firstEntry.methodDescription,
                formatSpecific: specific
            ),
            Record(
                packedSegments: firstRecord.packedSegments
                    + continuationRecord.packedSegments,
                packedPartCRC32: firstRecord.packedPartCRC32
                    + continuationRecord.packedPartCRC32,
                packedSize: packedSize,
                unpackedSize: firstRecord.unpackedSize,
                crc32: continuationRecord.crc32,
                firstFlags: firstRecord.firstFlags,
                lastFlags: continuationRecord.lastFlags,
                unpackVersion: firstRecord.unpackVersion,
                method: firstRecord.method,
                dictionarySize: firstRecord.dictionarySize,
                salt: firstRecord.salt
            )
        )
    }

    private static func parseVolume(
        source: any ByteSource,
        limits: ReadLimits,
        password: inout String?,
        passwordProvider: (any PasswordProvider)?,
        headerKeyCache: RAR3KeyCache,
        passwordEncodings: PasswordEncodingSelection,
        signatureOffset: UInt64
    ) throws -> ParsedVolume {
        let markerEnd = try Checked.add(signatureOffset, UInt64(signature.count))
        guard source.length >= markerEnd else {
            throw KaitoError.truncated
        }
        let marker = try readByteRange(
            source: source,
            offset: signatureOffset,
            count: signature.count
        )
        guard marker == signature else { throw KaitoError.unsupportedFormat }

        var offset = markerEnd
        var mainHeader: MainHeader?
        var pendingEntries: [PendingEntry] = []
        var records: [Record] = []
        var retainedMetadataSize: UInt64 = 0
        var encryptedHeaderWasValidated = false

        while offset < source.length {
            let encryptedHeader = mainHeader?.hasEncryptedHeaders == true
            let encryptedHeaderEnvelopeIsShort = encryptedHeader
                && source.length - offset < 24
            let parsedHeader: ParsedHeader
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
            let flags = littleUInt16(common, at: 3)
            let headerEnd = parsedHeader.physicalEnd

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
                guard offset == markerEnd else {
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
                    if password == nil {
                        password = try passwordProvider?.password(for: .rar)
                    }
                    guard password != nil else {
                        throw KaitoError.passwordRequired
                    }
                }
                mainHeader = MainHeader(flags: flags)
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
                return ParsedVolume(
                    pendingEntries: pendingEntries,
                    records: records,
                    mainHeader: mainHeader!,
                    requestsNextVolume: flags & EndFlag.nextVolume != 0
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
        return ParsedVolume(
            pendingEntries: pendingEntries,
            records: records,
            mainHeader: mainHeader,
            requestsNextVolume: false
        )
    }

    private static func parseFileHeader(
        _ header: [UInt8],
        source: any ByteSource,
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
                source: source,
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
            source: source,
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
        source: any ByteSource,
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
        var specific: [String: String] = [
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
        if kind == .symlink {
            specific["linkTargetStoredAsData"] = "true"
        }
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
            packedSegments: [RARSourceSegment(
                source: source,
                offset: dataOffset,
                length: packedSize
            )],
            packedPartCRC32: [flags & FileFlag.splitAfter != 0 ? fileCRC : nil],
            packedSize: packedSize,
            unpackedSize: unpackedSize,
            crc32: fileCRC,
            firstFlags: flags,
            lastFlags: flags,
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
        limits: ReadLimits,
        resolvedPassword: String?
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
        // compressed file. Consequently a group becomes observable only at
        // the first continuation: its independent predecessor is then the
        // group leader. Directories and method 0x30 never join or break the run.
        // The batch-13 RAR 6.24 black-box vectors establish that stored members
        // leave all solid state untouched, regardless of flags or unpack version.
        var solidGroups = [Int](repeating: -1, count: pendingEntries.count)
        var previousFileIndex: Int?
        for index in pendingEntries.indices
        where pendingEntries[index].kind != .directory && records[index].method != 0x30 {
            let continuesSolidStream = records[index].firstFlags & FileFlag.solid != 0
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
                .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
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
            nameEncoding: archiveEncoding,
            resolvedPassword: resolvedPassword
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
        passwordEncodings: PasswordEncodingSelection,
        limits: ReadLimits
    ) throws -> ParsedHeader {
        if !encrypted {
            let remaining = try Checked.sub(source.length, offset)
            guard remaining >= 7 else { throw KaitoError.truncated }
            let common = try readByteRange(
                source: source,
                offset: offset,
                count: 7
            )
            let headerSize = UInt64(littleUInt16(common, at: 5))
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
            return ParsedHeader(bytes: bytes, physicalEnd: end)
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
        // 暗号化 header は writer の OS 自体が暗号文にある。BMP 外の文字がある場合だけ
        // 二通りを試し、header CRC で確定する。候補数は常に最大 2。
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
    ) throws -> ParsedHeader {
        let commonSource = try RARAESCBCByteSource(
            source: source,
            ciphertextOffset: ciphertextOffset,
            ciphertextSize: 16,
            plaintextSize: 16,
            key: derived.key,
            initializationVector: derived.initializationVector
        )
        let common = try readByteRange(source: commonSource, offset: 0, count: 7)
        let headerSize = UInt64(littleUInt16(common, at: 5))
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
        return ParsedHeader(bytes: bytes, physicalEnd: end)
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
