import Foundation

/// A stateful, pull-based byte decompressor.
///
/// Instances are intentionally not thread-safe. For a non-empty destination,
/// a zero return value means that the stream has finished; nonempty streams
/// never use zero as a temporary "would block" result.
///
/// After `read(into:)` throws, callers must discard the instance. A conforming
/// decoder either latches the failure and rethrows it on every later call, or
/// leaves its state unspecified; each decoder's documentation says which.
public protocol Decompressor: AnyObject {
    /// Indicates whether the end of the compressed stream has been reached.
    var isFinished: Bool { get }

    /// Writes decompressed bytes into `buffer` and returns the number written.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}
