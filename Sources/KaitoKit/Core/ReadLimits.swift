import Foundation

/// Resource limits applied while parsing and reading an archive.
public struct ReadLimits: Sendable, Equatable {
    /// Maximum declared or produced size of a single entry.
    public var maxEntrySize: UInt64

    /// Maximum aggregate declared or produced uncompressed size in one reader.
    public var maxTotalUncompressedSize: UInt64

    /// Maximum entry size accepted by an in-memory read operation.
    public var maxInMemorySize: UInt64

    /// Maximum expanded single-file stream retained in memory while opening a
    /// compressed tar archive. Larger streams are staged in an unlinked
    /// temporary file. The default is 64 MiB. AES-encrypted ZIP XZ also uses
    /// this limit for authenticated compressed staging, with a 4 MiB ceiling.
    /// Verified RAR split-part staging uses the same limit and 4 MiB ceiling.
    public var inMemorySingleFileLimit: UInt64

    /// Minimum available space on the temporary volume while staging to disk.
    /// The default is 1 GiB, checked before spilling and every 256 MiB written.
    public var stagingFreeSpaceReserve: UInt64

    /// 並列復号の保持 byte 予算。nil は物理メモリの 50%。
    /// decoder ごとに適用し、二つの job を保持できなければ直列で復号する。
    /// codec の辞書上限は maxDictionarySize で別に制限する。
    public var parallelDecodeMemory: UInt64?

    /// Maximum number of entries accepted from one archive.
    public var maxEntryCount: Int

    /// Maximum size of a single format metadata allocation.
    /// The ZIP central directory grows with the entry count and is bounded by
    /// `maxTotalMetadataSize` instead.
    public var maxMetadataSize: UInt64

    /// Maximum number of records accepted in one format metadata record set,
    /// such as one entry's extra fields or one archive header's extras.
    public var maxMetadataRecordCount: Int

    /// Maximum number of components in one decoded archive path.
    public var maxPathComponentCount: Int

    /// Maximum aggregate logical metadata retained for all entries.
    /// Also bounds the ZIP central-directory size instead of `maxMetadataSize`.
    public var maxTotalMetadataSize: UInt64

    /// Maximum dictionary allocation accepted from compressed metadata.
    public var maxDictionarySize: UInt64

    /// StuffIt X JPEG の係数ブロック数上限。既定は 2,097,152。
    /// 24 MP の 4:4:4 と 48 MP の 4:2:0 を含み、progressive の係数 plane は最大 512 MiB。
    public var maxJPEGBlocks: Int

    /// RAR 多巻書庫と `.001` バイト分割セットで受理する最大巻数。既定は 128。
    /// 分割探索できる先頭巻では 0 以下を拒否し、1 なら兄弟が実在する場合だけ上限超過。
    public var maxVolumeCount: Int

    /// Maximum aggregate PBKDF2 work used to decrypt RAR5 archive headers.
    ///
    /// Work is measured in HMAC-SHA256 iterations and is charged only when a
    /// new password/salt/count context must be derived. Repeated envelopes that
    /// hit the reader-owned key cache do not consume the budget again.
    public var maxRAR5HeaderKDFWork: UInt64

    /// Maximum aggregate SHA-256 rounds for 7z header key derivations at open.
    /// Cache hits and direct keys consume no rounds; entry reads have a separate budget.
    /// The default permits four derivations at cycle power 24.
    public var maxSevenZipHeaderKDFWork: UInt64

    /// Maximum aggregate SHA-256 rounds for 7z entry key derivations per reader/password pair.
    /// The default is `16 * (1 << 24)`: 512 distinct salts at cycle power 19,
    /// or 16 derivations at cycle power 24. Cache hits and direct keys consume no
    /// rounds; the header budget is separate.
    /// Setting a different password replenishes the budget; setting the same password
    /// or retrying a failed read does not. `reopen()` and `open()` start with full budgets.
    /// Derivations interrupted by `CancellationError` are refunded.
    /// Hosts that automatically try multiple passwords must bound their own attempts;
    /// total exposure scales with the attempt count times the number of readers.
    public var maxSevenZipEntryKDFWork: UInt64

    /// reader と password の組ごとの StuffIt X 鍵・verifier 導出に使う MD5 圧縮回数の総数。
    /// 既定は `1 << 22`。約 4 KiB の一導出（release 実測で約 1.7 秒）を許し、8 KiB 以上は拒む。
    /// padding・verifier も数えるため、1 byte password の実境界は 4,032 byte。4,096 byte は超過する。
    /// 実際の鍵素材は 1 KiB 未満（RC4 の実例は 64、AES は最大 32、Blowfish は 56、DES は 8 byte）。
    /// 通常の小さい鍵なら reader 内の数千 entry を許す。catalog と entry で共有する。
    /// 別の password を設定すると戻り、同じ password の再設定や読取失敗では戻らない。
    /// CancellationError で中断した導出だけを返金する。
    /// reopen() / open() でも戻る。複数 password を自動試行する host は試行回数を縛る。
    /// 全体の露出は試行回数 × reader 数に比例する。
    public var maxStuffItXKDFWork: UInt64

    /// Maximum aggregate HMAC-SHA256 iterations for RAR5 entry key derivations per reader/password pair.
    /// The default is `16 * ((1 << 24) + 32)`, or sixteen derivations at count 24.
    /// Cache hits are free; the header budget is separate. A different password,
    /// `reopen()` or `open()` starts with a full budget. The same password and failed
    /// reads do not replenish it; cancelled derivations are refunded.
    /// Hosts that try multiple passwords must bound their own attempts.
    public var maxRAR5EntryKDFWork: UInt64

