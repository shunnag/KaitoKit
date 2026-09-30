import Foundation

/// Opens an archive, lists its entries, and reads or extracts their contents.
///
/// `ArchiveReader` is deliberately not thread-safe. Call ``reopen()`` to make
/// an inexpensive independent reader that shares the immutable byte source.
public final class ArchiveReader {
    private let source: any ByteSource
    private let stagedContainerSource: (any ByteSource)?
    private let tarEditingState: TarEditingSnapshot?
    // 拡張子・単一ストリームの名前・SFX 検出のヒント。分割セットでは .001 を除く。
    // Data と名前ヒントのない ByteSource はファイル名の由来を持たない。
    private let sourceURL: URL?
    private let zipDiskLayout: ZipDiskLayout?
    private let assembledVolumeSet: ArchiveVolumeSet?
    private let reader: any FormatReader
    private let options: ReaderOptions
    private let outputBudget: ArchiveOutputBudget
    private var extractionRootKey: String?
    private var extractedFiles: [Int: ExtractedFileIdentity] = [:]

    /// The detected archive format.
    public let format: ArchiveFormat

    /// Entries in archive order.
    public let entries: [ArchiveEntry]

    /// The numbered or native ZIP volume set of two or more files that `open(url:)` actually joined.
    ///
    /// This is `nil` for a single file, a `.001` without siblings, an explicitly named volume that is a
    /// symbolic link, and readers opened from `Data` or a `ByteSource`. StuffIt's own split format,
    /// RAR multi-volume sets, and the files a `.cue` sheet references are currently outside this API.
    /// ``reopen()`` shares the retained source and carries this snapshot over.
    public var volumeSet: ArchiveVolumeSet? { assembledVolumeSet }

    /// The archive-wide encoding selected for otherwise undeclared entry names.
    ///
    /// With automatic detection this is `nil` when every name was declared by
    /// the format or was valid UTF-8 without guessing. A fixed policy is
    /// reported whenever it applies to an undeclared name.
    public var nameEncoding: String.Encoding? {
        reader.nameEncoding
    }

    /// The password used for subsequent encrypted-entry operations.
    public var password: String?

    private init(input: OpenedArchiveInput, options: ReaderOptions) throws {
        self.source = input.source
        self.sourceURL = input.sourceURL
        self.zipDiskLayout = input.zipDiskLayout
        self.assembledVolumeSet = input.volumeSet
        self.options = options

        let opened = try FormatReaderFactory.open(input: input, options: options)
        // format と entries は形式 reader が持つ値そのもの。
        self.reader = opened.reader
        self.format = opened.reader.format
        self.entries = opened.reader.entries
        self.password = opened.password
        self.stagedContainerSource = opened.stagedContainerSource
        self.tarEditingState = opened.tarEditingState
        self.outputBudget = try ArchiveOutputBudget(
            entries: entries,
            limit: options.limits.maxTotalUncompressedSize
        )
    }

    /// Builds a reader around an already parsed format reader. This is used by
    /// formats whose immutable source graph contains more than the primary
    /// `ByteSource`, such as a RAR5 volume set. The format reader passed here
    /// must itself provide independent mutable decoder/password state.
    private init(
        sharing source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        parsedReader: any FormatReader,
        outputBudget: ArchiveOutputBudget,
        zipDiskLayout: ZipDiskLayout? = nil,
        volumeSet: ArchiveVolumeSet? = nil,
        stagedContainerSource: (any ByteSource)? = nil,
        tarEditingState: TarEditingSnapshot? = nil
    ) throws {
        self.source = source
        self.stagedContainerSource = stagedContainerSource
        self.tarEditingState = tarEditingState
        self.sourceURL = sourceURL
        self.zipDiskLayout = zipDiskLayout
        self.assembledVolumeSet = volumeSet
        self.options = options
        self.reader = parsedReader
        self.format = parsedReader.format
        self.entries = parsedReader.entries
        self.password = options.password
        self.outputBudget = outputBudget
    }

    /// Opens an archive stored at a file URL.
    ///
    /// Byte-split volumes that start at `.001` are joined with their siblings in the same parent
    /// directory before format detection.
    public static func open(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        let input = try OpenedArchiveInput.assemble(url: url, limits: options.limits)
        return try ArchiveReader(input: input, options: options)
    }

    /// Opens an archive from `Data` without intentionally copying its storage.
    public static func open(
        data: Data,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(input: OpenedArchiveInput(source: DataByteSource(data: data)), options: options)
    }

    /// Opens an archive from an arbitrary random-access byte source.
    public static func open(
        source: any ByteSource,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(input: OpenedArchiveInput(source: source), options: options)
    }

