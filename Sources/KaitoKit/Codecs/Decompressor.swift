import Foundation

/// A stateful, pull-based byte decompressor.
///
/// Instances are intentionally not thread-safe. For a non-empty destination,
/// a zero return value means that the stream has finished; nonempty streams
/// never use zero as a temporary "would block" result.
public protocol Decompressor: AnyObject {
    /// Indicates whether the end of the compressed stream has been reached.
    var isFinished: Bool { get }

    /// Writes decompressed bytes into `buffer` and returns the number written.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}
