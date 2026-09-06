import Darwin
import Foundation

struct ExtractedFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
}

struct ExtractionResult {
    let url: URL
    let fileIdentity: ExtractedFileIdentity?
}

enum Extractor {
    private static let copyBufferSize = 256 * 1024
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    static func extract(
        _ entry: ArchiveEntry,
        from reader: ArchiveReader,
        to directory: URL,
        options: ExtractionOptions,
        trustedTargets: [Int: ExtractedFileIdentity]
    ) throws -> ExtractionResult {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL
        let components = try safeComponents(
            for: entry.name,
            allowArchiveRoot: entry.kind == .directory
        )
        let destination = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        guard destination.path == root.path || isDescendant(destination, of: root),
              destination.path != root.path || entry.kind == .directory else {
            throw KaitoError.malformed("entry path escapes the extraction directory")
        }

        if entry.kind == .directory {
            // 暗号化ディレクトリも password / HMAC / CRC 検証を省略しない。
            // 展開ルートや中間ディレクトリを作る前に本体を最後まで消費する。
            try drain(reader.stream(entry))
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let rootDescriptor = Darwin.open(root.path, directoryOpenFlags)
        guard rootDescriptor >= 0 else { throw KaitoError.io(errno) }
        defer { _ = Darwin.close(rootDescriptor) }

        var extractedIdentity: ExtractedFileIdentity?
        switch entry.kind {
        case .directory:
            let descriptor = try openDirectory(
                components,
                below: rootDescriptor,
                create: true
            )
            defer { _ = Darwin.close(descriptor) }
            // `./` エントリは呼出側が所有する展開ルート自体の属性を変更しない。
            if !components.isEmpty {
                try restoreMetadata(
                    entry,
                    descriptor: descriptor,
                    options: options
                )
            }

        case .file:
            extractedIdentity = try extractRegularFile(
                entry,
                components: components,
                below: rootDescriptor,
                from: reader,
                options: options
            )

        case .symlink:
            guard options.createSymbolicLinks else {
                throw KaitoError.unsupportedMethod("symbolic-link extraction is disabled")
            }
            let parent = try openDirectory(
                Array(components.dropLast()),
                below: rootDescriptor,
                create: true
            )
            defer { _ = Darwin.close(parent) }
            let leaf = components[components.count - 1]
            let targetPath = try linkPath(for: entry, reader: reader)
            try validateSymbolicLinkTarget(targetPath, below: parent)
            try removeLeafIfRequested(leaf, below: parent, options: options)
            guard Darwin.symlinkat(targetPath, parent, leaf) == 0 else {
                throw KaitoError.io(errno)
            }

        case .hardlink:
            let targetPath = try linkPath(for: entry, reader: reader)
            let targetComponents = try safeRelativeLinkComponents(targetPath)
            let archivedTarget = try archivedHardLinkTarget(entry, in: reader)
            let archivedTargetComponents = try safeComponents(
                for: archivedTarget.name,
                allowArchiveRoot: false
            )
            guard archivedTargetComponents == targetComponents else {
                throw KaitoError.malformed("hard-link target does not match its archive member")
            }
            guard targetComponents != components else {
                throw KaitoError.malformed("hard-link target refers to itself")
            }
            let hasLinkData = entry.uncompressedSize ?? 0 > 0
            guard let trustedTargetIdentity = trustedTargets[archivedTarget.index] else {
                guard hasLinkData else {
                    throw KaitoError.malformed(
                        "hard-link target was not materialized by this archive reader"
                    )
                }
                // 単独展開では既存 inode を信用せず、pax linkdata を独立ファイルへ復元する。
                extractedIdentity = try extractRegularFile(
                    entry,
                    components: components,
                    below: rootDescriptor,
                    from: reader,
                    options: options
                )
                break
            }

            let destinationParent = try openDirectory(
                Array(components.dropLast()),
                below: rootDescriptor,
                create: true
            )
            defer { _ = Darwin.close(destinationParent) }
            let destinationLeaf = components[components.count - 1]

            let targetParent = try openDirectory(
                Array(targetComponents.dropLast()),
                below: rootDescriptor,
                create: false
            )
            defer { _ = Darwin.close(targetParent) }
            let targetLeaf = targetComponents[targetComponents.count - 1]
            let targetIdentity = try regularIdentity(targetLeaf, below: targetParent)
            guard targetIdentity == trustedTargetIdentity else {
                throw KaitoError.malformed(
                    "hard-link target was not created by this archive reader"
                )
            }
            if let destinationIdentity = try identityIfPresent(
                destinationLeaf,
                below: destinationParent
            ), destinationIdentity == targetIdentity {
                // 大文字小文字や Unicode 正規化が異なる同一パスも inode で検出する。
                throw KaitoError.malformed("hard-link target refers to its destination")
            }
            try removeLeafIfRequested(destinationLeaf, below: destinationParent, options: options)
            // 両親を O_NOFOLLOW で開いた dirfd に固定し、中間リンクの差替えを遮断する。
            guard Darwin.linkat(
                targetParent,
                targetLeaf,
                destinationParent,
                destinationLeaf,
                0
            ) == 0 else {
                throw KaitoError.io(errno)
            }
            do {
                guard try regularIdentity(
                    destinationLeaf,
                    below: destinationParent
                ) == targetIdentity else {
                    throw KaitoError.malformed("hard-link target changed during extraction")
                }
                if hasLinkData {
                    try replaceHardLinkedContents(
                        entry,
                        leaf: destinationLeaf,
                        below: destinationParent,
                        expectedIdentity: targetIdentity,
                        from: reader,
                        options: options
                    )
                }
                extractedIdentity = targetIdentity
            } catch {
                // 展開ルートは呼出側が排他的に所有する契約とし、linkat が作った葉を残さない。
                _ = Darwin.unlinkat(destinationParent, destinationLeaf, 0)
                throw error
            }

        case .other:
            throw KaitoError.unsupportedMethod("tar entry kind cannot be extracted")
        }
        return ExtractionResult(url: destination, fileIdentity: extractedIdentity)
    }

    private static func extractRegularFile(
        _ entry: ArchiveEntry,
        components: [String],
        below rootDescriptor: Int32,
        from reader: ArchiveReader,
        options: ExtractionOptions
    ) throws -> ExtractedFileIdentity {
        let parent = try openDirectory(
            Array(components.dropLast()),
            below: rootDescriptor,
            create: true
        )
        defer { _ = Darwin.close(parent) }
        let leaf = components[components.count - 1]
        // CRC/HMAC は stream 終端まで確定しない。既存 destination を先に消さず、
        // 同じ directory の一時 inode を完全検証してから不可分に公開する。
        let temporaryLeaf = ".kaitokit-\(UUID().uuidString)"
        let descriptor = Darwin.openat(
            parent,
            temporaryLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw KaitoError.io(errno) }
        var published = false
        defer {
            _ = Darwin.close(descriptor)
            if !published {
                _ = Darwin.unlinkat(parent, temporaryLeaf, 0)
            }
        }

        try write(reader.stream(entry), to: descriptor)
        try restoreMetadata(entry, descriptor: descriptor, options: options)
        let extractedIdentity = try regularIdentity(descriptor: descriptor)

        if options.overwriteExisting {
            // renameat は同一 directory 内の通常ファイル/リンク置換を不可分に行い、
            // directory は再帰削除せず失敗する。
            guard Darwin.renameat(parent, temporaryLeaf, parent, leaf) == 0 else {
                throw KaitoError.io(errno)
            }
        } else {
            // linkat は既存 leaf を置換しない。公開後に一時名だけを外す。
            guard Darwin.linkat(parent, temporaryLeaf, parent, leaf, 0) == 0 else {
                throw KaitoError.io(errno)
            }
            guard Darwin.unlinkat(parent, temporaryLeaf, 0) == 0 else {
                let code = errno
                _ = Darwin.unlinkat(parent, leaf, 0)
                throw KaitoError.io(code)
            }
        }
        published = true
        return extractedIdentity
    }

    private static func replaceHardLinkedContents(
        _ entry: ArchiveEntry,
        leaf: String,
        below parent: Int32,
        expectedIdentity: ExtractedFileIdentity,
        from reader: ArchiveReader,
        options: ExtractionOptions
    ) throws {
        let information = try regularStatus(leaf, below: parent)
        guard identity(from: information) == expectedIdentity else {
            throw KaitoError.malformed("hard-link destination changed before writing linkdata")
        }
        let originalMode = information.st_mode & mode_t(0o7777)
        let needsTemporaryWriteMode = originalMode & mode_t(S_IWUSR) == 0
        if needsTemporaryWriteMode {
            // leaf は検証済み dirfd 直下で、NOFOLLOW によりリンク差替えを追わない。
            guard Darwin.fchmodat(
                parent,
                leaf,
                originalMode | mode_t(S_IWUSR),
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw KaitoError.io(errno)
            }
            guard try regularIdentity(leaf, below: parent) == expectedIdentity else {
                throw KaitoError.malformed("hard-link destination changed while enabling writes")
            }
        }

        let descriptor = Darwin.openat(
            parent,
            leaf,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            if needsTemporaryWriteMode {
                _ = Darwin.fchmodat(parent, leaf, originalMode, AT_SYMLINK_NOFOLLOW)
            }
            throw KaitoError.io(code)
        }
        defer { _ = Darwin.close(descriptor) }
        var restoreOriginalMode = needsTemporaryWriteMode
        defer {
            if restoreOriginalMode {
                _ = Darwin.fchmod(descriptor, originalMode)
            }
        }
        guard try regularIdentity(descriptor: descriptor) == expectedIdentity else {
            throw KaitoError.malformed("hard-link destination changed before writing linkdata")
        }
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw KaitoError.io(errno)
        }
        try write(reader.stream(entry), to: descriptor)
        try restoreMetadata(entry, descriptor: descriptor, options: options)
        if needsTemporaryWriteMode, !options.preserveMetadata {
            guard Darwin.fchmod(descriptor, originalMode) == 0 else {
                throw KaitoError.io(errno)
            }
        }
        restoreOriginalMode = false
    }

