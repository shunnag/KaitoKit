private import Darwin
import Foundation
import KaitoKit
import Synchronization

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
        entry(at: index)?.name
    }

    /// Reads an entry completely, returning `nil` for an invalid index or read failure.
    public func contents(ofEntry index: Int32) -> Data? {
        guard let entry = entry(at: index) else { return nil }
        return try? reader.read(entry)
    }

    /// Returns the declared uncompressed size, or zero when it is unknown or invalid.
    public func uncompressedSize(ofEntry index: Int32) -> Int64 {
        guard let size = entry(at: index)?.uncompressedSize else { return 0 }
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

    /// Extracts an entry to the exact destination path and reports success.
    ///
    /// Tar hard-link dependencies are materialized within this call; separate
    /// calls do not preserve inode identity with one another.
    public func extractEntry(_ index: Int32, to path: String) -> Bool {
        guard let entry = entry(at: index), !path.isEmpty else { return false }

        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".kaitokit-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            guard let extractionChain = extractionChain(for: entry) else {
                return false
            }
            var extracted: URL?
            for member in extractionChain {
                extracted = try reader.extract(member, to: staging)
            }
            guard let extracted else { return false }
            try validateRelocatedSymbolicLink(entry, below: parent)
            // rename(2) は通常ファイル・リンクの置換を不可分に行い、既存ディレクトリを
            // 再帰削除しない。staging は destination と同じ親なので EXDEV にもならない。
            guard Darwin.rename(extracted.path, destination.path) == 0 else {
                return false
            }
            return true
        } catch {
            return false
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

    private func validateRelocatedSymbolicLink(
        _ entry: ArchiveEntry,
        below destinationParent: URL
    ) throws {
        guard entry.kind == .symlink else { return }
        let target: String?
        if let storedTarget = entry.formatSpecific["linkPath"] {
            target = storedTarget
        } else if entry.formatSpecific["linkTargetStoredAsData"] == "true" {
            target = String(data: try reader.read(entry), encoding: .utf8)
        } else {
            target = nil
        }
        guard let target,
              !target.isEmpty,
              !target.hasPrefix("/"),
              !target.utf8.contains(0) else {
            throw KaitoError.malformed("link target is missing or absolute")
        }
        let rawComponents = target
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !rawComponents.isEmpty, !rawComponents.contains("..") else {
            throw KaitoError.malformed("link target contains an unsafe component")
        }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else {
            throw KaitoError.malformed("link target contains no file component")
        }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = Darwin.open(destinationParent.path, flags)
        guard current >= 0 else { throw KaitoError.io(errno) }
        defer { _ = Darwin.close(current) }

        for component in components.dropLast() {
            let next = Darwin.openat(current, component, flags)
            if next < 0, errno == ENOENT {
                // 未作成の相対部分は `..` を含まず、現時点では親の外へ解決しない。
                return
            }
            guard next >= 0 else {
                throw KaitoError.malformed(
                    "relocated symbolic-link target traverses a link or non-directory"
                )
            }
            _ = Darwin.close(current)
            current = next
        }

        var information = stat()
        let leaf = components[components.count - 1]
        // AT_SYMLINK_NOFOLLOW により、移動先側の既存 target link 自体を検査する。
        if Darwin.fstatat(current, leaf, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (information.st_mode & S_IFMT) != S_IFLNK else {
                throw KaitoError.malformed(
                    "relocated symbolic-link target resolves through another link"
                )
            }
        } else if errno != ENOENT {
            throw KaitoError.io(errno)
        }
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
