import Foundation

// Deterministic old .rar/.r00 volume resolution with the same directory
// identity boundary as RARVolumeLocator. No third-party decoder source was used.
final class RAR13VolumeLocator {
    private let firstURL: URL
    private let directory: FileByteSource.DirectoryAnchor
    private let maxVolumeCount: Int
    private var volumes: [UInt64: RARLocatedVolume]

    init(
        firstVolumeURL: URL,
        firstVolumeSource: any ByteSource,
        firstVolumeDirectory: FileByteSource.DirectoryAnchor?,
        firstVolumeIdentitySource: (any ByteSource)?,
        firstVolumeSignatureOffset: UInt64,
        maxVolumeCount: Int
    ) throws {
        let url = firstVolumeURL.standardizedFileURL
        let opened = firstVolumeDirectory == nil ? try FileByteSource.openAnchored(url: url) : nil
        guard let directory = firstVolumeDirectory ?? opened?.directory else {
            throw KaitoError.malformed("RAR1.3 first volume anchor is incomplete")
        }
        guard let identity = (firstVolumeIdentitySource ?? firstVolumeSource) as? FileByteSource else {
            throw KaitoError.malformed("RAR1.3 first volume identity is unavailable")
        }
        try directory.verifyFirstVolumeIdentity(
            of: identity, named: url.lastPathComponent, label: "RAR1.3"
        )
        guard try readByteRange(
            source: firstVolumeSource, offset: firstVolumeSignatureOffset, count: 4
        ) == RAR13Reader.signature else {
            throw KaitoError.malformed("RAR1.3 first volume signature")
        }
        guard maxVolumeCount > 0 else {
            throw KaitoError.limitExceeded("RAR1.3 volume count")
        }
        self.firstURL = url
        self.directory = directory
        self.maxVolumeCount = maxVolumeCount
        volumes = [0: RARLocatedVolume(number: 0, url: url, source: firstVolumeSource)]
    }

    func locate(volumeNumber: UInt64) throws -> RARLocatedVolume {
        if let existing = volumes[volumeNumber] { return existing }
        guard volumeNumber > 0, volumeNumber < UInt64(maxVolumeCount) else {
            throw KaitoError.limitExceeded("RAR1.3 volume count")
        }
        guard volumes.count < maxVolumeCount else {
            throw KaitoError.limitExceeded("RAR1.3 volume count")
        }
        let name = try candidateName(volumeNumber: volumeNumber)
        guard let source = try directory.openRegularFile(named: name, label: "RAR1.3") else {
            throw KaitoError.truncated
        }
        guard try readByteRange(source: source, offset: 0, count: 4) == RAR13Reader.signature else {
            throw KaitoError.malformed("RAR1.3 continuation volume signature")
        }
        let result = RARLocatedVolume(
            number: volumeNumber,
            url: firstURL.deletingLastPathComponent().appendingPathComponent(name),
            source: source
        )
        volumes[volumeNumber] = result
        return result
    }

    private func candidateName(volumeNumber: UInt64) throws -> String {
        let fileExtension = firstURL.pathExtension.lowercased()
        guard fileExtension == "rar" || fileExtension == "exe" else {
            throw KaitoError.malformed("RAR1.3 old-numbered first volume is not .rar")
        }
        let ordinal = volumeNumber - 1
        let letterOffset = ordinal / 100
        guard letterOffset <= UInt64(UInt8(ascii: "z") - UInt8(ascii: "r")) else {
            throw KaitoError.limitExceeded("RAR1.3 volume number is too large")
        }
        let letter = Character(UnicodeScalar(UInt8(ascii: "r") + UInt8(letterOffset)))
        let digits = String(format: "%02d", ordinal % 100)
        return firstURL.deletingPathExtension().lastPathComponent + "." + String(letter) + digits
    }
}
