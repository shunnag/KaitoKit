import Foundation

/// Options controlling extraction to the file system.
public struct ExtractionOptions: Sendable {
    /// Whether an existing regular file may be replaced.
    public var overwriteExisting: Bool

    /// 書庫の更新時刻と POSIX permissions を復元するか。
    ///
    /// directory の特殊 bit は復元する。directory 以外の setuid / setgid は既定で落とし、
    /// `preserveSetUserIDBits` が true のときだけ復元する。sticky は変更しない。
    /// resource-fork entry は、この呼出しで作成した data inode にだけ復元する。
    /// false または permissions の無い entry では、新規 object の mode は umask 由来の既定値。
    /// 所有者・ACL・拡張属性は復元しない。
    public var preserveMetadata: Bool

    /// directory 以外でも setuid / setgid を復元するか。`preserveMetadata` が true のときだけ有効。
    public var preserveSetUserIDBits: Bool

    /// Whether safe relative symbolic links are created.
    public var createSymbolicLinks: Bool

    /// Creates extraction options.
    public init(
        overwriteExisting: Bool = true,
        preserveMetadata: Bool = true,
        createSymbolicLinks: Bool = true,
        preserveSetUserIDBits: Bool = false
    ) {
        self.overwriteExisting = overwriteExisting
        self.preserveMetadata = preserveMetadata
        self.createSymbolicLinks = createSymbolicLinks
        self.preserveSetUserIDBits = preserveSetUserIDBits
    }
}
