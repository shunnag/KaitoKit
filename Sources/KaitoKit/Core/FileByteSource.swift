import Darwin
import Foundation

/// A byte source backed by a file descriptor and `pread(2)`.
public final class FileByteSource: ByteSource, VolumeLocalityHinting {
    @TaskLocal static var testingVolumeIsLocal: (@Sendable (Int32) -> Bool)?
    @TaskLocal static var testingDidRead: (@Sendable (FileByteSource, UInt64, Int) -> Void)?
    let isOnNonLocalVolume: Bool

    private static func nonLocalVolume(_ descriptor: Int32) -> Bool {
        if let testingVolumeIsLocal { return !testingVolumeIsLocal(descriptor) }
        var information = statfs()
        guard Darwin.fstatfs(descriptor, &information) == 0 else { return false }
        return information.f_flags & UInt32(MNT_LOCAL) == 0
    }
    final class DirectoryAnchor: @unchecked Sendable {
        private let handle: InputFileDescriptor
        let accessPolicy: FileAccessPolicy

        init(path: String, accessPolicy: FileAccessPolicy = .persistent) throws {
            self.accessPolicy = accessPolicy
            if case .bounded = accessPolicy { FileDescriptorCache.shared.prepareForOpen() }
            let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw KaitoError.io(errno) }
            handle = try FileByteSource.makeHandle(descriptor, policy: accessPolicy) {
                let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard descriptor >= 0 else { throw KaitoError.io(errno) }
                return descriptor
            }
        }

