import Darwin
import Foundation

/// Keeps the old data fork available while an already materialized inode is updated in place.
enum HardLinkContentBackup {
    static func withBackup(
        of target: Int32, status: stat, below parent: Int32,
        clone: (Int32, Int32, String) -> Int32 = { Darwin.fclonefileat($0, $1, $2, 0) },
        checkSpace: (UInt64) throws -> Void,
        update: () throws -> Void
    ) throws {
        let name = ".kaitokit-link-backup-\(UUID().uuidString)"
        let backup: Int32
        if clone(target, parent, name) == 0 {
            // The target's permissions and the process umask can both restrict the clone.
            guard Darwin.fchmodat(parent, name, mode_t(0o600), AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                _ = Darwin.unlinkat(parent, name, 0)
                throw KaitoError.io(code)
            }
            backup = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if backup < 0 {
                let code = errno
                _ = Darwin.unlinkat(parent, name, 0)
                throw KaitoError.io(code)
            }
        } else {
            guard errno == ENOTSUP || errno == ENOSYS || errno == EXDEV else { throw KaitoError.io(errno) }
            try checkSpace(UInt64(status.st_size))
            backup = Darwin.openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard backup >= 0 else { throw KaitoError.io(errno) }
            do {
                try copyPrefix(from: target, to: backup, length: status.st_size) { count in
                    try Task.checkCancellation()
                    try checkSpace(count)
                }
            } catch {
                _ = Darwin.close(backup)
                _ = Darwin.unlinkat(parent, name, 0)
                throw error
            }
        }

        var removeBackup = true
        defer {
            _ = Darwin.close(backup)
            if removeBackup { _ = Darwin.unlinkat(parent, name, 0) }
        }
        do {
            try update()
        } catch {
            // A cancelled task or depleted free-space allowance must still be able to roll back.
            removeBackup = false
            var current = stat()
            guard Darwin.fstat(target, &current) == 0 else { throw KaitoError.io(errno) }
            let written = Darwin.lseek(target, 0, SEEK_CUR)
            guard written >= 0 else { throw KaitoError.io(errno) }
            let damagedPrefix = current.st_size < status.st_size ? status.st_size : min(written, status.st_size)
            if current.st_size > status.st_size {
                guard Darwin.ftruncate(target, status.st_size) == 0 else { throw KaitoError.io(errno) }
            }
            guard Darwin.lseek(target, 0, SEEK_SET) == 0 else { throw KaitoError.io(errno) }
            try copyPrefix(from: backup, to: target, length: damagedPrefix) { _ in }
            guard Darwin.fchmod(target, status.st_mode & 0o7777) == 0 else { throw KaitoError.io(errno) }
            var times = [status.st_atimespec, status.st_mtimespec]
            guard Darwin.futimens(target, &times) == 0 else { throw KaitoError.io(errno) }
            removeBackup = true
            throw error
        }
    }

    private static func copyPrefix(from source: Int32, to destination: Int32, length: off_t,
                                   beforeWrite: (UInt64) throws -> Void) throws {
        guard length > 0 else { return }
        let capacity = Int(min(length, 1 << 20))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while offset < length {
            let wanted = Int(min(off_t(capacity), length - offset))
            let count = Darwin.pread(source, buffer.baseAddress, wanted, offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw KaitoError.io(count == 0 ? EIO : errno) }
            try beforeWrite(UInt64(count))
            try writeAll(UnsafeRawBufferPointer(rebasing: buffer[..<count]), to: destination)
            offset += off_t(count)
        }
    }
}
