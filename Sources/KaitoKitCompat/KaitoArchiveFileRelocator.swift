private import Darwin
import Foundation
import KaitoKit

// hard link の実体を staging から展開先へ移すとき、renameat が EXDEV で失敗した場合に使う複写。
// 元の file を dirfd と O_NOFOLLOW で開き直して同一性を確かめ、一時名に書いてから renameat で公開する。
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
            try buffer.withUnsafeBytes { storage in
                try writeAll(UnsafeRawBufferPointer(rebasing: storage[..<count]), to: target)
            }
        }
    }
}
