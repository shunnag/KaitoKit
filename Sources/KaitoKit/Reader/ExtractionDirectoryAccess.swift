import Darwin
import Foundation

// KaitoKitCompat が展開先の dirfd を共有するため package。
// 親を O_NOFOLLOW で開いた descriptor を辿り、読めない自分の directory は一時的に 0700 を足して開き、
// close で元の mode に戻す。symlink や directory 以外を辿る path は malformed。
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