    private static func safeComponents(
        for name: String,
        allowArchiveRoot: Bool
    ) throws -> [String] {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.utf8.contains(0) else {
            throw KaitoError.malformed("absolute or empty entry path")
        }
        let rawComponents = name
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !rawComponents.contains("..") else {
            throw KaitoError.malformed("entry path contains an unsafe component")
        }
        // POSIX tar が通常付ける先頭の `./` はルート指定として正規化する。
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty ? true : allowArchiveRoot else {
            throw KaitoError.malformed("empty entry path")
        }
        return components
    }

    private static func openDirectory(
        _ components: [String],
        below rootDescriptor: Int32,
        create: Bool
    ) throws -> Int32 {
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw KaitoError.io(errno) }

        do {
            for component in components {
                if create, Darwin.mkdirat(current, component, mode_t(0o700)) != 0,
                   errno != EEXIST {
                    throw KaitoError.io(errno)
                }
                let next = Darwin.openat(current, component, directoryOpenFlags)
                guard next >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw KaitoError.malformed(
                            "extraction path traverses a non-directory or symbolic link"
                        )
                    }
                    throw KaitoError.io(errno)
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func removeLeafIfRequested(
        _ leaf: String,
        below parent: Int32,
        options: ExtractionOptions
    ) throws {
        guard options.overwriteExisting else { return }
        if Darwin.unlinkat(parent, leaf, 0) != 0, errno != ENOENT {
            // unlinkat(flags: 0) はディレクトリを再帰削除せず安全に失敗する。
            throw KaitoError.io(errno)
        }
    }

    private static func write(_ stream: EntryStream, to descriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        while true {
            let count = try buffer.withUnsafeMutableBytes { storage -> Int in
                // 不変条件: storage は配列の全確保領域で、EntryStream はその範囲を越えて書かない。
                try stream.read(into: storage)
            }
            if count == 0 { break }

            var written = 0
            while written < count {
                let result: Int = buffer.withUnsafeBytes { storage in
                    // 不変条件: written..<count は直前に読み込んだ配列要素だけを指す。
                    guard let base = storage.baseAddress else { return -1 }
                    return Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw KaitoError.io(errno) }
                written += result
            }
        }
    }

    private static func drain(_ stream: EntryStream) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        while try buffer.withUnsafeMutableBytes({ storage in
            try stream.read(into: storage)
        }) > 0 {}
    }

