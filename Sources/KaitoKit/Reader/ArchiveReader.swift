import Foundation

/// Opens an archive, lists its entries, and reads or extracts their contents.
///
/// `ArchiveReader` is deliberately not thread-safe. Call ``reopen()`` to make
/// an inexpensive independent reader that shares the immutable byte source.
public final class ArchiveReader {
    private let source: any ByteSource
    private let reader: any FormatReader
    private let options: ReaderOptions
    private var extractionRootKey: String?
    private var extractedFiles: [Int: ExtractedFileIdentity] = [:]

    /// The detected archive format.
    public let format: ArchiveFormat

    /// Entries in archive order.
    public let entries: [ArchiveEntry]

    /// The password used for subsequent encrypted-entry operations.
    public var password: String?

    private init(source: any ByteSource, options: ReaderOptions) throws {
        self.source = source
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
        case .rar, .sevenZip, .lha, .gzip, .bzip2, .xz:
            throw KaitoError.unsupportedFormat
        }
    }

    /// Opens an archive stored at a file URL.
    public static func open(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveReader {
        try ArchiveReader(source: FileByteSource(url: url), options: options)
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
        return try ArchiveReader(source: source, options: reopenedOptions)
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
