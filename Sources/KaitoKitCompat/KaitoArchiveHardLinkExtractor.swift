private import Darwin
import Foundation
import KaitoKit

/// tar の hard link を、参照先の実体から順に非公開の staging directory へ展開し、所定の名前へ移す。
///
/// 展開先の直下に owner だけが入れる staging を作り、連鎖の各 member をそこへ展開してから最後の file を
/// 目的の名前へ renameat（別 volume なら ``KaitoArchiveFileRelocator`` で複写）する。staging の削除と
/// 展開先の mode の復元は成功の一部として行う。別々の呼出しの間では inode を共有しない。
struct KaitoArchiveHardLinkExtractor {
    /// 参照先の index を解決する entry 列。
    let entries: [ArchiveEntry]
    /// 連鎖の一 member を staging へ展開し、書いた位置を返す。暗号化 entry の password 要求も含む。
    let extractMember: (ArchiveEntry, URL) throws -> URL

    func extract(
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
                extracted = try extractMember(member, staging)
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
            let components = try Extractor.safeComponents(for: entry.name, allowArchiveRoot: false)
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
                  entries.indices.contains(targetIndex) else {
                return nil
            }
            reversedChain.append(current)
            current = entries[targetIndex]
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
        let components = try Extractor.safeComponents(for: name, allowArchiveRoot: false)
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
}
