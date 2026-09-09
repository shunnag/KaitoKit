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
        let availableDataSize: UInt64
        let isDataTruncated: Bool
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
        let usesTweakedChecksums: Bool
    }

    private struct PendingEntry {
        let rawName: [UInt8]
        let name: String
        let pathComponents: [String]
        let kind: EntryKind
        let unpackedSize: UInt64?
        let packedSize: UInt64
        var availablePackedSize: UInt64? = nil
        var isIncomplete = false
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
        var availablePackedSize: UInt64? = nil
        var isIncomplete = false
        let unpackedSize: UInt64?
        let compression: RAR5CompressionInfo
        let encryption: RAR5EncryptionRecord?
        let hash: RAR5HashRecord?
        let redirectionType: UInt64?
        let requiresPreviousVolume: Bool
        let requiresNextVolume: Bool
    }

    private struct ArchiveEncryptionContext {
        let key: Data
        let passwordWasVerified: Bool
    }

    private struct PreparedPayload {
        let source: any ByteSource
        let offset: UInt64
        let hashKey: Data?
        let mismatchIsWrongPassword: Bool
    }

    /// Bounds the aggregate work of archive-header key derivations. The parse
    /// cache is sized to retain every context reachable within maxVolumeCount,
    /// so each distinct context here corresponds to one actual derivation.
    private struct HeaderKDFWorkBudget {
        let limit: UInt64
        private(set) var used: UInt64 = 0
        private var contexts: Set<RAR5KeyCacheKey> = []

        // private な格納プロパティがあると暗黙のメンバワイズ init も private になり、
        // Swift 6.3.3 では外側の型からも呼べないため明示する
        init(limit: UInt64) {
            self.limit = limit
        }

        mutating func charge(
            passwordUTF8: Data,
            salt: [UInt8],
            count: UInt8
        ) throws {
            let context = RAR5KeyCacheKey(
                passwordUTF8: passwordUTF8,
                salt: Data(salt),
                count: count
            )
            guard !contexts.contains(context) else { return }

            let work = (UInt64(1) << UInt64(count)) + 32
            let (total, overflow) = used.addingReportingOverflow(work)
            guard !overflow, total <= limit else {
                throw KaitoError.limitExceeded("RAR5 header encryption KDF work")
            }
            used = total
            contexts.insert(context)
        }
    }

    /// Structural decoder failures cannot distinguish damaged ciphertext from
    /// a wrong key when a file has no independently valid password check.
    private final class PasswordAmbiguousDecompressor: Decompressor {
        private let base: any Decompressor
        private let expectedSize: UInt64?
        private var produced: UInt64 = 0

        init(base: any Decompressor, expectedSize: UInt64?) {
            self.base = base
            self.expectedSize = expectedSize
        }

        var isFinished: Bool {
            guard base.isFinished else { return false }
            return expectedSize.map { produced == $0 } ?? true
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            do {
                let count = try base.read(into: buffer)
                guard count >= 0, count <= buffer.count else { return count }
                if count == 0, let expectedSize, produced < expectedSize {
                    throw KaitoError.wrongPassword
                }
                let (total, overflow) = produced.addingReportingOverflow(UInt64(count))
                if overflow || expectedSize.map({ total > $0 }) == true {
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

    /// Advances one solid compression group in archive order. Each published
    /// range is a generation-checked view of an internally verified entry
    /// stream. Retaining that inner stream lets a later forward request drain
    /// and authenticate an abandoned predecessor before reusing its LZ state.
    private final class SolidCoordinator {
        typealias StreamFactory = (
            Int,
            RAR5Decoder.SolidState
        ) throws -> EntryStream

        private let entryIndices: [Int]
        private let entryPositions: [Int: Int]
        private let dictionarySize: UInt64
        private let limits: ReadLimits
        private let factory: StreamFactory

        private var state: RAR5Decoder.SolidState?
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

        func stream(entryIndex: Int, unpackedSize: UInt64?) throws -> any Decompressor {
            guard let requestedPosition = entryPositions[entryIndex] else {
                throw KaitoError.malformed(
                    "RAR5 solid entry is not in its published group"
                )
            }
            generation = try Checked.add(generation, 1)

            do {
                if state == nil || requestedPosition < nextPosition
                    || activePosition.map({ requestedPosition <= $0 }) == true {
                    try restart()
                }

                if activeStream != nil {
                    try drainActiveStream()
                }
                while nextPosition < requestedPosition {
                    try openNextStream()
                    try drainActiveStream()
                }
                guard nextPosition == requestedPosition else {
                    throw KaitoError.malformed(
                        "RAR5 solid coordinator passed its requested entry"
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
            remaining: inout UInt64?,
            finished: inout Bool,
            into buffer: UnsafeMutableRawBufferPointer
        ) throws -> Int {
            guard expectedGeneration == generation else {
                throw KaitoError.malformed(
                    "a newer RAR5 solid stream invalidated this stream"
                )
            }
            guard !finished, !buffer.isEmpty else { return 0 }
            guard let activePosition,
                  entryIndices[activePosition] == entryIndex,
                  let activeStream else {
                throw KaitoError.malformed(
                    "RAR5 solid coordinator has no active entry stream"
                )
            }

            do {
                let actual = try activeStream.read(into: buffer)
                if let current = remaining {
                    remaining = try Checked.sub(current, UInt64(actual))
                }
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
            state = try RAR5Decoder.SolidState(dictionarySize: dictionarySize)
            nextPosition = 0
            activePosition = nil
            activeStream = nil
        }

        private func openNextStream() throws {
            guard activeStream == nil,
                  entryIndices.indices.contains(nextPosition),
                  let state else {
                throw KaitoError.malformed(
                    "RAR5 solid coordinator cannot open its next entry"
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

        /// Invalidates any published range and releases its dictionary. The
        /// parent reader calls this when a different solid group becomes
        /// active, bounding retained state to one group per non-thread-safe
        /// reader instead of one archive-declared dictionary per group.
        fileprivate func invalidateAndRelease() {
            generation &+= 1
            abandonState()
        }

        /// A range abandoned before EOF would otherwise stay retained through
        /// `activeStream`. Its deinitializer uses this generation-checked hook
        /// to drop the inner verified stream and shared dictionary promptly.
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
        private var remaining: UInt64?
        private var finished: Bool

        init(
            coordinator: SolidCoordinator,
            generation: UInt64,
            entryIndex: Int,
            unpackedSize: UInt64?,
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

    private struct ParseState {
        var pending: [PendingEntry] = []
        var archiveFlags = RAR5ArchiveFlags()
        var volumeNumber: UInt64 = 0
        var headersEncrypted = false
        var sawMainHeader = false
        var sawEndHeader = false
        var endFlags = RAR5EndFlags()
        var serviceHeaderCount = 0
        var retainedMetadataSize: UInt64 = 0
    }

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = nil

    private let source: any ByteSource
    private let sourceURL: URL?
    private let options: ReaderOptions
    private let records: [Record]
    private let solidGroupMembers: [Int: [Int]]
    private let keyCache = RAR5KeyCache()
    private var password: String?
    private var solidCoordinators: [Int: SolidCoordinator] = [:]
    private var activeSolidGroup: Int?

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
            options: options,
            passwordSelection: keyCache.passwordSelection
        )
        self.entries = parsed.entries
        self.records = parsed.records
        self.solidGroupMembers = Self.indexSolidGroups(parsed.entries)
        self.password = parsed.password
    }

    /// Returns an independent mutable reader while retaining the exact source
    /// handles authenticated during the original parse. In particular, a
    /// reopened multi-volume reader never resolves sibling paths a second time.
    func reopened(options: ReaderOptions) -> RAR5Reader {
        let reader = RAR5Reader(
            source: source,
            sourceURL: sourceURL,
            options: options,
            entries: entries,
            records: records
        )
        reader.keyCache.passwordSelection.selectedUTF8 = keyCache.passwordSelection.selectedUTF8
        return reader
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
        self.solidGroupMembers = Self.indexSolidGroups(entries)
        self.password = options.password
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
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
            throw KaitoError.notFound("RAR5 entry index \(entry.index)")
        }
        let record = records[entry.index]
        if let unpackedSize = record.unpackedSize {
            try Checked.size(unpackedSize, limit: limits.maxEntrySize)
        }

        // 切れた solid member は列挙だけ許し、連続する復号状態には渡さない。
        if options.recoverDamagedArchives, entry.isIncomplete, entry.solidGroup >= 0 {
            throw KaitoError.truncated
        }

        if Self.isZeroBodyRedirection(record.redirectionType) {
            return try EntryStream(
                source: source,
                offset: 0,
                length: 0,
                limits: limits
            )
        }
        try Self.validateStreamCompatibility(
            record,
            options: options,
            sourceURL: sourceURL
        )
        if let stream = try Self.symbolicLinkStream(entry: entry, record: record, limits: limits) {
            return stream
        }
        if record.compression.method != 0 {
            try Checked.size(
                record.compression.dictionarySize,
                limit: limits.maxDictionarySize
            )
        }

        if entry.solidGroup >= 0 {
            return try streamSolidEntry(
                entry,
                group: entry.solidGroup,
                limits: limits
            )
        }

        let prepared = try Self.preparePayload(
            record,
            entryIndex: entry.index,
            options: options,
            limits: limits,
            password: password,
            keyCache: keyCache
        )

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
                source: prepared.source,
                offset: prepared.offset,
                compressedSize: entry.isIncomplete
                    ? min(logicalStoredSize, record.availablePackedSize ?? record.packedSize)
                    : logicalStoredSize
            )
        } else {
            do {
                decompressor = try Self.makeCompressedDecompressor(
                    source: prepared.source,
                    offset: prepared.offset,
                    compressedSize: record.availablePackedSize ?? record.packedSize,
                    unpackedSize: outputLength,
                    dictionarySize: record.compression.dictionarySize,
                    limits: limits,
                    mismatchIsWrongPassword: prepared.mismatchIsWrongPassword
                )
            } catch KaitoError.truncated {
                guard options.recoverDamagedArchives, entry.isIncomplete else {
                    throw KaitoError.truncated
                }
                // 最初の圧縮 block すら揃わない場合、復号できた出力は 0 byte。
                decompressor = try CopyDecompressor(
                    source: prepared.source,
                    offset: prepared.offset,
                    compressedSize: 0
                )
            }
        }

        var completionCheck: (() throws -> Void)?
        // A successfully verified password-check value disambiguates a later
        // payload digest failure: it is corruption, not a bad password. Older
        // records without that independent check necessarily remain ambiguous.
        let mismatchIsWrongPassword = prepared.mismatchIsWrongPassword
        if options.verifyRAR5Blake2sp,
           !entry.isIncomplete,
           let recordHash = record.hash,
           recordHash.type == 0 {
            let hashing = try RAR5Blake2spDecompressor(
                base: decompressor,
                expected: recordHash.digest,
                hashKey: prepared.hashKey,
                entryIndex: entry.index,
                mismatchIsWrongPassword: mismatchIsWrongPassword
            )
            decompressor = hashing
            completionCheck = { try hashing.verify() }
        }
        let crc32Transform: ((UInt32) -> UInt32)? = prepared.hashKey.map { key in
            { checksum in RAR5ChecksumMAC.crc32(checksum, hashKey: key) }
        }
        // Incomplete unencrypted stored payloads are already bounded to available
        // bytes by CopyDecompressor, so preserve bulk reads without recovery wrapping.
        return try EntryStream(
            decompressor: entry.isIncomplete
                && !(record.compression.method == 0 && record.encryption == nil)
                ? RecoveryDecompressor(decompressor, maximumOutputSize: outputLength)
                : decompressor,
            length: entry.isIncomplete ? nil : outputLength,
            expectedCRC32: entry.isIncomplete ? nil : expectedCRC,
            entryIndex: entry.index,
            limits: limits,
            completionCheck: completionCheck,
            checksumMismatchIsWrongPassword: mismatchIsWrongPassword,
            crc32Transform: crc32Transform
        )
    }

    private func streamSolidEntry(
        _ entry: ArchiveEntry,
        group: Int,
        limits: ReadLimits
    ) throws -> EntryStream {
        // ArchiveReader is deliberately non-thread-safe and already permits
        // only one live range per group. Apply the same rule across groups so
        // an archive with many short solid runs cannot accumulate dictionaries.
        if let activeSolidGroup, activeSolidGroup != group {
            solidCoordinators[activeSolidGroup]?.invalidateAndRelease()
        }
        activeSolidGroup = group

        let coordinator: SolidCoordinator
        if let existing = solidCoordinators[group] {
            coordinator = existing
        } else {
            // Build and validate this immutable layout once. Repeated member
            // access is then O(1) rather than rescanning a million-entry group.
            guard let groupIndices = solidGroupMembers[group],
                  !groupIndices.isEmpty,
                  groupIndices.first == group,
                  groupIndices.contains(entry.index) else {
                throw KaitoError.malformed(
                    "RAR5 solid group membership is inconsistent"
                )
            }

            // Compression info stores a per-member minimum. One continuing
            // state is sized to the largest minimum in the run; later members
            // may advertise a smaller requirement.
            let dictionarySize = groupIndices.reduce(UInt64(128 * 1_024)) {
                indexMaximum, index in
                let member = records[index]
                guard (1...5).contains(member.compression.method),
                      member.compression.version == 0 else {
                    return indexMaximum
                }
                return max(indexMaximum, member.compression.dictionarySize)
            }

            let capturedEntries = entries
            let capturedRecords = records
            let capturedOptions = options
            let capturedPassword = password
            let capturedKeyCache = keyCache
            let capturedSourceURL = sourceURL
            coordinator = SolidCoordinator(
                entryIndices: groupIndices,
                dictionarySize: dictionarySize,
                limits: limits
            ) { index, state in
                guard capturedEntries.indices.contains(index),
                      capturedRecords.indices.contains(index) else {
                    throw KaitoError.malformed(
                        "RAR5 solid coordinator references an invalid entry"
                    )
                }
                return try Self.makeSolidVerifiedStream(
                    entry: capturedEntries[index],
                    record: capturedRecords[index],
                    options: capturedOptions,
                    limits: limits,
                    password: capturedPassword,
                    keyCache: capturedKeyCache,
                    sourceURL: capturedSourceURL,
                    state: state
                )
            }
            solidCoordinators[group] = coordinator
        }

        let range = try coordinator.stream(
            entryIndex: entry.index,
            unpackedSize: records[entry.index].unpackedSize
        )
        // The coordinator's retained inner EntryStream performs each member's
        // CRC and optional BLAKE2sp verification, including members discarded
        // while seeking forward. This outer range enforces the caller-facing
        // size limit without hashing the target a second time.
        return try EntryStream(
            decompressor: range,
            length: records[entry.index].unpackedSize,
            expectedCRC32: nil,
            entryIndex: entry.index,
            limits: limits
        )
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

    private static func makeSolidVerifiedStream(
        entry: ArchiveEntry,
        record: Record,
        options: ReaderOptions,
        limits: ReadLimits,
        password: String?,
        keyCache: RAR5KeyCache,
        sourceURL: URL?,
        state: RAR5Decoder.SolidState
    ) throws -> EntryStream {
        try validateStreamCompatibility(
            record,
            options: options,
            sourceURL: sourceURL
        )
        if let stream = try symbolicLinkStream(entry: entry, record: record, limits: limits) {
            return stream
        }
        let prepared = try preparePayload(
            record,
            entryIndex: entry.index,
            options: options,
            limits: limits,
            password: password,
            keyCache: keyCache
        )

        var decompressor: any Decompressor
        if record.compression.method == 0 {
            if record.encryption == nil, let outputLength = record.unpackedSize,
               outputLength != record.packedSize {
                throw KaitoError.malformed("RAR5 stored sizes differ")
            }
            if record.encryption != nil, record.unpackedSize == nil {
                throw KaitoError.unsupportedMethod(
                    "RAR5 encrypted stored entry with unknown unpacked size"
                )
            }
            let logicalStoredSize = record.unpackedSize ?? record.packedSize
            guard logicalStoredSize <= record.packedSize else {
                throw KaitoError.malformed(
                    "RAR5 encrypted stored entry exceeds its ciphertext"
                )
            }
            // A stored member is part of archive ordering but does not feed or
            // replace the continuing LZ dictionary. Black-box vectors include
            // a stored payload larger than the dictionary followed by a match
            // back into the compressed predecessor.
            decompressor = try CopyDecompressor(
                source: prepared.source,
                offset: prepared.offset,
                compressedSize: logicalStoredSize
            )
        } else {
            decompressor = try makeCompressedDecompressor(
                source: prepared.source,
                offset: prepared.offset,
                compressedSize: record.packedSize,
                unpackedSize: record.unpackedSize,
                dictionarySize: record.compression.dictionarySize,
                limits: limits,
                solidState: state,
                mismatchIsWrongPassword: prepared.mismatchIsWrongPassword
            )
        }
        var completionCheck: (() throws -> Void)?
        if options.verifyRAR5Blake2sp,
           let recordHash = record.hash,
           recordHash.type == 0 {
            let hashing = try RAR5Blake2spDecompressor(
                base: decompressor,
                expected: recordHash.digest,
                hashKey: prepared.hashKey,
                entryIndex: entry.index,
                mismatchIsWrongPassword: prepared.mismatchIsWrongPassword
            )
            decompressor = hashing
            completionCheck = { try hashing.verify() }
        }
        let crc32Transform: ((UInt32) -> UInt32)? = prepared.hashKey.map { key in
            { checksum in RAR5ChecksumMAC.crc32(checksum, hashKey: key) }
        }
        return try EntryStream(
            decompressor: decompressor,
            length: record.unpackedSize,
            expectedCRC32: entry.crc32,
            entryIndex: entry.index,
            limits: limits,
            completionCheck: completionCheck,
            checksumMismatchIsWrongPassword: prepared.mismatchIsWrongPassword,
            crc32Transform: crc32Transform
        )
    }

    private static func validateStreamCompatibility(
        _ record: Record,
        options: ReaderOptions,
        sourceURL: URL?
    ) throws {
        guard record.compression.version <= 1 else {
            throw KaitoError.unsupportedMethod(
                "RAR compression version \(record.compression.version)"
            )
        }
        guard record.compression.method <= 5 else {
            throw KaitoError.unsupportedMethod(
                "RAR5 compression method \(record.compression.method)"
            )
        }
        if record.compression.method != 0,
           record.compression.version != 0 {
            throw KaitoError.unsupportedMethod(
                "RAR compression algorithm version 1"
            )
        }
        if let encryption = record.encryption {
            guard encryption.version == 0 else {
                throw KaitoError.unsupportedMethod(
                    "RAR5 file encryption version \(encryption.version)"
                )
            }
            guard encryption.kdfCount <= options.maxRAR5KDFCountPower else {
                throw KaitoError.unsupportedMethod(
                    "RAR5 KDF count \(encryption.kdfCount)"
                )
            }
        }
        if record.requiresPreviousVolume || record.requiresNextVolume {
            if sourceURL == nil {
                throw KaitoError.unsupportedMethod("multi-volume from Data")
            }
            throw KaitoError.truncated
        }
    }

    private static func isZeroBodyRedirection(_ type: UInt64?) -> Bool {
        type == 4 || type == 5
    }

    private static func symbolicLinkStream(
        entry: ArchiveEntry,
        record: Record,
        limits: ReadLimits
    ) throws -> EntryStream? {
        guard let type = record.redirectionType, (1...3).contains(type) else {
            return nil
        }
        guard let target = entry.formatSpecific["linkPath"] else {
            throw KaitoError.malformed("RAR5 symbolic link has no target")
        }
        let length = UInt64(target.utf8.count)
        if let declared = record.unpackedSize, declared != length {
            throw KaitoError.malformed("RAR5 symbolic link target size differs")
        }
        try Checked.size(length, limit: limits.maxEntrySize)
        // The target is authenticated by the header CRC, not a data-body digest.
        // Returning these header bytes also leaves a continuing solid state intact.
        return try EntryStream(
            source: DataByteSource(data: Data(target.utf8)),
            offset: 0,
            length: length,
            limits: limits
        )
    }

    private static func makeCompressedDecompressor(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        unpackedSize: UInt64?,
        dictionarySize: UInt64,
        limits: ReadLimits,
        solidState: RAR5Decoder.SolidState? = nil,
        mismatchIsWrongPassword: Bool
    ) throws -> any Decompressor {
        do {
            let decoder = try RAR5Decoder(
                source: source,
                offset: offset,
                compressedSize: compressedSize,
                unpackedSize: unpackedSize,
                dictionarySize: dictionarySize,
                limits: limits,
                solidState: solidState
            )
            guard mismatchIsWrongPassword else { return decoder }
            return PasswordAmbiguousDecompressor(
                base: decoder,
                expectedSize: unpackedSize
            )
        } catch {
            guard mismatchIsWrongPassword else { throw error }
            try PasswordAmbiguousDecompressor.rethrowNormalized(error)
        }
    }

    /// Builds the bounded packed view shared by independent and solid decoders.
    /// The archive-declared packed size is rejected before any integrity
    /// scan, and encrypted split parts remain one continuous CBC stream.
    private static func preparePayload(
        _ record: Record,
        entryIndex: Int,
        options: ReaderOptions,
        limits: ReadLimits,
        password: String?,
        keyCache: RAR5KeyCache
    ) throws -> PreparedPayload {
        try Checked.size(record.packedSize, limit: limits.maxEntrySize)

        var encryptionKey: Data?
        var encryptionHashKey: Data?
        var hashKey: Data?
        var mismatchIsWrongPassword = record.encryption.map {
            $0.checkValue == nil
        } ?? false
        if let encryption = record.encryption {
            guard let password else { throw KaitoError.passwordRequired }
            let (keys, verified) = try keyCache.checkedKey(
                password: password,
                salt: encryption.salt,
                count: encryption.kdfCount,
                checkValue: encryption.checkValue
            )
            mismatchIsWrongPassword = !verified
            encryptionKey = keys.encryptionKey
            encryptionHashKey = keys.hashKey
            if encryption.usesTweakedChecksums {
                hashKey = keys.hashKey
            }
        }

        try validatePackedParts(
            record,
            entryIndex: entryIndex,
            options: options,
            encryptionHashKey: encryptionHashKey,
            mismatchIsWrongPassword: mismatchIsWrongPassword
        )

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
            // Every split part repeats identical file-encryption metadata
            // (validated while merging), so CBC chaining crosses segments.
            packedSource = try RARConcatenatedByteSource(
                segments: record.packedSegments,
                maximumLength: record.packedSize,
                maximumSegmentCount: limits.maxVolumeCount
            )
            packedOffset = 0
        }

        guard let encryption = record.encryption,
              let encryptionKey else {
            return PreparedPayload(
                source: packedSource,
                offset: packedOffset,
                hashKey: nil,
                mismatchIsWrongPassword: false
            )
        }
        let decrypted = try RARAESCBCByteSource(
            source: packedSource,
            ciphertextOffset: packedOffset,
            ciphertextSize: record.packedSize,
            // Compression blocks carry their own logical end. Stored entries
            // use their declared output size, so AES padding is never exposed.
            plaintextSize: record.packedSize,
            key: encryptionKey,
            initializationVector: Data(encryption.initializationVector)
        )
        return PreparedPayload(
            source: decrypted,
            offset: 0,
            hashKey: hashKey,
            mismatchIsWrongPassword: mismatchIsWrongPassword
        )
    }

    /// Authenticates each non-final volume range before a decoder observes any
    /// of the concatenated stream. This is deliberately chunked: packed sizes
    /// come from the archive and must never become a temporary allocation.
    private static func validatePackedParts(
        _ record: Record,
        entryIndex: Int,
        options: ReaderOptions,
        encryptionHashKey: Data?,
        mismatchIsWrongPassword: Bool
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
            let hashKey = integrity.usesTweakedChecksums
                ? encryptionHashKey
                : nil
            if integrity.usesTweakedChecksums, hashKey == nil {
                throw KaitoError.malformed(
                    "RAR5 packed checksum is tweaked without encryption"
                )
            }
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

            if let expectedCRC = integrity.crc32 {
                let actualCRC = hashKey.map {
                    RAR5ChecksumMAC.crc32(crc.value, hashKey: $0)
                } ?? crc.value
                guard actualCRC == expectedCRC else {
                    if mismatchIsWrongPassword, hashKey != nil {
                        throw KaitoError.wrongPassword
                    }
                    throw KaitoError.checksumMismatch(entry: entryIndex)
                }
            }
            if let expectedHash = integrity.hash,
               expectedHash.type == 0,
               verifyHash {
                guard expectedHash.digest.count == 32 else {
                    throw KaitoError.malformed("RAR5 BLAKE2sp digest is not 32 bytes")
                }
                guard var actualHash = hash?.finalize() else {
                    throw KaitoError.malformed("RAR5 packed hash state is missing")
                }
                if let hashKey {
                    actualHash = try RAR5ChecksumMAC.blake2sp(
                        actualHash,
                        hashKey: hashKey
                    )
                }
                guard RARConstantTime.equals(actualHash, Data(expectedHash.digest)) else {
                    if mismatchIsWrongPassword, hashKey != nil {
                        throw KaitoError.wrongPassword
                    }
                    throw KaitoError.checksumMismatch(entry: entryIndex)
                }
            }
        }
    }

    private static func parse(
        source: any ByteSource,
        sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?,
        options: ReaderOptions,
        passwordSelection: RAR5PasswordSelection
    ) throws -> (entries: [ArchiveEntry], records: [Record], password: String?) {
        var resolvedPassword = options.password
        // One archive-encryption envelope can occur per volume. Retaining every
        // reachable context makes the cumulative work accounting match actual
        // derivations rather than charging harmless repeated envelopes.
        let headerKeyCache = RAR5KeyCache(
            capacity: max(1, options.limits.maxVolumeCount),
            passwordSelection: passwordSelection
        )
        var headerKDFBudget = HeaderKDFWorkBudget(
            limit: options.limits.maxRAR5HeaderKDFWork
        )
        let first = try parseVolume(
            source: source,
            volumeNumber: 0,
            options: options,
            password: &resolvedPassword,
            keyCache: headerKeyCache,
            expectedHeaderEncryption: nil,
            headerKDFBudget: &headerKDFBudget
        )
        guard first.volumeNumber == 0 else {
            throw KaitoError.malformed(
                "RAR5 volume number \(first.volumeNumber) does not match expected 0"
            )
        }
        if first.archiveFlags.contains(RAR5ArchiveFlags.volumeNumber), first.volumeNumber == 0 {
            throw KaitoError.malformed(
                "RAR5 first volume has an explicit volume number"
            )
        }

        // 多巻の欠損を単一書庫の切断と混同せず、分割 entry の救済を禁止する。
        if options.recoverDamagedArchives,
           !first.sawEndHeader, first.archiveFlags.contains(RAR5ArchiveFlags.volume) {
            throw KaitoError.truncated
        }

        guard first.archiveFlags.contains(RAR5ArchiveFlags.volume), let sourceURL else {
            if first.endFlags.contains(RAR5EndFlags.moreVolumes),
               !first.archiveFlags.contains(RAR5ArchiveFlags.volume) {
                throw KaitoError.malformed(
                    "RAR5 non-volume requests a continuation volume"
                )
            }
            let published = try publish(
                first.pending,
                archiveFlags: first.archiveFlags,
                recoverDamagedArchives: options.recoverDamagedArchives
            )
            return (published.entries, published.records, resolvedPassword)
        }

        // The locator authenticates an unencrypted main header immediately. If
        // headers are encrypted it validates the leading type-4 envelope, and
        // parseVolume below authenticates/decrypts the main header and checks
        // the volume marker and number before accepting any packed ranges.
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
        var totalServiceHeaders = current.serviceHeaderCount

        try mergeFragments(
            current.pending,
            into: &merged,
            activeSplit: &activeSplit,
            limits: options.limits
        )

        while current.endFlags.contains(RAR5EndFlags.moreVolumes) {
            let nextNumber = try Checked.add(volumeNumber, 1)
            guard nextNumber < UInt64(options.limits.maxVolumeCount) else {
                throw KaitoError.limitExceeded("RAR5 volume count")
            }
            let located = try locator.locate(volumeNumber: nextNumber)
            let next = try parseVolume(
                source: located.source,
                volumeNumber: nextNumber,
                options: options,
                password: &resolvedPassword,
                keyCache: headerKeyCache,
                expectedHeaderEncryption: first.headersEncrypted,
                headerKDFBudget: &headerKDFBudget
            )
            guard next.archiveFlags.contains(RAR5ArchiveFlags.volume) else {
                throw KaitoError.malformed(
                    "RAR5 continuation is not marked as a volume"
                )
            }
            guard next.volumeNumber == nextNumber else {
                throw KaitoError.malformed(
                    "RAR5 volume number \(next.volumeNumber) does not match expected \(nextNumber)"
                )
            }
            // Swift 6.3.3 は暗黙メンバ `.solid` の文脈型を推論できない箇所があるため
            // 型名で修飾する(6.4 では推論できる)
            let nextIsSolid = next.archiveFlags.contains(RAR5ArchiveFlags.solid)
            let firstIsSolid = first.archiveFlags.contains(RAR5ArchiveFlags.solid)
            guard nextIsSolid == firstIsSolid else {
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
        let published = try publish(
            merged,
            archiveFlags: first.archiveFlags,
            recoverDamagedArchives: options.recoverDamagedArchives
        )
        return (published.entries, published.records, resolvedPassword)
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
        options: ReaderOptions,
        password: inout String?,
        keyCache: RAR5KeyCache,
        expectedHeaderEncryption: Bool?,
        headerKDFBudget: inout HeaderKDFWorkBudget
    ) throws -> ParseState {
        // 後続巻では救済を有効にせず、従来どおり切断を通知する。
        let recoverDamagedArchives = options.recoverDamagedArchives && volumeNumber == 0
        var state = ParseState()
        var offset = UInt64(signature.count)
        var archiveEncryption: ArchiveEncryptionContext?
        var headerBodyWasVerified = false
        // Allocation profiling found a 256 KiB allocation and zero fill in
        // every readBlock. Keep one bounded cursor per volume and seek across
        // payloads, retaining read-ahead when the next header is still cached.
        // The capacity depends only on caller limits, never header sizes.
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

        while offset < source.length, !state.sawEndHeader {
            let block: Block
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
                // header 自体が EOF で切れた場合だけ、既読 entry を残す。
                // CRC 検証後の共通 header の自己矛盾も救済しない。
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
        _ block: Block,
        options: ReaderOptions,
        password: inout String?,
        keyCache: RAR5KeyCache,
        headerKDFBudget: inout HeaderKDFWorkBudget
    ) throws -> ArchiveEncryptionContext {
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
        return ArchiveEncryptionContext(
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
    ) throws -> Block {
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

        let recordedCRC = UInt32(plaintext[0])
            | UInt32(plaintext[1]) << 8
            | UInt32(plaintext[2]) << 16
            | UInt32(plaintext[3]) << 24
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
    ) throws -> Block {
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
    ) throws -> Block {
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
            // 宣言値は保持し、救済時だけ EOF までを読み取り範囲にする。
            guard recoverDamagedArchives else { throw KaitoError.truncated }
            availableDataSize = try Checked.sub(sourceLength, dataOffset)
            isDataTruncated = true
            nextOffset = sourceLength
        }
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
            availableDataSize: availableDataSize,
            isDataTruncated: isDataTruncated,
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
        if hostOS == 0, name.contains("\\") {
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
        var extras = FileExtras()
        var singletonExtraTypes: Set<UInt64> = []
        try parseExtraRecords(&extraCursor, limits: options.limits) {
            type, record in
            try rejectDuplicateSingletonExtra(
                type,
                seen: &singletonExtraTypes,
                headerKind: "file"
            )
            switch type {
            case 0x01:
                extras.encryption = try parseEncryptionRecord(&record)
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

        let isIncomplete = options.recoverDamagedArchives && block.isDataTruncated
        let availablePackedSize = isIncomplete ? block.availableDataSize : nil
        let splitAfter = block.flags.contains(.splitAfter)
        return PendingEntry(
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
            packedSegments: [RARSourceSegment(
                source: source,
                offset: block.dataOffset,
                length: availablePackedSize ?? block.dataSize
            )],
            packedPartIntegrity: [PackedPartIntegrity(
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
        _ block: Block,
        limits: ReadLimits
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
        guard (0x01...0x06).contains(type) else { return }
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
        guard splitEncryptionParametersMatch(
                  first.extras.encryption,
                  continuation.extras.encryption
              ),
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
        // hash, CRC, and checksum-MAC flag describe the unpacked logical file
        // published to callers. RAR may add flag 0x0002 only in that final
        // encryption record while retaining one salt, IV, key, and CBC stream.
        extras.encryption = continuation.extras.encryption
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

    /// Split headers repeat the file-encryption parameters, but flag 0x0002 is
    /// local to the checksum/hash stored in that header. In particular, RAR
    /// sets it for the final unpacked-file digest while earlier headers carry
    /// an untweaked digest of their packed ciphertext range.
    private static func splitEncryptionParametersMatch(
        _ first: RAR5EncryptionRecord?,
        _ continuation: RAR5EncryptionRecord?
    ) -> Bool {
        switch (first, continuation) {
        case (nil, nil):
            return true
        case let (first?, continuation?):
            return first.version == continuation.version
                && (first.flags ^ continuation.flags) & ~UInt64(0x0002) == 0
                && first.kdfCount == continuation.kdfCount
                && first.salt == continuation.salt
                && first.initializationVector == continuation.initializationVector
                && first.checkValue == continuation.checkValue
        default:
            return false
        }
    }

    private static func publish(
        _ pending: [PendingEntry],
        archiveFlags: RAR5ArchiveFlags,
        recoverDamagedArchives: Bool
    ) throws -> (entries: [ArchiveEntry], records: [Record]) {
        var solidGroups = [Int](repeating: -1, count: pending.count)
        if archiveFlags.contains(RAR5ArchiveFlags.solid) {
            var previousFileIndex: Int?
            for index in pending.indices
            where pending[index].kind != .directory
                && !isZeroBodyRedirection(pending[index].extras.redirection?.type) {
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
        } else if pending.contains(where: {
            $0.kind != .directory
                && !isZeroBodyRedirection($0.extras.redirection?.type)
                && $0.compression.isSolid
        }) {
            throw KaitoError.malformed("RAR5 solid file is not in a solid archive")
        }

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        var lastEntryByNormalizedPath: [String: Int] = [:]
        entries.reserveCapacity(pending.count)
        records.reserveCapacity(pending.count)

        for (index, item) in pending.enumerated() {
            let zeroBodyRedirection = isZeroBodyRedirection(
                item.extras.redirection?.type
            )
            let publishedUnpackedSize: UInt64? = zeroBodyRedirection
                ? 0
                : item.unpackedSize
            let publishedPackedSize = zeroBodyRedirection ? 0 : item.packedSize
            var specific: [String: String] = [
                "rarVersion": item.compression.version == 0 ? "5" : "7",
                "compressionInfo": "0x" + String(item.compression.rawValue, radix: 16),
                "method": String(item.compression.method),
                "dictionarySize": String(item.compression.dictionarySize),
                "hostOS": String(item.hostOS),
                "attributes": "0x" + String(item.attributes, radix: 16),
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
                specific["hash"] = hash.digest.map {
                    let digits = String($0, radix: 16)
                    return $0 < 16 ? "0" + digits : digits
                }.joined()
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
            } else if item.kind == .symlink {
                specific["linkTargetStoredAsData"] = "true"
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
                uncompressedSize: publishedUnpackedSize,
                compressedSize: publishedPackedSize,
                modificationDate: item.modificationDate,
                posixPermissions: item.permissions,
                isEncrypted: !zeroBodyRedirection && item.extras.encryption != nil,
                solidGroup: solidGroups[index],
                crc32: zeroBodyRedirection ? nil : item.crc32,
                methodDescription: methodDescription,
                formatSpecific: specific,
                isIncomplete: recoverDamagedArchives && item.isIncomplete
            )
            entries.append(entry)
            if let normalizedName = normalizedExtractionPath(item.name) {
                // Resolve hard links before insertion so targets are always
                // earlier archive members and cannot form forward cycles.
                lastEntryByNormalizedPath[normalizedName] = entry.index
            }
            records.append(Record(
                packedSegments: zeroBodyRedirection ? [] : item.packedSegments,
                packedPartIntegrity: zeroBodyRedirection
                    ? []
                    : item.packedPartIntegrity,
                packedSize: publishedPackedSize,
                availablePackedSize: item.availablePackedSize,
                isIncomplete: recoverDamagedArchives && item.isIncomplete,
                unpackedSize: publishedUnpackedSize,
                compression: item.compression,
                encryption: item.extras.encryption,
                hash: item.extras.hash,
                redirectionType: item.extras.redirection?.type,
                requiresPreviousVolume: !zeroBodyRedirection && item.splitBefore,
                requiresNextVolume: !zeroBodyRedirection && item.splitAfter
            ))
        }
        return (entries, records)
    }

    private static func normalizedExtractionPath(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.first != 0x2F, !path.utf8.contains(0) else {
            return nil
        }
        let rawComponents = path
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !rawComponents.contains("..") else { return nil }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
