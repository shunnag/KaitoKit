import Foundation

/// Supplies a password when an archive format requires one.
public protocol PasswordProvider: Sendable {
    /// Returns a password for the detected format, or `nil` to decline.
    func password(for format: ArchiveFormat) throws -> String?
}

/// Options used while opening and reading an archive.
public struct ReaderOptions: Sendable {
    /// 未使用の入力ファイルハンドルを保持する方針。大量の書庫を同時保持するホストは
    /// bounded を選ぶ。既定は rename / unlink 後も開いた実体を読み続ける従来の契約。
    ///
    /// Idle input-handle retention. Hosts retaining many readers can choose bounded;
    /// the default preserves already-open files across rename and unlink.
    public var fileAccessPolicy: FileAccessPolicy = .persistent

    /// 入力遅延の方針。automatic は open 時に解決し、reopen() はその値を引き継ぐ。
    /// reopen(options:) は新しい reader 用に解決し直す。
    ///
    /// Input-latency policy. `reopen()` preserves the resolved value;
    /// `reopen(options:)` resolves it again for the new reader.
    public var inputLatency: InputLatency = .automatic

    /// RAR5 の一覧に Quick Open を使う方針。既定は使用しない。
    ///
    /// Policy for RAR5 Quick Open listing. Disabled by default.
    public var rar5QuickOpenPolicy: RAR5QuickOpenPolicy = .never

    func usesRAR5QuickOpen(for source: any ByteSource) -> Bool {
        switch rar5QuickOpenPolicy {
        case .never: false
        case .always: true
        case .highLatencyInput: resolvedInputLatency(for: source) == .high
        }
    }

    private var resolvedInputLatencySnapshot: InputLatency?

    func resolvingInputLatency(for source: any ByteSource) -> Self {
        var result = self
        if resolvedInputLatencySnapshot == nil {
            result.resolvedInputLatencySnapshot = resolvedInputLatency(for: source)
        }
        return result
    }

    func resolvedInputLatency(for source: any ByteSource) -> InputLatency {
        resolvedInputLatencySnapshot ?? (inputLatency == .automatic
            ? (byteSourceIsOnNonLocalVolume(source) ? .high : .low) : inputLatency)
    }

    /// 明示的な復号並列数の受理範囲。範囲外は最寄りの境界に丸める。
    public static let decodeThreadsRange = 1...1024
    @TaskLocal static var testingAutomaticThreads: (@Sendable (DecodePowerPolicy) -> Int)?
    private var automaticThreadsSnapshot: Int?

    /// 独立した圧縮単位の要求並列数。nil は CPU 構成・物理メモリ・電力方針から open 時に解決する。
    /// メモリ予算と process 共通の実行枠は別に適用する。reopen() は同じ解決値を引き継ぎ、
    /// reopen(options:) は新しい reader 用に解決し直す。
    public var decodeThreads: Int? {
        didSet { decodeThreads = decodeThreads.map(Self.clampedDecodeThreads) }
    }

    /// 自動復号並列数の電力方針。decodeThreads が nil のときだけ適用する。
    public var decodePowerPolicy: DecodePowerPolicy

    /// 7z の編集用の生値を記録する。reopen は値と記録を引き継ぐ。
    @_spi(SevenZipEditLayout) public var recordsSevenZipEditLayout: Bool = false

    /// tar の配置と圧縮の区切りを記録する。reopen は保持済みの記録を共有する。
    @_spi(TarEditLayout) public var recordsTarEditLayout: Bool = false

    /// The largest executable prefix inspected for an embedded archive marker.
    ///
    /// File-URL opens use this value automatically. Values above one MiB are
    /// clamped to one MiB, and zero disables executable-prefix scanning.
    public var maximumSFXScanSize: UInt64

    /// Data と任意 ByteSource で、実行形式 prefix 内の ZIP・RAR・7z・CAB・StuffIt 署名を探索する。
    /// 既定は無効。既存の LHA prefix 認識には影響しない。
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