    /// Creates a set of archive resource limits.
    ///
    /// - Parameters:
    ///   - maxEntrySize: Maximum size of one entry. The default is 4 GiB.
    ///   - maxTotalUncompressedSize: Maximum aggregate declared or produced
    ///     uncompressed size across entries in one reader. The default is 64 GiB.
    ///   - maxInMemorySize: Maximum size for `read` operations. The default is 1 GiB.
    ///   - inMemorySingleFileLimit: Maximum expanded compressed-tar stream
    ///     retained in memory. The default is 64 MiB.
    ///   - stagingFreeSpaceReserve: Minimum available temporary-volume space
    ///     while staging to disk. The default is 1 GiB.
    ///   - parallelDecodeMemory: 並列復号の保持 byte 予算。nil は物理メモリの 50%。
    ///   - maxEntryCount: Maximum number of entries. The default is one million.
    ///   - maxMetadataSize: Maximum single metadata allocation. The default is 16 MiB.
    ///     The ZIP central directory uses `maxTotalMetadataSize` instead.
    ///   - maxMetadataRecordCount: Maximum records in one metadata record set.
    ///     The default is 65,536.
    ///   - maxPathComponentCount: Maximum components in one path. The default is 1,024.
    ///   - maxTotalMetadataSize: Maximum aggregate retained metadata. The default is 256 MiB.
    ///     Also bounds the ZIP central-directory size.
    ///   - maxDictionarySize: Maximum codec dictionary size. The default is 1 GiB.
    ///   - maxJPEGBlocks: StuffIt X JPEG の係数ブロック数上限。既定は 2,097,152（係数 plane は最大 512 MiB）。
    ///   - maxVolumeCount: RAR 多巻・`.001` バイト分割セットの最大巻数。既定は 128。
    ///   - maxRAR5HeaderKDFWork: Maximum aggregate RAR5 encrypted-header KDF
    ///     work. The default permits four derivations at the maximum accepted
    ///     iteration exponent.
    ///   - maxSevenZipHeaderKDFWork: Maximum aggregate 7z header SHA-256 rounds.
    ///     The default is `4 * (1 << 24)`; entry-time derivations are excluded.
    ///   - maxSevenZipEntryKDFWork: Maximum aggregate 7z entry SHA-256 rounds per
    ///     reader/password pair. The default is `16 * (1 << 24)`; cache hits and direct keys are free.
    ///   - maxStuffItXKDFWork: reader と password の組ごとの StuffIt X KDF の MD5 圧縮回数上限。既定は `1 << 22`。
    ///   - maxRAR5EntryKDFWork: Maximum aggregate RAR5 entry HMAC-SHA256 iterations per
    ///     reader/password pair. The default is `16 * ((1 << 24) + 32)`; cache hits are free.
    public init(
        maxEntrySize: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maxTotalUncompressedSize: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        maxInMemorySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        inMemorySingleFileLimit: UInt64 = 64 * 1_024 * 1_024,
        stagingFreeSpaceReserve: UInt64 = 1_024 * 1_024 * 1_024,
        maxEntryCount: Int = 1_000_000,
        maxMetadataSize: UInt64 = 16 * 1_024 * 1_024,
        maxMetadataRecordCount: Int = 65_536,
        maxPathComponentCount: Int = 1_024,
        maxTotalMetadataSize: UInt64 = 256 * 1_024 * 1_024,
        maxDictionarySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        maxJPEGBlocks: Int = 2_097_152,
        maxVolumeCount: Int = 128,
        maxRAR5HeaderKDFWork: UInt64 = 4 * ((UInt64(1) << 24) + 32),
        maxSevenZipHeaderKDFWork: UInt64 = 4 * (UInt64(1) << 24),
        parallelDecodeMemory: UInt64? = nil,
        maxSevenZipEntryKDFWork: UInt64 = 16 * (UInt64(1) << 24),
        maxStuffItXKDFWork: UInt64 = UInt64(1) << 22,
        maxRAR5EntryKDFWork: UInt64 = 16 * ((UInt64(1) << 24) + 32)
    ) {
        self.maxEntrySize = maxEntrySize
        self.maxTotalUncompressedSize = maxTotalUncompressedSize
        self.maxInMemorySize = maxInMemorySize
        self.inMemorySingleFileLimit = inMemorySingleFileLimit
        self.stagingFreeSpaceReserve = stagingFreeSpaceReserve
        self.parallelDecodeMemory = parallelDecodeMemory
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxMetadataSize = maxMetadataSize
        self.maxMetadataRecordCount = max(0, maxMetadataRecordCount)
        self.maxPathComponentCount = max(0, maxPathComponentCount)
        self.maxTotalMetadataSize = maxTotalMetadataSize
        self.maxDictionarySize = maxDictionarySize
        self.maxJPEGBlocks = max(0, maxJPEGBlocks)
        self.maxVolumeCount = max(0, maxVolumeCount)
        self.maxRAR5HeaderKDFWork = maxRAR5HeaderKDFWork
        self.maxSevenZipHeaderKDFWork = maxSevenZipHeaderKDFWork
        self.maxSevenZipEntryKDFWork = maxSevenZipEntryKDFWork
        self.maxStuffItXKDFWork = maxStuffItXKDFWork
        self.maxRAR5EntryKDFWork = maxRAR5EntryKDFWork
    }

    // 物理メモリは process の生存中に変わらない。sysctl を folder ごとに繰り返さない。
    private static let cachedPhysicalMemory = ProcessInfo.processInfo.physicalMemory

    func resolvedParallelDecodeMemory(physicalMemory: UInt64 = cachedPhysicalMemory) -> Int {
        Int(clamping: parallelDecodeMemory ?? physicalMemory / 2)
    }
}
