import Darwin
import Foundation

/// Capacity information for the volume containing an open file or directory.
public enum ExtractionVolume {
    /// Available bytes for an unprivileged writer at the time of the call.
    public static func availableBytes(on descriptor: Int32) throws -> UInt64 {
        var information = statvfs()
        guard fstatvfs(descriptor, &information) == 0 else { throw KaitoError.io(errno) }
        return try Checked.mul(UInt64(information.f_bavail), UInt64(information.f_frsize))
    }

    /// Maximum size of a single file, if the mounted filesystem reports it.
    public static func maximumFileSize(on descriptor: Int32) throws -> UInt64? {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { throw KaitoError.io(errno) }
        let kind = withUnsafeBytes(of: &volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if ["msdos", "fat", "fat32"].contains(kind) { return UInt64(UInt32.max) }
        let mount = withUnsafeBytes(of: &volume.f_mntonname) { bytes in
            URL(fileURLWithFileSystemRepresentation: bytes.bindMemory(to: CChar.self).baseAddress!,
                isDirectory: true, relativeTo: nil)
        }
        let values = try? mount.resourceValues(forKeys: [.volumeMaximumFileSizeKey])
        guard let limit = values?.volumeMaximumFileSize, limit > 0 else { return nil }
        return UInt64(limit)
    }
}
