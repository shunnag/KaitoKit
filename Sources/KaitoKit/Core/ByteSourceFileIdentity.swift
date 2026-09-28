import Foundation

/// ctime は公開時の rename・属性復元でも変わるため含めない。同一性は digest の補助。
@_spi(TarEditLayout)
public struct ByteSourceFileIdentity: Sendable, Hashable {
    /// 保持した fd を fstat した device・inode・size。
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    /// 最終変更時刻（st_mtimespec）の秒と nanosecond。
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64

    /// 各値をそのまま保持する。``ByteSourceFileIdentityProviding`` の実装が使う。
    public init(device: UInt64, inode: UInt64, size: UInt64,
                modificationSeconds: Int64, modificationNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }
}

/// FileByteSource 以外の source が file の同一性を提供する。throw した場合は同一性なしとして扱う。
@_spi(TarEditLayout)
public protocol ByteSourceFileIdentityProviding: ByteSource {
    /// 呼出し時点の同一性。
    func currentFileIdentity() throws -> ByteSourceFileIdentity
}

/// source が file なら現在の identity。identity を持たない source は nil。
func currentTarArchiveIdentity(_ source: any ByteSource) -> ByteSourceFileIdentity? {
    if let file = source as? FileByteSource { return try? file.fileIdentity() }
    return try? (source as? any ByteSourceFileIdentityProviding)?.currentFileIdentity()
}