    /// How AppleDouble sidecars in ZIP and tar archives (`__MACOSX/._name`, `._name`) are exposed.
    /// The default, ``AppleDoublePolicy/merge``, removes them and publishes any resource fork they carry
    /// as `name/..namedfork/rsrc`. Encrypted sidecars cannot be inspected without a password and stay
    /// listed (``AppleDoublePolicy/hide`` still removes the ones below `__MACOSX/`).
    public var appleDoublePolicy: AppleDoublePolicy

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
        recoverDamagedArchives: Bool = false,
        appleDoublePolicy: AppleDoublePolicy = .merge,
        decodeThreads: Int? = nil,
        decodePowerPolicy: DecodePowerPolicy = .reduceInLowPowerMode
    ) {
        self.decodeThreads = decodeThreads.map(Self.clampedDecodeThreads)
        self.decodePowerPolicy = decodePowerPolicy
        self.appleDoublePolicy = appleDoublePolicy
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

    /// 表示時点の自動要求並列数。open / reopen(options:) は reader ごとに一度解決する。
    /// codec のメモリ予算は別に適用する。
    public static func automaticDecodeThreads(powerPolicy: DecodePowerPolicy = .reduceInLowPowerMode) -> Int {
        if let testingAutomaticThreads { return testingAutomaticThreads(powerPolicy) }
        let process = ProcessInfo.processInfo
        return automaticDecodeThreads(topology: .current, physicalMemory: process.physicalMemory,
            lowPowerMode: process.isLowPowerModeEnabled, thermalState: process.thermalState, policy: powerPolicy)
    }

    static func automaticDecodeThreads(topology: CPUTopology, physicalMemory: UInt64,
                                       lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState,
                                       policy: DecodePowerPolicy) -> Int {
        let n = topology.activeLogicalCPUs
        let thermalPressure = thermalState == .serious || thermalState == .critical
        let reduced = policy != .alwaysUseAllCores && (lowPowerMode
            || (policy == .reduceInLowPowerModeOrThermalPressure && thermalPressure))
        let half = n / 2 + n % 2
        let lowest = topology.performanceLevels.count >= 2 ? topology.performanceLevels.last!.logicalCPUs : half
        let requested = reduced ? max(1, min(half, lowest)) : n
        return max(1, Int(min(UInt64(requested), max(1, physicalMemory / (1 << 30)))))
    }

    var resolvedDecodeThreads: Int {
        decodeThreads ?? automaticThreadsSnapshot ?? Self.automaticDecodeThreads(powerPolicy: decodePowerPolicy)
    }

    func resolvingDecodeThreads() -> Self {
        var result = self
        if decodeThreads == nil, automaticThreadsSnapshot == nil {
            result.automaticThreadsSnapshot = Self.automaticDecodeThreads(powerPolicy: decodePowerPolicy)
        }
        return result
    }

    // 解析時の方針と上限を維持し、実行時だけの指定を取り込む。provider は原本を保持する。
    func reopening(with proposed: Self) throws -> Self {
        func requireUnchanged<T: Equatable>(_ original: T, _ replacement: T, _ name: String) throws {
            guard original == replacement else { throw KaitoError.unsupportedMethod("reopen cannot change \(name)") }
        }
        try requireUnchanged(fileAccessPolicy, proposed.fileAccessPolicy, "fileAccessPolicy")
        try requireUnchanged(rar5QuickOpenPolicy, proposed.rar5QuickOpenPolicy, "rar5QuickOpenPolicy")
        try requireUnchanged(recordsSevenZipEditLayout, proposed.recordsSevenZipEditLayout, "recordsSevenZipEditLayout")
        try requireUnchanged(recordsTarEditLayout, proposed.recordsTarEditLayout, "recordsTarEditLayout")
        try requireUnchanged(maximumSFXScanSize, proposed.maximumSFXScanSize, "maximumSFXScanSize")
        try requireUnchanged(scanForSFXInData, proposed.scanForSFXInData, "scanForSFXInData")
        try requireUnchanged(encodingPolicy, proposed.encodingPolicy, "encodingPolicy")
        try requireUnchanged(password.map { Array($0.utf8) }, proposed.password.map { Array($0.utf8) }, "password")
        try requireUnchanged(lazyLocalHeaders, proposed.lazyLocalHeaders, "lazyLocalHeaders")
        try requireUnchanged(recoverDamagedArchives, proposed.recoverDamagedArchives, "recoverDamagedArchives")
        try requireUnchanged(maxSevenZipAESCyclesPower, proposed.maxSevenZipAESCyclesPower, "maxSevenZipAESCyclesPower")
        try requireUnchanged(maxRAR5KDFCountPower, proposed.maxRAR5KDFCountPower, "maxRAR5KDFCountPower")
        try requireUnchanged(verifyRAR5Blake2sp, proposed.verifyRAR5Blake2sp, "verifyRAR5Blake2sp")
        try requireUnchanged(appleDoublePolicy, proposed.appleDoublePolicy, "appleDoublePolicy")
        var parsingLimits = proposed.limits
        parsingLimits.parallelDecodeMemory = limits.parallelDecodeMemory
        try requireUnchanged(limits, parsingLimits, "limits (only parallelDecodeMemory may change)")

        var result = self
        result.decodeThreads = proposed.decodeThreads
        result.decodePowerPolicy = proposed.decodePowerPolicy
        result.inputLatency = proposed.inputLatency
        result.limits.parallelDecodeMemory = proposed.limits.parallelDecodeMemory
        result.automaticThreadsSnapshot = nil
        result.resolvedInputLatencySnapshot = nil
        return result
    }

    private static func clampedDecodeThreads(_ value: Int) -> Int {
        max(decodeThreadsRange.lowerBound, min(decodeThreadsRange.upperBound, value))
    }
}

/// How `__MACOSX/._name` (Finder / ditto ZIP) and `._name` (macOS tar) AppleDouble sidecars are exposed.
public enum AppleDoublePolicy: String, Sendable, CaseIterable {
    /// Sidecars are removed from the entry list. A sidecar that carries a resource fork is published
    /// as `name/..namedfork/rsrc` (`formatSpecific["fork"] == "resource"`) right after its data
    /// file; sidecars that hold only Finder information and extended attributes disappear. This is
    /// the default.
    case merge

    /// Sidecars and the `__MACOSX` directories are removed; resource forks are not published.
    case hide

    /// Every entry is listed exactly as the archive stores it.
    case expose
}

/// RAR5 の Quick Open 記録を一覧に使う方針。
///
/// Controls use of RAR5 Quick Open records for listing.
public enum RAR5QuickOpenPolicy: Sendable {
    /// Quick Open を使用しない。
    ///
    /// Never use Quick Open.
    case never
    /// 解決済みの入力遅延が high の場合に使用する。
    ///
    /// Use Quick Open when resolved input latency is high.
    case highLatencyInput
    /// 対応する暗号化されていないヘッダで使用する。
    ///
    /// Use Quick Open for eligible unencrypted headers.
    case always
}
