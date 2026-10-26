import Foundation

// 参照仕様: LZMA SDK DOC/7zFormat.txt (18.06)。
// container 実装には XADMaster / 7-Zip C++ archive decoder のコードを取り込まず、
// 7zz は差分 oracle のみに使う。
final class SevenZipReader: FormatReader {
    private struct Record: Sendable, Equatable {
        let substream: SevenZipSubstream?
        let isEncrypted: Bool
    }

    /// Windows 属性のうち、entry の種別に使う bit。
    private enum WindowsAttribute {
        static let directory: UInt32 = 0x10
        /// 上位 16 bit に Unix mode が入っている印（p7zip 系の拡張）。
        static let unixExtension: UInt32 = 0x8000
    }

    let format: ArchiveFormat = .sevenZip
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding? = nil

    private let source: any ByteSource
    private let limits: ReadLimits
    let avoidsHeaderScans: Bool
    private let decodeThreads: Int
    private let maximumAESCyclesPower: UInt8
    private let streams: SevenZipStreamsInfo?
    private let packedRanges: [[Int: SevenZipPackRange]]
    private let records: [Record]
    private let editState: SevenZipEditState?
    private let keyCache: SevenZipAESKeyCache
    // internal は低 cycles のテストで既消費分を模擬するため。
    let entryKDFBudget: KDFWorkBudget
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private var coordinators: [Int: SevenZipFolderCoordinator] = [:]
    private var resetIndexCaches: [Int: SevenZipLZMA2ResetIndexCache] = [:]
    private var password: String?

    // 非 solid folder の先行復号。順方向の読み（直前より後ろの entry）を観測してから始め、
    // 後方へ戻ったら捨てる。reader の境界を越えて共有しない（reopened は新しく作る）。
    private var prefetcher: SevenZipFolderPrefetcher?
    private var prefetchCursor = 0
    /// 予算が既存の batch に使われている間、組み直さず次の投入を待つ。
    private var pendingPrefetchBatch: SevenZipFolderPrefetcher.Batch?
    private var lastStreamedEntryIndex: Int?
    private var readsForward = false
    /// 一つの葉にまとめる folder 群の出力の目標と個数の上限。
    private static let prefetchBatchBytes = 256 * 1_024
    private static let prefetchBatchUnits = 1_024
    /// 先行復号する folder の出力の上限。先行復号は多数の小さな entry のための経路で、folder の
    /// 出力を丸ごと保持するので、これより大きい folder は従来の直列・reset 並列経路に任せる。
    /// 保持量の上限は 2 × worker 数 × (この値 + prefetchBatchBytes + scratch) で、entry の大きさに
    /// 依らない（上限なしでは 1 folder = 1 batch が並列復号予算いっぱいまで溜まった）。
    static let prefetchMaxUnitBytes = UInt64(4 * prefetchBatchBytes)

    var resolvedPassword: String? { password }

    var hasRetainedDecoderState: Bool {
        coordinators.values.contains { $0.hasRetainedDecoderState }
    }

    // Test hook: 先行復号の利用状況。prefetcher が作られていなければ nil。
    var prefetchStatistics: (batches: Int, servedFolders: Int, heldBytes: Int)? {
        prefetcher.map { ($0.submittedBatchCount, $0.servedFolderCount, $0.heldBytes) }
    }

    init(source: any ByteSource, options: ReaderOptions, baseOffset: UInt64 = 0) throws {
        self.source = source
        self.limits = options.limits
        self.entryKDFBudget = KDFWorkBudget(limit: options.limits.maxSevenZipEntryKDFWork,
                                          subject: "7z entry KDF work")
        self.avoidsHeaderScans = options.resolvedInputLatency(for: source) == .high
        self.decodeThreads = options.resolvedDecodeThreads
        self.maximumAESCyclesPower = options.maxSevenZipAESCyclesPower

        let editRecorder = options.recordsSevenZipEditLayout ? SevenZipEditRecorder() : nil
        editRecorder?.state.baseOffset = baseOffset
        let keyCache = SevenZipAESKeyCache()
        let packedStreamVerifier = SevenZipPackedStreamVerifier(source: source)
        let metadataBudget = SevenZipMetadataBudget(
            limit: options.limits.maxTotalMetadataSize
        )
        let nextHeader = try SevenZipHeaderDecoder.readNextHeader(
            source: source,
            limits: options.limits,
            editRecorder: editRecorder
        )
        let decoder = SevenZipHeaderDecoder(
            source: source,
            packedDataEnd: nextHeader.absoluteOffset,
            options: options,
            keyCache: keyCache,
            packedStreamVerifier: packedStreamVerifier,
            metadataBudget: metadataBudget,
            editRecorder: editRecorder
        )
        let decodedHeader = try decoder.decodeNextHeader(nextHeader.bytes)
        let header = try decoder.parseHeader(decodedHeader)

        let ranges: [[Int: SevenZipPackRange]]
        if let streams = header.streams {
            ranges = try SevenZipFolderLayout.ranges(
                for: streams,
                sourceLength: source.length,
                packedDataEnd: nextHeader.absoluteOffset
            )
        } else {
            ranges = []
        }

        let built = try Self.makeEntries(
            files: header.files,
            streams: header.streams,
            packedRanges: ranges,
            limits: options.limits,
            metadataBudget: metadataBudget
        )
        self.streams = header.streams
        self.packedRanges = ranges
        self.entries = built.entries
        self.records = built.records
        self.keyCache = keyCache
        self.packedStreamVerifier = packedStreamVerifier
        self.password = decoder.password
        self.editState = editRecorder?.state
    }

