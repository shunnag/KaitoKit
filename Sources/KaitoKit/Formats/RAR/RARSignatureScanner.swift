import Foundation

/// Locates a RAR4 or RAR5 marker at offset zero or after a bounded SFX
/// executable prefix. The format readers authenticate the following main
/// header, so this scanner deliberately performs only marker recognition.
enum RARSignatureScanner {
    enum Version {
        case rar4
        case rar5
    }

    struct Match {
        let offset: UInt64
        let version: Version
    }

    /// Include the longest signature so a marker beginning at the final
    /// permitted byte remains visible.
    static let maximumSFXSize: UInt64 = FormatDetector.maximumSFXScanSize

    /// Returns the marker at offset zero, or the first one inside the bounded
    /// executable prefix.
    static func find(
        source: any ByteSource
    ) throws -> Match? {
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]
        let rar5: [UInt8] = rar4.dropLast() + [0x01, 0x00]
        let prefixCount = try Checked.toInt(min(source.length, UInt64(rar5.count)))
        let prefix = try readByteRange(source: source, offset: 0, count: prefixCount)
        if prefix.count >= rar5.count, prefix.prefix(rar5.count).elementsEqual(rar5) {
            return Match(offset: 0, version: .rar5)
        }
        if prefix.count >= rar4.count, prefix.prefix(rar4.count).elementsEqual(rar4) {
            return Match(offset: 0, version: .rar4)
        }

        let maximumRead = try Checked.add(maximumSFXSize, UInt64(rar5.count))
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= rar4.count else { return nil }
        let bytes = try readByteRange(source: source, offset: 0, count: count)

        let maximumStart = min(
            Int(maximumSFXSize),
            bytes.count - rar4.count
        )
        guard maximumStart >= 1 else { return nil }
        for index in 1...maximumStart where bytes[index] == rar4[0] {
            if index <= bytes.count - rar5.count,
               bytes[index..<(index + rar5.count)].elementsEqual(rar5) {
                return Match(offset: UInt64(index), version: .rar5)
            }
            if bytes[index..<(index + rar4.count)].elementsEqual(rar4) {
                return Match(offset: UInt64(index), version: .rar4)
            }
        }
        return nil
    }
}
