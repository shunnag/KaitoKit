import Foundation

// Provenance / format references:
// - RARLab, "RAR 5.0 archive format" technote (volume flags, zero-based
//   volume numbers, signature, main-header layout and CRC32 coverage).
// - bitplane/rar-research's unofficial clean-room RAR 1.5-4.x notes
//   (old .rar/.r00 naming and new .partN.rar naming).
// - KaitoKit M3 requirements for same-directory lookup and Data-backed errors.
// No unrar, 7-Zip Rar29, XADMaster, The Unarchiver, or RAR5 decoder source was
// consulted.

enum RARVolumeNaming: Sendable {
    case rar4Old
    case rar4New
    case rar5
}

struct RARLocatedVolume: Sendable {
    let number: UInt64
    let url: URL?
    let source: any ByteSource
}

/// Resolves only deterministic sibling names below the first volume's directory.
final class RARVolumeLocator {
    private struct PartPattern: Sendable {
        let prefix: String
        let marker: String
        let width: Int
        let firstPartNumber: UInt64
        let archiveExtension: String
    }

    private enum Origin: Sendable {
        case file(
            directory: URL,
            handle: FileByteSource.DirectoryAnchor,
            firstURL: URL,
            pattern: PartPattern?
        )
        case anonymous
    }

    private let naming: RARVolumeNaming
    private let origin: Origin
    private let maxMetadataSize: UInt64
    private let maxVolumeCount: Int
    private var volumes: [UInt64: RARLocatedVolume]

    init(
        firstVolumeURL: URL,
        firstVolumeSource: (any ByteSource)? = nil,
        firstVolumeDirectory: FileByteSource.DirectoryAnchor? = nil,
        naming: RARVolumeNaming,
        maxMetadataSize: UInt64 = 16 * 1_024 * 1_024,
        maxVolumeCount: Int = 128
    ) throws {
        let maxVolumeCount = max(0, maxVolumeCount)
        guard maxVolumeCount > 0 else {
            throw KaitoError.limitExceeded(Self.volumeCountLabel(for: naming))
        }
        let firstURL = firstVolumeURL.standardizedFileURL
        let pattern: PartPattern?
        switch naming {
        case .rar4Old:
            pattern = nil
        case .rar4New, .rar5:
            pattern = Self.partPattern(for: firstURL)
        }
        if case .rar5 = naming,
           let pattern,
           pattern.firstPartNumber != 1 {
            throw KaitoError.malformed(
                "RAR5 numbered input is not the first .part1.rar volume"
            )
        }

        let source: any ByteSource
        let handle: FileByteSource.DirectoryAnchor?
        switch (firstVolumeSource, firstVolumeDirectory) {
        case let (providedSource?, providedDirectory):
            source = providedSource
            handle = providedDirectory
        case (nil, nil):
            let opened = try FileByteSource.openAnchored(url: firstURL)
            source = opened.source
            handle = opened.directory
        default:
            throw KaitoError.malformed("RAR first volume anchor is incomplete")
        }
        let first = RARLocatedVolume(number: 0, url: firstURL, source: source)
        try Self.validate(
            first,
            naming: naming,
            maxMetadataSize: maxMetadataSize
        )

        let directory = firstURL.deletingLastPathComponent().standardizedFileURL
        guard let descriptorSource = source as? FileByteSource else {
            throw KaitoError.malformed("RAR first volume anchor is incomplete")
        }
        guard let handle else {
            // 親を開けない fallback は匿名 origin とし、後続巻は既存の unsupportedMethod で拒否する。
            self.naming = naming
            self.origin = .anonymous
            self.maxMetadataSize = maxMetadataSize
            self.maxVolumeCount = maxVolumeCount
            self.volumes = [0: first]
            return
        }
        try handle.verifyFirstVolumeIdentity(
            of: descriptorSource,
            named: firstURL.lastPathComponent,
            label: "RAR"
        )
        self.naming = naming
        self.origin = .file(
            directory: directory,
            handle: handle,
            firstURL: firstURL,
            pattern: pattern
        )
        self.maxMetadataSize = maxMetadataSize
        self.maxVolumeCount = maxVolumeCount
        self.volumes = [0: first]
    }

    /// Anonymous sources retain volume zero, but any continuation has the exact
    /// failure required by the public Data-backed reader contract.
    init(
        dataBackedSource source: any ByteSource,
        naming: RARVolumeNaming,
        maxMetadataSize: UInt64 = 16 * 1_024 * 1_024,
        maxVolumeCount: Int = 128
    ) throws {
        let maxVolumeCount = max(0, maxVolumeCount)
        guard maxVolumeCount > 0 else {
            throw KaitoError.limitExceeded(Self.volumeCountLabel(for: naming))
        }
        let first = RARLocatedVolume(number: 0, url: nil, source: source)
        try Self.validate(
            first,
            naming: naming,
            maxMetadataSize: maxMetadataSize
        )
        self.naming = naming
        self.origin = .anonymous
        self.maxMetadataSize = maxMetadataSize
        self.maxVolumeCount = maxVolumeCount
        self.volumes = [0: first]
    }

