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
    private let descriptor: Int32

    /// Total number of bytes captured when the file was opened.
    public let length: UInt64

    /// Opens a file for read-only random access.
    public init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
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

        self.descriptor = descriptor
        self.length = UInt64(information.st_size)
    }

    /// Opens a file-system path for read-only random access.
    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    deinit {
        Darwin.close(descriptor)
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