    private static func linkPath(
        for entry: ArchiveEntry,
        reader: ArchiveReader
    ) throws -> String {
        let linkPath: String
        if let retained = entry.formatSpecific["linkPath"] {
            linkPath = retained
        } else if entry.kind == .symlink,
                  entry.formatSpecific["linkTargetStoredAsData"] == "true" {
            let bytes = try reader.read(entry)
            guard let decoded = String(data: bytes, encoding: .utf8) else {
                throw KaitoError.malformed("symbolic-link target is not valid UTF-8")
            }
            linkPath = decoded
        } else {
            throw KaitoError.malformed("link target is missing or absolute")
        }
        guard
              !linkPath.isEmpty,
              !linkPath.hasPrefix("/"),
              !linkPath.utf8.contains(0) else {
            throw KaitoError.malformed("link target is missing or absolute")
        }
        _ = try safeRelativeLinkComponents(linkPath)
        return linkPath
    }

    private static func safeRelativeLinkComponents(_ linkPath: String) throws -> [String] {
        let rawComponents = linkPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !rawComponents.isEmpty, !rawComponents.contains("..") else {
            throw KaitoError.malformed("link target contains an unsafe component")
        }
        let components = rawComponents.filter { $0 != "." }
        guard !components.isEmpty else {
            throw KaitoError.malformed("link target contains no file component")
        }
        return components
    }