    func locate(volumeNumber: UInt64) throws -> RARLocatedVolume {
        if let existing = volumes[volumeNumber] { return existing }
        guard case let .file(directory, handle, firstURL, pattern) = origin else {
            throw KaitoError.unsupportedMethod("multi-volume from Data")
        }
        guard volumeNumber < UInt64(maxVolumeCount),
              volumes.count < maxVolumeCount else {
            throw KaitoError.limitExceeded(Self.volumeCountLabel(for: naming))
        }

        let name = try candidateName(
            firstURL: firstURL,
            pattern: pattern,
            volumeNumber: volumeNumber
        )
        guard let source = try handle.openRegularFile(named: name, label: "RAR") else {
            throw KaitoError.truncated
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let result = RARLocatedVolume(
            number: volumeNumber,
            url: url,
            source: source
        )
        try Self.validate(
            result,
            naming: naming,
            maxMetadataSize: maxMetadataSize
        )
        volumes[volumeNumber] = result
        return result
    }

    private func candidateName(
        firstURL: URL,
        pattern: PartPattern?,
        volumeNumber: UInt64
    ) throws -> String {
        guard volumeNumber > 0 else { return firstURL.lastPathComponent }
        switch naming {
        case .rar4Old:
            let firstExtension = firstURL.pathExtension.lowercased()
            guard firstExtension == "rar" else {
                throw KaitoError.malformed("RAR4 old-numbered first volume is not .rar")
            }
            let ordinal = volumeNumber - 1
            let letterOffset = ordinal / 100
            guard letterOffset <= UInt64(UInt8(ascii: "z") - UInt8(ascii: "r")) else {
                throw KaitoError.limitExceeded("RAR4 old volume number is too large")
            }
            let letter = Character(UnicodeScalar(UInt8(ascii: "r") + UInt8(letterOffset)))
            let digits = String(ordinal % 100)
            let suffix = String(repeating: "0", count: 2 - digits.count) + digits
            return firstURL.deletingPathExtension().lastPathComponent
                + "." + String(letter) + suffix

        case .rar4New, .rar5:
            let fallbackPrefix = firstURL.deletingPathExtension().lastPathComponent
            let firstName = firstURL.lastPathComponent
            let fallbackExtension = firstName.lowercased().hasSuffix(".rar")
                ? String(firstName.suffix(4))
                : ".rar"
            let selected = pattern ?? PartPattern(
                prefix: fallbackPrefix,
                marker: ".part",
                width: 1,
                firstPartNumber: 1,
                archiveExtension: fallbackExtension
            )
            let (partNumber, overflow) = selected.firstPartNumber
                .addingReportingOverflow(volumeNumber)
            guard !overflow else {
                throw KaitoError.limitExceeded("RAR volume number overflow")
            }
            let rawDigits = String(partNumber)
            let digits = String(
                repeating: "0",
                count: max(0, selected.width - rawDigits.count)
            ) + rawDigits
            return selected.prefix + selected.marker + digits
                + selected.archiveExtension
        }
    }

    private static func partPattern(for url: URL) -> PartPattern? {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".rar") else { return nil }
        let stem = String(name.dropLast(4))
        guard let marker = stem.range(
            of: ".part",
            options: [.backwards, .caseInsensitive]
        ) else { return nil }
        let digitText = String(stem[marker.upperBound...])
        guard !digitText.isEmpty,
              digitText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let number = UInt64(digitText),
              number > 0 else {
            return nil
        }
        return PartPattern(
            prefix: String(stem[..<marker.lowerBound]),
            marker: String(stem[marker]),
            width: digitText.count,
            firstPartNumber: number,
            archiveExtension: String(name.suffix(4))
        )
    }

    private static func volumeCountLabel(for naming: RARVolumeNaming) -> String {
        switch naming {
        case .rar4Old, .rar4New: "RAR4 volume count"
        case .rar5: "RAR5 volume count"
        }
    }

    private static func validate(
        _ volume: RARLocatedVolume,
        naming: RARVolumeNaming,
        maxMetadataSize: UInt64
    ) throws {
        switch naming {
        case .rar4Old, .rar4New:
            let expected: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
            guard try readByteRange(
                source: volume.source,
                offset: 0,
                count: expected.count
            ) == expected else {
                throw KaitoError.malformed("RAR4 volume signature mismatch")
            }
        case .rar5:
            try validateRAR5(volume, maxMetadataSize: maxMetadataSize)
        }
    }

