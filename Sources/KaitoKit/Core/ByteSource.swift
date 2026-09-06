import Darwin
import Foundation

/// A random-access source of immutable archive bytes.
public protocol ByteSource: Sendable {
    /// Total number of readable bytes.
    var length: UInt64 { get }

    /// Reads bytes at an absolute offset without changing shared cursor state.
    ///
    /// The method returns zero at end of input and never reads beyond `length`.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

/// A byte source backed by a file descriptor and `pread(2)`.
public final class FileByteSource: ByteSource {
    final class DirectoryAnchor: @unchecked Sendable {
        let descriptor: Int32

        init(path: String) throws {
            descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { throw KaitoError.io(errno) }
        }

        deinit {
            _ = Darwin.close(descriptor)
        }
    }

    struct AnchoredOpen: Sendable {
        let source: FileByteSource
        let directory: DirectoryAnchor
    }

    private struct OpenedDescriptor {
        let descriptor: Int32
        let length: UInt64
        let directory: DirectoryAnchor
    }

    private let descriptor: Int32

    /// Total number of bytes captured when the file was opened.
    public let length: UInt64

    // The caller has already validated the descriptor and transfers its sole
    // ownership here. Keeping this internal preserves the public path-opening
    // behavior while allowing race-free openat/fstat callers.
    init(takingOwnershipOfValidatedDescriptor descriptor: Int32, length: UInt64) {
        precondition(descriptor >= 0)
        self.descriptor = descriptor
        self.length = length
    }

    /// Opens a file for read-only random access.
    public init(url: URL) throws {
        let opened = try Self.openDescriptorAnchoredToParent(url: url)
        self.descriptor = opened.descriptor
        self.length = opened.length
    }

    /// Opens the parent before the leaf and returns both owned handles. Archive
    /// readers pass the exact parent handle to sibling-file locators.
    static func openAnchored(url: URL) throws -> AnchoredOpen {
        let opened = try openDescriptorAnchoredToParent(url: url)
        return AnchoredOpen(
            source: FileByteSource(
                takingOwnershipOfValidatedDescriptor: opened.descriptor,
                length: opened.length
            ),
            directory: opened.directory
        )
    }

    private static func openDescriptorAnchoredToParent(
        url: URL
    ) throws -> OpenedDescriptor {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        let directory = try DirectoryAnchor(path: parent.path)

        // O_NONBLOCK prevents a hostile FIFO path from hanging before fstat can
        // reject it. Explicit archive leaves may still be symbolic links; RAR
        // volume-set lookup applies its stricter no-follow policy separately.
        let descriptor = Darwin.openat(
            directory.descriptor,
            standardized.lastPathComponent,
            O_RDONLY | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw KaitoError.io(errno)
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

    deinit {
        Darwin.close(descriptor)
    }

    /// Compares the stable kernel identity of this open file with another
    /// descriptor. Used to anchor a parsed first volume to a retained dirfd.
    func hasSameFileIdentity(as otherDescriptor: Int32) -> Bool {
        var ownInformation = stat()
        var otherInformation = stat()
        guard Darwin.fstat(descriptor, &ownInformation) == 0,
              Darwin.fstat(otherDescriptor, &otherInformation) == 0 else {
            return false
        }
        return ownInformation.st_dev == otherInformation.st_dev
            && ownInformation.st_ino == otherInformation.st_ino
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

        while true {
            // baseAddress から requested バイトは呼び出し側のバッファ内で、offset + requested は length 以下。
            let result = Darwin.pread(descriptor, baseAddress, requested, off_t(offset))
            if result >= 0 {
                return result
            }
            if errno != EINTR {
                throw KaitoError.io(errno)
            }
        }
    }
}

/// A byte source that retains a `Data` value without copying its storage.
public final class DataByteSource: ByteSource {
    // internal にして、テストでは COW ストレージの同一性を直接確認できるようにする。
    let data: Data

    /// Total number of bytes in the retained data.
    public var length: UInt64 {
        UInt64(data.count)
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public init(data: Data) {
        self.data = data
    }

    /// Retains a data value using `Data` copy-on-write semantics.
    public convenience init(_ data: Data) {
        self.init(data: data)
    }

    /// Copies a requested range into the caller-provided buffer.
    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else {
            return 0
        }

        let available = try Checked.sub(length, offset)
        let count = try Checked.toInt(min(UInt64(buffer.count), available))
        let start = try Checked.toInt(offset)
        guard count > 0, let destination = buffer.baseAddress else {
            return 0
        }

        return data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.baseAddress else {
                return 0
            }
            // start + count は上の length 検証済みで、両ポインタの有効領域は count バイト以上。
            destination.copyMemory(from: source.advanced(by: start), byteCount: count)
            return count
        }
    }
}

// 形式 parser が検証済みの一範囲を一括取得するための共通 primitive。
// 通常の FileByteSource では最初の pread が全範囲を返し、短い実装だけ継続する。
func readByteRange(
    source: any ByteSource,
    offset: UInt64,
    count: Int
) throws -> [UInt8] {
    guard count >= 0 else {
        throw KaitoError.malformed("negative byte-range size")
    }
    let end = try Checked.add(offset, UInt64(count))
    guard end <= source.length else { throw KaitoError.truncated }
    guard count > 0 else { return [] }

    var result = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
        let readOffset = try Checked.add(offset, UInt64(filled))
        let actual = try result.withUnsafeMutableBytes { storage in
            // filled..<count は未充填の確保済み領域で、source へそれ以外を公開しない。
            try source.read(
                into: UnsafeMutableRawBufferPointer(rebasing: storage[filled..<count]),
                at: readOffset
            )
        }
        guard actual > 0, actual <= count - filled else {
            throw KaitoError.truncated
        }
        filled += actual
    }
    return result
}
