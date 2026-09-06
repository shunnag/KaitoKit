import Foundation

/// An entry name in its original encoded representation.
public struct RawName: Sendable, Equatable {
    /// Original bytes stored in the archive.
    public let bytes: [UInt8]

    /// Encoding declared by the format, when present.
    public let declaredEncoding: String.Encoding?

    /// Whether the raw format marked the name as a directory path.
    public let isDirectoryHint: Bool

    /// Creates an original archive name.
    public init(
        bytes: [UInt8],
        declaredEncoding: String.Encoding? = nil,
        isDirectoryHint: Bool = false
    ) {
        self.bytes = bytes
        self.declaredEncoding = declaredEncoding
        self.isDirectoryHint = isDirectoryHint
    }

    /// Creates an original archive name from data.
    public init(
        data: Data,
        declaredEncoding: String.Encoding? = nil,
        isDirectoryHint: Bool = false
    ) {
        self.init(
            bytes: Array(data),
            declaredEncoding: declaredEncoding,
            isDirectoryHint: isDirectoryHint
        )
    }
}
