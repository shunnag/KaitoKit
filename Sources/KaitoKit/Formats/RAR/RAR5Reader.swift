import Foundation

// Format reference: RARLab, "RAR 5.0 archive format",
// https://www.rarlab.com/technote.htm (accessed 2026-09-06).
// This is a clean-room implementation of the published format description.
// RARLab/UnRAR, 7-Zip, XADMaster, and The Unarchiver source code were not used.

final class RAR5Reader: FormatReader {
    static let signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]

    private struct PreparedPayload {
        let source: any ByteSource
        let offset: UInt64
        let hashKey: Data?
        let mismatchIsWrongPassword: Bool
    }

    let format: ArchiveFormat = .rar
    private(set) var entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = nil

    private let source: any ByteSource
    private let sourceURL: URL?
    private let options: ReaderOptions
    private let records: [RAR5EntryRecord]
    private let quickOpenVerification: RAR5QuickOpenVerification
    private let solidGroupMembers: [Int: [Int]]
    private let solidGroupExcludedMembers: [Int: [Int]]
    private let keyCache = RAR5KeyCache()
    let entryKDFBudget: KDFWorkBudget
    // Independent members recycle decoder windows and tables through this pool.
    private let scratchPool: RAR5Decoder.ScratchPool
    private var password: String?
    private var solidCoordinators: [Int: RARSolidCoordinator<RAR5Decoder.SolidState>] = [:]
    private var activeSolidGroup: Int?
    // factory は coordinator.stream の同期呼出し中だけ、この照合済み先読みを受け取る。
    private final class SolidPriming {
        var index: Int?
        var record: RAR5EntryRecord?
        func take(_ index: Int) -> RAR5EntryRecord? {
            guard self.index == index else { return nil }
            defer { self.record = nil; self.index = nil }
            return record
        }
    }
    private let solidPriming = SolidPriming()
    // Decodes later independent members on the leaf pool; nil below two workers.
    private lazy var prefetcher: IndependentEntryPrefetcher? = makePrefetcher()
    // Test hook: creates the prefetcher if the first stream has not yet.
    var prefetcherForTesting: IndependentEntryPrefetcher? { prefetcher }
    var pooledScratchByteCount: Int { scratchPool.heldByteCount }

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
        self.entryKDFBudget = KDFWorkBudget(limit: options.limits.maxRAR5EntryKDFWork,
                                          subject: "RAR5 entry KDF work")
        self.password = options.password
        self.scratchPool = RAR5Decoder.ScratchPool(
            capacity: max(4, options.resolvedDecodeThreads + 1),
            memoryBudget: options.limits.resolvedParallelDecodeMemory()
        )

        guard source.length >= UInt64(Self.signature.count) else {
            throw KaitoError.truncated
        }
        let signature = try readByteRange(source: source, offset: 0, count: Self.signature.count)
        guard signature == Self.signature else { throw KaitoError.unsupportedFormat }

        let parsed = try RAR5EntryPublisher.parse(
            source: source,
            sourceURL: sourceURL,
            sourceDirectoryAnchor: sourceDirectoryAnchor,
            options: options,
            passwordSelection: keyCache.passwordSelection
        )
        self.entries = parsed.entries
        self.records = parsed.records
        self.quickOpenVerification = parsed.records.lazy.flatMap(\.headerGuards).compactMap { $0 }.first?.verification ?? RAR5QuickOpenVerification()
        let groups = Self.indexSolidGroups(parsed.entries)
        self.solidGroupMembers = groups
        self.solidGroupExcludedMembers = Self.indexSolidGroupExclusions(groups, records: parsed.records)
        self.password = parsed.password
    }

    /// Returns an independent mutable reader while retaining the exact source
    /// handles authenticated during the original parse. In particular, a
    /// reopened multi-volume reader never resolves sibling paths a second time.
    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        // guard の原本 source と検証状態を共有し、先読み buffer は共有しない。
        let reader = RAR5Reader(
            source: source,
            sourceURL: sourceURL,
            options: options,
            entries: entries,
            records: records,
            quickOpenVerification: quickOpenVerification
        )
        reader.keyCache.passwordSelection.selectedUTF8 = keyCache.passwordSelection.selectedUTF8
        return reader
    }

    private init(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        entries: [ArchiveEntry],
        records: [RAR5EntryRecord],
        quickOpenVerification: RAR5QuickOpenVerification
    ) {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.entryKDFBudget = KDFWorkBudget(limit: options.limits.maxRAR5EntryKDFWork,
                                          subject: "RAR5 entry KDF work")
        self.entries = entries
        self.records = records
        self.quickOpenVerification = quickOpenVerification
        let groups = Self.indexSolidGroups(entries)
        self.solidGroupMembers = groups
        self.solidGroupExcludedMembers = Self.indexSolidGroupExclusions(groups, records: records)
        self.password = options.password
        self.scratchPool = RAR5Decoder.ScratchPool(
            capacity: max(4, options.resolvedDecodeThreads + 1),
            memoryBudget: options.limits.resolvedParallelDecodeMemory()
        )
    }

    func headerOffsetForTesting(entry: ArchiveEntry) -> UInt64 {
        records[entry.index].headerOffset
    }

    var recordsForTesting: [RAR5EntryRecord] { records }

    var guardedHeaderCountForTesting: Int { records.flatMap(\.headerGuards).compactMap { $0 }.count }

    func setPassword(_ password: String?) {
        guard self.password.map({ Array($0.utf8) }) != password.map({ Array($0.utf8) }) else { return }
        self.password = password
        keyCache.removeAll()
        entryKDFBudget.reset()
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
        try quickOpenVerification.checkPoison()
        let record = try records[entry.index].verifyingHeaders()
        if let unpackedSize = record.unpackedSize {
            try Checked.size(unpackedSize, limit: limits.maxEntrySize)
        }

        // A truncated solid member is listable only; it never feeds the
        // continuing decoder state.
        if options.recoverDamagedArchives, entry.isIncomplete, entry.solidGroup >= 0 {
            throw KaitoError.truncated
        }

        if record.redirectionType == RAR5RedirectionType.fileCopy,
           let targetText = entry.formatSpecific["fileCopyTargetIndex"],
           let targetIndex = Int(targetText),
           entries.indices.contains(targetIndex) {
            if quickOpenVerification.hasAllocatedSlots {
                // 参照先より後の名前を偽る写しも、最後の同名 entry の選択を変え得る。
                for previous in records[(targetIndex + 1)..<entry.index] {
                    _ = try previous.verifyingHeaders(prime: false)
                }
            }
            // 参照元は入口で照合済み。再帰先も入口で自身の全 fragment を照合する。
            // A file copy (`rar -oi`) has no body and names an earlier entry with
            // the same content. Its declared size was matched against that target
            // while listing, so the target's stream (and CRC) is returned as is.
            return try stream(for: entries[targetIndex], limits: limits)
        }
        if (record.redirectionType == RAR5RedirectionType.fileCopy
            || record.redirectionType == RAR5RedirectionType.hardLink),
           quickOpenVerification.hasAllocatedSlots {
            // hard link と未解決の copy も、先行する写しが名前・種類・サイズを偽った結果かもしれない。
            // 空の結果を返す前に参照解決へ影響する全候補を照合する。通常の本文経路は増やさない。
            for previous in records[..<entry.index] { _ = try previous.verifyingHeaders(prime: false) }
        }
        if RAR5RedirectionType.isZeroBody(record.redirectionType) {
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
                limits: limits,
                verifiedRecord: record
            )
        }

        let prepared = try Self.preparePayload(
            record,
            entryIndex: entry.index,
            options: options,
            limits: limits,
            password: password,
            keyCache: keyCache,
            entryKDFBudget: entryKDFBudget
        )

        let outputLength: UInt64? = record.unpackedSize
        var decompressor: any Decompressor
        var blake2spWasVerified = false
        if record.compression.method == 0 {
            let storedSize = try Self.logicalStoredSize(record)
            decompressor = try CopyDecompressor(
                source: prepared.source,
                offset: prepared.offset,
                compressedSize: entry.isIncomplete
                    ? min(storedSize, record.availablePackedSize ?? record.packedSize)
                    : storedSize
            )
        } else if let prefetched = try prefetcher?.take(entry.index) {
            // Decoded ahead and BLAKE2sp-verified on a worker. The CRC-32 is
            // still checked by the stream below, exactly like the serial path.
            decompressor = try CopyDecompressor(
                source: DataByteSource(data: prefetched),
                offset: 0,
                compressedSize: UInt64(prefetched.count)
            )
            blake2spWasVerified = true
        } else {
            do {
                decompressor = try Self.makeCompressedDecompressor(
                    source: prepared.source,
                    offset: prepared.offset,
                    compressedSize: record.availablePackedSize ?? record.packedSize,
                    unpackedSize: outputLength,
                    dictionarySize: record.compression.dictionarySize,
                    limits: limits,
                    scratchPool: scratchPool,
                    mismatchIsWrongPassword: prepared.mismatchIsWrongPassword
                )
            } catch KaitoError.truncated {
                guard options.recoverDamagedArchives, entry.isIncomplete else {
                    throw KaitoError.truncated
                }
                // Without even the first compressed block, zero bytes are recoverable.
                decompressor = try CopyDecompressor(
                    source: prepared.source,
                    offset: prepared.offset,
                    compressedSize: 0
                )
            }
        }

        prefetcher?.schedule(after: entry.index)

        // Incomplete unencrypted stored payloads are already bounded to available
        // bytes by CopyDecompressor, so preserve bulk reads without recovery wrapping.
        if entry.isIncomplete,
           !(record.compression.method == 0 && record.encryption == nil) {
            decompressor = RecoveryDecompressor(decompressor, maximumOutputSize: outputLength)
        }
        // A recovered incomplete entry has no digest, size or CRC to verify.
        return try Self.makeVerifiedEntryStream(
            decompressor: decompressor,
            record: record,
            entryIndex: entry.index,
            prepared: prepared,
            verifiesBlake2sp: options.verifyRAR5Blake2sp && !entry.isIncomplete && !blake2spWasVerified,
            length: entry.isIncomplete ? nil : outputLength,
            expectedCRC32: entry.isIncomplete ? nil : entry.crc32,
            limits: limits
        )
    }

    private func streamSolidEntry(
        _ entry: ArchiveEntry,
        group: Int,
        limits: ReadLimits,
        verifiedRecord: RAR5EntryRecord
    ) throws -> EntryStream {
        solidPriming.index = entry.index
        solidPriming.record = verifiedRecord
        defer { solidPriming.index = nil; solidPriming.record = nil }
        // ArchiveReader is deliberately non-thread-safe and already permits
        // only one live range per group. Apply the same rule across groups so
        // an archive with many short solid runs cannot accumulate dictionaries.
        if let activeSolidGroup, activeSolidGroup != group {
            solidCoordinators[activeSolidGroup]?.invalidateAndRelease()
        }
        activeSolidGroup = group

        // 一覧の種類や redirection によって辞書の列から省かれた member も、写しが
        // 偽装されていないことを先に検める。通常の file member は factory が先読みと共用する。
        if let excluded = solidGroupExcludedMembers[group] {
            for index in excluded {
                if index > entry.index { break }
                _ = try records[index].verifyingHeaders(prime: false)
            }
        }

        let coordinator: RARSolidCoordinator<RAR5Decoder.SolidState>
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
            let capturedEntryKDFBudget = entryKDFBudget
            let capturedSourceURL = sourceURL
            let capturedPriming = solidPriming
            coordinator = RARSolidCoordinator<RAR5Decoder.SolidState>(
                formatLabel: "RAR5",
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
                    record: capturedPriming.take(index) ?? capturedRecords[index],
                    options: capturedOptions,
                    limits: limits,
                    password: capturedPassword,
                    keyCache: capturedKeyCache,
                    entryKDFBudget: capturedEntryKDFBudget,
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
        // A file copy reports its target's solid group but has no body, so it
        // never joins the decoding chain; reads go to the target's stream.
        for index in entries.indices
        where entries[index].solidGroup >= 0
            && entries[index].formatSpecific["fileCopyTargetIndex"] == nil {
            result[entries[index].solidGroup, default: []].append(index)
        }
        return result
    }

    // 除外された写しだけを索引にし、通常の member 列を stream ごとに再走査しない。
    private static func indexSolidGroupExclusions(
        _ groups: [Int: [Int]], records: [RAR5EntryRecord]
    ) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for (group, members) in groups {
            var excluded: [Int] = []
            for (previous, next) in zip(members, members.dropFirst()) where next > previous + 1 {
                for index in (previous + 1)..<next where records[index].headerGuards.contains(where: { $0 != nil }) {
                    excluded.append(index)
                }
            }
            if !excluded.isEmpty { result[group] = excluded }
        }
        return result
    }

    private static func makeSolidVerifiedStream(
        entry: ArchiveEntry,
        record: RAR5EntryRecord,
        options: ReaderOptions,
        limits: ReadLimits,
        password: String?,
        keyCache: RAR5KeyCache,
        entryKDFBudget: KDFWorkBudget,
        sourceURL: URL?,
        state: RAR5Decoder.SolidState
    ) throws -> EntryStream {
        let record = try record.verifyingHeaders()
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
            keyCache: keyCache,
            entryKDFBudget: entryKDFBudget
        )

        let decompressor: any Decompressor
        if record.compression.method == 0 {
            let storedSize = try logicalStoredSize(record)
            // A stored member is part of archive ordering but does not feed or
            // replace the continuing LZ dictionary. Black-box vectors include
            // a stored payload larger than the dictionary followed by a match
            // back into the compressed predecessor.
            decompressor = try CopyDecompressor(
                source: prepared.source,
                offset: prepared.offset,
                compressedSize: storedSize
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
        return try makeVerifiedEntryStream(
            decompressor: decompressor,
            record: record,
            entryIndex: entry.index,
            prepared: prepared,
            verifiesBlake2sp: options.verifyRAR5Blake2sp,
            length: record.unpackedSize,
            expectedCRC32: entry.crc32,
            limits: limits
        )
    }

    // MARK: - Independent-member prefetch

    private func makePrefetcher() -> IndependentEntryPrefetcher? {
        let workers = options.resolvedDecodeThreads
        guard workers >= 2 else { return nil }
        let entries = entries, records = records, options = options
        let limits = options.limits, scratchPool = scratchPool, sourceURL = sourceURL
        return IndependentEntryPrefetcher(
            workers: workers,
            memoryBudget: limits.resolvedParallelDecodeMemory(),
            memberCount: records.count,
            candidate: { index in
                Self.prefetchCandidate(index, entries: entries, records: records)
            },
            decodeBatch: { members, shouldStop in
                Self.decodeIndependentBatch(
                    members, records: records, options: options, limits: limits,
                    scratchPool: scratchPool, sourceURL: sourceURL, shouldStop: shouldStop
                )
            }
        )
    }

    /// An independent, complete, unencrypted, version-zero compressed member
    /// of known size with a plain body. Everything else keeps the serial path.
    private static func prefetchCandidate(
        _ index: Int,
        entries: [ArchiveEntry],
        records: [RAR5EntryRecord]
    ) -> IndependentEntryPrefetcher.Candidate? {
        guard entries.indices.contains(index), records.indices.contains(index) else { return nil }
        let entry = entries[index]
        let record = records[index]
        guard entry.solidGroup < 0, !entry.isIncomplete,
              record.compression.method != 0, record.compression.version == 0,
              record.encryption == nil, record.redirectionType == nil,
              let unpackedSize = record.unpackedSize, unpackedSize > 0,
              let outputSize = Int(exactly: unpackedSize),
              let packedSize = Int(exactly: record.packedSize),
              let dictionarySize = Int(exactly: record.compression.dictionarySize) else { return nil }
        let window = RAR5Decoder.retainedWindowSize(
            expectedSize: unpackedSize, dictionarySize: dictionarySize
        )
        // ここでは入力範囲の計画だけを行い、worker の照合前に復号・出力しない。
        return IndependentEntryPrefetcher.Candidate(
            index: index,
            outputSize: outputSize,
            scratchBytes: packedSize + window + RAR5Decoder.ScratchPool.stateOverheadBytes,
            packedSegment: record.packedSegments.count == 1 ? record.packedSegments.first : nil,
            headerOffset: record.headerGuards.first.flatMap { $0 }?.headerOffset
        )
    }

    /// Worker-side decode of one batch: one recycled decoder state serves every
    /// member in turn, and when the members' packed bodies are consecutive in
    /// one file the whole span is read with a single call. A member that fails
    /// here is left nil for the serial path to decode and report.
    private static func decodeIndependentBatch(
        _ members: [IndependentEntryPrefetcher.Candidate],
        records: [RAR5EntryRecord],
        options: ReaderOptions,
        limits: ReadLimits,
        scratchPool: RAR5Decoder.ScratchPool,
        sourceURL: URL?,
        shouldStop: () -> Bool
    ) -> [Data?] {
        var outputs = [Data?](repeating: nil, count: members.count)
        guard let first = members.first else { return outputs }
        var state = scratchPool.take(windowSize: RAR5Decoder.retainedWindowSize(
            expectedSize: records[first.index].unpackedSize,
            dictionarySize: Int(clamping: records[first.index].compression.dictionarySize)
        ))
        defer { if let state { scratchPool.recycle(state) } }
        let span = PrefetchedPackedSpan.read(members: members)
        for (position, member) in members.enumerated() {
            if position % 8 == 0, shouldStop() { break }
            outputs[position] = try? decodeIndependentMember(
                records[member.index], entryIndex: member.index, options: options,
                limits: limits, scratchPool: scratchPool, state: &state,
                span: span, sourceURL: sourceURL
            )
        }
        return outputs
    }

    /// The same payload preparation and decoder as the serial path, drained
    /// completely, with the member's BLAKE2sp digest checked here so the
    /// reader can skip it.
    private static func decodeIndependentMember(
        _ record: RAR5EntryRecord,
        entryIndex: Int,
        options: ReaderOptions,
        limits: ReadLimits,
        scratchPool: RAR5Decoder.ScratchPool,
        state: inout RAR5Decoder.SolidState?,
        span: PrefetchedPackedSpan?,
        sourceURL: URL?
    ) throws -> Data {
        let spanCoversMember = record.packedSegments.count == 1
            && span?.covers(record.packedSegments[0].offset, length: record.packedSize) == true
        let record = try record.verifyingHeaders(span: span, prime: !spanCoversMember)
        guard let unpackedSize = record.unpackedSize, record.encryption == nil else {
            throw KaitoError.malformed("RAR5 prefetch candidate is not independent")
        }
        try validateStreamCompatibility(record, options: options, sourceURL: sourceURL)
        let prepared = try preparePayload(
            record, entryIndex: entryIndex, options: options, limits: limits,
            password: nil, keyCache: RAR5KeyCache(),
            entryKDFBudget: KDFWorkBudget(limit: 0, subject: "RAR5 entry KDF work")
        )
        var source = prepared.source
        if let span, record.packedSegments.count == 1,
           span.covers(prepared.offset, length: record.packedSize) {
            source = span
        }
        let retained = RAR5Decoder.retainedWindowSize(
            expectedSize: unpackedSize,
            dictionarySize: Int(clamping: record.compression.dictionarySize)
        )
        if let current = state, current.windowSize < retained {
            scratchPool.recycle(current)
            state = nil
        }
        if state == nil {
            state = scratchPool.take(windowSize: retained)
                ?? (try? RAR5Decoder.SolidState(dictionarySize: UInt64(retained)))
        }
        let decoder = try makeCompressedDecompressor(
            source: source,
            offset: prepared.offset,
            compressedSize: record.packedSize,
            unpackedSize: unpackedSize,
            dictionarySize: record.compression.dictionarySize,
            limits: limits,
            scratchPool: state == nil ? scratchPool : nil,
            independentState: state,
            mismatchIsWrongPassword: prepared.mismatchIsWrongPassword
        )
        // One spare byte verifies the declared end exactly like EntryStream.
        let size = try Checked.toInt(unpackedSize)
        var output = Data(count: size + 1)
        try output.withUnsafeMutableBytes { destination in
            var total = 0
            while total <= size, !decoder.isFinished {
                let count = try decoder.read(into: UnsafeMutableRawBufferPointer(
                    rebasing: destination[total..<(size + 1)]
                ))
                guard count > 0 else { break }
                total += count
            }
            guard total == size, decoder.isFinished else {
                throw KaitoError.malformed("RAR5 prefetched member size mismatch")
            }
        }
        output.removeLast()
        if options.verifyRAR5Blake2sp, let hash = record.hash, hash.type == 0 {
            var digest = Blake2sp()
            digest.update(output)
            guard ConstantTime.equals(digest.finalize(), Data(hash.digest)) else {
                throw KaitoError.checksumMismatch(entry: entryIndex)
            }
        }
        return output
    }

    /// Output size of a stored (method 0) member. An unencrypted payload must
    /// match its declared size; an encrypted one must declare a size that fits
    /// within its AES-padded ciphertext.
    private static func logicalStoredSize(_ record: RAR5EntryRecord) throws -> UInt64 {
        if record.encryption == nil, let outputLength = record.unpackedSize,
           outputLength != record.packedSize {
            throw KaitoError.malformed("RAR5 stored sizes differ")
        }
        if record.encryption != nil, record.unpackedSize == nil {
            throw KaitoError.unsupportedMethod(
                "RAR5 encrypted stored entry with unknown unpacked size"
            )
        }
        let size = record.unpackedSize ?? record.packedSize
        guard size <= record.packedSize else {
            throw KaitoError.malformed(
                "RAR5 encrypted stored entry exceeds its ciphertext"
            )
        }
        return size
    }

    /// Adds the checks shared by independent and solid members: the optional
    /// BLAKE2sp digest and the password-dependent CRC transform. A successfully
    /// verified password-check value disambiguates a later payload digest
    /// failure: it is corruption, not a bad password. Older records without
    /// that independent check necessarily remain ambiguous.
    private static func makeVerifiedEntryStream(
        decompressor base: any Decompressor,
        record: RAR5EntryRecord,
        entryIndex: Int,
        prepared: PreparedPayload,
        verifiesBlake2sp: Bool,
        length: UInt64?,
        expectedCRC32: UInt32?,
        limits: ReadLimits
    ) throws -> EntryStream {
        var decompressor = base
        var completionCheck: (() throws -> Void)?
        if verifiesBlake2sp,
           let recordHash = record.hash,
           recordHash.type == 0 {
            let hashing = try RAR5Blake2spDecompressor(
                base: decompressor,
                expected: recordHash.digest,
                hashKey: prepared.hashKey,
                entryIndex: entryIndex,
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
            length: length,
            expectedCRC32: expectedCRC32,
            entryIndex: entryIndex,
            limits: limits,
            completionCheck: completionCheck,
            checksumMismatchIsWrongPassword: prepared.mismatchIsWrongPassword,
            crc32Transform: crc32Transform
        )
    }

    private static func validateStreamCompatibility(
        _ record: RAR5EntryRecord,
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

    private static func symbolicLinkStream(
        entry: ArchiveEntry,
        record: RAR5EntryRecord,
        limits: ReadLimits
    ) throws -> EntryStream? {
        guard let type = record.redirectionType, RAR5RedirectionType.symbolicLinks.contains(type) else {
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
        scratchPool: RAR5Decoder.ScratchPool? = nil,
        independentState: RAR5Decoder.SolidState? = nil,
        mismatchIsWrongPassword: Bool
    ) throws -> any Decompressor {
        do {
            let decoder = try RAR5Decoder(
                source: source,
                offset: offset,
                compressedSize: compressedSize,
                expectedSize: unpackedSize,
                dictionarySize: dictionarySize,
                limits: limits,
                solidState: solidState,
                scratchPool: scratchPool,
                independentState: independentState
            )
            guard mismatchIsWrongPassword else { return decoder }
            return RARPasswordAmbiguousDecompressor(
                base: decoder,
                expectedSize: unpackedSize
            )
        } catch {
            guard mismatchIsWrongPassword else { throw error }
            try RARPasswordAmbiguousDecompressor.rethrowNormalized(error)
        }
    }

    /// Builds the bounded packed view shared by independent and solid decoders.
    /// The archive-declared packed size is rejected before any integrity
    /// scan, and encrypted split parts remain one continuous CBC stream.
    private static func preparePayload(
        _ record: RAR5EntryRecord,
        entryIndex: Int,
        options: ReaderOptions,
        limits: ReadLimits,
        password: String?,
        keyCache: RAR5KeyCache,
        entryKDFBudget: KDFWorkBudget
    ) throws -> PreparedPayload {
        // stream・solid factory・prefetch が全 guard を照合した局所 record のみを受け取る。
        // validatePackedParts も同じ順序で走るため、KDF と packed 検査は照合より後になる。
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
                checkValue: encryption.checkValue,
                refund: entryKDFBudget.refund,
                charge: { _ in
                    try entryKDFBudget.charge((UInt64(1) << UInt64(encryption.kdfCount)) + 32)
                }
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
            packedSource = try ConcatenatedByteSource(
                segments: record.packedSegments,
                maximumLength: record.packedSize,
                maximumSegmentCount: limits.maxVolumeCount,
                label: "RAR split stream"
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
        _ record: RAR5EntryRecord,
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
                guard ConstantTime.equals(actualHash, Data(expectedHash.digest)) else {
                    if mismatchIsWrongPassword, hashKey != nil {
                        throw KaitoError.wrongPassword
                    }
                    throw KaitoError.checksumMismatch(entry: entryIndex)
                }
            }
        }
    }

}
