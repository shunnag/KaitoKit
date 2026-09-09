import Foundation

/// Detects supported archive containers from their structural signatures.
///
/// Detection uses a stable order so ambiguous inputs behave consistently:
///
/// 1. A checksum-valid tar header (or the two-block empty-tar terminator) wins
///    over bytes in its pathname that resemble a shorter stream signature.
/// 2. Native markers are checked in this order: ZIP, RAR, 7-Zip, XZ,
///    structurally plausible LHA, gzip, bzip2, UNIX compress, then bare ustar.
///    LHA precedes the two-byte stream markers because its header supplies a
///    method and a bounded size envelope.
/// 3. When enabled, markers inside a recognized Mach-O or PE prefix are
///    considered by ascending offset, with ZIP, RAR, then 7-Zip as the stable
///    same-offset order.
/// 4. File-name hints are considered last and never replace content evidence.
public enum FormatDetector {
    private static let tarBlockSize = 512
    private static let zipEOCDMinimumSize = 22
    private static let zipMaximumCommentSize = 65_535
    private static let zipMaximumTrailingDataSize = 1 * 1_024 * 1_024
    /// Executable-prefix detection never examines a marker beyond one MiB.
    static let maximumSFXScanSize: UInt64 = 1 * 1_024 * 1_024
    /// Include the longest signature so a marker beginning at the final
    /// permitted byte remains visible.
    static let maximumRARSFXSize: UInt64 = maximumSFXScanSize
    /// LHA self-extractors in the compatibility corpus place their first
    /// member below this bound. Header bytes beyond the bound may be read only
    /// to authenticate a candidate beginning within it.
    static let maximumLHASFXSize: UInt64 = 1 * 1_024 * 1_024
    /// A genuine executable is not expected to contain even one accidental,
    /// authenticated LHA header. Capping retries keeps deliberately dense
    /// prefixes from turning candidate validation into unbounded parser work.
    private static let maximumLHASFXCandidates = 64

    enum RARVersion {
        case rar4
        case rar5
    }

    struct RARSignatureMatch {
        let offset: UInt64
        let version: RARVersion
    }

    struct LHASignatureMatch {
        let offset: UInt64
    }

    struct SFXSignatureMatch: Equatable {
        let offset: UInt64
        let format: ArchiveFormat
    }

