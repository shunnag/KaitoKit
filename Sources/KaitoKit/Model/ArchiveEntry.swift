import Foundation

/// Metadata describing one entry in an archive.
public struct ArchiveEntry: Sendable, Equatable {
    /// Stable zero-based index in archive order.
    public let index: Int

    /// Original encoded name and format-provided name metadata.
    public let rawName: RawName

    /// Name resolved according to the reader's encoding policy.
    public let name: String

    /// Path components retained for safe extraction checks.
    public let pathComponents: [String]

    /// Logical kind of the entry.
    public let kind: EntryKind

    /// Declared uncompressed size, when known.
    public let uncompressedSize: UInt64?

    /// Declared compressed or stored size, when known.
    public let compressedSize: UInt64?

    /// Modification time, when present.
    public let modificationDate: Date?

    /// POSIX permission bits, when present.
    public let posixPermissions: UInt16?

    /// Whether the entry payload is encrypted.
    public let isEncrypted: Bool

    /// Whether recovery found missing payload bytes or an unverified payload extent.
    /// The payload of such an entry is returned without any integrity check
    /// (CRC-32, WinZip AES HMAC, MacBinary CRC-16), so it is unauthenticated.
    public let isIncomplete: Bool

    /// Solid-stream group identifier, or `-1` for an independent entry.
    public let solidGroup: Int

    /// Expected CRC-32, when present.
    public let crc32: UInt32?

    /// Human-readable compression or storage method.
    public let methodDescription: String

    /// Additional format-specific metadata.
    public let formatSpecific: [String: String]

    /// Creates archive entry metadata.
    public init(
        index: Int,
        rawName: RawName,
        name: String,
        pathComponents: [String],
        kind: EntryKind,
        uncompressedSize: UInt64?,
        compressedSize: UInt64?,
        modificationDate: Date?,
        posixPermissions: UInt16?,
        isEncrypted: Bool,
        solidGroup: Int,
        crc32: UInt32?,
        methodDescription: String,
        formatSpecific: [String: String],
        isIncomplete: Bool = false
    ) {
        self.isIncomplete = isIncomplete
        self.index = index
        self.rawName = rawName
        self.name = name
        self.pathComponents = pathComponents
        self.kind = kind
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.posixPermissions = posixPermissions
        self.isEncrypted = isEncrypted
        self.solidGroup = solidGroup
        self.crc32 = crc32
        self.methodDescription = methodDescription
        self.formatSpecific = formatSpecific
    }
}
