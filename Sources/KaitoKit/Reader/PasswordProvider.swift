import Foundation

/// Supplies a password when an archive format requires one.
public protocol PasswordProvider: Sendable {
    /// Returns a password for the detected format, or `nil` to decline.
    func password(for format: ArchiveFormat) throws -> String?
}

/// Options used while opening and reading an archive.
public struct ReaderOptions: Sendable {
    /// The largest executable prefix inspected for an embedded archive marker.
    ///
    /// File-URL opens use this value automatically. Values above one MiB are
    /// clamped to one MiB, and zero disables executable-prefix scanning.
    public var maximumSFXScanSize: UInt64

    /// Whether `Data` and arbitrary `ByteSource` opens inspect executable
    /// prefixes for embedded ZIP, RAR, and 7-Zip markers.
    ///
    /// This is off by default because these inputs do not carry file-system
    /// provenance. It does not affect the established LHA prefix recognition.
    public var scanForSFXInData: Bool

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

    /// Whether damaged ZIP, tar, LHA, and RAR5 archives retain recoverable entries.
    /// Incomplete entries expose only the payload bytes that can be decoded, and
    /// their integrity is **not** verified: CRC-32, WinZip AES HMAC, and MacBinary
    /// CRC-16 checks are all skipped for them. Bytes recovered from an encrypted
    /// incomplete entry are unauthenticated and may have been tampered with, so
    /// treat them as untrusted. Entries that are not incomplete stay fully
    /// verified, and healthy archives read identically with this enabled.
    ///
    /// Two RAR5 cases are deliberately not recovered. A multi-volume archive
    /// whose later volumes are missing still fails, so an entry that continues
    /// into the next volume is never reported as complete. An incomplete member
    /// of a solid group is listed with `isIncomplete` but throws when read,
    /// because its decoder state is shared with the members that follow it.
    /// An incomplete *encrypted* RAR5 entry returns no bytes at all rather than
    /// unauthenticated ones.
    public var recoverDamagedArchives: Bool

    /// Maximum iterated-SHA-256 cycle power accepted from 7zAES metadata.
    ///
    /// The special direct-key value `0x3f` remains accepted. The default of 24
    /// permits normal 7-Zip archives while bounding attacker-controlled work.
    public var maxSevenZipAESCyclesPower: UInt8 {
        didSet { maxSevenZipAESCyclesPower = min(maxSevenZipAESCyclesPower, 62) }
    }

    /// Maximum binary logarithm of PBKDF2 iterations accepted from RAR5 metadata.
    ///
    /// RAR5 stores an attacker-controlled iteration exponent. The default of 24
    /// matches the milestone's resource ceiling while allowing normal archives.
    /// Values above 24 are clamped to that non-raiseable safety ceiling.
    public var maxRAR5KDFCountPower: UInt8 {
        didSet { maxRAR5KDFCountPower = min(maxRAR5KDFCountPower, 24) }
    }

    /// Whether optional RAR5 BLAKE2sp digests are verified when present.
    public var verifyRAR5Blake2sp: Bool

    /// Creates reader options.
    public init(
        encodingPolicy: EncodingPolicy = .automatic(),
        limits: ReadLimits = ReadLimits(),
        password: String? = nil,
        passwordProvider: (any PasswordProvider)? = nil,
        lazyLocalHeaders: Bool = true,
        maxSevenZipAESCyclesPower: UInt8 = 24,
        maxRAR5KDFCountPower: UInt8 = 24,
        verifyRAR5Blake2sp: Bool = true,
        maximumSFXScanSize: UInt64 = 1 * 1_024 * 1_024,
        scanForSFXInData: Bool = false,
        recoverDamagedArchives: Bool = false
    ) {
        self.maximumSFXScanSize = min(
            maximumSFXScanSize,
            1 * 1_024 * 1_024
        )
        self.recoverDamagedArchives = recoverDamagedArchives
        self.scanForSFXInData = scanForSFXInData
        self.encodingPolicy = encodingPolicy
        self.limits = limits
        self.password = password
        self.passwordProvider = passwordProvider
        self.lazyLocalHeaders = lazyLocalHeaders
        self.maxSevenZipAESCyclesPower = min(maxSevenZipAESCyclesPower, 62)
        self.maxRAR5KDFCountPower = min(maxRAR5KDFCountPower, 24)
        self.verifyRAR5Blake2sp = verifyRAR5Blake2sp
    }
}

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
