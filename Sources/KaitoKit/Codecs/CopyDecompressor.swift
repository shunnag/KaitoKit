import Foundation

/// A bounded pass-through decompressor for stored archive data.
public final class CopyDecompressor: Decompressor {
    // 小さい entry は Data の inline/既存 allocation 経路の方が軽いため一括経路を限定する。
    static let directReadMinimumSize = 1 * 1_024 * 1_024

    // ByteSource 呼出しを償却しつつ、直前に書いた byte が cache にある間に CRC を進める。
    static let directReadChunkSize = 4 * 1_024 * 1_024

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

    // EntryStream の既知長一括 read 専用。最終 Data の領域を直接 ByteSource に渡し、
    // 読めた plaintext 範囲をその場で CRC/HMAC 等の上位処理へ通知する。
    // 通常の read(into:) の「一回で buffer 全体まで」という挙動は変えない。
    func readDirectly(
        into buffer: UnsafeMutableRawBufferPointer,
        didRead: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int {
        guard !buffer.isEmpty, offset < endOffset else {
            return 0
        }

        var total = 0
        while total < buffer.count, offset < endOffset {
            let sourceRemaining = try Checked.sub(endOffset, offset)
            let destinationRemaining = buffer.count - total
            let requested = try Checked.toInt(min(
                UInt64(Self.directReadChunkSize),
                UInt64(destinationRemaining),
                sourceRemaining
            ))
            let end = total + requested
            let destination = UnsafeMutableRawBufferPointer(
                rebasing: buffer[total..<end]
            )
            let count = try source.read(into: destination, at: offset)
            guard count >= 0, count <= requested else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard count > 0 else {
                throw KaitoError.truncated
            }

            offset = try Checked.add(offset, UInt64(count))
            try didRead(UnsafeRawBufferPointer(rebasing: destination[..<count]))
            total += count
        }
        return total
    }
}