        fileprivate func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
            try handle.withDescriptor(body)
        }
    }

    struct AnchoredOpen: Sendable {
        let source: FileByteSource
        let directory: DirectoryAnchor?
    }

    private struct OpenedDescriptor {
        let descriptor: Int32
        let length: UInt64
        let directory: DirectoryAnchor?
    }

    private let handle: InputFileDescriptor

    /// Total number of bytes captured when the file was opened.
    public let length: UInt64

    // The caller has already validated the descriptor and transfers its sole
    // ownership here. Keeping this internal preserves the public path-opening
    // behavior while allowing race-free openat/fstat callers.
    init(takingOwnershipOfValidatedDescriptor descriptor: Int32, length: UInt64) {
        precondition(descriptor >= 0)
        self.isOnNonLocalVolume = Self.nonLocalVolume(descriptor)
        self.handle = InputFileDescriptor(takingOwnershipOf: descriptor)
        self.length = length
    }

    /// Opens a file for read-only random access.
    public init(url: URL) throws {
        let opened = try Self.openDescriptorAnchoredToParent(url: url, accessPolicy: .persistent)
        self.isOnNonLocalVolume = Self.nonLocalVolume(opened.descriptor)
        self.handle = try Self.fileHandle(opened.descriptor, url: url, directory: opened.directory,
                                          policy: .persistent)
        self.length = opened.length
    }

    /// 指定した保持方針で開く。既存の init(url:) は persistent のまま維持する。
    ///
    /// Opens with the requested retention policy. The original initializer remains persistent.
    public init(url: URL, accessPolicy: FileAccessPolicy) throws {
        let opened = try Self.openDescriptorAnchoredToParent(url: url, accessPolicy: accessPolicy)
        self.isOnNonLocalVolume = Self.nonLocalVolume(opened.descriptor)
        self.handle = try Self.fileHandle(opened.descriptor, url: url, directory: opened.directory,
                                          policy: accessPolicy)
        self.length = opened.length
    }

    /// 親を葉より先に開き、所有する両ハンドルを返す。親の読み取りが許可されない
    /// 場合だけ directory は nil となる。reader はこの親ハンドルを巻探索へ渡す。
    static func openAnchored(url: URL, accessPolicy: FileAccessPolicy = .persistent) throws -> AnchoredOpen {
        let opened = try openDescriptorAnchoredToParent(url: url, accessPolicy: accessPolicy)
        let isOnNonLocalVolume = nonLocalVolume(opened.descriptor)
        let source = FileByteSource(
            handle: try fileHandle(opened.descriptor, url: url, directory: opened.directory,
                                   policy: accessPolicy), length: opened.length,
            isOnNonLocalVolume: isOnNonLocalVolume)
        return AnchoredOpen(
            source: source,
            directory: opened.directory
        )
    }

    private init(handle: InputFileDescriptor, length: UInt64, isOnNonLocalVolume: Bool) {
        self.isOnNonLocalVolume = isOnNonLocalVolume
        self.handle = handle
        self.length = length
    }

    /// 初回 FD の所有権を引き受け、再 open でも同じ実体・同じ内容属性を要求する。
    fileprivate static func makeHandle(
        _ descriptor: Int32, policy: FileAccessPolicy,
        reopen: @escaping @Sendable () throws -> Int32
    ) throws -> InputFileDescriptor {
        if case .persistent = policy { return InputFileDescriptor(takingOwnershipOf: descriptor) }
        let identity: InputFileIdentity
        do { identity = try InputFileIdentity(descriptor: descriptor) }
        catch { Darwin.close(descriptor); throw error }
        return try InputFileDescriptor(takingOwnershipOf: descriptor) {
            let descriptor = try reopen()
            do { try identity.validate(descriptor) }
            catch { Darwin.close(descriptor); throw error }
            return descriptor
        }
    }

    private static func fileHandle(_ descriptor: Int32, url: URL, directory: DirectoryAnchor?,
                                   policy: FileAccessPolicy) throws -> InputFileDescriptor {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let name = standardized.lastPathComponent
        return try makeHandle(descriptor, policy: policy) {
            let descriptor: Int32
            if let directory {
                descriptor = try directory.withDescriptor {
                    let descriptor = Darwin.openat($0, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
                    guard descriptor >= 0 else { throw KaitoError.io(errno) }
                    return descriptor
                }
            } else { descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
            guard descriptor >= 0 else { throw KaitoError.io(errno) }
            return descriptor
        }
    }

    private static func openDescriptorAnchoredToParent(
        url: URL, accessPolicy: FileAccessPolicy
    ) throws -> OpenedDescriptor {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        let directory: DirectoryAnchor?
        do {
            directory = try DirectoryAnchor(path: parent.path, accessPolicy: accessPolicy)
        } catch KaitoError.io(let code) where code == EPERM || code == EACCES {
            // 親の読み取りだけが許可されない場合は、葉を直接開き、巻探索の anchor は持たない。
            directory = nil
        }

        // O_NONBLOCK prevents a hostile FIFO path from hanging before fstat can
        // reject it. Explicit archive leaves may still be symbolic links; RAR
        // volume-set lookup applies its stricter no-follow policy separately.
        let descriptor: Int32
        let openError: Int32
        if case .bounded = accessPolicy { FileDescriptorCache.shared.prepareForOpen() }
        if let directory {
            (descriptor, openError) = try directory.withDescriptor {
                let descriptor = Darwin.openat($0, standardized.lastPathComponent,
                                              O_RDONLY | O_CLOEXEC | O_NONBLOCK)
                return (descriptor, descriptor < 0 ? errno : 0)
            }
        } else {
            descriptor = Darwin.open(
                standardized.path,
                O_RDONLY | O_CLOEXEC | O_NONBLOCK
            )
            openError = descriptor < 0 ? errno : 0
        }
        guard descriptor >= 0 else {
            throw KaitoError.io(openError)
        }

        var information = stat()
        // descriptor はこの初期化中に閉じられず、fstat の出力領域は呼び出し完了まで有効。
        guard Darwin.fstat(descriptor, &information) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw KaitoError.io(code)
        }
        guard information.st_size >= 0 else {
            Darwin.close(descriptor)
            throw KaitoError.malformed("file has a negative size")
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw KaitoError.malformed("file is not a regular file")
        }
        return OpenedDescriptor(
            descriptor: descriptor,
            length: UInt64(information.st_size),
            directory: directory
        )
    }

    /// Opens a file-system path for read-only random access.
    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    /// 指定した保持方針でファイルシステムのパスを開く。
    ///
    /// Opens a file-system path with the requested retention policy.
    public convenience init(path: String, accessPolicy: FileAccessPolicy) throws {
        try self.init(url: URL(fileURLWithPath: path), accessPolicy: accessPolicy)
    }

    /// 組み立てに保持する fd の属性を採る。URL の再 open やディレクトリ走査はしない。
    func fileIdentity() throws -> ByteSourceFileIdentity {
        try handle.withDescriptor { descriptor in
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0 else { throw KaitoError.io(errno) }
            guard information.st_size >= 0 else { throw KaitoError.malformed("file has a negative size") }
            return ByteSourceFileIdentity(device: UInt64(UInt32(bitPattern: information.st_dev)),
                                          inode: UInt64(information.st_ino), size: UInt64(information.st_size),
                                          modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                                          modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec))
        }
    }

    func volume(at url: URL) throws -> ArchiveVolumeSet.Volume {
        try handle.withDescriptor { descriptor in
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0 else { throw KaitoError.io(errno) }
            guard information.st_size >= 0 else { throw KaitoError.malformed("file has a negative size") }
            return ArchiveVolumeSet.Volume(
                url: url,
                length: UInt64(information.st_size),
                device: UInt64(UInt32(bitPattern: information.st_dev)),
                inode: UInt64(information.st_ino),
                mode: UInt16(information.st_mode),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
            )
        }
    }

    /// Compares the stable kernel identity of this open file with another
    /// descriptor. Used to anchor a parsed first volume to a retained dirfd.
    func hasSameFileIdentity(as otherDescriptor: Int32) throws -> Bool {
        try handle.withDescriptor { descriptor in
            var ownInformation = stat()
            var otherInformation = stat()
            guard Darwin.fstat(descriptor, &ownInformation) == 0,
                  Darwin.fstat(otherDescriptor, &otherInformation) == 0 else {
                throw KaitoError.io(errno)
            }
            return ownInformation.st_dev == otherInformation.st_dev
                && ownInformation.st_ino == otherInformation.st_ino
        }
    }

    func hasSameFileIdentity(as other: FileByteSource) throws -> Bool {
        try other.handle.withDescriptor { try hasSameFileIdentity(as: $0) }
    }

    /// 追加のファイルを開かず、保持した親の葉が同じ通常ファイルか検査する。
    fileprivate func matchesRegularFile(directory: Int32, name: String) throws -> Bool {
        try handle.withDescriptor { descriptor in
            var own = stat()
            var leaf = stat()
            guard Darwin.fstat(descriptor, &own) == 0 else { throw KaitoError.io(errno) }
            if Darwin.fstatat(directory, name, &leaf, AT_SYMLINK_NOFOLLOW) != 0 {
                let code = errno
                if code == ENOENT { return false }
                throw KaitoError.io(code)
            }
            guard (leaf.st_mode & S_IFMT) == S_IFREG else { return false }
            return own.st_dev == leaf.st_dev && own.st_ino == leaf.st_ino
        }
    }

    /// Reads bytes with `pread(2)` while respecting the captured file length.
    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else {
            return 0
        }
        guard offset <= UInt64(Int64.max) else {
            throw KaitoError.limitExceeded("file offset exceeds off_t")
        }

        let remaining = try Checked.sub(length, offset)
        let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))
        guard requested > 0, let baseAddress = buffer.baseAddress else {
            return 0
        }

        return try handle.withDescriptor { descriptor in
            while true {
                // baseAddress から requested バイトは呼び出し側のバッファ内で、offset + requested は length 以下。
                let result = Darwin.pread(descriptor, baseAddress, requested, off_t(offset))
                if result >= 0 {
                    Self.testingDidRead?(self, offset, result)
                    return result
                }
                if errno != EINTR {
                    throw KaitoError.io(errno)
                }
            }
        }
    }
}