    private static func archivedHardLinkTarget(
        _ entry: ArchiveEntry,
        in reader: ArchiveReader
    ) throws -> ArchiveEntry {
        // parser は各 target index を直前の正規化名へ結び、過去向きの file/link chain
        // だけを発行する。公開 entry の canonical 検証後なので、ここでは直近一段で十分。
        return try priorHardLinkTarget(of: entry, in: reader)
    }

    private static func priorHardLinkTarget(
        of entry: ArchiveEntry,
        in reader: ArchiveReader
    ) throws -> ArchiveEntry {
        guard let indexText = entry.formatSpecific["hardLinkTargetIndex"],
              let targetIndex = Int(indexText),
              targetIndex >= 0,
              targetIndex < entry.index,
              reader.entries.indices.contains(targetIndex) else {
            throw KaitoError.malformed("hard-link target is not a prior archive member")
        }
        return reader.entries[targetIndex]
    }

    private static func validateSymbolicLinkTarget(
        _ linkPath: String,
        below parent: Int32
    ) throws {
        let components = try safeRelativeLinkComponents(linkPath)
        var current = Darwin.dup(parent)
        guard current >= 0 else { throw KaitoError.io(errno) }
        defer { _ = Darwin.close(current) }

        for component in components.dropLast() {
            let next = Darwin.openat(current, component, directoryOpenFlags)
            if next < 0, errno == ENOENT {
                // まだ存在しない相対ターゲットも、`..` が無いため字句上はルート内に留まる。
                return
            }
            guard next >= 0 else {
                throw KaitoError.malformed(
                    "symbolic-link target traverses a non-directory or symbolic link"
                )
            }
            _ = Darwin.close(current)
            current = next
        }

        let leaf = components[components.count - 1]
        var information = stat()
        // information は fstatat 完了まで有効で、AT_SYMLINK_NOFOLLOW によりリンクを追わない。
        if Darwin.fstatat(current, leaf, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (information.st_mode & S_IFMT) != S_IFLNK else {
                throw KaitoError.malformed("symbolic-link target resolves through another link")
            }
        } else if errno != ENOENT {
            throw KaitoError.io(errno)
        }
    }

    private static func regularIdentity(
        _ leaf: String,
        below parent: Int32
    ) throws -> ExtractedFileIdentity {
        identity(from: try regularStatus(leaf, below: parent))
    }

    private static func regularStatus(
        _ leaf: String,
        below parent: Int32
    ) throws -> stat {
        var information = stat()
        // AT_SYMLINK_NOFOLLOW によりリンク自身を検査し、FIFO を開いて停止しない。
        guard Darwin.fstatat(parent, leaf, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw KaitoError.malformed("hard-link target is not a regular file")
        }
        return information
    }

    private static func regularIdentity(
        descriptor: Int32
    ) throws -> ExtractedFileIdentity {
        var information = stat()
        // descriptor は呼出側が保持し、fstat 完了まで閉じられない。
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw KaitoError.malformed("extracted object is not a regular file")
        }
        return identity(from: information)
    }

    private static func identityIfPresent(
        _ leaf: String,
        below parent: Int32
    ) throws -> ExtractedFileIdentity? {
        var information = stat()
        if Darwin.fstatat(parent, leaf, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            return identity(from: information)
        }
        if errno == ENOENT { return nil }
        throw KaitoError.io(errno)
    }

    private static func identity(from information: stat) -> ExtractedFileIdentity {
        ExtractedFileIdentity(
            device: information.st_dev,
            inode: information.st_ino,
            generation: information.st_gen
        )
    }

    private static func restoreMetadata(
        _ entry: ArchiveEntry,
        descriptor: Int32,
        options: ExtractionOptions
    ) throws {
        guard options.preserveMetadata else { return }
        if let permissions = entry.posixPermissions,
           Darwin.fchmod(descriptor, mode_t(permissions)) != 0 {
            throw KaitoError.io(errno)
        }
        if let date = entry.modificationDate {
            let interval = date.timeIntervalSince1970
            let integral = interval.rounded(.down)
            guard interval.isFinite,
                  let seconds = Int(exactly: integral) else {
                throw KaitoError.malformed("entry modification time is out of range")
            }
            let fractional = interval - integral
            let nanoseconds = min(
                999_999_999,
                max(0, Int((fractional * 1_000_000_000).rounded(.down)))
            )
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(tv_sec: seconds, tv_nsec: nanoseconds),
            ]
            // futimens は二要素の配列を呼び出し中だけ参照し、固定済み fd の属性だけを変える。
            guard Darwin.futimens(descriptor, &times) == 0 else {
                throw KaitoError.io(errno)
            }
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        // 呼出側で同じ root から組み立てて標準化済み。存在する root だけを再標準化すると、
        // `/private/tmp` のような symlink prefix が未作成の leaf と非対称に解決され得る。
        let rootPath = root.path
        let candidatePath = candidate.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

}
