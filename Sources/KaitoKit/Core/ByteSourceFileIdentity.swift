import Foundation

/// ctime は公開時の rename・属性復元でも変わるため含めない。同一性は digest の補助。
@_spi(TarEditLayout)
public struct ByteSourceFileIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: UInt64,
                modificationSeconds: Int64, modificationNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }
}

@_spi(TarEditLayout)
public protocol ByteSourceFileIdentityProviding: ByteSource {
    func currentFileIdentity() throws -> ByteSourceFileIdentity
}

/// source が file なら現在の identity。identity を持たない source は nil。
func currentTarArchiveIdentity(_ source: any ByteSource) -> ByteSourceFileIdentity? {
    if let file = source as? FileByteSource { return try? file.fileIdentity() }
    return try? (source as? any ByteSourceFileIdentityProviding)?.currentFileIdentity()
}