extension FileByteSource.DirectoryAnchor {
    func matchesRegularFile(_ source: FileByteSource, named name: String) throws -> Bool {
        try withDescriptor { try source.matchesRegularFile(directory: $0, name: name) }
    }

    /// 保持済みの親から兄弟を開く。欠番は nil、symlink・FIFO・directory は拒否する。
    func openRegularFile(
        named name: String,
        label: String
    ) throws -> FileByteSource? {
        if case .bounded = accessPolicy { FileDescriptorCache.shared.prepareForOpen() }
        let (descriptor, code) = try withDescriptor {
            let descriptor = Darwin.openat($0, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard descriptor >= 0 else {
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw KaitoError.malformed("\(label) volume is not a regular file")
            }
            throw KaitoError.io(code)
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw KaitoError.io(code)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw KaitoError.malformed("\(label) volume is not a regular file")
        }
        guard information.st_size >= 0 else {
            _ = Darwin.close(descriptor)
            throw KaitoError.malformed("file has a negative size")
        }
        let isOnNonLocalVolume = FileByteSource.nonLocalVolume(descriptor)
        let handle = try FileByteSource.makeHandle(descriptor, policy: accessPolicy) { [self] in
            let descriptor = try withDescriptor {
                let descriptor = Darwin.openat($0, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw KaitoError.io(errno) }
                return descriptor
            }
            guard descriptor >= 0 else { throw KaitoError.io(errno) }
            return descriptor
        }
        return FileByteSource(handle: handle, length: UInt64(information.st_size),
                              isOnNonLocalVolume: isOnNonLocalVolume)
    }

    /// 先頭巻の dev/ino を保持した親の同名ファイルと比較し、差し替えを検出する。
    func verifyFirstVolumeIdentity(
        of source: FileByteSource,
        named name: String,
        label: String
    ) throws {
        if case .bounded = accessPolicy { FileDescriptorCache.shared.prepareForOpen() }
        let (descriptor, code) = try withDescriptor {
            let descriptor = Darwin.openat($0, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard descriptor >= 0 else {
            if code == ELOOP {
                throw KaitoError.malformed("\(label) volume is not a regular file")
            }
            if code == ENOENT { throw KaitoError.malformed("\(label) first volume changed during open") }
            throw KaitoError.io(code)
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else { throw KaitoError.io(errno) }
        guard (information.st_mode & S_IFMT) == S_IFREG,
              try source.hasSameFileIdentity(as: descriptor) else {
            throw KaitoError.malformed("\(label) first volume changed during open")
        }
    }
}
