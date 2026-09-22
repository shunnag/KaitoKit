import Foundation

private final class ArchiveOutputBudget {
    private let limit: UInt64
    private let declaredTotal: UInt64
    private var total: UInt64
    private var unknownEntrySizes: [Int: UInt64] = [:]
    private var limitWasExceeded = false

    init(entries: [ArchiveEntry], limit: UInt64) throws {
        self.limit = limit
        var declaredTotal: UInt64 = 0
        for entry in entries {
            guard let size = entry.uncompressedSize else { continue }
            let next = declaredTotal.addingReportingOverflow(size)
            guard !next.overflow, next.partialValue <= limit else {
                throw KaitoError.limitExceeded("total uncompressed size")
            }
            declaredTotal = next.partialValue
        }
        self.declaredTotal = declaredTotal
        self.total = declaredTotal
    }

    private init(limit: UInt64, declaredTotal: UInt64) {
        self.limit = limit
        self.declaredTotal = declaredTotal
        self.total = declaredTotal
    }

    func reopened() -> sending ArchiveOutputBudget {
        // The immutable entry sum was checked at open. Reset runtime charges
        // and terminal failures without walking a large shared entry array.
        ArchiveOutputBudget(limit: limit, declaredTotal: declaredTotal)
    }

    func ensureUsable() throws {
        guard !limitWasExceeded else {
            throw KaitoError.limitExceeded("total uncompressed size")
        }
    }

    func availableAdditionalSize(index: Int, producedSize: UInt64) throws -> UInt64 {
        try ensureUsable()
        let previouslyRecorded = unknownEntrySizes[index] ?? 0
        let replayAllowance = previouslyRecorded > producedSize
            ? previouslyRecorded - producedSize
            : 0
        let unallocatedAllowance = limit - total
        return try Checked.add(replayAllowance, unallocatedAllowance)
    }

    func recordUnknownEntry(index: Int, producedSize: UInt64) throws {
        try ensureUsable()
        let previous = unknownEntrySizes[index] ?? 0
        guard producedSize > previous else { return }
        let additional = try Checked.sub(producedSize, previous)
        guard additional <= limit - total else {
            limitWasExceeded = true
            throw KaitoError.limitExceeded("total uncompressed size")
        }
        let nextTotal = total + additional
        unknownEntrySizes[index] = producedSize
        total = nextTotal
    }

    func recordLimitExceeded() throws {
        limitWasExceeded = true
        throw KaitoError.limitExceeded("total uncompressed size")
    }
}

/// Opens an archive, lists its entries, and reads or extracts their contents.
///
/// `ArchiveReader` is deliberately not thread-safe. Call ``reopen()`` to make
/// an inexpensive independent reader that shares the immutable byte source.
public final class ArchiveReader {
    private let source: any ByteSource
    private let stagedTarSource: (any ByteSource)?
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
        self.password = options.password

        let stuffItInput = try FormatDetector.stuffItInput(source: source, limits: options.limits,
            maximumSFXScanSize: sourceURL != nil || options.scanForSFXInData ? options.maximumSFXScanSize : 0)
        let detected = try stuffItInput == nil ? FormatDetector.detect(
            source: source,
            sourceURL: sourceURL,
            options: options,
            skipStuffIt: true
        ) : FormatDetector.envelopeFormat(stuffItInput!)

