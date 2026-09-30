import Foundation

/// 形式選択・SFX の source view・圧縮 container の staging を担当する。
/// ArchiveReader の entry 操作と再オープン時の可変状態から分離する。
enum FormatReaderFactory {
    /// 入力の identity・名前ヒント・巻配置を保ったまま検出し、形式 reader を生成する。
    static func open(input: OpenedArchiveInput, options: ReaderOptions) throws -> OpenedFormatReader {
        let detected = try detectFormat(source: input.source, sourceURL: input.sourceURL, options: options)
        if input.zipDiskLayout != nil, detected.format != .zip {
            throw KaitoError.malformed("ZIP split volume set is not a ZIP archive")
        }
        return try openFormatReader(detected, source: input.source, sourceURL: input.sourceURL,
            sourceDirectoryAnchor: input.directoryAnchor, sourceVolumeURL: input.volumeURL,
            zipDiskLayout: input.zipDiskLayout, volumeSet: input.volumeSet, options: options)
    }

    /// 形式検出の結果。StuffIt の envelope（wrapper を剥いだ payload と resource fork）があれば持つ。
    struct DetectedFormat {
        let format: ArchiveFormat
        let stuffItInput: MacEnvelope?
    }

    /// 形式 reader を開いた結果。format と entries は reader 自身から取る。
    struct OpenedFormatReader {
        let reader: any FormatReader
        /// options.password から始め、reader が解決した password があればそれ。
        let password: String?
        /// 圧縮 tar / cpio を展開した staging。reopen はこれを共有する。
        var stagedContainerSource: (any ByteSource)?
        var tarEditingState: TarEditingSnapshot?
    }

    /// StuffIt の envelope を一段だけ剥がしてから形式を検出する。envelope があればその形式が結果。
    static func detectFormat(
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
                                      stagedContainerSource: staged, tarEditingState: tarEditingState)
        case .cpio:
            return OpenedFormatReader(reader: try CpioReader(source: staged, options: options),
                                      password: options.password, stagedContainerSource: staged)
        case .pbzxAuto:
            // pbzx は Apple の pkg / OTA が cpio payload を包むためだけに使う container なので、
            // 展開結果が cpio ならその entry を直接公開し、そうでなければ単一 stream に留める。
            if CpioHeader.detectVariant(try readByteRange(source: staged, offset: 0, count: Int(min(6, staged.length))),
                                source: staged) != nil {
                return OpenedFormatReader(reader: try CpioReader(source: staged, options: options),
                                          password: options.password, stagedContainerSource: staged)
            }
            return OpenedFormatReader(reader: single, password: options.password)
        }
    }

    /// 名前（または pbzx の形式）から、単一 stream の展開結果を渡す container を決める。
    private static func compressedContainer(for sourceURL: URL?, detected: ArchiveFormat) -> CompressedNaming.Container? {
        CompressedNaming.compressedContainer(name: sourceURL?.lastPathComponent, detected: detected)
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
}