    /// Opens a byte source with a URL hint for URL-dependent format detection.
    /// `sourceURL` is an optional filename hint for compressed tar aliases and
    /// single-file entry names. The primary archive bytes come from `source`.
    public static func open(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(input: OpenedArchiveInput(source: source, sourceURL: sourceURL), options: options)
    }

    /// Returns a forward-only stream for an entry.
    ///
    /// Checksums and format verification that cover the complete entry are
    /// finalized by the last `read`. Earlier chunks may therefore be returned
    /// before a malformed final checksum or tag is reported.
    public func stream(_ entry: ArchiveEntry) throws -> EntryStream {
        try validate(entry)
        if entry.uncompressedSize == nil {
            try outputBudget.ensureUsable()
        }
        try preparePassword(for: entry)
        let stream = try reader.stream(for: entry, limits: options.limits)
        observeOutputBudget(stream, for: entry)
        return stream
    }

    private func observeOutputBudget(_ stream: EntryStream, for entry: ArchiveEntry) {
        if entry.uncompressedSize == nil {
            stream.observeProducedSize(
                availableAdditionalSize: { [outputBudget] producedSize in
                    try outputBudget.availableAdditionalSize(
                        index: entry.index,
                        producedSize: producedSize
                    )
                },
                didProduce: { [outputBudget] producedSize in
                    try outputBudget.recordUnknownEntry(
                        index: entry.index,
                        producedSize: producedSize
                    )
                },
                didExceedLimit: { [outputBudget] in
                    try outputBudget.recordLimitExceeded()
                }
            )
        }
    }

    /// Reads one entry into an exactly sized in-memory buffer.
    public func read(_ entry: ArchiveEntry) throws -> Data {
        try validate(entry)
        if let declared = entry.uncompressedSize {
            try Checked.size(declared, limit: options.limits.maxInMemorySize)
        }
        return try stream(entry).readAll()
    }

    /// Returns the raw record range of an entry in formats whose records can be carried over without
    /// recompression.
    ///
    /// This is `nil` for unsupported formats, incomplete entries (`isIncomplete`), and `.001`
    /// byte-split sets. Only ZIP is currently supported: the range includes any data descriptor and
    /// is validated against the central directory. For `.zNN` / `.zxNN` split volumes the range is
    /// absolute in the joined stream. Encrypted entries are returned without a password; the payload
    /// is not decrypted, decompressed, or integrity-checked. The source bytes must stay unchanged from
    /// this call until the copy completes.
    public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord? {
        try validate(entry)
        guard !entry.isIncomplete, zipDiskLayout != nil || !(source is ConcatenatedByteSource) else { return nil }
        return try reader.rawRecord(for: entry, limits: options.limits)
    }

    /// entries[index] の生レコード範囲。同一性比較だけを省き、公開 API と同じ検証を行う。
    /// .expose の ZIP は CD 順。password を要求せず、取消しも検査しない。
    @_spi(ZipRawLayout)
    public func zipRawRecordLayout(at index: Int) throws -> ZipRawRecordLayout? {
        guard entries.indices.contains(index) else {
            throw KaitoError.notFound("archive entry index \(index)")
        }
        guard !entries[index].isIncomplete,
              zipDiskLayout != nil || !(source is ConcatenatedByteSource) else { return nil }
        return try reader.zipRawRecordLayout(at: index, limits: options.limits)
    }

    /// LHA の member の配置。LHA 以外、recovery、分割巻では nil。
    /// 終端の後ろを最大 65,536 byte だけ読む。password を要求せず、取消しを検査しない。
    @_spi(LHARawLayout)
    public func lhaRawLayout() throws -> LHAArchiveLayout? {
        guard let lha = reader as? LHAReader,
              !options.recoverDamagedArchives,
              volumeSet == nil, !(source is ConcatenatedByteSource) else { return nil }
        return try lha.rawLayout()
    }

    /// 暗号だけを外した保存 payload。展開と CRC 照合は行わない。
    /// ZipCrypto の 1 byte 照合値を通る誤 password は、呼出側で CRC を検査する。
    /// AES は verifier と、最終 chunk を返す前の HMAC を照合する。
    /// aesKey があれば password/provider と鍵 cache を使わず、salt・強度の相違は malformed。
    @_spi(ZipRawLayout)
    public func zipStoredPayloadStream(at index: Int, aesKey: ZipAESKeyMaterial? = nil) throws -> EntryStream {
        try makeZipStream(at: index, aesKey: aesKey, storedOnly: true)
    }

    /// 渡した AES 材料で stream(_:) と同じ復号・展開・CRC / HMAC 照合を行う。
    /// AES 以外への材料は malformed。password/provider と鍵 cache は使わない。
    @_spi(ZipRawLayout)
    public func zipStream(at index: Int, aesKey: ZipAESKeyMaterial) throws -> EntryStream {
        try makeZipStream(at: index, aesKey: aesKey, storedOnly: false)
    }