    /// Detects the archive format exposed by an arbitrary byte source.
    ///
    /// Executable-prefix scanning is disabled unless
    /// ``ReaderOptions/scanForSFXInData`` is enabled. Native signatures at
    /// offset zero and established LHA prefix recognition are unaffected.
    public static func detect(
        source: any ByteSource,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveFormat {
        try detect(
            source: source,
            fileName: nil,
            sfxScanSize: options.scanForSFXInData
                ? options.maximumSFXScanSize
                : 0,
            limits: options.limits
        )
    }

    /// Detects the archive format in `data` without copying its storage.
    ///
    /// Executable-prefix scanning is off by default and can be opted into with
    /// ``ReaderOptions/scanForSFXInData``.
    public static func detect(
        data: Data,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveFormat {
        try detect(source: DataByteSource(data: data), options: options)
    }

    /// Detects the archive format at a file URL.
    ///
    /// File URLs inspect a bounded Mach-O or PE prefix by default. If content
    /// recognition does not decide the result, `.tar` and `.Z` extensions are
    /// used as hints. LZMA_Alone requires a `.lzma` extension and a plausible
    /// header, and is checked last.
    public static func detect(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveFormat {
        let source = try FileByteSource(url: url)
        return try detect(
            source: source,
            fileName: url.lastPathComponent,
            sfxScanSize: options.maximumSFXScanSize,
            limits: options.limits
        )
    }

    /// Detects using a source already opened for `sourceURL`.
    ///
    /// ArchiveReader uses this overload to preserve one file descriptor while
    /// retaining the URL-only executable scan and extension-hint behavior.
    static func detect(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions
    ) throws -> ArchiveFormat {
        try detect(
            source: source,
            fileName: sourceURL?.lastPathComponent,
            sfxScanSize: sourceURL != nil
                ? options.maximumSFXScanSize
                : (options.scanForSFXInData ? options.maximumSFXScanSize : 0),
            limits: options.limits
        )
    }

    private static func detect(
        source: any ByteSource,
        fileName: String?,
        sfxScanSize: UInt64,
        limits: ReadLimits
    ) throws -> ArchiveFormat {
        let prefixLength = try Checked.toInt(min(source.length, UInt64(tarBlockSize)))
        let prefix = try read(source: source, at: 0, count: prefixLength)

        // 512-byte 全体で検証できる tar checksum は短い magic より強い証拠になる。
        if try hasValidTarChecksum(prefix) {
            return .tar
        }
        if try isEmptyTar(source: source, firstBlock: prefix) {
            return .tar
        }

        if hasPrefix(prefix, [0x50, 0x4B, 0x03, 0x04])
            || hasPrefix(prefix, [0x50, 0x4B, 0x05, 0x06])
            || hasPrefix(prefix, [0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        if hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
            || hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
            return .rar
        }
        if hasPrefix(prefix, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }
        if hasPrefix(prefix, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xz
        }
        if try isLHAHeader(prefix, sourceLength: source.length) {
            return .lha
        }
        if hasPrefix(prefix, [0x1F, 0x8B]) {
            return .gzip
        }
        if isBzip2Header(prefix) {
            return .bzip2
        }
        if hasPrefix(prefix, [0x1F, 0x9D]) {
            return .compress
        }
        if try isTarHeader(prefix) {
            return .tar
        }
        // A damaged first local marker can still belong to a native ZIP when
        // its end record places the central directory at an absolute base of
        // zero. A nonzero inferred base is an SFX prefix and follows the
        // executable-prefix policy below.
        if try containsNativeZipEOCD(source: source) {
            return .zip
        }
        if let embedded = try findSFXSignature(
            source: source,
            maximumScanSize: sfxScanSize
        ) {
            return embedded.format
        }
        if try findLHASFXSignature(source: source) != nil {
            return .lha
        }

        if let fileName {
            let pathExtension = URL(fileURLWithPath: fileName).pathExtension
            if pathExtension.caseInsensitiveCompare("tar") == .orderedSame {
                return .tar
            }
            if pathExtension.caseInsensitiveCompare("Z") == .orderedSame {
                return .compress
            }
            // LZMA SDK lzma-specification.txt (2015-06-14) の header を
            // 最後に検査する。magic が無いため拡張子だけでは受理しない。
            if pathExtension.caseInsensitiveCompare("lzma") == .orderedSame,
               LZMAAloneHeader.isPlausible(prefix, limits: limits) {
                return .lzma
            }
        }

        throw KaitoError.unsupportedFormat
    }

    private static func hasPrefix(_ bytes: [UInt8], _ signature: [UInt8]) -> Bool {
        guard bytes.count >= signature.count else {
            return false
        }
        return bytes.indices.prefix(signature.count).allSatisfy { bytes[$0] == signature[$0] }
    }

    private static func isBzip2Header(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4,
              bytes[0] == 0x42,
              bytes[1] == 0x5A,
              bytes[2] == 0x68 else {
            return false
        }
        return (0x31...0x39).contains(bytes[3])
    }

    /// Locates the first ZIP, RAR, or 7-Zip marker in a recognized executable
    /// prefix. The scan bound is clamped even when this internal entry point is
    /// called directly.
    static func findSFXSignature(
        source: any ByteSource,
        maximumScanSize: UInt64
    ) throws -> SFXSignatureMatch? {
        let scanSize = min(maximumScanSize, maximumSFXScanSize)
        guard scanSize > 0 else { return nil }

        let longestSignatureSize: UInt64 = 8
        let maximumRead = try Checked.add(scanSize, longestSignatureSize)
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= 4 else { return nil }
        let bytes = try read(source: source, at: 0, count: count)
        guard isMachOOrPEPrefix(bytes) else { return nil }

        let zipLocal: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let zipEmpty: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let zipSpanned: [UInt8] = [0x50, 0x4B, 0x07, 0x08]
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5: [UInt8] = rar4.dropLast() + [0x01, 0x00]
        let sevenZip: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

        let maximumStart = min(Int(scanSize), bytes.count - 4)
        guard maximumStart >= 1 else { return nil }
        for index in 1...maximumStart {
            // Offset is the primary tie-break. This fixed per-offset order is
            // also the order documented on FormatDetector.
            if matches(bytes, signature: zipLocal, at: index)
                || matches(bytes, signature: zipEmpty, at: index)
                || matches(bytes, signature: zipSpanned, at: index) {
                return SFXSignatureMatch(offset: UInt64(index), format: .zip)
            }
            if matches(bytes, signature: rar5, at: index)
                || matches(bytes, signature: rar4, at: index) {
                return SFXSignatureMatch(offset: UInt64(index), format: .rar)
            }
            if matches(bytes, signature: sevenZip, at: index) {
                return SFXSignatureMatch(offset: UInt64(index), format: .sevenZip)
            }
        }
        return nil
    }

    private static func matches(
        _ bytes: [UInt8],
        signature: [UInt8],
        at offset: Int
    ) -> Bool {
        guard offset >= 0, offset <= bytes.count - signature.count else {
            return false
        }
        return bytes[offset..<(offset + signature.count)].elementsEqual(signature)
    }

    private static func isMachOOrPEPrefix(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }

        let magic = Array(bytes[0..<4])
        let machOMagics: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE], // 32-bit, native byte order
            [0xCE, 0xFA, 0xED, 0xFE], // 32-bit, swapped byte order
            [0xFE, 0xED, 0xFA, 0xCF], // 64-bit, native byte order
            [0xCF, 0xFA, 0xED, 0xFE], // 64-bit, swapped byte order
            [0xCA, 0xFE, 0xBA, 0xBE], // universal binary
            [0xBE, 0xBA, 0xFE, 0xCA], // swapped universal binary
            [0xCA, 0xFE, 0xBA, 0xBF], // 64-bit universal binary
            [0xBF, 0xBA, 0xFE, 0xCA], // swapped 64-bit universal binary
        ]
        if machOMagics.contains(magic) {
            return true
        }

        guard bytes.count >= 64,
              bytes[0] == 0x4D,
              bytes[1] == 0x5A else {
            return false
        }
        let peOffset = UInt64(bytes[0x3C])
            | (UInt64(bytes[0x3D]) << 8)
            | (UInt64(bytes[0x3E]) << 16)
            | (UInt64(bytes[0x3F]) << 24)
        guard peOffset >= 64,
              peOffset <= UInt64(bytes.count - 4),
              let offset = Int(exactly: peOffset) else {
            return false
        }
        return bytes[offset] == 0x50
            && bytes[offset + 1] == 0x45
            && bytes[offset + 2] == 0
            && bytes[offset + 3] == 0
    }

    private static func isLHAHeader(
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

    /// Returns the first LHA member header at offset zero or after a bounded
    /// executable prefix.
    static func findLHASignature(
        source: any ByteSource
    ) throws -> LHASignatureMatch? {
        try findLHASignatures(source: source).first
    }

    /// Returns authenticated LHA candidates in prefix order. A native archive
    /// at offset zero is authoritative. Embedded candidates are retained so
    /// the full parser can reject a plausible header embedded in executable
    /// code and resume at the next candidate.
    static func findLHASignatures(
        source: any ByteSource
    ) throws -> [LHASignatureMatch] {
        let prefixCount = try Checked.toInt(min(source.length, UInt64(tarBlockSize)))
        let prefix = try read(source: source, at: 0, count: prefixCount)
        if try isLHAHeader(prefix, sourceLength: source.length) {
            return [LHASignatureMatch(offset: 0)]
        }
        return try findLHASFXSignatures(source: source)
    }

    private static func findLHASFXSignature(
        source: any ByteSource
    ) throws -> LHASignatureMatch? {
        try findLHASFXSignatures(source: source).first
    }

    private static func findLHASFXSignatures(
        source: any ByteSource
    ) throws -> [LHASignatureMatch] {
        let maximumHeaderSize: UInt64 = UInt64(UInt16.max)
        let maximumRead = try Checked.add(maximumLHASFXSize, maximumHeaderSize)
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= 22 else { return [] }
        let bytes = try read(source: source, at: 0, count: count)
        let maximumStart = min(Int(maximumLHASFXSize), bytes.count - 21)
        guard maximumStart >= 1 else { return [] }

        var matches: [LHASignatureMatch] = []
        matches.reserveCapacity(1)
        for index in 1...maximumStart where bytes[index + 2] == 0x2D {
            guard isLHAFamilyMethod(bytes, at: index),
                  isAuthenticatedLHASFXHeader(bytes, at: index) else {
                continue
            }
            matches.append(LHASignatureMatch(offset: UInt64(index)))
            if matches.count == maximumLHASFXCandidates {
                break
            }
        }
        return matches
    }

    private static func isLHAFamilyMethod(_ bytes: [UInt8], at index: Int) -> Bool {
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

    private static func isAuthenticatedLHASFXHeader(
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

    private static func isTarHeader(_ bytes: [UInt8]) throws -> Bool {
        guard bytes.count >= tarBlockSize else {
            return false
        }

        if bytes[257] == 0x75,
           bytes[258] == 0x73,
           bytes[259] == 0x74,
           bytes[260] == 0x61,
           bytes[261] == 0x72 {
            return true
        }

        return try hasValidTarChecksum(bytes)
    }

    private static func hasValidTarChecksum(_ bytes: [UInt8]) throws -> Bool {
        guard bytes.count >= tarBlockSize else {
            return false
        }

        // 終端のゼロブロックを空の tar ヘッダと誤認しない。
        guard bytes[..<tarBlockSize].contains(where: { $0 != 0 }) else {
            return false
        }
        guard let recordedChecksum = try parseTarChecksum(bytes[148..<156]) else {
            return false
        }

        var unsignedSum: UInt64 = 0
        var signedSum: Int64 = 0
        for index in 0..<tarBlockSize {
            let byte: UInt8 = (148..<156).contains(index) ? 0x20 : bytes[index]
            unsignedSum = try Checked.add(unsignedSum, UInt64(byte))
            signedSum += Int64(Int8(bitPattern: byte))
        }

        // 古い実装が作った signed-char checksum も安全に認識する。
        return recordedChecksum == unsignedSum
            || (signedSum >= 0 && recordedChecksum == UInt64(signedSum))
    }

    private static func isEmptyTar(
        source: any ByteSource,
        firstBlock: [UInt8]
    ) throws -> Bool {
        guard firstBlock.count == tarBlockSize,
              firstBlock.allSatisfy({ $0 == 0 }),
              source.length >= UInt64(tarBlockSize * 2) else {
            return false
        }
        let secondBlock = try read(
            source: source,
            at: UInt64(tarBlockSize),
            count: tarBlockSize
        )
        return secondBlock.allSatisfy { $0 == 0 }
    }

    private static func parseTarChecksum(_ field: ArraySlice<UInt8>) throws -> UInt64? {
        var value: UInt64 = 0
        var sawDigit = false
        var reachedPadding = false
        var reachedNULTerminator = false

        for byte in field {
            if byte == 0 {
                reachedNULTerminator = true
                continue
            }
            if byte == 0x20 {
                if sawDigit {
                    reachedPadding = true
                }
                continue
            }
            guard !reachedNULTerminator,
                  !reachedPadding,
                  (0x30...0x37).contains(byte) else {
                return nil
            }
            sawDigit = true
            value = try Checked.mul(value, 8)
            value = try Checked.add(value, UInt64(byte - 0x30))
        }
        return sawDigit ? value : nil
    }

    private static func containsNativeZipEOCD(
        source: any ByteSource
    ) throws -> Bool {
        guard source.length >= UInt64(zipEOCDMinimumSize) else {
            return false
        }

        let maximumSearch = zipMaximumCommentSize
            + zipEOCDMinimumSize
            + zipMaximumTrailingDataSize
        let searchLength = try Checked.toInt(min(source.length, UInt64(maximumSearch)))
        let searchOffset = try Checked.sub(source.length, UInt64(searchLength))
        let tail = try read(source: source, at: searchOffset, count: searchLength)
        guard tail.count >= zipEOCDMinimumSize else {
            return false
        }

        for index in stride(
            from: tail.count - zipEOCDMinimumSize,
            through: 0,
            by: -1
        ) {
            guard tail[index] == 0x50,
                  tail[index + 1] == 0x4B,
                  tail[index + 2] == 0x05,
                  tail[index + 3] == 0x06 else {
                continue
            }

            let highCommentLength = try Checked.shiftLeft(
                UInt64(tail[index + 21]),
                by: 8
            )
            let commentLength = UInt64(tail[index + 20]) | highCommentLength
            let recordLength = try Checked.add(UInt64(zipEOCDMinimumSize), commentLength)
            let recordEnd = try Checked.add(UInt64(index), recordLength)
            guard recordEnd <= UInt64(tail.count),
                  UInt64(tail.count) - recordEnd <= UInt64(zipMaximumTrailingDataSize) else {
                continue
            }

            let directorySize = littleEndianUInt32(tail, at: index + 12)
            let directoryOffset = littleEndianUInt32(tail, at: index + 16)
            // ZIP64 sentinels require the ZIP64 end record to infer a base.
            // Normal ZIP64 archives still have a native local marker at zero.
            guard directorySize != UInt64(UInt32.max),
                  directoryOffset != UInt64(UInt32.max) else {
                continue
            }
            let directoryEnd = directoryOffset.addingReportingOverflow(directorySize)
            guard !directoryEnd.overflow else { continue }
            let absoluteRecordOffset = try Checked.add(searchOffset, UInt64(index))
            if directoryEnd.partialValue == absoluteRecordOffset {
                return true
            }
        }
        return false
    }

    private static func littleEndianUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt64 {
        UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 24)
    }

    /// Locates a RAR4 or RAR5 marker at offset zero or after a bounded SFX
    /// executable prefix. The format readers authenticate the following main
    /// header, so this routine deliberately performs only marker recognition.
    static func findRARSignature(
        source: any ByteSource
    ) throws -> RARSignatureMatch? {
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]
        let rar5: [UInt8] = rar4.dropLast() + [0x01, 0x00]
        let prefixCount = try Checked.toInt(min(source.length, UInt64(rar5.count)))
        let prefix = try read(source: source, at: 0, count: prefixCount)
        if prefix.count >= rar5.count, prefix.prefix(rar5.count).elementsEqual(rar5) {
            return RARSignatureMatch(offset: 0, version: .rar5)
        }
        if prefix.count >= rar4.count, prefix.prefix(rar4.count).elementsEqual(rar4) {
            return RARSignatureMatch(offset: 0, version: .rar4)
        }

        let maximumRead = try Checked.add(maximumRARSFXSize, UInt64(rar5.count))
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= rar4.count else { return nil }
        let bytes = try read(source: source, at: 0, count: count)

        let maximumStart = min(
            Int(maximumRARSFXSize),
            bytes.count - rar4.count
        )
        guard maximumStart >= 1 else { return nil }
        for index in 1...maximumStart where bytes[index] == rar4[0] {
            if index <= bytes.count - rar5.count,
               bytes[index..<(index + rar5.count)].elementsEqual(rar5) {
                return RARSignatureMatch(offset: UInt64(index), version: .rar5)
            }
            if bytes[index..<(index + rar4.count)].elementsEqual(rar4) {
                return RARSignatureMatch(offset: UInt64(index), version: .rar4)
            }
        }
        return nil
    }

    private static func read(
        source: any ByteSource,
        at offset: UInt64,
        count: Int
    ) throws -> [UInt8] {
        guard count >= 0 else {
            throw KaitoError.malformed("negative detector read size")
        }
        let endOffset = try Checked.add(offset, UInt64(count))
        guard endOffset <= source.length else {
            throw KaitoError.truncated
        }
        guard count > 0 else {
            return []
        }

        var result = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let readOffset = try Checked.add(offset, UInt64(filled))
            let bytesRead = try result.withUnsafeMutableBytes { bytes -> Int in
                // filled..<count は result の有効範囲で、ByteSource に未充填部分だけを公開する。
                let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<count])
                return try source.read(into: destination, at: readOffset)
            }
            guard bytesRead >= 0, bytesRead <= count - filled else {
                throw KaitoError.malformed("ByteSource returned an invalid byte count")
            }
            guard bytesRead != 0 else {
                throw KaitoError.truncated
            }
            filled += bytesRead
        }
        return result
    }
}