        if zipDiskLayout != nil, detected != .zip {
            throw KaitoError.malformed("ZIP split volume set is not a ZIP archive")
        }
        var stagedTarSource: (any ByteSource)?
        switch detected {
        case .tar:
            let tar = try AppleDoubleReader.wrap(TarReader(source: source, options: options), options: options)
            reader = tar
            entries = tar.entries
            format = .tar
        case .zip:
            // Finder / ditto の `__MACOSX/._name` sidecar は方針に従って畳む（既定は resource fork へ統合）。
            let zip = try AppleDoubleReader.wrap(ZipReader(source: source, options: options, diskLayout: zipDiskLayout), options: options)
            reader = zip
            entries = zip.entries
            format = .zip
        case .sevenZip:
            let sevenZipSource = try Self.sevenZipSource(
                from: source,
                sourceURL: sourceURL,
                options: options
            )
            let sevenZip = try SevenZipReader(
                source: sevenZipSource,
                options: options
            )
            reader = sevenZip
            entries = sevenZip.entries
            format = .sevenZip
            password = sevenZip.resolvedPassword
        case .rar:
            // 連結済み source では RAR 独自の多巻探索を行わず、Data と同じ扱いにする。
            // 単巻 .001 の場合は、名前ヒントでなく実際に開いた葉を identity 検証に使う。
            let rarSourceURL = source is ConcatenatedByteSource
                ? nil
                : (sourceVolumeURL ?? sourceURL)
            guard let signature = try FormatDetector.findRARSignature(source: source) else {
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
                entries = rar.entries
                format = .rar
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
                entries = rar.entries
                format = .rar
                password = rar.resolvedPassword
            }
        case .lha:
            // FormatDetector accepts a lone terminator only with an LHA
            // filename hint. There is no member header for the SFX scanner.
            let signatures = source.length == 1
                ? [FormatDetector.LHASignatureMatch(offset: 0)]
                : try FormatDetector.findLHASignatures(source: source)
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
            entries = lha.entries
            format = .lha
        case .stuffItX:
            let stuffItX = try StuffItXReader(source: stuffItInput?.data ?? source,
                                             resourceFork: stuffItInput?.resource, options: options)
            reader = stuffItX
            entries = stuffItX.entries
            format = .stuffItX
            password = stuffItX.resolvedPassword
        case .stuffIt:
            let stuffIt = try StuffItReader(source: stuffItInput?.data ?? source,
                                              resourceFork: stuffItInput?.resource, options: options)
            reader = stuffIt
            entries = stuffIt.entries
            format = .stuffIt
        case .macBinary, .appleSingle, .binHex:
            // wrapper の payload が StuffIt でない: wrapper 自身を data fork + resource fork の 1 file として公開する。
            guard let envelope = stuffItInput, envelope.wrapper != nil else { throw KaitoError.unsupportedFormat }
            let wrapper = try MacWrapperReader(envelope: envelope, format: detected, options: options,
                                               fallbackFileName: sourceURL?.lastPathComponent)
            reader = wrapper
            entries = wrapper.entries
            format = detected
        case .ar:
            let ar = try ArReader(source: source, options: options)
            reader = ar
            entries = ar.entries
            format = .ar
        case .cpio:
            let cpio = try CpioReader(source: source, options: options)
            reader = cpio
            entries = cpio.entries
            format = .cpio
        case .iso:
            let iso = try ISOReader(source: source, options: options)
            reader = iso
            entries = iso.entries
            format = .iso
        case .udf:
            let udf = try UDFReader(source: source, options: options)
            reader = udf
            entries = udf.entries
            format = .udf
        case .wim:
            let wim = try WIMReader(source: source, options: options)
            reader = wim
            entries = wim.entries
            format = .wim
        case .compoundFile:
            let cfb = try CFBReader(source: source, options: options)
            reader = cfb
            entries = cfb.entries
            format = .compoundFile
        case .chm:
            let chm = try CHMReader(source: source, options: options)
            reader = chm
            entries = chm.entries
            format = .chm
        case .arj:
            let arj = try ARJReader(source: source, options: options)
            reader = arj
            entries = arj.entries
            format = .arj
        case .dmg:
            let dmg = try DMGReader(source: source, options: options)
            reader = dmg
            entries = dmg.entries
            format = .dmg
        case .cab:
            // 実行形式 prefix の後ろにある cabinet は 7z と同じ規則で位置を求めて rebase する。
            let cabSource = try Self.sfxRebasedSource(
                from: source, sourceURL: sourceURL, options: options,
                nativeSignature: [0x4D, 0x53, 0x43, 0x46], format: .cab
            )
            let cab = try CabReader(source: cabSource, options: options)
            reader = cab
            entries = cab.entries
            format = .cab
        case .rpm:
            let rpm = try RpmReader(source: source, options: options)
            reader = rpm
            entries = rpm.entries
            format = .rpm
        case .xar:
            let xar = try XarReader(source: source, options: options)
            reader = xar
            entries = xar.entries
            format = .xar
        case .gzip, .bzip2, .xz, .zstd, .lz4, .compress, .lzma, .lzip, .brotli, .pbzx:
            let single = try SingleFileReader(
                source: source,
                format: detected,
                options: options,
                fallbackFileName: sourceURL?.lastPathComponent
            )
            let container = Self.compressedContainer(for: sourceURL, detected: detected)
            if let container {
                // The expanded tar / cpio envelope is staging input, not a
                // published entry. Its stream uses maxEntrySize; the aggregate
                // budget constructed below applies to the inner reader's members.
                let stream = try single.stream(
                    for: single.entries[0],
                    limits: options.limits
                )
                let staged = try SingleFileMaterializer.materialize(
                    stream,
                    limits: options.limits
                )
                stagedTarSource = staged
                switch container {
                case .tar:
                    let tar = try AppleDoubleReader.wrap(TarReader(source: staged, options: options), options: options)
                    reader = tar
                    entries = tar.entries
                    format = .tar
                case .cpio:
                    let cpio = try CpioReader(source: staged, options: options)
                    reader = cpio
                    entries = cpio.entries
                    format = .cpio
                case .pbzxAuto:
                    // pbzx は Apple の pkg / OTA が cpio payload を包むためだけに使う container なので、
                    // 展開結果が cpio ならその entry を直接公開し、そうでなければ単一 stream に留める。
                    if CpioHeader.probe(try readByteRange(source: staged, offset: 0, count: Int(min(6, staged.length))),
                                        source: staged) != nil {
                        let cpio = try CpioReader(source: staged, options: options)
                        reader = cpio
                        entries = cpio.entries
                        format = .cpio
                    } else {
                        stagedTarSource = nil
                        reader = single
                        entries = single.entries
                        format = detected
                    }
                }
            } else {
                reader = single
                entries = single.entries
                format = detected
            }
        }