    private static func validateRAR5(
        _ volume: RARLocatedVolume,
        maxMetadataSize: UInt64
    ) throws {
        let signature: [UInt8] = [
            0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00,
        ]
        guard try readByteRange(
            source: volume.source,
            offset: 0,
            count: signature.count
        ) == signature else {
            throw KaitoError.malformed("RAR5 volume signature mismatch")
        }

        var reader = try ByteReader(source: volume.source, offset: UInt64(signature.count))
        let storedCRC = try reader.readUInt32LE()
        let sizeField = try readVInt(from: &reader)
        guard sizeField.encoded.count <= 3 else {
            throw KaitoError.malformed("RAR5 header-size vint exceeds 3 bytes")
        }
        guard sizeField.value >= 2 else {
            throw KaitoError.malformed("RAR5 header size is too small")
        }
        try Checked.size(sizeField.value, limit: maxMetadataSize)
        guard sizeField.value <= reader.remaining else { throw KaitoError.truncated }
        let bodySize = try Checked.toInt(sizeField.value)
        let body = [UInt8](try reader.readBytes(bodySize))
        var crcBytes = sizeField.encoded
        crcBytes.append(contentsOf: body)
        guard CRC32.checksum(crcBytes) == storedCRC else {
            throw KaitoError.malformed("RAR5 volume main header CRC mismatch")
        }

        var cursor = VIntCursor(body)
        let type = try cursor.read()
        let headerFlags = try cursor.read()
        let extraSize = headerFlags & 0x0001 != 0 ? try cursor.read() : 0
        let dataSize = headerFlags & 0x0002 != 0 ? try cursor.read() : 0

        if type == 4 {
            guard headerFlags == 0, extraSize == 0, dataSize == 0 else {
                throw KaitoError.malformed(
                    "RAR5 archive encryption header has invalid common flags"
                )
            }
            let version = try cursor.read()
            guard version == 0 else {
                throw KaitoError.unsupportedMethod(
                    "RAR5 archive encryption version \(version)"
                )
            }
            let encryptionFlags = try cursor.read()
            guard encryptionFlags & ~UInt64(0x0001) == 0 else {
                throw KaitoError.unsupportedMethod(
                    "RAR5 archive encryption flags 0x\(String(encryptionFlags, radix: 16))"
                )
            }
            _ = try cursor.readUInt8() // KDF count is bounded by RAR5Reader.
            try cursor.skip(16) // global archive-header salt
            if encryptionFlags & 0x0001 != 0 { try cursor.skip(12) }
            guard cursor.isAtEnd else {
                throw KaitoError.malformed(
                    "RAR5 archive encryption header has trailing fields"
                )
            }
            // The encrypted main header is authenticated and its volume number
            // checked by RAR5Reader immediately after this structural check.
            return
        }

        guard type == 1 else {
            throw KaitoError.malformed("RAR5 volume does not start with a main header")
        }
        _ = extraSize
        _ = dataSize
        let archiveFlags = try cursor.read()
        guard archiveFlags & 0x0001 != 0 else {
            throw KaitoError.malformed("RAR5 continuation is not marked as a volume")
        }
        let recordedNumber = archiveFlags & 0x0002 != 0 ? try cursor.read() : 0
        guard recordedNumber == volume.number else {
            throw KaitoError.malformed(
                "RAR5 volume number \(recordedNumber) does not match expected \(volume.number)"
            )
        }
        if volume.number == 0, archiveFlags & 0x0002 != 0 {
            throw KaitoError.malformed(
                "RAR5 first volume has an explicit volume number"
            )
        }
    }

    private static func readVInt(
        from reader: inout ByteReader
    ) throws -> (value: UInt64, encoded: [UInt8]) {
        var value: UInt64 = 0
        var encoded: [UInt8] = []
        for index in 0..<10 {
            let byte = try reader.readUInt8()
            encoded.append(byte)
            let shift = index * 7
            if shift < 64 {
                let usefulBits = min(7, 64 - shift)
                let mask = (UInt64(1) << UInt64(usefulBits)) - 1
                value |= (UInt64(byte & 0x7F) & mask) << UInt64(shift)
            }
            if byte & 0x80 == 0 { return (value, encoded) }
        }
        throw KaitoError.malformed("RAR vint exceeds 10 bytes")
    }

    private struct VIntCursor {
        let bytes: [UInt8]
        var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < bytes.count else { throw KaitoError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - offset else {
                throw KaitoError.truncated
            }
            offset += count
        }

        mutating func read() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw KaitoError.truncated }
                let byte = bytes[offset]
                offset += 1
                let shift = index * 7
                if shift < 64 {
                    let usefulBits = min(7, 64 - shift)
                    let mask = (UInt64(1) << UInt64(usefulBits)) - 1
                    value |= (UInt64(byte & 0x7F) & mask) << UInt64(shift)
                }
                if byte & 0x80 == 0 { return value }
            }
            throw KaitoError.malformed("RAR vint exceeds 10 bytes")
        }
    }
}
