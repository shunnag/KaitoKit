import Foundation

/// A zero-copy view that presents a suffix of another byte source at offset
/// zero. Container readers use this when an executable prefix precedes an
/// otherwise native archive stream.
final class RebasedByteSource: ByteSource {
    private let source: any ByteSource
    private let baseOffset: UInt64

    let length: UInt64

    init(source: any ByteSource, baseOffset: UInt64) throws {
        guard baseOffset <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.baseOffset = baseOffset
        self.length = try Checked.sub(source.length, baseOffset)
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let available = try Checked.sub(length, offset)
        let requested = try Checked.toInt(min(UInt64(buffer.count), available))
        let absoluteOffset = try Checked.add(baseOffset, offset)
        let destination = UnsafeMutableRawBufferPointer(
            rebasing: buffer[..<requested]
        )
        let count = try source.read(into: destination, at: absoluteOffset)
        guard count >= 0, count <= requested else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        return count
    }
}

/// 別の source の一範囲を offset 0 から提示し、後続 member を codec が消費しないようにする。
final class BoundedByteSource: ByteSource {
    private let source: any ByteSource
    private let baseOffset: UInt64
    let length: UInt64

    init(source: any ByteSource, baseOffset: UInt64, length: UInt64) throws {
        guard try Checked.add(baseOffset, length) <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.baseOffset = baseOffset
        self.length = length
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let count = try Checked.toInt(min(UInt64(buffer.count), Checked.sub(length, offset)))
        let actual = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]),
                                     at: Checked.add(baseOffset, offset))
        guard actual >= 0, actual <= count else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        return actual
    }
}