    private init(source: any ByteSource, options: ReaderOptions, entries: [ArchiveEntry],
                 streams: SevenZipStreamsInfo?, packedRanges: [[Int: SevenZipPackRange]], records: [Record],
                 editState: SevenZipEditState?) {
        self.source = source
        self.limits = options.limits
        self.entryKDFBudget = KDFWorkBudget(limit: options.limits.maxSevenZipEntryKDFWork,
                                          subject: "7z entry KDF work")
        self.avoidsHeaderScans = options.resolvedInputLatency(for: source) == .high
        self.decodeThreads = options.resolvedDecodeThreads
        self.maximumAESCyclesPower = options.maxSevenZipAESCyclesPower
        self.entries = entries
        self.streams = streams
        self.packedRanges = packedRanges
        self.records = records
        self.editState = editState
        self.keyCache = SevenZipAESKeyCache()
        self.packedStreamVerifier = SevenZipPackedStreamVerifier(source: source)
        self.password = options.password
    }

    deinit {
        // 実行中・未開始の先行復号を止める。葉の closure は reader の可変状態を持たない。
        prefetcher?.reset()
    }

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        // folder coordinator、reset index、検証済み pack の記録、導出済みの鍵
        // （header の復号に使った鍵を含む）は reader の境界を越えて共有しない。
        SevenZipReader(source: source, options: options, entries: entries,
                       streams: streams, packedRanges: packedRanges, records: records, editState: editState)
    }

    func editingSnapshot() -> SevenZipEditingSnapshot? {
        editState?.snapshot(streams: streams)
    }

    func decryptedPackedStream(folder index: Int, packedInput: Int) throws -> EntryStream {
        guard let streams, streams.folders.indices.contains(index) else {
            throw KaitoError.notFound("7z folder \(index)")
        }
        let factory = try SevenZipFolderDecoderFactory(
            source: source, folder: streams.folders[index], packedRanges: packedRanges[index],
            limits: limits, password: password, keyCache: keyCache,
            maximumAESCyclesPower: maximumAESCyclesPower, packedStreamVerifier: packedStreamVerifier,
            entryKDFBudget: entryKDFBudget)
        let decrypted = try factory.makeDecryptedPackedDecoder(packedInput: packedInput)
        return try EntryStream(decompressor: decrypted.decoder, length: decrypted.length,
                               expectedCRC32: nil, entryIndex: -1, limits: limits)
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
        entryKDFBudget.reset()
        coordinators.removeAll(keepingCapacity: false)
    }

    private func resetIndexCache(for folderIndex: Int) -> SevenZipLZMA2ResetIndexCache {
        if let cached = resetIndexCaches[folderIndex] { return cached }
        let cache = SevenZipLZMA2ResetIndexCache()
        resetIndexCaches[folderIndex] = cache
        return cache
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        let record = records[try recordIndex(of: entry, label: "7z")]
        guard let substream = record.substream else {
            let empty = DataByteSource(data: Data())
            let decoder = try CopyDecompressor(source: empty, offset: 0, compressedSize: 0)
            return try EntryStream(
                decompressor: decoder,
                length: 0,
                expectedCRC32: entry.crc32,
                entryIndex: entry.index,
                limits: limits,
                checksumMismatchIsWrongPassword: false
            )
        }
        guard let streams,
              substream.folderIndex >= 0,
              substream.folderIndex < streams.folders.count else {
            throw KaitoError.malformed("7z entry references an invalid folder")
        }

        let folder = streams.folders[substream.folderIndex]
        if substream.offset == 0,
           substream.size == folder.unpackSizes[folder.finalOutputIndex],
           folder.coders.count == 1,
           folder.coders.first.map({ SevenZipMethod.kind(for: $0.methodID) == .copy }) == true {
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: folder,
                packedRanges: packedRanges[substream.folderIndex],
                limits: self.limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier,
                workers: decodeThreads,
                entryKDFBudget: entryKDFBudget
            )
            return try EntryStream(
                decompressor: factory.makeDecoder(),
                length: substream.size,
                expectedCRC32: substream.digest.value,
                entryIndex: entry.index,
                limits: limits
            )
        }

        let folderHasMultipleSubstreams = entry.solidGroup >= 0
        if !folderHasMultipleSubstreams,
           let prefetched = try prefetchedDecompressor(for: entry, substream: substream) {
            return try EntryStream(
                decompressor: prefetched,
                length: substream.size,
                expectedCRC32: substream.digest.value,
                entryIndex: entry.index,
                limits: limits,
                checksumMismatchIsWrongPassword: record.isEncrypted
            )
        }

        let coordinator: SevenZipFolderCoordinator
        if folderHasMultipleSubstreams,
           let cached = coordinators[substream.folderIndex] {
            coordinator = cached
        } else {
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: folder,
                packedRanges: packedRanges[substream.folderIndex],
                limits: self.limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier,
                workers: decodeThreads,
                resetIndexCache: resetIndexCache(for: substream.folderIndex),
                avoidsHeaderScans: avoidsHeaderScans,
                entryKDFBudget: entryKDFBudget
            )
            coordinator = SevenZipFolderCoordinator(factory: factory)
            if folderHasMultipleSubstreams {
                coordinators[substream.folderIndex] = coordinator
            }
        }
        let decompressor = try coordinator.stream(
            offset: substream.offset,
            length: substream.size
        )
        return try EntryStream(
            decompressor: decompressor,
            length: substream.size,
            expectedCRC32: substream.digest.value,
            entryIndex: entry.index,
            limits: limits,
            checksumMismatchIsWrongPassword: record.isEncrypted
        )
    }

    // MARK: 非 solid folder の先行復号

    /// 順方向に読まれている非 solid entry について、先の folder を葉に投入し、この entry の
    /// folder が先行復号済みならその出力を返す。それ以外（未投入・検査失敗・後方 seek）は nil で、
    /// 呼出元は従来の直列経路を使う。
    private func prefetchedDecompressor(
        for entry: ArchiveEntry, substream: SevenZipSubstream
    ) throws -> (any Decompressor)? {
        guard decodeThreads > 1, LeafDecodePool.shared.capacity > 1 else { return nil }
        defer { lastStreamedEntryIndex = entry.index }
        if let last = lastStreamedEntryIndex {
            if entry.index < last {
                prefetcher?.reset()
                prefetchCursor = 0
                pendingPrefetchBatch = nil
                readsForward = false
            } else if entry.index > last {
                readsForward = true
            }
        }
        guard readsForward else { return nil }
        let prefetcher = self.prefetcher ?? SevenZipFolderPrefetcher(
            workers: decodeThreads, memoryBudget: limits.resolvedParallelDecodeMemory()
        )
        self.prefetcher = prefetcher
        prefetcher.dropBatches(endingBefore: entry.index)
        try schedulePrefetch(prefetcher, from: entry.index + 1)
        return try prefetcher.take(folder: substream.folderIndex)
    }

    /// cursor から先の record を見て、対象になる folder を batch にまとめて投入する。
    /// cursor は単調に進み、投入待ちの batch の record は再走査しない。
    private func schedulePrefetch(_ prefetcher: SevenZipFolderPrefetcher, from start: Int) throws {
        prefetchCursor = max(prefetchCursor, start)
        guard let streams else { return }
        if let pending = pendingPrefetchBatch {
            if pending.lastEntryIndex < start - 1 {
                pendingPrefetchBatch = nil
            } else {
                guard prefetcher.submit(pending) else { return }
                pendingPrefetchBatch = nil
            }
        }
        while prefetchCursor < records.count, prefetcher.canSubmitMore {
            var units: [SevenZipFolderPrefetcher.Unit] = []
            var outputBytes = 0
            var scratchBytes = 0
            while prefetchCursor < records.count,
                  outputBytes < Self.prefetchBatchBytes, units.count < Self.prefetchBatchUnits {
                let index = prefetchCursor
                try checkCancellation(every: index)
                if let unit = try prefetchUnit(forRecordAt: index, streams: streams, prefetcher: prefetcher) {
                    let scratch = max(scratchBytes, unit.scratchBytes)
                    // 各 unit が入っても、その出力の和が予算を超える前に batch を閉じる。
                    guard unit.outputSize + 1 <= prefetcher.memoryBudget - outputBytes - scratch else { break }
                    units.append(unit)
                    outputBytes += unit.outputSize + 1
                    scratchBytes = scratch
                }
                prefetchCursor = index + 1
            }
            guard !units.isEmpty else { return }
            let batch = try SevenZipFolderPrefetcher.Batch(units: units)
            guard prefetcher.submit(batch) else {
                // 既存の batch が予算か枠を使っている。record を再走査せず投入だけを再試行する。
                pendingPrefetchBatch = batch
                return
            }
        }
    }

    /// 先行復号できる record なら Unit を作る。対象は暗号化されていない非 solid の単一 substream で、
    /// 出力が prefetchMaxUnitBytes と maxInMemorySize（一括保持の既存上限）以下、coder 列の memory を
    /// 見積もれる folder。大きい folder は従来の直列・reset 並列経路がそのまま扱う。
    private func prefetchUnit(
        forRecordAt index: Int, streams: SevenZipStreamsInfo, prefetcher: SevenZipFolderPrefetcher
    ) throws -> SevenZipFolderPrefetcher.Unit? {
        let record = records[index]
        guard let substream = record.substream, !record.isEncrypted,
              entries[index].solidGroup < 0, substream.offset == 0, substream.size > 0,
              substream.folderIndex >= 0, substream.folderIndex < streams.folders.count else { return nil }
        let folderIndex = substream.folderIndex
        let folder = streams.folders[folderIndex]
        guard folder.unpackSizes.count == folder.outputCount,
              folder.unpackSizes.indices.contains(folder.finalOutputIndex),
              substream.size == folder.unpackSizes[folder.finalOutputIndex],
              substream.size <= Self.prefetchMaxUnitBytes,
              substream.size <= limits.maxInMemorySize,
              substream.size <= limits.maxEntrySize,
              substream.size <= UInt64(Int.max) else { return nil }
        let ranges = packedRanges[folderIndex]
        guard let scratch = Self.prefetchScratchEstimate(folder: folder, packedRanges: ranges),
              let held = try? Checked.add(Checked.add(substream.size, 1), scratch),
              held <= UInt64(prefetcher.memoryBudget) else { return nil }
        let source = self.source, limits = self.limits, verifier = packedStreamVerifier
        let cyclesPower = maximumAESCyclesPower
        return SevenZipFolderPrefetcher.Unit(
            folderIndex: folderIndex, entryIndex: index, outputSize: Int(substream.size),
            expectedCRC32: substream.digest.value, folderCRC32: folder.digest.value,
            scratchBytes: Int(clamping: scratch)
        ) {
            // 葉は直列 decoder だけを作る（葉の中で他の葉を待たない）。
            try SevenZipFolderDecoderFactory(
                source: source, folder: folder, packedRanges: ranges, limits: limits, password: nil,
                keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: cyclesPower,
                packedStreamVerifier: verifier, workers: 1
            ).makeDecoder()
        }
    }

    /// folder の coder 列が出力以外に使う memory の見積り。見積もれない coder（zstd・AES・未対応）は nil。
    private static func prefetchScratchEstimate(
        folder: SevenZipFolder, packedRanges: [Int: SevenZipPackRange]
    ) -> UInt64? {
        var total: UInt64 = 0
        var hasCompression = false
        for coder in folder.coders {
            guard folder.unpackSizes.indices.contains(coder.firstOutput) else { return nil }
            let output = folder.unpackSizes[coder.firstOutput]
            let kind = SevenZipMethod.kind(for: coder.methodID)
            let consumesBytes: Bool
            switch kind {
            case .lzma:
                guard coder.properties.count == 5,
                      let configuration = try? LZMAProperties(packed: coder.properties[0], requireLZMA2LiteralLimit: false),
                      let literals = try? configuration.literalProbabilityCount() else { return nil }
                let dictionary = max(UInt64(4_096), UInt64(coder.properties[1])
                    | UInt64(coder.properties[2]) << 8 | UInt64(coder.properties[3]) << 16
                    | UInt64(coder.properties[4]) << 24)
                total &+= min(dictionary, max(1, output)) &+ UInt64(literals &* 2) &+ (1 << 19)
                consumesBytes = true; hasCompression = true
            case .lzma2:
                guard coder.properties.count == 1,
                      let dictionary = try? LZMA2Decoder.dictionarySize(for: coder.properties[0]) else { return nil }
                total &+= min(dictionary, max(1, output)) &+ (1 << 19)
                consumesBytes = true; hasCompression = true
            case .ppmd7:
                guard coder.properties.count == 5 else { return nil }
                let memory = UInt64(coder.properties[1]) | UInt64(coder.properties[2]) << 8
                    | UInt64(coder.properties[3]) << 16 | UInt64(coder.properties[4]) << 24
                total &+= memory &+ (1 << 20)
                consumesBytes = true; hasCompression = true
            case .deflate, .deflate64:
                total &+= 1 << 20
                consumesBytes = true; hasCompression = true
            case .bzip2:
                total &+= 8 << 20
                consumesBytes = true; hasCompression = true
            case .bcj2:
                total &+= 1 << 20
                consumesBytes = false; hasCompression = true
            case .copy, .delta, .swap, .branch:
                total &+= 1 << 18
                consumesBytes = false
            case .zstd, .aes, .unsupported:
                return nil
            }
            if consumesBytes, coder.inputCount == 1, let bound = folder.boundOutput(forInput: coder.firstInput) {
                // 上流 coder の出力を一括で保持する経路。
                guard folder.unpackSizes.indices.contains(bound) else { return nil }
                total &+= folder.unpackSizes[bound]
            }
        }
        return hasCompression ? total : nil
    }

    private static func makeEntries(
        files: [SevenZipFileMetadata],
        streams: SevenZipStreamsInfo?,
        packedRanges: [[Int: SevenZipPackRange]],
        limits: ReadLimits,
        metadataBudget: SevenZipMetadataBudget
    ) throws -> (entries: [ArchiveEntry], records: [Record]) {
        let substreams = streams?.substreams ?? []
        let streamedFileCount = files.lazy.filter(\.hasStream).count
        guard streamedFileCount == substreams.count else {
            throw KaitoError.malformed("7z file and substream counts differ")
        }

        var folderSubstreamCounts: [Int: Int] = [:]
        for (index, stream) in substreams.enumerated() {
            try checkCancellation(every: index)
            folderSubstreamCounts[stream.folderIndex, default: 0] += 1
        }
        var folderPackedSizes: [UInt64] = []
        if let streams {
            folderPackedSizes.reserveCapacity(streams.folders.count)
            for index in streams.folders.indices {
                try checkCancellation(every: index)
                var total: UInt64 = 0
                for range in packedRanges[index].values {
                    total = try Checked.add(total, range.size)
                }
                folderPackedSizes.append(total)
            }
        }

        var entries: [ArchiveEntry] = []
        var records: [Record] = []
        // ArchiveEntry/Record の backing storage を確保する前に、FilesInfo と
        // 同時保持される固定費を共有予算から先に確保する。
        try metadataBudget.reserve(
            count: files.count,
            bytesPerRecord: 256,
            description: "7z published entry metadata"
        )
        entries.reserveCapacity(files.count)
        records.reserveCapacity(files.count)
        var streamIndex = 0

        for (index, file) in files.enumerated() {
            try checkCancellation(every: index)
            let substream: SevenZipSubstream?
            let folder: SevenZipFolder?
            if file.hasStream {
                guard streamIndex < substreams.count, let streams else {
                    throw KaitoError.malformed("missing 7z file substream")
                }
                substream = substreams[streamIndex]
                folder = streams.folders[substreams[streamIndex].folderIndex]
                streamIndex += 1
            } else {
                substream = nil
                folder = nil
            }
            let size = substream?.size ?? 0
            try Checked.size(size, limit: limits.maxEntrySize)

            let (kind, unixMode) = classify(file: file)
            let components = file.name
                .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }
            guard !components.isEmpty else {
                throw KaitoError.malformed("7z entry has an empty path")
            }
            guard components.count <= limits.maxPathComponentCount else {
                throw KaitoError.limitExceeded("7z path component count")
            }

            let encrypted = folder?.coders.contains {
                SevenZipMethod.kind(for: $0.methodID) == .aes
            } ?? false
            let methods = folder?.coders.map(SevenZipMethod.description(for:)) ?? ["Copy"]
            let specific = formatSpecific(for: file, kind: kind, isEncrypted: encrypted)

            var entryMetadata = try Checked.add(
                UInt64(file.rawName.count),
                UInt64(file.name.utf8.count)
            )
            entryMetadata = try Checked.add(
                entryMetadata,
                try Checked.mul(UInt64(components.count), UInt64(MemoryLayout<String>.stride))
            )
            for component in components {
                entryMetadata = try Checked.add(entryMetadata, UInt64(component.utf8.count))
            }
            try metadataBudget.reserve(
                entryMetadata,
                description: "7z published entry metadata"
            )

            let compressedSize = substream.map { folderPackedSizes[$0.folderIndex] }
            let solidGroup: Int
            if let substream,
               folderSubstreamCounts[substream.folderIndex, default: 0] > 1 {
                solidGroup = substream.folderIndex
            } else {
                solidGroup = -1
            }
            entries.append(ArchiveEntry(
                index: index,
                rawName: RawName(
                    bytes: file.rawName,
                    declaredEncoding: .utf16LittleEndian,
                    isDirectoryHint: kind == .directory
                ),
                name: file.name,
                pathComponents: components,
                kind: kind,
                uncompressedSize: size,
                compressedSize: compressedSize,
                modificationDate: file.modificationTime,
                posixPermissions: unixMode.map { $0 & 0o7777 },
                isEncrypted: encrypted,
                solidGroup: solidGroup,
                crc32: substream?.digest.value,
                methodDescription: methods.joined(separator: "+"),
                formatSpecific: specific
            ))
            records.append(Record(substream: substream, isEncrypted: encrypted))
        }
        guard streamIndex == substreams.count else {
            throw KaitoError.malformed("unused 7z substreams")
        }
        return (entries, records)
    }

    /// Windows 属性に Unix mode があれば（`unixExtension`）その種別を優先し、無ければ DOS の
    /// directory 属性で決める。どちらでもなく stream も EmptyFile・Anti も無い file は directory。
    private static func classify(file: SevenZipFileMetadata) -> (kind: EntryKind, unixMode: UInt16?) {
        let unixMode: UInt16? = file.windowsAttributes.flatMap { attributes in
            guard attributes & WindowsAttribute.unixExtension != 0 else { return nil }
            return UInt16(truncatingIfNeeded: attributes >> 16)
        }
        let unixType = unixMode.map { $0 & 0o170000 }
        let dosDirectory = file.windowsAttributes.map { $0 & WindowsAttribute.directory != 0 } ?? false
        let kind: EntryKind
        if unixType == 0o120000 {
            kind = .symlink
        } else if unixType == 0o040000 || dosDirectory
                    || (!file.hasStream && !file.isEmptyFile && !file.isAnti) {
            kind = .directory
        } else {
            kind = .file
        }
        return (kind, unixMode)
    }

    /// `ArchiveEntry.formatSpecific` に載せる 7z 固有の値。
    private static func formatSpecific(
        for file: SevenZipFileMetadata,
        kind: EntryKind,
        isEncrypted: Bool
    ) -> [String: String] {
        var specific: [String: String] = [
            "encryption": isEncrypted ? "7zAES-256" : "none",
            "anti": file.isAnti ? "true" : "false",
            "emptyFile": file.isEmptyFile ? "true" : "false",
            "emptyStream": file.hasStream ? "false" : "true"
        ]
        if let attributes = file.windowsAttributes {
            specific["windowsAttributes"] = hexadecimalAttributes(attributes)
        }
        if let startPosition = file.startPosition {
            specific["startPosition"] = String(startPosition)
        }
        if let creationTime = file.creationTime {
            specific["creationTime"] = String(creationTime.timeIntervalSince1970)
        }
        if let accessTime = file.accessTime {
            specific["accessTime"] = String(accessTime.timeIntervalSince1970)
        }
        if kind == .symlink { specific["linkTargetStoredAsData"] = "true" }
        return specific
    }

    /// `String(format: "0x%08x", value)` と同じ表記（小文字、8 桁）。entry 数万件の open で
    /// Foundation の format 解析を繰り返さない。
    private static func hexadecimalAttributes(_ value: UInt32) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = [0x30, 0x78]
        bytes.reserveCapacity(10)
        for shift in stride(from: 28, through: 0, by: -4) {
            bytes.append(digits[Int((value >> UInt32(shift)) & 0xF)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
