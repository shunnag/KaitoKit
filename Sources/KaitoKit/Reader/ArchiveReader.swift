import Foundation

/// Opens an archive, lists its entries, and reads or extracts their contents.
///
/// `ArchiveReader` is deliberately not thread-safe. Call ``reopen()`` to make
/// an inexpensive independent reader that shares the immutable byte source.
public final class ArchiveReader {
    private let source: any ByteSource
    private let stagedTarSource: (any ByteSource)?
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

    /// URL open で実際に連結した 2 巻以上の numbered / native ZIP セット。
    /// 単一ファイル、兄弟のない .001、明示した巻が symlink、Data / ByteSource open は nil。
    /// StuffIt 固有の分割、RAR の多巻、.cue の参照先は現在この API の対象外。
    /// reopen は保持済み source を共有し、このスナップショットも引き継ぐ。
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

    private init(
        source: any ByteSource,
        sourceURL: URL? = nil,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor? = nil,
        sourceVolumeURL: URL? = nil,
        zipDiskLayout: ZipDiskLayout? = nil,
        volumeSet: ArchiveVolumeSet? = nil,
        options: ReaderOptions
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.zipDiskLayout = zipDiskLayout
        self.assembledVolumeSet = volumeSet
        self.options = options

        let detected = try Self.detectFormat(source: source, sourceURL: sourceURL, options: options)
        if zipDiskLayout != nil, detected.format != .zip {
            throw KaitoError.malformed("ZIP split volume set is not a ZIP archive")
        }
        let opened = try Self.openFormatReader(
            detected, source: source, sourceURL: sourceURL,
            sourceDirectoryAnchor: sourceDirectoryAnchor, sourceVolumeURL: sourceVolumeURL,
            zipDiskLayout: zipDiskLayout, volumeSet: volumeSet, options: options
        )
        // format と entries は形式 reader が持つ値そのもの。
        self.reader = opened.reader
        self.format = opened.reader.format
        self.entries = opened.reader.entries
        self.password = opened.password
        self.stagedTarSource = opened.stagedTarSource
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
        stagedTarSource: (any ByteSource)? = nil,
        tarEditingState: TarEditingSnapshot? = nil
    ) throws {
        self.source = source
        self.stagedTarSource = stagedTarSource
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
    /// `.001` から始まるバイト分割巻は、形式検出の前に同じ親の兄弟巻を連結する。
    public static func open(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        let input = try OpenedArchiveInput.assemble(url: url, limits: options.limits)
        return try ArchiveReader(
            source: input.source,
            sourceURL: input.sourceURL,
            sourceDirectoryAnchor: input.directoryAnchor,
            sourceVolumeURL: input.volumeURL,
            zipDiskLayout: input.zipDiskLayout,
            volumeSet: input.volumeSet,
            options: options
        )
    }

    /// Opens an archive from `Data` without intentionally copying its storage.
    public static func open(
        data: Data,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(source: DataByteSource(data: data), options: options)
    }

    /// Opens an archive from an arbitrary random-access byte source.
    public static func open(
        source: any ByteSource,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(source: source, options: options)
    }

    /// Opens a byte source with a URL hint for URL-dependent format detection.
    /// `sourceURL` is an optional filename hint for compressed tar aliases and
    /// single-file entry names. The primary archive bytes come from `source`.
    public static func open(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(source: source, sourceURL: sourceURL, options: options)
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

    /// 再圧縮せずに運べる形式では生レコード範囲を返す。未対応形式・isIncomplete・.001 バイト分割セットは nil。
    /// 現在は ZIP のみ対応し、data descriptor を含む範囲と中央ディレクトリとの整合を検証する。
    /// .zNN / .zxNN 分割巻では連結ストリーム上の絶対範囲を返す。
    /// 暗号化 entry もパスワードなしで取得できる。payload の復号・展開・完全性検証は行わない。
    /// 呼び出しからコピー完了まで、source の byte は不変でなければならない。
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

    /// 同じ不変の byte source を共有する独立した reader を作る。
    /// 返された reader は別の isolation domain に送信できる。
    public func reopen() throws -> sending ArchiveReader {
        var reopenedOptions = options
        reopenedOptions.password = password
        if let parsedReader = try reader.reopened(options: reopenedOptions) {
            return try ArchiveReader(
                sharing: stagedTarSource ?? source,
                sourceURL: sourceURL,
                options: reopenedOptions,
                parsedReader: parsedReader,
                outputBudget: outputBudget.reopened(),
                zipDiskLayout: zipDiskLayout,
                volumeSet: volumeSet,
                stagedTarSource: stagedTarSource,
                tarEditingState: tarEditingState
            )
        }
        if let stagedTarSource, reader is CpioReader {
            // 圧縮 cpio / pbzx の展開結果は保持済みなので、再展開せずその source から開き直す。
            return try ArchiveReader(
                source: stagedTarSource,
                sourceURL: nil,
                zipDiskLayout: nil,
                volumeSet: volumeSet,
                options: reopenedOptions
            )
        }
        return try ArchiveReader(
            source: source,
            sourceURL: sourceURL,
            zipDiskLayout: zipDiskLayout,
            volumeSet: volumeSet,
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
            try detectFormat(source: output, sourceURL: sourceURL, options: options).format
        }
        guard detected == codec, compressedContainer(for: sourceURL, detected: detected) == .tar else {
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
            parsedReader: parsed, outputBudget: budget, stagedTarSource: image, tarEditingState: snapshot)
    }

    private static func makeTarEditingState(container: TarContainer, archive: any ByteSource,
                                           image: any ByteSource, reader: any FormatReader,
                                           options: ReaderOptions, recorder: CompressedTarMapRecorder? = nil,
                                           identityBefore: ByteSourceFileIdentity?) -> TarEditingSnapshot {
        let tar = reader as? TarReader
        let mapReason: ChunkMapUnavailableReason
        switch container {
        case .plain: mapReason = .notCompressed
        case .other(let format): mapReason = .unsupportedCodec(format)
        default: mapReason = options.recoverDamagedArchives ? .recoveryMode : .inconsistent
        }
        let recorded = recorder?.finish(imageLength: image.length, archiveLength: archive.length)
        let identityAfter = currentTarArchiveIdentity(archive)
        let changed = identityBefore != identityAfter
        return TarEditingSnapshot(container: container, image: image, archive: archive,
                                  layout: tar?.layoutStorage?.layout,
                                  layoutUnavailableReason: tar == nil ? .wrappedEntries : tar?.layoutStorage?.unavailableReason,
                                  chunkMap: changed ? nil : recorded?.map,
                                  chunkMapUnavailableReason: changed ? .archiveChangedDuringOpen : recorded?.map == nil ? recorded?.reason ?? mapReason : nil,
                                  archiveIdentity: changed ? nil : identityBefore, limits: options.limits)
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

    /// 形式検出の結果。StuffIt の envelope（wrapper を剥いだ payload と resource fork）があれば持つ。
    private struct DetectedFormat {
        let format: ArchiveFormat
        let stuffItInput: StuffItEnvelope?
    }

    /// 形式 reader を開いた結果。format と entries は reader 自身から取る。
    private struct OpenedFormatReader {
        let reader: any FormatReader
        /// options.password から始め、reader が解決した password があればそれ。
        let password: String?
        /// 圧縮 tar / cpio を展開した staging。reopen はこれを共有する。
        var stagedTarSource: (any ByteSource)?
        var tarEditingState: TarEditingSnapshot?
    }

    /// StuffIt の envelope を一段だけ剥がしてから形式を検出する。envelope があればその形式が結果。
    private static func detectFormat(
        source: any ByteSource, sourceURL: URL?, options: ReaderOptions
    ) throws -> DetectedFormat {
        let stuffItInput = try FormatDetector.stuffItInput(source: source, limits: options.limits,
            maximumSFXScanSize: sourceURL != nil || options.scanForSFXInData ? options.maximumSFXScanSize : 0)
        let format: ArchiveFormat
        if let stuffItInput {
            format = try FormatDetector.envelopeFormat(stuffItInput)
        } else {
            format = try FormatDetector.detect(source: source, sourceURL: sourceURL, options: options, skipStuffIt: true)
        }
        return DetectedFormat(format: format, stuffItInput: stuffItInput)
    }

    /// 検出した形式の reader を開く。tar は編集用の配置を記録し、
    /// 単一 stream は ``openCompressedContainer`` で内側の tar / cpio まで開く。
    private static func openFormatReader(
        _ detected: DetectedFormat, source: any ByteSource, sourceURL: URL?,
        sourceDirectoryAnchor: FileByteSource.DirectoryAnchor?, sourceVolumeURL: URL?,
        zipDiskLayout: ZipDiskLayout?, volumeSet: ArchiveVolumeSet?, options: ReaderOptions
    ) throws -> OpenedFormatReader {
        let stuffItInput = detected.stuffItInput
        let recordsTarLayout = options.recordsTarEditLayout && volumeSet == nil && !(source is ConcatenatedByteSource)
        var tarOptions = options
        tarOptions.recordsTarEditLayout = recordsTarLayout
        let reader: any FormatReader
        var password = options.password
        var tarEditingState: TarEditingSnapshot?
        switch detected.format {
        case .tar:
            let identityBefore = recordsTarLayout ? currentTarArchiveIdentity(source) : nil
            let tar = try AppleDoubleReader.wrap(TarReader(source: source, options: tarOptions), options: options)
            reader = tar
            if recordsTarLayout {
                tarEditingState = makeTarEditingState(container: .plain, archive: source, image: source,
                                                      reader: tar, options: options, identityBefore: identityBefore)
            }
        case .zip:
            // Finder / ditto の `__MACOSX/._name` sidecar は方針に従って畳む（既定は resource fork へ統合）。
            reader = try AppleDoubleReader.wrap(ZipReader(source: source, options: options, diskLayout: zipDiskLayout), options: options)
        case .sevenZip:
            let sevenZipSource = try sevenZipSource(
                from: source,
                sourceURL: sourceURL,
                options: options
            )
            var sevenZipOptions = options
            sevenZipOptions.recordsSevenZipEditLayout = options.recordsSevenZipEditLayout
                && volumeSet == nil && !(source is ConcatenatedByteSource)
            let sevenZip = try SevenZipReader(
                source: sevenZipSource,
                options: sevenZipOptions,
                baseOffset: source.length - sevenZipSource.length
            )
            reader = sevenZip
            password = sevenZip.resolvedPassword
        case .rar:
            // 連結済み source では RAR 独自の多巻探索を行わず、Data と同じ扱いにする。
            // 単巻 .001 の場合は、名前ヒントでなく実際に開いた葉を identity 検証に使う。
            let rarSourceURL = source is ConcatenatedByteSource
                ? nil
                : (sourceVolumeURL ?? sourceURL)
            guard let signature = try RARSignatureScanner.find(source: source) else {
                throw KaitoError.unsupportedFormat
            }
            if signature.version == .rar5 {
                let rarSource: any ByteSource
                if signature.offset > 0 {
                    rarSource = try RebasedByteSource(source: source, baseOffset: signature.offset)
                } else {
                    rarSource = source
                }
                let rar = try RAR5Reader(
                    source: rarSource,
                    options: options,
                    sourceURL: signature.offset == 0 ? rarSourceURL : nil,
                    sourceDirectoryAnchor: signature.offset == 0
                        ? sourceDirectoryAnchor
                        : nil
                )
                reader = rar
                password = rar.resolvedPassword
            } else {
                let rar = try RAR4Reader(
                    source: source,
                    options: options,
                    sourceURL: signature.offset == 0 ? rarSourceURL : nil,
                    sourceDirectoryAnchor: signature.offset == 0
                        ? sourceDirectoryAnchor
                        : nil,
                    signatureOffset: signature.offset
                )
                reader = rar
                password = rar.resolvedPassword
            }
        case .lha:
            // FormatDetector accepts a lone terminator only with an LHA
            // filename hint. There is no member header for the SFX scanner.
            let signatures = source.length == 1
                ? [LHASignatureScanner.Match(offset: 0)]
                : try LHASignatureScanner.findSignatures(source: source)
            guard !signatures.isEmpty else {
                throw KaitoError.unsupportedFormat
            }
            var parsedReader: LHAReader?
            var candidateError: KaitoError?
            for signature in signatures {
                do {
                    parsedReader = try LHAReader(
                        source: source,
                        options: options,
                        headerOffset: signature.offset
                    )
                    break
                } catch let error as KaitoError {
                    switch error {
                    case .malformed, .truncated, .checksumMismatch:
                        // An authenticated base header can still be an
                        // executable byte pattern. Try the next bounded SFX
                        // candidate only for structural parse failures.
                        candidateError = candidateError ?? error
                    default:
                        throw error
                    }
                }
            }
            guard let lha = parsedReader else {
                throw candidateError ?? KaitoError.unsupportedFormat
            }
            reader = lha
        case .stuffItX:
            let stuffItX = try StuffItXReader(source: stuffItInput?.data ?? source,
                                             resourceFork: stuffItInput?.resource, options: options)
            reader = stuffItX
            password = stuffItX.resolvedPassword
        case .stuffIt:
            reader = try StuffItReader(source: stuffItInput?.data ?? source,
                                       resourceFork: stuffItInput?.resource, options: options)
        case .macBinary, .appleSingle, .binHex:
            // wrapper の payload が StuffIt でない: wrapper 自身を data fork + resource fork の 1 file として公開する。
            guard let envelope = stuffItInput, envelope.wrapper != nil else { throw KaitoError.unsupportedFormat }
            reader = try MacWrapperReader(envelope: envelope, format: detected.format, options: options,
                                          fallbackFileName: sourceURL?.lastPathComponent)
        case .ar:
            reader = try ArReader(source: source, options: options)
        case .cpio:
            reader = try CpioReader(source: source, options: options)
        case .iso:
            reader = try ISOReader(source: source, options: options)
        case .udf:
            reader = try UDFReader(source: source, options: options)
        case .wim:
            reader = try WIMReader(source: source, options: options)
        case .compoundFile:
            reader = try CFBReader(source: source, options: options)
        case .chm:
            reader = try CHMReader(source: source, options: options)
        case .arj:
            reader = try ARJReader(source: source, options: options)
        case .dmg:
            reader = try DMGReader(source: source, options: options)
        case .cab:
            // 実行形式 prefix の後ろにある cabinet は 7z と同じ規則で位置を求めて rebase する。
            let cabSource = try sfxRebasedSource(
                from: source, sourceURL: sourceURL, options: options,
                nativeSignature: [0x4D, 0x53, 0x43, 0x46], format: .cab
            )
            reader = try CabReader(source: cabSource, options: options)
        case .rpm:
            reader = try RpmReader(source: source, options: options)
        case .xar:
            reader = try XarReader(source: source, options: options)
        case .gzip, .bzip2, .xz, .zstd, .lz4, .compress, .lzma, .lzip, .brotli, .pbzx:
            return try openCompressedContainer(detected.format, source: source, sourceURL: sourceURL,
                                               recordsTarLayout: recordsTarLayout, tarOptions: tarOptions, options: options)
        }
        return OpenedFormatReader(reader: reader, password: password, tarEditingState: tarEditingState)
    }

    /// 単一 stream を展開し、名前が示す内側の tar / cpio を開く。container を持たなければ stream 自身を公開する。
    private static func openCompressedContainer(
        _ detected: ArchiveFormat, source: any ByteSource, sourceURL: URL?,
        recordsTarLayout: Bool, tarOptions: ReaderOptions, options: ReaderOptions
    ) throws -> OpenedFormatReader {
        let container = compressedContainer(for: sourceURL, detected: detected)
        let identityBefore = recordsTarLayout && container == .tar ? currentTarArchiveIdentity(source) : nil
        let single = try SingleFileReader(
            source: source,
            format: detected,
            options: options,
            fallbackFileName: sourceURL?.lastPathComponent
        )
        let mapRecorder = recordsTarLayout && !options.recoverDamagedArchives && container == .tar
            && [.gzip, .bzip2, .xz].contains(detected) ? CompressedTarMapRecorder(format: detected) : nil
        guard let container else {
            return OpenedFormatReader(reader: single, password: options.password)
        }
        // The expanded tar / cpio envelope is staging input, not a
        // published entry. Its stream uses maxEntrySize; the aggregate
        // budget ArchiveReader constructs afterwards applies to the inner reader's members.
        let stream = try single.stagingStream(limits: options.limits, recorder: mapRecorder)
        let staged = try SingleFileMaterializer.materialize(
            stream,
            limits: options.limits
        )
        switch container {
        case .tar:
            let tar = try AppleDoubleReader.wrap(TarReader(source: staged, options: tarOptions), options: options)
            var tarEditingState: TarEditingSnapshot?
            if recordsTarLayout {
                let kind: TarContainer = detected == .gzip ? .gzip : detected == .bzip2 ? .bzip2 : detected == .xz ? .xz : .other(detected)
                tarEditingState = makeTarEditingState(container: kind, archive: source, image: staged,
                                                      reader: tar, options: options, recorder: mapRecorder,
                                                      identityBefore: identityBefore)
            }
            return OpenedFormatReader(reader: tar, password: options.password,
                                      stagedTarSource: staged, tarEditingState: tarEditingState)
        case .cpio:
            return OpenedFormatReader(reader: try CpioReader(source: staged, options: options),
                                      password: options.password, stagedTarSource: staged)
        case .pbzxAuto:
            // pbzx は Apple の pkg / OTA が cpio payload を包むためだけに使う container なので、
            // 展開結果が cpio ならその entry を直接公開し、そうでなければ単一 stream に留める。
            if CpioHeader.probe(try readByteRange(source: staged, offset: 0, count: Int(min(6, staged.length))),
                                source: staged) != nil {
                return OpenedFormatReader(reader: try CpioReader(source: staged, options: options),
                                          password: options.password, stagedTarSource: staged)
            }
            return OpenedFormatReader(reader: single, password: options.password)
        }
    }

    /// 単一 stream の展開結果を渡す内側の container。
    private enum CompressedContainer {
        case tar
        case cpio
        /// pbzx: 展開結果が cpio ならその entry を公開し、そうでなければ単一 stream。
        case pbzxAuto
    }

    /// 名前（または pbzx の形式）から、単一 stream の展開結果を渡す container を決める。
    /// `.tlz` は LZMA_Alone（GNU tar）と lzip（lzip 自身の慣習）の両方が使うため、
    /// 署名で判別した方を採る。cpio は `.cpgz`（Archive Utility）と `.cpio.<codec>` を扱う。
    private static func compressedContainer(for sourceURL: URL?, detected: ArchiveFormat) -> CompressedContainer? {
        if detected == .pbzx { return .pbzxAuto }
        guard let name = sourceURL?.lastPathComponent.lowercased() else {
            return nil
        }
        let codecSuffixes: [(String, ArchiveFormat)] = [
            (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd), (".lz4", .lz4),
            (".lzma", .lzma), (".lz", .lzip), (".br", .brotli), (".z", .compress),
        ]
        for (suffix, format) in codecSuffixes where name.hasSuffix(".tar" + suffix) {
            return format == detected ? .tar : nil
        }
        for (suffix, format) in codecSuffixes where name.hasSuffix(".cpio" + suffix) {
            return format == detected ? .cpio : nil
        }
        let tarAliases: [(String, Set<ArchiveFormat>)] = [
            (".tgz", [.gzip]), (".tbz2", [.bzip2]), (".tbz", [.bzip2]), (".txz", [.xz]),
            (".tzst", [.zstd]), (".tlz", [.lzma, .lzip]), (".tbr", [.brotli]),
            (".tz", [.compress]), (".taz", [.compress]),
        ]
        for (suffix, formats) in tarAliases where name.hasSuffix(suffix) {
            return formats.contains(detected) ? .tar : nil
        }
        if name.hasSuffix(".cpgz") { return detected == .gzip ? .cpio : nil }
        return nil
    }

    private static func sevenZipSource(
        from source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions
    ) throws -> any ByteSource {
        try sfxRebasedSource(
            from: source, sourceURL: sourceURL, options: options,
            nativeSignature: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], format: .sevenZip
        )
    }

    /// 先頭に native 署名があればそのまま、実行形式 prefix の後ろに署名があれば rebase した source。
    private static func sfxRebasedSource(
        from source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        nativeSignature: [UInt8],
        format: ArchiveFormat
    ) throws -> any ByteSource {
        if source.length >= UInt64(nativeSignature.count),
           try readByteRange(
               source: source,
               offset: 0,
               count: nativeSignature.count
           ) == nativeSignature {
            return source
        }
        let scanSize = sourceURL != nil
            ? options.maximumSFXScanSize
            : (options.scanForSFXInData ? options.maximumSFXScanSize : 0)
        guard scanSize > 0,
              let match = try FormatDetector.findSFXSignature(
                source: source,
                maximumScanSize: scanSize
              ),
              match.format == format else {
            return source
        }
        return try RebasedByteSource(source: source, baseOffset: match.offset)
    }

}
