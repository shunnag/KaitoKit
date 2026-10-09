import Foundation

/// Supplies a password when an archive format requires one.
public protocol PasswordProvider: Sendable {
    /// Returns a password for the detected format, or `nil` to decline.
    func password(for format: ArchiveFormat) throws -> String?
}

/// Options used while opening and reading an archive.
public struct ReaderOptions: Sendable {
    /// 明示的な復号並列数の受理範囲。範囲外は最寄りの境界に丸める。
    public static let decodeThreadsRange = 1...1024
    @TaskLocal static var testingAutomaticThreads: (@Sendable (DecodePowerPolicy) -> Int)?
    private var automaticThreadsSnapshot: Int?

    /// XZ / bzip2 の要求並列数。nil は CPU 構成・物理メモリ・電力方針から open 時に解決する。
    /// メモリ予算と process 共通の実行枠は別に適用する。reopen は同じ解決値を引き継ぐ。
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

    /// 表示時点の自動要求並列数。reader は open 時に一度解決し、codec のメモリ予算は別に適用する。
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