        self.stagedTarSource = stagedTarSource
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
        stagedTarSource: (any ByteSource)? = nil
    ) throws {
        self.source = source
        self.stagedTarSource = stagedTarSource
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
        let standardized = url.standardizedFileURL
        let opened = try FileByteSource.openAnchored(url: standardized)
        let split = try SplitVolumeSet.assemble(
            firstVolumeURL: standardized,
            firstVolumeSource: opened.source,
            directory: opened.directory,
            limits: options.limits
        )
        let zipSplit = try split == nil ? ZipSplitVolumeSet.assemble(
            url: standardized, source: opened.source, directory: opened.directory, limits: options.limits
        ) : nil
        // classic StuffIt の分割セット（100 byte header の part）は兄弟を集めて data / resource fork に組む。
        let stuffItSplit = try split == nil && zipSplit == nil ? StuffItSplitSet.assemble(
            firstVolumeURL: standardized, source: opened.source, directory: opened.directory, limits: options.limits
        ) : nil
        // `.cue` は data track の image file（同じ directory）を開く。
        let cue = try split == nil && zipSplit == nil && stuffItSplit == nil ? CueSheet.assemble(
            url: standardized, source: opened.source, directory: opened.directory, limits: options.limits
        ) : nil
        // 兄弟のない .001 でも .tar.gz などのヒントを保持する。
        let sourceURL = SplitVolumeSet.naming(forFirstVolumeName: standardized.lastPathComponent) != nil
            ? standardized.deletingPathExtension()
            : standardized
        return try ArchiveReader(
            source: split?.source ?? zipSplit?.source ?? stuffItSplit.map { $0 as any ByteSource } ?? cue ?? opened.source,
            sourceURL: sourceURL,
            sourceDirectoryAnchor: split == nil ? opened.directory : nil,
            sourceVolumeURL: split == nil ? standardized : nil,
            zipDiskLayout: zipSplit?.layout,
            volumeSet: split?.volumeSet ?? zipSplit?.volumeSet,
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
        return stream
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
        let parsedReader: any FormatReader
        if let merged = reader as? AppleDoubleReader {
            parsedReader = try merged.reopened(options: reopenedOptions)
        } else if let zip = reader as? ZipReader {
            parsedReader = zip.reopened(options: reopenedOptions)
        } else if let tar = reader as? TarReader {
            parsedReader = tar.reopened(options: reopenedOptions)
        } else if let sevenZip = reader as? SevenZipReader {
            parsedReader = sevenZip.reopened(options: reopenedOptions)
        } else if let lha = reader as? LHAReader {
            parsedReader = lha.reopened(options: reopenedOptions)
        } else if let rar5 = reader as? RAR5Reader {
            parsedReader = rar5.reopened(options: reopenedOptions)
        } else if let rar4 = reader as? RAR4Reader {
            parsedReader = rar4.reopened(options: reopenedOptions)
        } else if let stagedTarSource, reader is CpioReader {
            // 圧縮 cpio / pbzx の展開結果は保持済みなので、再展開せずその source から開き直す。
            return try ArchiveReader(
                source: stagedTarSource,
                sourceURL: nil,
                zipDiskLayout: nil,
                volumeSet: volumeSet,
                options: reopenedOptions
            )
        } else {
            return try ArchiveReader(
                source: source,
                sourceURL: sourceURL,
                zipDiskLayout: zipDiskLayout,
                volumeSet: volumeSet,
                options: reopenedOptions
            )
        }
        return try ArchiveReader(
            sharing: stagedTarSource ?? source,
            sourceURL: sourceURL,
            options: reopenedOptions,
            parsedReader: parsedReader,
            outputBudget: outputBudget.reopened(),
            zipDiskLayout: zipDiskLayout,
            volumeSet: volumeSet,
            stagedTarSource: stagedTarSource
        )
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
        if let stuffIt = reader as? StuffItReader { try stuffIt.validateEncryptionSupport(for: entry) }
        if let stuffItX = reader as? StuffItXReader { try stuffItX.validateEncryptionSupport(for: entry) }
        if entry.isEncrypted, password == nil, let provider = options.passwordProvider {
            password = try provider.password(for: format)
        }
        reader.setPassword(password)
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
