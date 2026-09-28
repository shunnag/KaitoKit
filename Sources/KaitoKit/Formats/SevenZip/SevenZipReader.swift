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
    private let maximumAESCyclesPower: UInt8
    private let streams: SevenZipStreamsInfo?
    private let packedRanges: [[Int: SevenZipPackRange]]
    private let records: [Record]
    private let editState: SevenZipEditState?
    private let keyCache: SevenZipAESKeyCache
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private var coordinators: [Int: SevenZipFolderCoordinator] = [:]
    private var password: String?

    var resolvedPassword: String? { password }

    var hasRetainedDecoderState: Bool {
        coordinators.values.contains { $0.hasRetainedDecoderState }
    }

    init(source: any ByteSource, options: ReaderOptions, baseOffset: UInt64 = 0) throws {
        self.source = source
        self.limits = options.limits
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

    func reopened(options: ReaderOptions) -> sending (any FormatReader)? {
        // folder coordinator、検証済み pack の記録、導出済みの鍵（header の復号に使った鍵を含む）は
        // reader の境界を越えて共有しない。
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
            maximumAESCyclesPower: maximumAESCyclesPower, packedStreamVerifier: packedStreamVerifier)
        let decrypted = try factory.makeDecryptedPackedDecoder(packedInput: packedInput)
        return try EntryStream(decompressor: decrypted.decoder, length: decrypted.length,
                               expectedCRC32: nil, entryIndex: -1, limits: limits)
    }

    func setPassword(_ password: String?) {
        guard self.password != password else { return }
        self.password = password
        keyCache.removeAll()
        coordinators.removeAll(keepingCapacity: false)
    }

    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entry.index >= 0, entry.index < records.count,
              entries[entry.index] == entry else {
            throw KaitoError.notFound("7z entry index \(entry.index)")
        }
        let record = records[entry.index]
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
                packedStreamVerifier: packedStreamVerifier
            )
            return try EntryStream(
                decompressor: factory.makeDecoder(),
                length: substream.size,
                expectedCRC32: substream.digest.value,
                entryIndex: entry.index,
                limits: limits
            )
        }

        let coordinator: SevenZipFolderCoordinator
        let folderHasMultipleSubstreams = entry.solidGroup >= 0
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
                packedStreamVerifier: packedStreamVerifier
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
            specific["windowsAttributes"] = String(format: "0x%08x", attributes)
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
}
