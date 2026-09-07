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

/// A thin, failure-tolerant compatibility facade for the XADArchive surface used by cooViewer.
///
/// It reproduces optional construction, `Int32` entry indexes, optional names and contents,
/// boolean extraction results, mutable passwords, and independent/solid group reporting.
/// Detailed errors and streaming are intentionally available only through `ArchiveReader`.
public final class KaitoArchive {
    private static let zipLazyLocalHeaders = Mutex(true)

    private let reader: ArchiveReader

    /// Whether newly opened ZIP archives defer local-header validation until first read.
    ///
    /// This process-wide default is concurrency-safe and initially `true`. Use
    /// ``setDefaultZipLazyLocalHeaders(_:)`` to change it for subsequently created archives.
    public static var defaultZipLazyLocalHeaders: Bool {
        zipLazyLocalHeaders.withLock { $0 }
    }

    /// Changes local-header validation behavior for subsequently opened ZIP archives.
    public static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) {
        zipLazyLocalHeaders.withLock { $0 = enabled }
    }

    /// Opens an archive at a file-system path, returning `nil` when it cannot be opened.
    public init?(file path: String) {
        do {
            reader = try ArchiveReader.open(
                url: URL(fileURLWithPath: path),
                options: ReaderOptions(
                    lazyLocalHeaders: Self.defaultZipLazyLocalHeaders
                )
            )
        } catch {
            return nil
        }
    }

    /// Opens an archive backed by `Data`, returning `nil` when it cannot be opened.
    public init?(data: Data) {
        do {
            reader = try ArchiveReader.open(
                data: data,
                options: ReaderOptions(
                    lazyLocalHeaders: Self.defaultZipLazyLocalHeaders
                )
            )
        } catch {
            return nil
        }
    }

    /// Returns the number of archive entries using the XADArchive-compatible integer width.
    public func numberOfEntries() -> Int32 {
        Int32(exactly: reader.entries.count) ?? Int32.max
    }

    /// Returns the decoded name for an entry, or `nil` for an invalid index.
    public func name(ofEntry index: Int32) -> String? {
        guard let entry = entry(at: index) else { return nil }
        guard entry.kind == .directory else { return entry.name }

        var name = entry.name
        while name.last == "/" || name.last == "\\" {
            name.removeLast()
        }
        return name
    }

    /// Reads an entry completely, returning `nil` for an invalid index or read failure.
    public func contents(ofEntry index: Int32) -> Data? {
        guard let entry = entry(at: index) else { return nil }
        return try? reader.read(entry)
    }

    /// Returns the declared uncompressed size.
    ///
    /// Unknown sizes use `Int64.max`, matching XADMaster. Invalid indexes return zero.
    public func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard let entry = entry(at: index) else { return 0 }
        guard let size = entry.uncompressedSize else { return Int64.max }
        return Int64(exactly: size) ?? Int64.max
    }

    /// Reports whether an entry declares an uncompressed size.
    public func entryHasSize(_ index: Int32) -> Bool {
        entry(at: index)?.uncompressedSize != nil
    }

    /// Reports whether an entry is a directory.
    public func entryIsDirectory(_ index: Int32) -> Bool {
        entry(at: index)?.kind == .directory
    }

    /// Reports whether an entry is encrypted.
    public func entryIsEncrypted(_ index: Int32) -> Bool {
        entry(at: index)?.isEncrypted ?? false
    }

    /// Reports whether any archive entry is encrypted.
    public func isEncrypted() -> Bool {
        reader.entries.contains { $0.isEncrypted }
    }

    /// Sets or clears the password used by later reads and extraction operations.
    public func setPassword(_ password: String?) {
        reader.password = password
    }

    /// Returns an entry's solid group, or `-1` for an invalid or independent entry.
    public func solidGroup(ofEntry index: Int32) -> Int32 {
        guard let group = entry(at: index)?.solidGroup else { return -1 }
        return Int32(exactly: group) ?? -1
    }

    /// Extracts an entry below the destination directory and reports success.
    ///
    /// Tar hard-link dependencies are materialized within this call; separate
    /// calls do not preserve inode identity with one another.
    public func extractEntry(_ index: Int32, to path: String) -> Bool {
        guard let entry = entry(at: index), !path.isEmpty else { return false }

        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL

        do {
            guard entry.kind == .hardlink else {
                _ = try reader.extract(entry, to: destination)
                return true
            }
            return try extractHardLink(entry, to: destination, fileManager: fileManager)
        } catch {
            return false
        }
    }

    private func extractHardLink(
        _ entry: ArchiveEntry,
        to destination: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard let extractionChain = extractionChain(for: entry) else {
            return false
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
                  targetIndex < current.index,
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
        let rawComponents = name
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !name.isEmpty,
              !name.hasPrefix("/"),
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

    private func entry(at index: Int32) -> ArchiveEntry? {
        guard index >= 0 else { return nil }
        let position = Int(index)
        guard reader.entries.indices.contains(position) else { return nil }
        return reader.entries[position]
    }
}

/// A source-compatible type name for the supported XADArchive surface.
public typealias XADArchive = KaitoArchive
