import Foundation

/// Portable metadata associated with an archive entry.
public struct EntryAttributes: Sendable, Equatable {
    /// Entry modification time, when present.
    public var modificationDate: Date?

    /// Entry access time, when present.
    public var accessDate: Date?

    /// Entry creation time, when present.
    public var creationDate: Date?

    /// The low 12 POSIX permission and special-mode bits, when present.
    public var posixPermissions: UInt16?

    /// Format-specific attributes not represented by portable fields.
    public var formatSpecific: [String: String]

    /// Creates portable entry metadata.
    public init(
        modificationDate: Date? = nil,
        accessDate: Date? = nil,
        creationDate: Date? = nil,
        posixPermissions: UInt16? = nil,
        formatSpecific: [String: String] = [:]
    ) {
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.creationDate = creationDate
        self.posixPermissions = posixPermissions
        self.formatSpecific = formatSpecific
    }
}
