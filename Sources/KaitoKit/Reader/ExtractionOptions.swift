import Foundation

/// Options controlling extraction to the file system.
public struct ExtractionOptions: Sendable {
    /// Whether an existing regular file may be replaced.
    public var overwriteExisting: Bool

    /// Whether archive modification times and POSIX permissions are restored.
    ///
    /// Newly created objects use umask-derived file-system defaults when this is
    /// `false`, or when an entry does not carry POSIX permissions.
    public var preserveMetadata: Bool

    /// Whether safe relative symbolic links are created.
    public var createSymbolicLinks: Bool

    /// Creates extraction options.
    public init(
        overwriteExisting: Bool = true,
        preserveMetadata: Bool = true,
        createSymbolicLinks: Bool = true
    ) {
        self.overwriteExisting = overwriteExisting
        self.preserveMetadata = preserveMetadata
        self.createSymbolicLinks = createSymbolicLinks
    }
}
