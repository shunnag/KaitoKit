import Foundation

/// Supplies a password when an archive format requires one.
public protocol PasswordProvider: Sendable {
    /// Returns a password for the detected format, or `nil` to decline.
    func password(for format: ArchiveFormat) throws -> String?
}

/// Options used while opening and reading an archive.
public struct ReaderOptions: Sendable {
    /// The policy used to decode entry names.
    public var encodingPolicy: EncodingPolicy

    /// Resource limits applied while parsing and reading.
    public var limits: ReadLimits

    /// An initial archive password.
    public var password: String?

    /// A fallback password provider.
    public var passwordProvider: (any PasswordProvider)?

    /// Whether ZIP local headers are validated only when their entry is first read.
    public var lazyLocalHeaders: Bool

    /// Maximum iterated-SHA-256 cycle power accepted from 7zAES metadata.
    ///
    /// The special direct-key value `0x3f` remains accepted. The default of 24
    /// permits normal 7-Zip archives while bounding attacker-controlled work.
    public var maxSevenZipAESCyclesPower: UInt8

    /// Creates reader options.
    public init(
        encodingPolicy: EncodingPolicy = .automatic(),
        limits: ReadLimits = ReadLimits(),
        password: String? = nil,
        passwordProvider: (any PasswordProvider)? = nil,
        lazyLocalHeaders: Bool = true,
        maxSevenZipAESCyclesPower: UInt8 = 24
    ) {
        self.encodingPolicy = encodingPolicy
        self.limits = limits
        self.password = password
        self.passwordProvider = passwordProvider
        self.lazyLocalHeaders = lazyLocalHeaders
        self.maxSevenZipAESCyclesPower = min(maxSevenZipAESCyclesPower, 62)
    }
}

/// Options controlling extraction to the file system.
public struct ExtractionOptions: Sendable {
    /// Whether an existing regular file may be replaced.
    public var overwriteExisting: Bool

    /// Whether modification times and POSIX permissions are restored.
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