    private func makeZipStream(at index: Int, aesKey: ZipAESKeyMaterial?, storedOnly: Bool) throws -> EntryStream {
        guard entries.indices.contains(index) else {
            throw KaitoError.notFound("archive entry index \(index)")
        }
        let entry = entries[index]
        guard !entry.isIncomplete, zipDiskLayout != nil || !(source is ConcatenatedByteSource) else {
            throw KaitoError.unsupportedMethod("ZIP stored payload")
        }
        if !storedOnly, entry.uncompressedSize == nil {
            try outputBudget.ensureUsable()
        }
        if aesKey == nil { try preparePassword(for: entry) }
        guard let stream = try reader.zipStream(at: index, limits: options.limits,
                                               aesKey: aesKey, storedOnly: storedOnly) else {
            throw KaitoError.unsupportedMethod("ZIP stored payload")
        }
        if !storedOnly { observeOutputBudget(stream, for: entry) }
        return stream
    }

    /// Safely extracts one entry below `directory` and returns its destination.
    ///
    /// The caller must prevent other threads or processes from mutating the
    /// extraction root until this operation returns.
    /// A zero-body hard link requires its target to have been extracted first,
    /// to the same root with this reader. Forward references must be deferred
    /// until their targets are extracted. Switching roots or
    /// calling ``reopen()`` starts independent extraction provenance.
    public func extract(
        _ entry: ArchiveEntry,
        to directory: URL,
        options extractionOptions: ExtractionOptions = ExtractionOptions()
    ) throws -> URL {
        try validate(entry)
        let rootKey = Self.stableExtractionRootKey(directory)
        if extractionRootKey != rootKey {
            extractionRootKey = rootKey
            extractedFiles.removeAll(keepingCapacity: false)
        }
        let result = try Extractor.extract(
            entry,
            from: self,
            to: directory,
            options: extractionOptions,
            trustedTargets: extractedFiles
        )
        if let identity = result.fileIdentity {
            extractedFiles[entry.index] = identity
        }
        return result.url
    }

    /// Makes an independent reader that shares the same immutable byte source.
    ///
    /// The returned reader can be sent to another isolation domain.
    public func reopen() throws -> sending ArchiveReader {
        var reopenedOptions = options
        reopenedOptions.password = password
        if let parsedReader = try reader.reopened(options: reopenedOptions) {
            return try ArchiveReader(
                sharing: stagedContainerSource ?? source,
                sourceURL: sourceURL,
                options: reopenedOptions,
                parsedReader: parsedReader,
                outputBudget: outputBudget.reopened(),
                zipDiskLayout: zipDiskLayout,
                volumeSet: volumeSet,
                stagedContainerSource: stagedContainerSource,
                tarEditingState: tarEditingState
            )
        }
        if let stagedContainerSource, reader is CpioReader {
            // 圧縮 cpio / pbzx の展開結果は保持済みなので、再展開せずその source から開き直す。
            return try ArchiveReader(
                input: OpenedArchiveInput(source: stagedContainerSource, volumeSet: volumeSet),
                options: reopenedOptions
            )
        }
        return try ArchiveReader(
            input: OpenedArchiveInput(source: source, sourceURL: sourceURL,
                                     zipDiskLayout: zipDiskLayout, volumeSet: volumeSet),
            options: reopenedOptions
        )
    }

    /// 保持済みの生値だけを返す。source の読取りや password の要求は行わない。
    @_spi(SevenZipEditLayout)
    public func sevenZipEditingSnapshot() -> SevenZipEditingSnapshot? {
        guard options.recordsSevenZipEditLayout, format == .sevenZip,
              volumeSet == nil, !(source is ConcatenatedByteSource) else { return nil }
        return (reader as? SevenZipReader)?.editingSnapshot()
    }

    /// AES の出力長までの圧縮済み平文。展開と出力 CRC の照合は行わない。
    @_spi(SevenZipEditLayout)
    public func sevenZipDecryptedPackedStream(folder: Int, packedInput: Int) throws -> EntryStream {
        guard let sevenZip = reader as? SevenZipReader else {
            throw KaitoError.notFound("7z folder \(folder)")
        }
        sevenZip.setPassword(password)
        return try sevenZip.decryptedPackedStream(folder: folder, packedInput: packedInput)
    }

    /// 保持済みの tar 編集用の値。`recordsTarEditLayout` を有効にした tar / 圧縮 tar の open だけが作り、
    /// 分割巻・cpio・pbzx・tar 以外は nil。source の読取りや password の要求は行わない。
    @_spi(TarEditLayout)
    public func tarEditingSnapshot() -> TarEditingSnapshot? { tarEditingState }

