import Darwin
import Foundation

package final class ExtractionDirectoryHandle {
    package let descriptor: Int32

    private var modeToRestore: mode_t?
    private var isClosed = false

    fileprivate init(descriptor: Int32, modeToRestore: mode_t?) {
        self.descriptor = descriptor
        self.modeToRestore = modeToRestore
    }

    package func restoreMode() throws {
        guard let modeToRestore else { return }
        guard Darwin.fchmod(descriptor, modeToRestore) == 0 else {
            throw KaitoError.io(errno)
        }
        self.modeToRestore = nil
    }

    package func keepCurrentMode() {
        modeToRestore = nil
    }

    package func close() {
        guard !isClosed else { return }
        if let modeToRestore {
            _ = Darwin.fchmod(descriptor, modeToRestore)
        }
        _ = Darwin.close(descriptor)
        self.modeToRestore = nil
        isClosed = true
    }

    deinit {
        close()
    }
}

package enum ExtractionDirectoryAccess {
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let permissionBits = mode_t(0o7777)
    private static let temporaryOwnerAccess = mode_t(0o700)

    package static func openRoot(at path: String) throws -> ExtractionDirectoryHandle {
        let descriptor = Darwin.open(path, openFlags)
        if descriptor >= 0 {
            return try makeAccessible(descriptor)
        }

        let openError = errno
        guard openError == EACCES else {
            throw directoryOpenError(openError)
        }

        var information = stat()
        guard Darwin.lstat(path, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw KaitoError.malformed(
                "extraction path traverses a non-directory or symbolic link"
            )
        }
        guard information.st_uid == Darwin.geteuid() else {
            throw KaitoError.io(openError)
        }

        let originalMode = information.st_mode & permissionBits
        guard Darwin.chmod(path, originalMode | temporaryOwnerAccess) == 0 else {
            throw KaitoError.io(errno)
        }
        let retry = Darwin.open(path, openFlags)
        guard retry >= 0 else {
            let retryError = errno
            _ = Darwin.chmod(path, originalMode)
            throw directoryOpenError(retryError)
        }
        do {
            try validateDirectory(retry)
            return ExtractionDirectoryHandle(
                descriptor: retry,
                modeToRestore: originalMode
            )
        } catch {
            _ = Darwin.fchmod(retry, originalMode)
            _ = Darwin.close(retry)
            throw error
        }
    }

    package static func open(
        _ components: [String],
        below rootDescriptor: Int32,
        create: Bool
    ) throws -> ExtractionDirectoryHandle {
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw KaitoError.io(errno) }
        var currentModeToRestore: mode_t?

        do {
            for component in components {
                // openat の一回分は必ず単一成分。結合文字を含む / を書記素として扱わない。
                guard !component.isEmpty, !component.utf8.contains(0), !component.utf8.contains(0x2F) else {
                    throw KaitoError.malformed("extraction directory component contains a separator")
                }
                if create, Darwin.mkdirat(current, component, mode_t(0o777)) != 0,
                   errno != EEXIST {
                    throw KaitoError.io(errno)
                }

                let next = try openComponent(component, below: current)
                do {
                    try restore(currentModeToRestore, on: current)
                } catch {
                    if let mode = next.modeToRestore {
                        _ = Darwin.fchmod(next.descriptor, mode)
                    }
                    _ = Darwin.close(next.descriptor)
                    throw error
                }
                _ = Darwin.close(current)
                current = next.descriptor
                currentModeToRestore = next.modeToRestore
            }
            return ExtractionDirectoryHandle(
                descriptor: current,
                modeToRestore: currentModeToRestore
            )
        } catch {
            if let currentModeToRestore {
                _ = Darwin.fchmod(current, currentModeToRestore)
            }
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func makeAccessible(
        _ descriptor: Int32
    ) throws -> ExtractionDirectoryHandle {
        let accessible = try makeAccessibleDescriptor(descriptor)
        return ExtractionDirectoryHandle(
            descriptor: accessible.descriptor,
            modeToRestore: accessible.modeToRestore
        )
    }

    private static func openComponent(
        _ component: String,
        below parent: Int32
    ) throws -> (descriptor: Int32, modeToRestore: mode_t?) {
        let descriptor = Darwin.openat(parent, component, openFlags)
        if descriptor >= 0 {
            return try makeAccessibleDescriptor(descriptor)
        }

        let openError = errno
        guard openError == EACCES else {
            throw directoryOpenError(openError)
        }

        var information = stat()
        guard Darwin.fstatat(parent, component, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw KaitoError.malformed(
                "extraction path traverses a non-directory or symbolic link"
            )
        }
        guard information.st_uid == Darwin.geteuid() else {
            throw KaitoError.io(openError)
        }

        let originalMode = information.st_mode & permissionBits
        guard Darwin.fchmodat(
            parent,
            component,
            originalMode | temporaryOwnerAccess,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw KaitoError.io(errno)
        }
        let retry = Darwin.openat(parent, component, openFlags)
        guard retry >= 0 else {
            let retryError = errno
            _ = Darwin.fchmodat(parent, component, originalMode, AT_SYMLINK_NOFOLLOW)
            throw directoryOpenError(retryError)
        }
        do {
            try validateDirectory(retry)
            return (retry, originalMode)
        } catch {
            _ = Darwin.fchmod(retry, originalMode)
            _ = Darwin.close(retry)
            throw error
        }
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw KaitoError.io(errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw KaitoError.malformed(
                "extraction path traverses a non-directory or symbolic link"
            )
        }
    }

    private static func restore(_ mode: mode_t?, on descriptor: Int32) throws {
        guard let mode else { return }
        guard Darwin.fchmod(descriptor, mode) == 0 else {
            throw KaitoError.io(errno)
        }
    }

    private static func directoryOpenError(_ code: Int32) -> KaitoError {
        if code == ELOOP || code == ENOTDIR {
            return KaitoError.malformed(
                "extraction path traverses a non-directory or symbolic link"
            )
        }
        return KaitoError.io(code)
    }

    private static func makeAccessibleDescriptor(
        _ descriptor: Int32
    ) throws -> (descriptor: Int32, modeToRestore: mode_t?) {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw KaitoError.io(code)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw KaitoError.malformed(
                "extraction path traverses a non-directory or symbolic link"
            )
        }

        let originalMode = information.st_mode & permissionBits
        guard information.st_uid == Darwin.geteuid(),
              originalMode & temporaryOwnerAccess != temporaryOwnerAccess else {
            return (descriptor, nil)
        }
        guard Darwin.fchmod(descriptor, originalMode | temporaryOwnerAccess) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw KaitoError.io(code)
        }
        return (descriptor, originalMode)
    }
}

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

        let rootDirectory = try ExtractionDirectoryAccess.openRoot(at: root.path)
        defer { rootDirectory.close() }
        let rootDescriptor = rootDirectory.descriptor

        var extractedIdentity: ExtractedFileIdentity?
        switch entry.kind {
        case .directory:
            let directory = try ExtractionDirectoryAccess.open(
                components,
                below: rootDescriptor,
                create: true
            )
            defer { directory.close() }
            // `./` エントリは呼出側が所有する展開ルート自体の属性を変更しない。
            if !components.isEmpty {
                try restoreMetadata(
                    entry,
                    descriptor: directory.descriptor,
                    options: options
                )
                if options.preserveMetadata, entry.posixPermissions != nil {
                    directory.keepCurrentMode()
                } else {
                    try directory.restoreMode()
                }
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
            let parent = try ExtractionDirectoryAccess.open(
                Array(components.dropLast()),
                below: rootDescriptor,
                create: true
            )
            defer { parent.close() }
            let leaf = components[components.count - 1]
            let targetPath = try linkPath(for: entry, reader: reader)
            try validateSymbolicLinkTarget(
                targetPath, parentComponents: Array(components.dropLast()), below: rootDescriptor
            )
            try removeLeafIfRequested(leaf, below: parent.descriptor, options: options)
            guard Darwin.symlinkat(targetPath, parent.descriptor, leaf) == 0 else {
                throw KaitoError.io(errno)
            }
            try parent.restoreMode()

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
            let hasLinkData = (entry.compressedSize ?? entry.uncompressedSize ?? 0) > 0
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

            let destinationParent = try ExtractionDirectoryAccess.open(
                Array(components.dropLast()),
                below: rootDescriptor,
                create: true
            )
            defer { destinationParent.close() }
            let destinationLeaf = components[components.count - 1]

            let targetParent = try ExtractionDirectoryAccess.open(
                Array(targetComponents.dropLast()),
                below: rootDescriptor,
                create: false
            )
            defer { targetParent.close() }
            let targetLeaf = targetComponents[targetComponents.count - 1]
            let targetIdentity = try regularIdentity(
                targetLeaf,
                below: targetParent.descriptor
            )
            guard targetIdentity == trustedTargetIdentity else {
                throw KaitoError.malformed(
                    "hard-link target was not created by this archive reader"
                )
            }
            if let destinationIdentity = try identityIfPresent(
                destinationLeaf,
                below: destinationParent.descriptor
            ), destinationIdentity == targetIdentity {
                // 大文字小文字や Unicode 正規化が異なる同一パスも inode で検出する。
                throw KaitoError.malformed("hard-link target refers to its destination")
            }
            try removeLeafIfRequested(
                destinationLeaf,
                below: destinationParent.descriptor,
                options: options
            )
            // 両親を O_NOFOLLOW で開いた dirfd に固定し、中間リンクの差替えを遮断する。
            guard Darwin.linkat(
                targetParent.descriptor,
                targetLeaf,
                destinationParent.descriptor,
                destinationLeaf,
                0
            ) == 0 else {
                throw KaitoError.io(errno)
            }
            do {
                guard try regularIdentity(
                    destinationLeaf,
                    below: destinationParent.descriptor
                ) == targetIdentity else {
                    throw KaitoError.malformed("hard-link target changed during extraction")
                }
                if hasLinkData {
                    try replaceHardLinkedContents(
                        entry,
                        leaf: destinationLeaf,
                        below: destinationParent.descriptor,
                        expectedIdentity: targetIdentity,
                        from: reader,
                        options: options
                    )
                }
                extractedIdentity = targetIdentity
                try targetParent.restoreMode()
                try destinationParent.restoreMode()
            } catch {
                // 展開ルートは呼出側が排他的に所有する契約とし、linkat が作った葉を残さない。
                _ = Darwin.unlinkat(destinationParent.descriptor, destinationLeaf, 0)
                throw error
            }

        case .other:
            if entry.formatSpecific["redirectionType"] == "5" {
                throw KaitoError.unsupportedMethod("RAR5 file-copy redirection")
            }
            throw KaitoError.unsupportedMethod("tar entry kind cannot be extracted")
        }
        try rootDirectory.restoreMode()
        return ExtractionResult(url: destination, fileIdentity: extractedIdentity)
    }

    private static func extractRegularFile(
        _ entry: ArchiveEntry,
        components: [String],
        below rootDescriptor: Int32,
        from reader: ArchiveReader,
        options: ExtractionOptions
    ) throws -> ExtractedFileIdentity {
        let parent = try ExtractionDirectoryAccess.open(
            Array(components.dropLast()),
            below: rootDescriptor,
            create: true
        )
        defer { parent.close() }
        let leaf = components[components.count - 1]
        // CRC/HMAC は stream 終端まで確定しない。既存 destination を先に消さず、
        // 同じ directory の一時 inode を完全検証してから不可分に公開する。
        let temporaryLeaf = ".kaitokit-\(UUID().uuidString)"
        let descriptor = Darwin.openat(
            parent.descriptor,
            temporaryLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o666)
        )
        guard descriptor >= 0 else { throw KaitoError.io(errno) }
        var published = false
        defer {
            _ = Darwin.close(descriptor)
            if !published {
                _ = Darwin.unlinkat(parent.descriptor, temporaryLeaf, 0)
            }
        }

        try write(reader.stream(entry), to: descriptor)
        try restoreMetadata(entry, descriptor: descriptor, options: options)
        let extractedIdentity = try regularIdentity(descriptor: descriptor)

        if options.overwriteExisting {
            // renameat は同一 directory 内の通常ファイル/リンク置換を不可分に行い、
            // directory は再帰削除せず失敗する。
            guard Darwin.renameat(
                parent.descriptor,
                temporaryLeaf,
                parent.descriptor,
                leaf
            ) == 0 else {
                throw KaitoError.io(errno)
            }
        } else {
            // linkat は既存 leaf を置換しない。公開後に一時名だけを外す。
            guard Darwin.linkat(
                parent.descriptor,
                temporaryLeaf,
                parent.descriptor,
                leaf,
                0
            ) == 0 else {
                throw KaitoError.io(errno)
            }
            guard Darwin.unlinkat(parent.descriptor, temporaryLeaf, 0) == 0 else {
                let code = errno
                _ = Darwin.unlinkat(parent.descriptor, leaf, 0)
                throw KaitoError.io(code)
            }
        }
        published = true
        try parent.restoreMode()
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
              name.utf8.first != 0x2F,
              !name.utf8.contains(0) else {
            throw KaitoError.malformed("absolute or empty entry path")
        }
        let rawComponents = name
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
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
              linkPath.utf8.first != 0x2F,
              !linkPath.utf8.contains(0) else {
            throw KaitoError.malformed("link target is missing or absolute")
        }
        if entry.kind == .hardlink { _ = try safeRelativeLinkComponents(linkPath) }
        return linkPath
    }

    private static func safeRelativeLinkComponents(_ linkPath: String) throws -> [String] {
        let rawComponents = linkPath
            .utf8.split(separator: 0x2F, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
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
        // xar の前方参照も許すが、実際の link には同じ reader が展開した inode を要求する。
        guard let indexText = entry.formatSpecific["hardLinkTargetIndex"],
              let targetIndex = Int(indexText),
              targetIndex >= 0,
              targetIndex != entry.index,
              reader.entries.indices.contains(targetIndex) else {
            throw KaitoError.malformed("hard-link target is not a distinct archive member")
        }
        return reader.entries[targetIndex]
    }

    private static func validateSymbolicLinkTarget(
        _ linkPath: String,
        parentComponents: [String],
        below root: Int32
    ) throws {
        // まず全体の深さを検査し、途中でも root より上へ出ないことを保証する。
        // 実際の walk では a/.. を消さず、a が既存 symlink なら必ず拒否する。
        let relative = linkPath.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }.filter { $0 != "." }
        var depth = parentComponents.count
        for component in relative {
            if component == ".." {
                guard depth > 0 else {
                    throw KaitoError.malformed("symbolic-link target escapes the extraction directory")
                }
                depth -= 1
            } else {
                depth += 1
            }
        }
        let components = parentComponents + relative
        guard !components.isEmpty else { return }
        if let lastDotDot = components.lastIndex(of: "..") {
            // 最後の .. までの実 directory を固定する。未作成部分を許すと、後続
            // entry がそこを symlink にして a/.. の意味を変えられる。
            let prefix: ExtractionDirectoryHandle
            do {
                prefix = try ExtractionDirectoryAccess.open(
                    Array(components[...lastDotDot]), below: root, create: false
                )
            } catch KaitoError.io(let code) where code == ENOENT {
                throw KaitoError.malformed("symbolic-link target escapes the extraction directory")
            }
            defer { prefix.close() }
            try prefix.restoreMode()
        }
        let targetParent: ExtractionDirectoryHandle
        do {
            targetParent = try ExtractionDirectoryAccess.open(
                Array(components.dropLast()),
                below: root,
                create: false
            )
        } catch KaitoError.io(let code) where code == ENOENT {
            // 最後の .. より後だけは未作成でもよい。前方参照を許し、親走査の
            // 意味を後続 entry が変更できないことは上の実 directory walk で確認する。
            return
        }
        defer { targetParent.close() }

        let leaf = components[components.count - 1]
        var information = stat()
        // information は fstatat 完了まで有効で、AT_SYMLINK_NOFOLLOW によりリンクを追わない。
        if Darwin.fstatat(
            targetParent.descriptor,
            leaf,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard (information.st_mode & S_IFMT) != S_IFLNK else {
                throw KaitoError.malformed("symbolic-link target resolves through another link")
            }
        } else if errno != ENOENT && errno != ENAMETOOLONG {
            // An overlong leaf cannot exist, including as a symlink. ENOTDIR
            // remains fatal: the parent is an open directory and the leaf has
            // no separators, so it would violate the validated walk's assumptions.
            throw KaitoError.io(errno)
        }
        try targetParent.restoreMode()
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
        if options.preserveMetadata,
           let permissions = entry.posixPermissions,
           Darwin.fchmod(descriptor, mode_t(permissions)) != 0 {
            throw KaitoError.io(errno)
        }
        guard options.preserveMetadata else { return }
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
        // パス境界は書記素境界ではない。先頭の結合文字が直前の / と結合しても同じ子である。
        return candidatePath.utf8.starts(with: prefix.utf8)
    }

}
