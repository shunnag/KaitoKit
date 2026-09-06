import Foundation

/// A bounded pass-through decompressor for stored archive data.
public final class CopyDecompressor: Decompressor {
    private let source: any ByteSource
    private let endOffset: UInt64
    private var offset: UInt64

    /// Creates a pass-through stream over a validated byte-source range.
    public init(source: any ByteSource, offset: UInt64, compressedSize: UInt64) throws {
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else {
            throw KaitoError.truncated
        }

        self.source = source
        self.offset = offset
        self.endOffset = endOffset
    }

    /// Indicates whether all bytes in the bounded source range were copied.
    public var isFinished: Bool {
        offset == endOffset
    }

    /// Copies up to `buffer.count` bytes from the bounded source range.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, offset < endOffset else {
            return 0
        }

        let remaining = try Checked.sub(endOffset, offset)
        let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))

        // buffer の先頭 requested バイトは呼び出し元が確保済みで、requested <= buffer.count。
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested])
        let count = try source.read(into: destination, at: offset)
        guard count >= 0, count <= requested else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        guard count != 0 else {
            throw KaitoError.truncated
        }

        offset = try Checked.add(offset, UInt64(count))
        return count
    }
}
