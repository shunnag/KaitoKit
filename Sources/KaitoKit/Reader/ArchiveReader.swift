import Foundation

private final class ArchiveOutputBudget {
    private let limit: UInt64
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
        self.total = declaredTotal
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
    // 拡張子・単一ストリームの名前・SFX 検出のヒント。分割セットでは .001 を除く。
    // Data と任意の ByteSource はファイル名の由来を持たない。
    private let sourceURL: URL?
    private let reader: any FormatReader
    private let options: ReaderOptions
    private let outputBudget: ArchiveOutputBudget
    private var extractionRootKey: String?
    private var extractedFiles: [Int: ExtractedFileIdentity] = [:]

    /// The detected archive format.
    public let format: ArchiveFormat

    /// Entries in archive order.
    public let entries: [ArchiveEntry]

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
        options: ReaderOptions
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.password = options.password

        let detected = try FormatDetector.detect(
            source: source,
            sourceURL: sourceURL,
            options: options
        )

        switch detected {
        case .tar:
            let tar = try TarReader(source: source, options: options)
            reader = tar
            entries = tar.entries
            format = .tar
        case .zip:
            let zip = try ZipReader(source: source, options: options)
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
            let signatures = try FormatDetector.findLHASignatures(source: source)
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
        case .cab:
            let cab = try CabReader(source: source, options: options)
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
        case .gzip, .bzip2, .xz, .compress, .lzma:
            let single = try SingleFileReader(
                source: source,
                format: detected,
                options: options,
                fallbackFileName: sourceURL?.lastPathComponent
            )
            if Self.compressedTarFormat(for: sourceURL) == detected {
                // The expanded tar envelope is staging input, not a published
                // entry. Its stream uses maxEntrySize; the aggregate budget
                // constructed below applies to the TarReader's members.
                let stream = try single.stream(
                    for: single.entries[0],
                    limits: options.limits
                )
                let tarSource = try SingleFileMaterializer.materialize(
                    stream,
                    limits: options.limits
                )
                let tar = try TarReader(source: tarSource, options: options)
                reader = tar
                entries = tar.entries
                format = .tar
            } else {
                reader = single
                entries = single.entries
                format = detected
            }
        }

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
        parsedReader: any FormatReader
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.reader = parsedReader
        self.format = parsedReader.format
        self.entries = parsedReader.entries
        self.password = options.password
        self.outputBudget = try ArchiveOutputBudget(
            entries: parsedReader.entries,
            limit: options.limits.maxTotalUncompressedSize
        )
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
        // 兄弟のない .001 でも .tar.gz などのヒントを保持する。
        let sourceURL = SplitVolumeSet.naming(forFirstVolumeName: standardized.lastPathComponent) != nil
            ? standardized.deletingPathExtension()
            : standardized
        return try ArchiveReader(
            source: split?.source ?? opened.source,
            sourceURL: sourceURL,
            sourceDirectoryAnchor: split == nil ? opened.directory : nil,
            sourceVolumeURL: split == nil ? standardized : nil,
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

    /// 再圧縮せずに運べる形式では生レコード範囲を返す。未対応形式・isIncomplete・分割セットは nil。
    /// 現在は ZIP のみ対応し、data descriptor を含む範囲と中央ディレクトリとの整合を検証する。
    /// 暗号化 entry もパスワードなしで取得できる。payload の復号・展開・完全性検証は行わない。
    /// 呼び出しからコピー完了まで、source の byte は不変でなければならない。
    public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord? {
        try validate(entry)
        guard !entry.isIncomplete, !(source is ConcatenatedByteSource) else { return nil }
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
        if let rar5 = reader as? RAR5Reader {
            return try ArchiveReader(
                sharing: source,
                sourceURL: sourceURL,
                options: reopenedOptions,
                parsedReader: rar5.reopened(options: reopenedOptions)
            )
        }
        if let rar4 = reader as? RAR4Reader {
            return try ArchiveReader(
                sharing: source,
                sourceURL: sourceURL,
                options: reopenedOptions,
                parsedReader: rar4.reopened(options: reopenedOptions)
            )
        }
        return try ArchiveReader(
            source: source,
            sourceURL: sourceURL,
            options: reopenedOptions
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
        if entry.isEncrypted, password == nil, let provider = options.passwordProvider {
            password = try provider.password(for: format)
        }
        reader.setPassword(password)
    }

    private static func compressedTarFormat(for sourceURL: URL?) -> ArchiveFormat? {
        guard let name = sourceURL?.lastPathComponent.lowercased() else {
            return nil
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .gzip
        }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") {
            return .bzip2
        }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") {
            return .xz
        }
        // 既存の LZWDecoder と tar staging を .tar.Z / .tZ にも適用する。
        if name.hasSuffix(".tar.z") || name.hasSuffix(".tz") {
            return .compress
        }
        return nil
    }

    private static func sevenZipSource(
        from source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions
    ) throws -> any ByteSource {
        let nativeSignature: [UInt8] = [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]
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
              match.format == .sevenZip else {
            return source
        }
        return try RebasedByteSource(source: source, baseOffset: match.offset)
    }

}