    /// 保持した復号済み image と圧縮 byte の digest で継ぎを検証する。
    @_spi(TarEditLayout)
    public static func openSplicedCompressedTar(
        output: any ByteSource, sourceURL: URL?, base: TarEditingSnapshot,
        splice: CompressedTarSplice, options: ReaderOptions
    ) throws -> sending ArchiveReader {
        try openSplicedCompressedTar(output: output, sourceURL: sourceURL, base: base,
                                    splice: splice, options: options, storagePolicy: TarSpliceStoragePolicy())
    }

    static func openSplicedCompressedTar(
        output: any ByteSource, sourceURL: URL?, base: TarEditingSnapshot,
        splice: CompressedTarSplice, options: ReaderOptions, storagePolicy: TarSpliceStoragePolicy
    ) throws -> sending ArchiveReader {
        let identity = currentTarArchiveIdentity(output)
        let codec: ArchiveFormat
        switch (base.container, base.chunkMap) {
        case (.gzip, .gzip): codec = .gzip
        case (.bzip2, .bzip2): codec = .bzip2
        case (.xz, .xz): codec = .xz
        default: throw TarSpliceVerificationError(.baseNotSpliceable)
        }
        guard !options.recoverDamagedArchives else { throw TarSpliceVerificationError(.baseNotSpliceable) }
        let detected = try tarSpliceVerification(.baseNotSpliceable) {
            try FormatReaderFactory.detectFormat(source: output, sourceURL: sourceURL, options: options).format
        }
        guard detected == codec, CompressedNaming.compressedContainer(name: sourceURL?.lastPathComponent, detected: detected) == .tar else {
            throw TarSpliceVerificationError(.baseNotSpliceable)
        }
        // 外側の名前・metadata の上限も、全体の open と同じ順で検める。
        let single = try tarSpliceVerification(.framingMismatch) {
            try SingleFileReader(source: output, format: detected, options: options, fallbackFileName: sourceURL?.lastPathComponent)
        }
        let verifier = try CompressedTarSpliceVerifier(output: output, base: base, splice: splice, limits: options.limits,
                                                     gzipHeaderLength: single.tarSpliceGzipHeaderLength)
        let image = try verifier.materialize(policy: storagePolicy)
        var tarOptions = options
        tarOptions.recordsTarEditLayout = true
        let parsed = try AppleDoubleReader.wrap(TarReader(source: image, options: tarOptions), options: options)
        let budget = try ArchiveOutputBudget(entries: parsed.entries, limit: options.limits.maxTotalUncompressedSize)
        if let identity, currentTarArchiveIdentity(output) != identity { throw TarSpliceVerificationError(.outputChanged) }
        let tar = parsed as? TarReader
        let snapshot = TarEditingSnapshot(container: base.container, image: image, archive: output,
            layout: tar?.layoutStorage?.layout,
            layoutUnavailableReason: tar == nil ? .wrappedEntries : tar?.layoutStorage?.unavailableReason,
            chunkMap: verifier.map, chunkMapUnavailableReason: verifier.mapUnavailableReason,
            archiveIdentity: identity, limits: options.limits)
        return try ArchiveReader(sharing: output, sourceURL: sourceURL, options: tarOptions,
            parsedReader: parsed, outputBudget: budget, stagedContainerSource: image, tarEditingState: snapshot)
    }

    private func validate(_ entry: ArchiveEntry) throws {
        guard entry.index >= 0, entry.index < entries.count else {
            throw KaitoError.notFound("archive entry index \(entry.index)")
        }
        let canonical = entries[entry.index]
        guard canonical == entry else {
            throw KaitoError.notFound("archive entry \(entry.index)")
        }
    }

    /// Resolves the nearest existing ancestor before adding any missing path
    /// suffix. This gives an uncreated `/private/tmp` path and its later
    /// `/tmp` spelling the same key without creating the extraction root before
    /// the entry stream has been validated.
    private static func stableExtractionRootKey(_ directory: URL) -> String {
        let manager = FileManager.default
        var ancestor = directory.standardizedFileURL
        var missingComponents: [String] = []

        while !manager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                return directory.standardizedFileURL.path
            }
            let component = ancestor.lastPathComponent
            if !component.isEmpty { missingComponents.append(component) }
            ancestor = parent
        }

        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.path
    }

    private func preparePassword(for entry: ArchiveEntry) throws {
        // 復号に必須の resource / hash がなければ、password provider より先に診断する。
        try reader.validateEncryptionSupport(for: entry)
        if entry.isEncrypted, password == nil, let provider = options.passwordProvider {
            password = try provider.password(for: format)
        }
        reader.setPassword(password)
    }
}
