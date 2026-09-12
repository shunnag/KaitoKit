private import Darwin
import Foundation
import KaitoKit
import Synchronization

enum KaitoArchiveFileRelocator {
    private static let copyBufferSize = 256 * 1024
    private static let permissionBits = mode_t(0o7777)

    static func copyRegularFile(
        from sourceParent: Int32,
        sourceLeaf: String,
        to destinationParent: Int32,
        destinationLeaf: String
    ) throws {
        var sourceInformation = stat()
        guard Darwin.fstatat(
            sourceParent,
            sourceLeaf,
            &sourceInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (sourceInformation.st_mode & S_IFMT) == S_IFREG else {
            throw KaitoError.malformed("relocation source is not a regular file")
        }

        let sourceMode = sourceInformation.st_mode & permissionBits
        var sourceModeNeedsRestoration = false
        if sourceMode & mode_t(S_IRUSR) == 0 {
            guard Darwin.fchmodat(
                sourceParent,
                sourceLeaf,
                sourceMode | mode_t(S_IRUSR),
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw KaitoError.io(errno)
            }
            sourceModeNeedsRestoration = true
        }

        let source = Darwin.openat(
            sourceParent,
            sourceLeaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard source >= 0 else {
            let code = errno
            if sourceModeNeedsRestoration {
                _ = Darwin.fchmodat(
                    sourceParent,
                    sourceLeaf,
                    sourceMode,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            throw KaitoError.io(code)
        }
        defer {
            if sourceModeNeedsRestoration {
                _ = Darwin.fchmod(source, sourceMode)
            }
            _ = Darwin.close(source)
        }

        var openedInformation = stat()
        guard Darwin.fstat(source, &openedInformation) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (openedInformation.st_mode & S_IFMT) == S_IFREG,
              openedInformation.st_dev == sourceInformation.st_dev,
              openedInformation.st_ino == sourceInformation.st_ino,
              openedInformation.st_gen == sourceInformation.st_gen else {
            throw KaitoError.malformed("relocation source changed while opening")
        }
        if sourceModeNeedsRestoration {
            guard Darwin.fchmod(source, sourceMode) == 0 else {
                throw KaitoError.io(errno)
            }
            sourceModeNeedsRestoration = false
        }

        let temporaryLeaf = ".kaitokit-relocate-\(UUID().uuidString)"
        let target = Darwin.openat(
            destinationParent,
            temporaryLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard target >= 0 else { throw KaitoError.io(errno) }
        var targetIsOpen = true
        var published = false
        defer {
            if targetIsOpen {
                _ = Darwin.close(target)
            }
            if !published {
                _ = Darwin.unlinkat(destinationParent, temporaryLeaf, 0)
            }
        }

        try copyContents(from: source, to: target)
        var times = [sourceInformation.st_atimespec, sourceInformation.st_mtimespec]
        guard Darwin.futimens(target, &times) == 0 else {
            throw KaitoError.io(errno)
        }
        guard Darwin.fchmod(target, sourceMode) == 0 else {
            throw KaitoError.io(errno)
        }
        guard Darwin.close(target) == 0 else {
            targetIsOpen = false
            throw KaitoError.io(errno)
        }
        targetIsOpen = false

        guard Darwin.renameat(
            destinationParent,
            temporaryLeaf,
            destinationParent,
            destinationLeaf
        ) == 0 else {
            throw KaitoError.io(errno)
        }
        published = true
    }

    private static func copyContents(from source: Int32, to target: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(source, storage.baseAddress, storage.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw KaitoError.io(errno) }
            if count == 0 { return }

            var written = 0
            while written < count {
                let result: Int = buffer.withUnsafeBytes { storage in
                    guard let baseAddress = storage.baseAddress else { return -1 }
                    return Darwin.write(
                        target,
                        baseAddress.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw KaitoError.io(errno) }
                written += result
            }
        }
    }
}

/// Delegate callbacks corresponding to the commonly used `XADArchiveDelegate` methods.
///
/// XADMaster exposes these callbacks as optional Objective-C protocol methods. KaitoKitCompat
/// uses Swift protocol requirements with no-op default implementations instead, so conformers
/// implement only the callbacks they need.
public protocol KaitoArchiveDelegate: AnyObject {
    /// Reproduces XADMaster's request for a password before reading an encrypted entry.
    ///
    /// Call ``KaitoArchive/setPassword(_:)`` before returning. Unlike XADMaster, this callback
    /// cannot participate in a failable initializer that needs a password to parse encrypted
    /// archive headers, because the delegate is assigned after initialization.
    func archiveNeedsPassword(_ archive: KaitoArchive)

    /// Reproduces XADMaster's name-encoding override callback for undecorated name bytes.
    ///
    /// Return an encoding to rebuild the archive with ``EncodingPolicy/fixed(_:)``, or `nil`
    /// to accept KaitoKit's archive-wide detection. KaitoKit calls this after the delegate is
    /// assigned rather than from inside the failable initializer.
    func archive(
        _ archive: KaitoArchive,
        nameEncodingForData data: Data,
        guess: String.Encoding,
        confidence: Double
    ) -> String.Encoding?

    /// Reproduces XADMaster's per-entry extraction progress callback.
    ///
    /// Whole-entry data reads report each produced chunk. File-system extraction currently
    /// reports one completion update because `Extractor` owns its streaming loop.
    func archive(
        _ archive: KaitoArchive,
        extractionProgressForEntry entry: Int32,
        bytes: Int64,
        of total: Int64
    )
}

public extension KaitoArchiveDelegate {
    /// Supplies the Swift equivalent of an unimplemented optional XADMaster password callback.
    func archiveNeedsPassword(_ archive: KaitoArchive) {}

    /// Supplies the Swift equivalent of an unimplemented optional XADMaster encoding callback.
    func archive(
        _ archive: KaitoArchive,
        nameEncodingForData data: Data,
        guess: String.Encoding,
        confidence: Double
    ) -> String.Encoding? {
        nil
    }

    /// Supplies the Swift equivalent of an unimplemented optional XADMaster progress callback.
    func archive(
        _ archive: KaitoArchive,
        extractionProgressForEntry entry: Int32,
        bytes: Int64,
        of total: Int64
    ) {}
}

/// A failure-tolerant compatibility facade for the XADArchive surface used by cooViewer.
///
/// It reproduces optional construction, `Int32` entry indexes, optional names and contents,
/// boolean extraction results, mutable passwords, delegate callbacks, and solid groups. Unlike
/// XADMaster, detailed failures are available as ``lastError`` and throwing/streaming operations
/// remain on `ArchiveReader`.
public final class KaitoArchive {
    private enum Input {
        case file(url: URL, reportedFilename: String)
        case data(Data)
    }

    private static let zipLazyLocalHeaders = Mutex(true)

    private let input: Input
    private var options: ReaderOptions
    private var reader: ArchiveReader
    private var explicitlySelectedNameEncoding: String.Encoding?

    /// Receives the XADArchiveDelegate-shaped compatibility callbacks.
    ///
    /// XADMaster may consult its delegate during construction. KaitoKitCompat instead consults
    /// an assigned delegate immediately afterward and rebuilds when it selects another encoding;
    /// header-encrypted archives therefore still need the modern API for initialization callbacks.
    public weak var delegate: (any KaitoArchiveDelegate)? {
        didSet {
            consultDelegateForNameEncoding()
        }
    }

    /// The most recent compatibility-operation error.
    ///
    /// XADMaster commonly collapses failures into `nil` or `false`. KaitoKitCompat reproduces
    /// those return values and additionally retains the corresponding `KaitoError`; successful
    /// read, extraction, password, or encoding operations clear it.
    public private(set) var lastError: KaitoError?

    /// Reproduces XADMaster's process-wide ZIP lazy-local-header default.
    ///
    /// The value applies only to subsequently created archives, as in XADMaster. KaitoKitCompat
    /// additionally synchronizes concurrent reads and writes to this class property.
    public static var defaultZipLazyLocalHeaders: Bool {
        zipLazyLocalHeaders.withLock { $0 }
    }

    /// Reproduces XADMaster's setter for the ZIP lazy-local-header class default.
    ///
    /// The difference is that KaitoKitCompat synchronizes the process-wide value. Existing
    /// archive instances retain the option with which they were opened.
    public static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        zipLazyLocalHeaders.withLock { $0 = enabled }
    }

    /// Reproduces XADMaster's failable archive initializer for a file-system path.
    ///
    /// It returns `nil` for every open failure like XADMaster. Use `ArchiveReader.open(url:)`
    /// when the caller needs the opening error or a password provider for encrypted headers.
    public init?(file path: String) {
        let input = Input.file(
            url: URL(fileURLWithPath: path),
            reportedFilename: path
        )
        let options = ReaderOptions(
            lazyLocalHeaders: Self.defaultZipLazyLocalHeaders
        )
        guard let reader = try? Self.open(input, options: options) else { return nil }
        self.input = input
        self.options = options
        self.reader = reader
        explicitlySelectedNameEncoding = nil
        delegate = nil
        lastError = nil
    }

    /// Reproduces XADMaster's failable archive initializer for an in-memory `Data` value.
    ///
    /// KaitoKitCompat retains the `Data` so ``setNameEncoding(_:)`` can rebuild the reader.
    /// As with XADMaster's compatibility shape, open failures are represented by `nil`.
    public init?(data: Data) {
        let input = Input.data(data)
        let options = ReaderOptions(
            lazyLocalHeaders: Self.defaultZipLazyLocalHeaders
        )
        guard let reader = try? Self.open(input, options: options) else { return nil }
        self.input = input
        self.options = options
        self.reader = reader
        explicitlySelectedNameEncoding = nil
        delegate = nil
        lastError = nil
    }

    /// Reproduces XADMaster's failable file initializer with a URL-shaped Swift overload.
    ///
    /// Unlike the path initializer, this overload accepts only a file URL. The returned value is
    /// `nil` for non-file URLs and open failures; ``filename()`` reports the URL's path.
    public init?(fileURL: URL) {
        guard fileURL.isFileURL else { return nil }
        let input = Input.file(
            url: fileURL,
            reportedFilename: fileURL.path
        )
        let options = ReaderOptions(
            lazyLocalHeaders: Self.defaultZipLazyLocalHeaders
        )
        guard let reader = try? Self.open(input, options: options) else { return nil }
        self.input = input
        self.options = options
        self.reader = reader
        explicitlySelectedNameEncoding = nil
        delegate = nil
        lastError = nil
    }

    /// Reproduces XADMaster's entry count with its `Int32` compatibility width.
    ///
    /// `ArchiveReader.entries.count` remains the full-width Swift alternative. A count that cannot
    /// fit in `Int32` is clamped, though the default limits make that difference unreachable.
    public func numberOfEntries() -> Int32 {
        Int32(exactly: reader.entries.count) ?? Int32.max
    }

    /// Reproduces XADMaster's decoded display name and `nil` result for an invalid index.
    ///
    /// Directory names omit trailing `/` or `\\` in this facade, matching XADMaster. The modern
    /// `ArchiveEntry.name` keeps the format reader's original normalized directory spelling.
    public func name(ofEntry index: Int32) -> String? {
        guard let entry = checkedEntry(at: index) else { return nil }
        guard entry.kind == .directory else { return entry.name }

        var name = entry.name
        while name.last == "/" || name.last == "\\" {
            name.removeLast()
        }
        return name
    }

    /// Reproduces XADMaster's whole-entry `Data` read and `nil` failure result.
    ///
    /// KaitoKitCompat still applies `ReadLimits`, drains the decoder through completion, records
    /// ``lastError``, and sends delegate progress updates for each produced chunk.
    public func contents(ofEntry index: Int32) -> Data? {
        dataForEntry(index)
    }

    /// Reproduces XADMaster's alternate whole-entry data accessor.
    ///
    /// This is an alias of ``contents(ofEntry:)``. KaitoKitCompat differs only by retaining a
    /// typed ``lastError`` and enforcing the configured modern read limits.
    public func dataForEntry(_ index: Int32) -> Data? {
        readEntry(at: index)
    }

    /// Provides a Swift-label alias for XADMaster's whole-entry data accessor.
    ///
    /// It returns exactly the same data or `nil` as ``dataForEntry(_:)``; the additional spelling
    /// is a KaitoKitCompat convenience and was not a distinct XADMaster operation.
    public func data(forEntry index: Int32) -> Data? {
        dataForEntry(index)
    }

    /// Reproduces XADMaster's declared 64-bit uncompressed size.
    ///
    /// Unknown sizes use `Int64.max` and invalid indexes return zero, matching the compatibility
    /// behavior. The modern API represents unknown sizes as `nil` and uses `UInt64` otherwise.
    public func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard let entry = checkedEntry(at: index) else { return 0 }
        guard let size = entry.uncompressedSize else { return Int64.max }
        return Int64(exactly: size) ?? Int64.max
    }

    /// Reproduces XADMaster's distinction between a declared size and an unknown size.
    ///
    /// Invalid indexes return `false`; the modern equivalent is
    /// `ArchiveEntry.uncompressedSize != nil`.
    public func entryHasSize(_ index: Int32) -> Bool {
        checkedEntry(at: index)?.uncompressedSize != nil
    }

    /// Reproduces XADMaster's directory-entry query.
    ///
    /// Invalid indexes return `false`; the modern equivalent is `ArchiveEntry.kind == .directory`.
    public func entryIsDirectory(_ index: Int32) -> Bool {
        checkedEntry(at: index)?.kind == .directory
    }

    /// Reproduces XADMaster's link-entry query for symbolic and hard links.
    ///
    /// KaitoKit exposes the two cases separately as `.symlink` and `.hardlink`; this compatibility
    /// method combines them and returns `false` for an invalid index.
    public func entryIsLink(_ index: Int32) -> Bool {
        guard let kind = checkedEntry(at: index)?.kind else { return false }
        return kind == .symlink || kind == .hardlink
    }

    /// Reproduces XADMaster's resource-fork-entry query.
    ///
    /// KaitoKit does not publish resource forks as separate entries, so this deliberately returns
    /// `false` for every valid or invalid index.
    public func entryIsResourceFork(_ index: Int32) -> Bool {
        guard checkedEntry(at: index) != nil else { return false }
        return false
    }

    /// Reproduces XADMaster's per-entry encryption query.
    ///
    /// Invalid indexes return `false`; method details remain available only in modern metadata.
    public func entryIsEncrypted(_ index: Int32) -> Bool {
        checkedEntry(at: index)?.isEncrypted ?? false
    }

    /// Reproduces XADMaster's archive-wide encryption query.
    ///
    /// It examines published entries; archives whose headers require a password must still be
    /// opened with the modern API because this facade's failable initializer has no delegate yet.
    public func isEncrypted() -> Bool {
        reader.entries.contains { $0.isEncrypted }
    }

    /// Reproduces XADMaster's mutable password used by subsequent entry operations.
    ///
    /// KaitoKitCompat forwards it to the current `ArchiveReader`; changing it cannot recover a
    /// facade initializer that already returned `nil` for encrypted headers.
    public func setPassword(_ password: String?) {
        reader.password = password
        options.password = password
        lastError = nil
    }

    /// Reproduces the cooViewer XADMaster fork's solid-group identifier.
    ///
    /// `-1` means an independent or invalid entry. Unlike `entryIsSolid`, a nonnegative identifier
    /// describes the whole dependency group, including its first entry.
    public func solidGroup(ofEntry index: Int32) -> Int32 {
        guard let group = checkedEntry(at: index)?.solidGroup else { return -1 }
        return Int32(exactly: group) ?? -1
    }

    /// Reproduces XADMaster's file-attribute dictionary for an entry.
    ///
    /// KaitoKitCompat returns modification date and POSIX permissions when present plus `.type`.
    /// It omits XADMaster attributes that `ArchiveEntry` does not model and returns an empty
    /// dictionary for an invalid index while recording ``lastError``.
    public func attributesOfEntry(_ index: Int32) -> [FileAttributeKey: Any] {
        guard let entry = checkedEntry(at: index) else { return [:] }
        var attributes: [FileAttributeKey: Any] = [
            .type: fileAttributeType(for: entry.kind),
        ]
        if let date = entry.modificationDate {
            attributes[.modificationDate] = date
        }
        if let permissions = entry.posixPermissions {
            attributes[.posixPermissions] = NSNumber(value: permissions)
        }
        return attributes
    }

    /// Reproduces XADMaster's human-readable archive format name.
    ///
    /// KaitoKitCompat returns one stable container name and does not include parser subclass or
    /// compression-method details that some XADMaster format names contain.
    public func formatName() -> String {
        switch reader.format.rawValue {
        case "zip": "Zip"
        case "rar": "RAR"
        case "7z": "7-Zip"
        case "lha": "LHA"
        case "sit": "StuffIt"
        case "sitx": "StuffIt X"
        case "tar": "Tar"
        case "ar": "AR"
        case "cpio": "Cpio"
        case "xar": "XAR"
        case "cab": "CAB"
        case "rpm": "RPM"
        case "iso": "ISO 9660"
        case "gzip": "Gzip"
        case "bzip2": "Bzip2"
        case "xz": "XZ"
        case "zstd": "Zstandard"
        case "compress": "Compress"
        case "lzma": "LZMA_Alone"
        default: reader.format.rawValue
        }
    }

    /// Reproduces XADMaster's source filename accessor.
    ///
    /// File-backed instances return the supplied path spelling; Data-backed instances return
    /// `nil`, because KaitoKitCompat does not synthesize a filename for anonymous bytes.
    public func filename() -> String? {
        guard case let .file(_, reportedFilename) = input else { return nil }
        return reportedFilename
    }

    /// Returns the archive-wide name encoding in the XADMaster compatibility shape.
    ///
    /// Unlike XADMaster's nonoptional numeric default, `nil` means that no undecorated legacy name
    /// required a choice. An explicit ``setNameEncoding(_:)`` value is returned even when every
    /// name carries its own format-declared encoding.
    public var nameEncoding: String.Encoding? {
        explicitlySelectedNameEncoding ?? reader.nameEncoding
    }

    /// Reproduces XADMaster's ability to reinterpret undecorated entry names with one encoding.
    ///
    /// KaitoKitCompat maps this to `EncodingPolicy.fixed` and rebuilds the reader from the retained
    /// file URL or `Data`. If rebuilding fails, the previous entries remain available and
    /// ``lastError`` records the failure.
    public func setNameEncoding(_ encoding: String.Encoding) {
        var updatedOptions = options
        updatedOptions.encodingPolicy = .fixed(encoding)
        updatedOptions.password = reader.password
        do {
            let rebuilt = try Self.open(input, options: updatedOptions)
            reader = rebuilt
            options = updatedOptions
            explicitlySelectedNameEncoding = encoding
            lastError = nil
        } catch {
            record(error)
        }
    }

    /// Reproduces XADMaster's directory-based single-entry extraction and Boolean result.
    ///
    /// The `to:` path is always a directory. KaitoKitCompat retains modern path and metadata
    /// checks; tar hard-link dependencies are materialized within this call, so separate calls do
    /// not preserve inode identity. Failures set ``lastError``.
    public func extractEntry(_ index: Int32, to path: String) -> Bool {
        guard let entry = checkedEntry(at: index) else { return false }
        guard !path.isEmpty else {
            lastError = .notFound("empty extraction directory")
            return false
        }

        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL

        do {
            guard entry.kind == .hardlink else {
                try requestPasswordIfNeeded(for: entry)
                let extracted = try reader.extract(entry, to: destination)
                reportCompletedExtraction(entry, index: index, destination: extracted)
                lastError = nil
                return true
            }
            let result = try extractHardLink(entry, to: destination, fileManager: fileManager)
            if result {
                reportCompletedExtraction(entry, index: index, destination: nil)
                lastError = nil
            }
            return result
        } catch {
            record(error)
            return false
        }
    }

    private func extractHardLink(
        _ entry: ArchiveEntry,
        to destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard let extractionChain = extractionChain(for: entry) else {
            throw KaitoError.malformed("hard-link target chain is invalid")
        }
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let destinationDirectory = try ExtractionDirectoryAccess.openRoot(
            at: destination.path
        )
        defer { destinationDirectory.close() }
        let stagingLeaf = ".kaitokit-\(UUID().uuidString)"
        let staging = destination.appendingPathComponent(stagingLeaf, isDirectory: true)
        let stagingDirectory = try createPrivateStagingDirectory(
            named: stagingLeaf,
            below: destinationDirectory.descriptor
        )

        var extractionError: (any Error)?
        do {
            try makeStagingParentsAccessible(
                for: extractionChain,
                below: stagingDirectory.descriptor
            )
            var extracted: URL?
            for member in extractionChain {
                try requestPasswordIfNeeded(for: member)
                extracted = try reader.extract(member, to: staging)
            }
            guard let extracted else {
                throw KaitoError.malformed("hard-link extraction produced no destination")
            }
            try relocate(extracted, named: entry.name, below: destination)
        } catch {
            extractionError = error
        }

        // The private tree is deliberately left owner-accessible, so pathname-based
        // recursive removal remains usable even when the process umask created mode-000
        // extraction directories. Cleanup and destination-mode restoration are part of
        // a successful compatibility extraction rather than best-effort defers.
        stagingDirectory.close()
        var cleanupError: (any Error)?
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            cleanupError = error
        }
        var restorationError: (any Error)?
        do {
            try destinationDirectory.restoreMode()
        } catch {
            restorationError = error
        }
        if let cleanupError { throw cleanupError }
        if let restorationError { throw restorationError }
        if let extractionError { throw extractionError }
        return true
    }

    private func createPrivateStagingDirectory(
        named leaf: String,
        below destination: Int32
    ) throws -> ExtractionDirectoryHandle {
        guard Darwin.mkdirat(destination, leaf, mode_t(0o700)) == 0 else {
            throw KaitoError.io(errno)
        }
        do {
            let directory = try ExtractionDirectoryAccess.open(
                [leaf],
                below: destination,
                create: false
            )
            guard Darwin.fchmod(directory.descriptor, mode_t(0o700)) == 0 else {
                throw KaitoError.io(errno)
            }
            directory.keepCurrentMode()
            return directory
        } catch {
            _ = Darwin.unlinkat(destination, leaf, AT_REMOVEDIR)
            throw error
        }
    }

    private func makeStagingParentsAccessible(
        for extractionChain: [ArchiveEntry],
        below staging: Int32
    ) throws {
        for entry in extractionChain {
            let components = try safePathComponents(for: entry.name)
            for count in 1..<components.count {
                let directory = try ExtractionDirectoryAccess.open(
                    Array(components.prefix(count)),
                    below: staging,
                    create: true
                )
                defer { directory.close() }
                guard Darwin.fchmod(directory.descriptor, mode_t(0o700)) == 0 else {
                    throw KaitoError.io(errno)
                }
                directory.keepCurrentMode()
            }
        }
    }

    private func extractionChain(for entry: ArchiveEntry) -> [ArchiveEntry]? {
        guard entry.kind == .hardlink else { return [entry] }

        var reversedChain: [ArchiveEntry] = []
        var visited: Set<Int> = []
        var current = entry
        while current.kind == .hardlink {
            guard visited.insert(current.index).inserted,
                  let targetText = current.formatSpecific["hardLinkTargetIndex"],
                  let targetIndex = Int(targetText),
                  targetIndex >= 0,
                  targetIndex != current.index,
                  reader.entries.indices.contains(targetIndex) else {
                return nil
            }
            reversedChain.append(current)
            current = reader.entries[targetIndex]
        }
        guard current.kind == .file else { return nil }
        reversedChain.append(current)
        return Array(reversedChain.reversed())
    }

    private func relocate(
        _ source: URL,
        named name: String,
        below destination: URL
    ) throws {
        let components = try safePathComponents(for: name)
        let leaf = components[components.count - 1]

        let root = try ExtractionDirectoryAccess.openRoot(at: destination.path)
        defer { root.close() }
        let parent = try ExtractionDirectoryAccess.open(
            Array(components.dropLast()),
            below: root.descriptor,
            create: true
        )
        defer { parent.close() }

        let sourceParentURL = source.deletingLastPathComponent()
        let sourceParent = try ExtractionDirectoryAccess.openRoot(at: sourceParentURL.path)
        defer { sourceParent.close() }

        if Darwin.renameat(
            sourceParent.descriptor,
            source.lastPathComponent,
            parent.descriptor,
            leaf
        ) == 0 {
            try sourceParent.restoreMode()
            try parent.restoreMode()
            try root.restoreMode()
            return
        }
        let code = errno
        guard code == EXDEV else { throw KaitoError.io(code) }
        try KaitoArchiveFileRelocator.copyRegularFile(
            from: sourceParent.descriptor,
            sourceLeaf: source.lastPathComponent,
            to: parent.descriptor,
            destinationLeaf: leaf
        )
        try sourceParent.restoreMode()
        try parent.restoreMode()
        try root.restoreMode()
    }

    private func safePathComponents(for name: String) throws -> [String] {
        let rawComponents = name.utf8
            .split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !name.isEmpty,
              name.utf8.first != 0x2F,
              !name.utf8.contains(0),
              !rawComponents.contains("..") else {
            throw KaitoError.malformed("entry path is malformed")
        }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else {
            throw KaitoError.malformed("entry path is empty")
        }
        return components
    }

    private static func open(
        _ input: Input,
        options: ReaderOptions
    ) throws -> ArchiveReader {
        switch input {
        case let .file(url, _):
            try ArchiveReader.open(url: url, options: options)
        case let .data(data):
            try ArchiveReader.open(data: data, options: options)
        }
    }

    private func checkedEntry(at index: Int32) -> ArchiveEntry? {
        guard index >= 0 else {
            lastError = .notFound("archive entry index \(index)")
            return nil
        }
        let position = Int(index)
        guard reader.entries.indices.contains(position) else {
            lastError = .notFound("archive entry index \(index)")
            return nil
        }
        return reader.entries[position]
    }

    private func readEntry(at index: Int32) -> Data? {
        guard let entry = checkedEntry(at: index) else { return nil }
        do {
            try requestPasswordIfNeeded(for: entry)
            let stream = try reader.stream(entry)
            let data = try readAll(
                from: stream,
                entry: entry,
                compatibilityIndex: index
            )
            lastError = nil
            return data
        } catch {
            record(error)
            return nil
        }
    }

    private func readAll(
        from stream: EntryStream,
        entry: ArchiveEntry,
        compatibilityIndex: Int32
    ) throws -> Data {
        let total = compatibilitySize(entry.uncompressedSize)
        if let declaredSize = entry.uncompressedSize {
            try Checked.size(declaredSize, limit: options.limits.maxInMemorySize)
            let size = try Checked.toInt(declaredSize)
            if size == 0 {
                reportProgress(index: compatibilityIndex, bytes: 0, total: 0)
                return Data()
            }

            var result = Data(count: size)
            var written = 0
            try result.withUnsafeMutableBytes { storage in
                while written < size {
                    let upperBound = min(size, written + 256 * 1_024)
                    let destination = UnsafeMutableRawBufferPointer(
                        rebasing: storage[written..<upperBound]
                    )
                    let count = try stream.read(into: destination)
                    guard count > 0 else { throw KaitoError.truncated }
                    written += count
                    reportProgress(
                        index: compatibilityIndex,
                        bytes: Int64(written),
                        total: total
                    )
                }
            }
            return result
        }

        var result = Data()
        let initialCapacity = min(options.limits.maxInMemorySize, 256 * 1_024)
        result.reserveCapacity(try Checked.toInt(initialCapacity))
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            guard count > 0 else { break }
            let nextSize = try Checked.add(UInt64(result.count), UInt64(count))
            try Checked.size(nextSize, limit: options.limits.maxInMemorySize)
            result.append(contentsOf: buffer[..<count])
            reportProgress(
                index: compatibilityIndex,
                bytes: compatibilitySize(nextSize),
                total: total
            )
        }
        if result.isEmpty {
            reportProgress(index: compatibilityIndex, bytes: 0, total: total)
        }
        return result
    }

    private func requestPasswordIfNeeded(for entry: ArchiveEntry) throws {
        guard entry.isEncrypted, reader.password == nil else { return }
        delegate?.archiveNeedsPassword(self)
        guard reader.password != nil else { throw KaitoError.passwordRequired }
    }

    private func consultDelegateForNameEncoding() {
        guard explicitlySelectedNameEncoding == nil, let delegate else { return }
        guard let rawName = reader.entries.lazy.map(\.rawName).first(where: {
            $0.declaredEncoding == nil
                && !$0.bytes.isEmpty
                && String(data: Data($0.bytes), encoding: .utf8) == nil
        }) else {
            return
        }

        let detection = EncodingDetector.detect(bytes: rawName.bytes)
        let guess = reader.nameEncoding ?? detection.encoding
        guard let selected = delegate.archive(
            self,
            nameEncodingForData: Data(rawName.bytes),
            guess: guess,
            confidence: detection.confidence
        ), selected != reader.nameEncoding else {
            return
        }
        setNameEncoding(selected)
    }

    private func reportProgress(index: Int32, bytes: Int64, total: Int64) {
        delegate?.archive(
            self,
            extractionProgressForEntry: index,
            bytes: bytes,
            of: total
        )
    }

    private func reportCompletedExtraction(
        _ entry: ArchiveEntry,
        index: Int32,
        destination: URL?
    ) {
        let total = compatibilitySize(entry.uncompressedSize)
        let produced: Int64
        if let size = entry.uncompressedSize {
            produced = compatibilitySize(size)
        } else if let destination,
                  let attributes = try? FileManager.default.attributesOfItem(
                    atPath: destination.path
                  ),
                  let size = attributes[.size] as? NSNumber {
            produced = max(0, size.int64Value)
        } else {
            produced = 0
        }
        reportProgress(index: index, bytes: produced, total: total)
    }

    private func compatibilitySize(_ size: UInt64?) -> Int64 {
        guard let size else { return Int64.max }
        return Int64(exactly: size) ?? Int64.max
    }

    private func fileAttributeType(for kind: EntryKind) -> FileAttributeType {
        switch kind {
        case .directory:
            .typeDirectory
        case .symlink:
            .typeSymbolicLink
        case .file, .hardlink:
            .typeRegular
        case .other:
            .typeUnknown
        }
    }

    private func record(_ error: any Error) {
        if let error = error as? KaitoError {
            lastError = error
            return
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain {
            lastError = .io(Int32(clamping: cocoaError.code))
        } else {
            lastError = .malformed(cocoaError.localizedDescription)
        }
    }
}

/// Reproduces XADMaster's public archive type name for source-level migration.
///
/// This is a Swift type alias rather than a separate Objective-C runtime class; both spellings
/// therefore expose the same KaitoKitCompat behavior and differences documented above.
public typealias XADArchive = KaitoArchive
