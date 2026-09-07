/// Resource limits applied while parsing and reading an archive.
public struct ReadLimits: Sendable, Equatable {
    /// Maximum declared or produced size of a single entry.
    public var maxEntrySize: UInt64

    /// Maximum entry size accepted by an in-memory read operation.
    public var maxInMemorySize: UInt64

    /// Maximum number of entries accepted from one archive.
    public var maxEntryCount: Int

    /// Maximum size of a single format metadata allocation.
    public var maxMetadataSize: UInt64

    /// Maximum number of key/value records retained from format metadata.
    public var maxMetadataRecordCount: Int

    /// Maximum number of components in one decoded archive path.
    public var maxPathComponentCount: Int

    /// Maximum aggregate logical metadata retained for all entries.
    public var maxTotalMetadataSize: UInt64

    /// Maximum dictionary allocation accepted from compressed metadata.
    public var maxDictionarySize: UInt64

    /// Maximum number of volumes accepted in one multi-volume archive.
    public var maxVolumeCount: Int

    /// Maximum aggregate PBKDF2 work used to decrypt RAR5 archive headers.
    ///
    /// Work is measured in HMAC-SHA256 iterations and is charged only when a
    /// new password/salt/count context must be derived. Repeated envelopes that
    /// hit the reader-owned key cache do not consume the budget again.
    public var maxRAR5HeaderKDFWork: UInt64

    /// Creates a set of archive resource limits.
    ///
    /// - Parameters:
    ///   - maxEntrySize: Maximum size of one entry. The default is 4 GiB.
    ///   - maxInMemorySize: Maximum size for `read` operations. The default is 1 GiB.
    ///   - maxEntryCount: Maximum number of entries. The default is one million.
    ///   - maxMetadataSize: Maximum single metadata allocation. The default is 16 MiB.
    ///   - maxMetadataRecordCount: Maximum retained metadata records. The default is 65,536.
    ///   - maxPathComponentCount: Maximum components in one path. The default is 1,024.
    ///   - maxTotalMetadataSize: Maximum aggregate retained metadata. The default is 256 MiB.
    ///   - maxDictionarySize: Maximum codec dictionary size. The default is 1 GiB.
    ///   - maxVolumeCount: Maximum volumes in one archive. The default is 128.
    ///   - maxRAR5HeaderKDFWork: Maximum aggregate RAR5 encrypted-header KDF
    ///     work. The default permits four derivations at the maximum accepted
    ///     iteration exponent.
    public init(
        maxEntrySize: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maxInMemorySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        maxEntryCount: Int = 1_000_000,
        maxMetadataSize: UInt64 = 16 * 1_024 * 1_024,
        maxMetadataRecordCount: Int = 65_536,
        maxPathComponentCount: Int = 1_024,
        maxTotalMetadataSize: UInt64 = 256 * 1_024 * 1_024,
        maxDictionarySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        maxVolumeCount: Int = 128,
        maxRAR5HeaderKDFWork: UInt64 = 4 * ((UInt64(1) << 24) + 32)
    ) {
        self.maxEntrySize = maxEntrySize
        self.maxInMemorySize = maxInMemorySize
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxMetadataSize = maxMetadataSize
        self.maxMetadataRecordCount = max(0, maxMetadataRecordCount)
        self.maxPathComponentCount = max(0, maxPathComponentCount)
        self.maxTotalMetadataSize = maxTotalMetadataSize
        self.maxDictionarySize = maxDictionarySize
        self.maxVolumeCount = max(0, maxVolumeCount)
        self.maxRAR5HeaderKDFWork = maxRAR5HeaderKDFWork
    }
}
