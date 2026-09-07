import Foundation

/// Opens an archive, lists its entries, and reads or extracts their contents.
///
/// `ArchiveReader` is deliberately not thread-safe. Call ``reopen()`` to make
/// an inexpensive independent reader that shares the immutable byte source.
public final class ArchiveReader {
    private let source: any ByteSource
    // Retained only for formats whose continuation volumes are resolved beside
    // the original file. Data and arbitrary ByteSource readers deliberately
    // have no filesystem provenance.
    private let sourceURL: URL?
    private let reader: any FormatReader
    private let options: ReaderOptions
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
        options: ReaderOptions
    ) throws {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.password = options.password

        let detected = try FormatDetector.detect(source: source)
        format = detected

        switch detected {
        case .tar:
            let tar = try TarReader(source: source, options: options)
            reader = tar
            entries = tar.entries
        case .zip:
            let zip = try ZipReader(source: source, options: options)
            reader = zip
            entries = zip.entries
        case .sevenZip:
            let sevenZip = try SevenZipReader(source: source, options: options)
            reader = sevenZip
            entries = sevenZip.entries
            password = sevenZip.resolvedPassword
        case .rar:
            guard let signature = try FormatDetector.findRARSignature(source: source) else {
                throw KaitoError.unsupportedFormat
            }
            if signature.version == .rar5 {
                guard signature.offset == 0 else {
                    throw KaitoError.unsupportedMethod("RAR5 SFX archive")
                }
                let rar = try RAR5Reader(
                    source: source,
                    options: options,
                    sourceURL: sourceURL,
                    sourceDirectoryAnchor: sourceDirectoryAnchor
                )
                reader = rar
                entries = rar.entries
                password = rar.resolvedPassword
            } else {
                let rar = try RAR4Reader(
                    source: source,
                    options: options,
                    sourceURL: signature.offset == 0 ? sourceURL : nil,
                    sourceDirectoryAnchor: signature.offset == 0
                        ? sourceDirectoryAnchor
                        : nil,
                    signatureOffset: signature.offset
                )
                reader = rar
                entries = rar.entries
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
        case .gzip, .bzip2, .xz:
            throw KaitoError.unsupportedFormat
        }
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
    ) {
        self.source = source
        self.sourceURL = sourceURL
        self.options = options
        self.reader = parsedReader
        self.format = parsedReader.format
        self.entries = parsedReader.entries
        self.password = options.password
    }

    /// Opens an archive stored at a file URL.
    public static func open(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        let opened = try FileByteSource.openAnchored(url: url)
        return try ArchiveReader(
            source: opened.source,
            sourceURL: url.standardizedFileURL,
            sourceDirectoryAnchor: opened.directory,
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
    public func stream(_ entry: ArchiveEntry) throws -> EntryStream {
        try validate(entry)
        try preparePassword(for: entry)
        return try reader.stream(for: entry, limits: options.limits)
    }

    /// Reads one entry into an exactly sized in-memory buffer.
    public func read(_ entry: ArchiveEntry) throws -> Data {
        try validate(entry)
        if let declared = entry.uncompressedSize {
            try Checked.size(declared, limit: options.limits.maxInMemorySize)
        }
        return try stream(entry).readAll()
    }

    /// Safely extracts one entry below `directory` and returns its destination.
    ///
    /// The caller must prevent other threads or processes from mutating the
    /// extraction root until this operation returns.
    /// A zero-body hard link requires its target to have been extracted first,
    /// in archive order, to the same root with this reader. Switching roots or
    /// calling ``reopen()`` starts independent extraction provenance.
    public func extract(
        _ entry: ArchiveEntry,
        to directory: URL,
        options extractionOptions: ExtractionOptions = ExtractionOptions()
    ) throws -> URL {
        try validate(entry)
        let rootKey = directory.standardizedFileURL.path
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

    /// Creates a new independent reader sharing the same immutable byte source.
    public func reopen() throws -> ArchiveReader {
        var reopenedOptions = options
        reopenedOptions.password = password
        if let rar5 = reader as? RAR5Reader {
            return ArchiveReader(
                sharing: source,
                sourceURL: sourceURL,
                options: reopenedOptions,
                parsedReader: rar5.reopened(options: reopenedOptions)
            )
        }
        if let rar4 = reader as? RAR4Reader {
            return ArchiveReader(
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

    private func preparePassword(for entry: ArchiveEntry) throws {
        if entry.isEncrypted, password == nil, let provider = options.passwordProvider {
            password = try provider.password(for: format)
        }
        reader.setPassword(password)
    }
}
