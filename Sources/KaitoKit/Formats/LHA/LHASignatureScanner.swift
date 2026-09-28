import Foundation

/// Recognizes LHA member headers at offset zero or after a bounded executable
/// prefix. Only the base-header structure (level 0–3 size, method and
/// checksum) is inspected; `LHAHeaderParser` parses the members.
enum LHASignatureScanner {
    struct Match {
        let offset: UInt64
    }

    /// LHA self-extractors in the compatibility corpus place their first
    /// member below this bound. Header bytes beyond the bound may be read only
    /// to authenticate a candidate beginning within it.
    static let maximumSFXSize: UInt64 = 1 * 1_024 * 1_024
    /// A genuine executable is not expected to contain even one accidental,
    /// authenticated LHA header. Capping retries keeps deliberately dense
    /// prefixes from turning candidate validation into unbounded parser work.
    private static let maximumSFXCandidates = 64
    /// The same leading window `FormatDetector` inspects for an offset-zero header.
    private static let prefixSize = 512

    /// Whether `bytes` (the start of the source) is a structurally plausible
    /// LHA base header whose declared size fits in `sourceLength`.
    static func isHeader(
        _ bytes: [UInt8],
        sourceLength: UInt64
    ) throws -> Bool {
        guard bytes.count >= 21,
              bytes[2] == 0x2D,
              bytes[6] == 0x2D else {
            return false
        }

        let methodMatches =
            (bytes[3] == 0x6C && (bytes[4] == 0x68 || bytes[4] == 0x7A))
            || (bytes[3] == 0x70 && bytes[4] == 0x6D)
        guard methodMatches else {
            return false
        }

        let level = bytes[20]
        let totalSize: UInt64
        switch level {
        case 0:
            // Level 0/1 store the base-header size excluding the two leading
            // size/checksum bytes. Both fixed fields and the name CRC must fit.
            guard bytes[0] >= 22 else { return false }
            totalSize = try Checked.add(UInt64(bytes[0]), 2)
        case 1:
            guard bytes[0] >= 25 else { return false }
            totalSize = try Checked.add(UInt64(bytes[0]), 2)
        case 2:
            // Level 2 uses a little-endian total header size. A low byte of
            // zero is the archive end marker, and the format therefore
            // forbids total header sizes that are multiples of 256.
            guard bytes[0] != 0 else { return false }
            totalSize = UInt64(bytes[0]) | (UInt64(bytes[1]) << 8)
            guard totalSize >= 26 else { return false }
        case 3:
            // Level 3 declares a four-byte extension-size width, followed by
            // its four-byte total header size and first extension size.
            guard bytes.count >= 32,
                  bytes[0] == 4,
                  bytes[1] == 0 else {
                return false
            }
            totalSize = UInt64(bytes[24])
                | (UInt64(bytes[25]) << 8)
                | (UInt64(bytes[26]) << 16)
                | (UInt64(bytes[27]) << 24)
            guard totalSize >= 32 else { return false }
        default:
            return false
        }
        return totalSize <= sourceLength
    }

    /// Returns authenticated LHA candidates in prefix order. A native archive
    /// at offset zero is authoritative. Embedded candidates are retained so
    /// the full parser can reject a plausible header embedded in executable
    /// code and resume at the next candidate.
    static func findSignatures(
        source: any ByteSource
    ) throws -> [Match] {
        let prefixCount = try Checked.toInt(min(source.length, UInt64(prefixSize)))
        let prefix = try readByteRange(source: source, offset: 0, count: prefixCount)
        if try isHeader(prefix, sourceLength: source.length) {
            return [Match(offset: 0)]
        }
        return try findSFXSignatures(source: source)
    }

    static func findSFXSignature(
        source: any ByteSource
    ) throws -> Match? {
        try findSFXSignatures(source: source).first
    }

    private static func findSFXSignatures(
        source: any ByteSource
    ) throws -> [Match] {
        let maximumHeaderSize: UInt64 = UInt64(UInt16.max)
        let maximumRead = try Checked.add(maximumSFXSize, maximumHeaderSize)
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= 22 else { return [] }
        let bytes = try readByteRange(source: source, offset: 0, count: count)
        let maximumStart = min(Int(maximumSFXSize), bytes.count - 21)
        guard maximumStart >= 1 else { return [] }

        var matches: [Match] = []
        matches.reserveCapacity(1)
        for index in 1...maximumStart where bytes[index + 2] == 0x2D {
            guard isFamilyMethod(bytes, at: index),
                  isAuthenticatedSFXHeader(bytes, at: index) else {
                continue
            }
            matches.append(Match(offset: UInt64(index)))
            if matches.count == maximumSFXCandidates {
                break
            }
        }
        return matches
    }

    private static func isFamilyMethod(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index <= bytes.count - 7,
              bytes[index + 2] == 0x2D,
              bytes[index + 6] == 0x2D else {
            return false
        }
        let family0 = bytes[index + 3]
        let family1 = bytes[index + 4]
        let variant = bytes[index + 5]
        let validVariant = (0x30...0x39).contains(variant)
            || (0x41...0x5A).contains(variant)
            || (0x61...0x7A).contains(variant)
        return validVariant
            && ((family0 == 0x6C && (family1 == 0x68 || family1 == 0x7A))
                || (family0 == 0x70 && family1 == 0x6D))
    }

    private static func isAuthenticatedSFXHeader(
        _ bytes: [UInt8],
        at index: Int
    ) -> Bool {
        guard index >= 0, index <= bytes.count - 21 else { return false }
        let level = bytes[index + 20]
        switch level {
        case 0, 1:
            let minimumSize = level == 0 ? 24 : 27
            let totalSize = Int(bytes[index]) + 2
            guard totalSize >= minimumSize,
                  totalSize <= bytes.count - index else {
                return false
            }
            var sum: UInt8 = 0
            for byte in bytes[(index + 2)..<(index + totalSize)] {
                sum &+= byte
            }
            return sum == bytes[index + 1]

        case 2:
            let totalSize = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            guard bytes[index] != 0,
                  totalSize >= 26,
                  totalSize <= bytes.count - index else {
                return false
            }
            let headerEnd = index + totalSize
            var currentSize = Int(bytes[index + 24])
                | (Int(bytes[index + 25]) << 8)
            var cursor = index + 26
            var records = 0
            while currentSize != 0 {
                guard currentSize >= 3,
                      cursor <= headerEnd,
                      currentSize <= headerEnd - cursor,
                      records <= Int(UInt16.max) else {
                    return false
                }
                let recordEnd = cursor + currentSize
                if bytes[cursor] == 0x00 {
                    guard currentSize >= 5 else { return false }
                    let expected = UInt16(bytes[cursor + 1])
                        | (UInt16(bytes[cursor + 2]) << 8)
                    var authenticated = Array(bytes[index..<headerEnd])
                    let crcOffset = cursor - index + 1
                    authenticated[crcOffset] = 0
                    authenticated[crcOffset + 1] = 0
                    return CRC16.checksum(authenticated) == expected
                }
                currentSize = Int(bytes[recordEnd - 2])
                    | (Int(bytes[recordEnd - 1]) << 8)
                cursor = recordEnd
                records += 1
            }
            // Common-header CRC is optional in interoperable level-2 files;
            // the bounded size, method, and extension envelope remain a
            // sufficiently strong candidate for the real parser to validate.
            return true

        default:
            return false
        }
    }
}
