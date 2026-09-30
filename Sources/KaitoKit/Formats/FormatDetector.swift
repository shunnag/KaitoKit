import Foundation

/// Detects supported archive containers from their structural signatures.
///
/// Detection uses a stable order so ambiguous inputs behave consistently:
///
/// 1. A checksum-valid 512-byte tar member header wins over bytes in its
///    pathname that resemble a shorter stream signature.
/// 2. A StuffIt envelope (a StuffIt / StuffIt X payload, a StuffIt SFX, or a
///    MacBinary / AppleSingle / BinHex wrapper) is unwrapped one level unless
///    a native signature from step 3 rules it out.
/// 3. Native markers at offset zero, in this order: ZIP, RAR, 7-Zip; the UDIF
///    (dmg) trailer; XZ, lzip, pbzx, WIM, CFB, CHM, ARJ (main header
///    authenticated), xar, LZ4, Zstandard (skippable frames resolved by the
///    first regular frame), RPM, CAB, structurally plausible LHA, gzip, bzip2,
///    UNIX compress, `!<arch>` / `!<thin>` ar, structurally valid ASCII cpio.
///    LHA precedes the two-byte stream markers because its header supplies a
///    method and a bounded size envelope.
/// 4. A native ZIP whose first local marker is damaged is still recognized
///    when its end record places the central directory at absolute base zero.
/// 5. When enabled, markers inside a recognized Mach-O or PE prefix are
///    considered by ascending offset, with ZIP, RAR, 7-Zip, then CAB as the
///    stable same-offset order; then an LHA self-extractor, then an ARJ DOS
///    self-extractor.
/// 6. ISO 9660 / UDF volume descriptors at sector 16, on the plain image and
///    on a raw-sector (BIN/CUE, .img, .mdf) image; then a raw Apple disk image
///    (GPT / APM / bare HFS+).
/// 7. File-name hints follow content evidence: `.tar`, `.Z`, an empty
///    `.lha` / `.lzh`, LZMA_Alone (`.lzma` / `.tlz` with a plausible header),
///    brotli (`.br` / `.tbr` with a valid header and a trial decode).
/// 8. Binary cpio is considered last and must validate a bounded record chain.
public enum FormatDetector {
    private static let tarBlockSize = 512
    /// Executable-prefix detection never examines a marker beyond one MiB.
    static let maximumSFXScanSize: UInt64 = 1 * 1_024 * 1_024

    // LHA / RAR の走査は LHASignatureScanner / RARSignatureScanner にある。
    // 以下はその入口を FormatDetector の名前で呼ぶ既存 caller のための転送。
    static let maximumRARSFXSize: UInt64 = RARSignatureScanner.maximumSFXSize
    static let maximumLHASFXSize: UInt64 = LHASignatureScanner.maximumSFXSize
    static func findRARSignature(source: any ByteSource) throws -> RARSignatureScanner.Match? {
        try RARSignatureScanner.find(source: source)
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
            limits: options.limits,
            recoverDamagedArchives: options.recoverDamagedArchives
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
    /// `.001` からのバイト分割巻は ArchiveReader と同じ規則・上限で連結する。
    ///
    /// File URLs inspect a bounded Mach-O or PE prefix by default. If content
    /// recognition does not decide the result, `.tar` and `.Z` extensions are
    /// used as hints. LZMA_Alone requires a `.lzma` or `.tlz` extension and a plausible
    /// header, and brotli requires a `.br` or `.tbr` extension, a valid stream header and a
    /// successful trial decode; both are checked before binary cpio. A single LHA terminator
    /// requires a `.lha` or `.lzh` file name because it has no unique magic.
    public static func detect(
        url: URL,
        options: ReaderOptions = ReaderOptions()
    ) throws -> ArchiveFormat {
        let input = try OpenedArchiveInput.assemble(url: url, limits: options.limits)
        let format = try detect(source: input.source, sourceURL: input.sourceURL, options: options)
        guard input.zipDiskLayout == nil || format == .zip else {
            throw KaitoError.malformed("ZIP split volume set is not a ZIP archive")
        }
        return format
    }

    /// Detects using a source already opened for `sourceURL`.
    ///
    /// ArchiveReader uses this overload to preserve one file descriptor while
    /// retaining the URL-only executable scan and extension-hint behavior.
    static func detect(
        source: any ByteSource,
        sourceURL: URL?,
        options: ReaderOptions,
        skipStuffIt: Bool = false
    ) throws -> ArchiveFormat {
        try detect(
            source: source,
            fileName: sourceURL?.lastPathComponent,
            sfxScanSize: sourceURL != nil
                ? options.maximumSFXScanSize
                : (options.scanForSFXInData ? options.maximumSFXScanSize : 0),
            limits: options.limits,
            recoverDamagedArchives: options.recoverDamagedArchives,
            skipStuffIt: skipStuffIt
        )
    }

    static func stuffItFormat(_ source: any ByteSource) throws -> ArchiveFormat {
        let prefix = try readByteRange(source: source, offset: 0, count: Int(min(8, source.length)))
        return prefix == Array("StuffIt!".utf8) ? .stuffItX : .stuffIt
    }

    /// envelope の形式: payload が StuffIt なら classic / X、そうでなければ wrapper 自身（MacBinary /
    /// AppleSingle / BinHex 4）を 1 file の書庫として扱う。
    static func envelopeFormat(_ envelope: MacEnvelope) throws -> ArchiveFormat {
        let inner = try readByteRange(source: envelope.data, offset: 0, count: Int(min(envelope.data.length, 100)))
        if StuffItHeader.signature(inner) != nil || inner.starts(with: "StuffIt!".utf8) {
            return try stuffItFormat(envelope.data)
        }
        switch envelope.wrapper?.kind {
        case .macBinary: return .macBinary
        case .appleSingle: return .appleSingle
        case .binHex: return .binHex
        case nil: return try stuffItFormat(envelope.data)
        }
    }

    // wrapper は一段だけ剥がす。内側の他形式へは再帰的に dispatch しない。
    static func stuffItInput(source: any ByteSource, prefix: [UInt8]? = nil, limits: ReadLimits,
                             maximumSFXScanSize: UInt64 = 0) throws -> MacEnvelope? {
        // URL open で連結済みの分割セットは data fork と resource fork をそのまま渡す。
        if let split = source as? StuffItSplitSource {
            return MacEnvelope(data: split, resource: split.resourceFork)
        }
        let bytes = try prefix ?? readByteRange(source: source, offset: 0, count: Int(min(source.length, 512)))
        // Data で開いた分割 part は、単独で R+D を覆う場合だけ連結なしで成立する。
        if StuffItSplitHeader(bytes) != nil,
           let split = try StuffItSplitSet.assemble(firstVolumeURL: nil, source: source, directory: nil, limits: limits) {
            return MacEnvelope(data: split, resource: split.resourceFork)
        }
        if TarHeaderBlock.isPlausibleMemberHeader(bytes) { return nil }
        if bytes.starts(with: "StuffIt?".utf8) { throw KaitoError.unsupportedFormat }
        if StuffItHeader.signature(bytes) != nil || bytes.starts(with: "StuffIt!".utf8) {
            return MacEnvelope(data: source, resource: nil)
        }
        if bytes.starts(with: [0x4d, 0x5a]) {
            guard let offset = try StuffItSFX.find(source: source, maximumScanSize: maximumSFXScanSize, limits: limits) else { return nil }
            return MacEnvelope(data: try RebasedByteSource(source: source, baseOffset: offset), resource: nil)
        }
        // 強い先頭署名を持つ既存形式の payload を BinHex の説明文として探索しない。
        let nativePrefixes: [[UInt8]] = [
            [0x50, 0x4b, 3, 4], [0x50, 0x4b, 5, 6], [0x50, 0x4b, 7, 8], [0x50, 0x4b, 0x30, 0x30],
            [0x52, 0x61, 0x72, 0x21, 0x1a, 7], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
            [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0], [0x04, 0x22, 0x4d, 0x18], [0x02, 0x21, 0x4c, 0x18], [0x1f, 0x8b], [0x1f, 0x9d],
            [0xed, 0xab, 0xee, 0xdb], [0x4d, 0x53, 0x43, 0x46],
            LzipMember.magic, PbzxHeader.magic, WIMHeader.signature, CFBHeader.signature,
            CHMHeader.signature, ARJHeader.identifier
        ]
        if nativePrefixes.contains(where: { hasPrefix(bytes, $0) }) || XarHeader.isPlausibleHeader(bytes)
            || ZstdFrameHeader.hasMagic(bytes) || isBzip2Header(bytes)
            || ArReader.isPlausibleArchive(bytes, sourceLength: source.length) { return nil }
        if try LHASignatureScanner.isHeader(bytes, sourceLength: source.length) { return nil }
        // wrapper の payload が StuffIt でなくても、wrapper 自身を 1 file の書庫として公開する（envelopeFormat）。
        return try MacEnvelopeParser.unwrap(source: source, prefix: bytes, limits: limits)
    }

    private static func detect(
        source: any ByteSource,
        fileName: String?,
        sfxScanSize: UInt64,
        limits: ReadLimits,
        recoverDamagedArchives: Bool,
        skipStuffIt: Bool = false
    ) throws -> ArchiveFormat {
        let prefixLength = try Checked.toInt(min(source.length, UInt64(tarBlockSize)))
        let prefix = try readByteRange(source: source, offset: 0, count: prefixLength)

        // 512-byte 全体で検証できる tar checksum は短い magic より強い証拠になる。
        if TarHeaderBlock.isPlausibleMemberHeader(prefix) {
            return .tar
        }

        if !skipStuffIt, let envelope = try stuffItInput(source: source, prefix: prefix, limits: limits, maximumSFXScanSize: sfxScanSize) {
            return try envelopeFormat(envelope)
        }

        if hasPrefix(prefix, [0x50, 0x4B, 0x03, 0x04])
            || hasPrefix(prefix, [0x50, 0x4B, 0x05, 0x06])
            || hasPrefix(prefix, [0x50, 0x4B, 0x07, 0x08])
            || hasPrefix(prefix, [0x50, 0x4B, 0x30, 0x30]) {
            return .zip
        }
        if hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
            || hasPrefix(prefix, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
            return .rar
        }
        if hasPrefix(prefix, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }
        // UDIF（.dmg）は先頭が最初の chunk の圧縮 data（bzip2 / xz / zlib の magic）なので、単一 file の
        // 圧縮形式より先に末尾の koly で判定する。
        if try UDIFTrailer.read(source: source) != nil { return .dmg }
        if hasPrefix(prefix, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xz
        }
        // draft-diaz-lzip §2: `LZIP` + version。version 1 以外は reader 側で unsupportedMethod にする。
        if hasPrefix(prefix, LzipMember.magic), prefix.count > 4 {
            return .lzip
        }
        if hasPrefix(prefix, PbzxHeader.magic) { return .pbzx }
        if hasPrefix(prefix, WIMHeader.signature) { return .wim }
        if hasPrefix(prefix, CFBHeader.signature) { return .compoundFile }
        if hasPrefix(prefix, CHMHeader.signature), prefix.count >= 8, [2, 3].contains(CHMBytes.u32(prefix, 4)) { return .chm }
        // ARJ: 先頭の header id + CRC の合う main header。DOS SFX（MZ）は下の実行形式 prefix の走査で扱う。
        if hasPrefix(prefix, ARJHeader.identifier), try ARJReader.findMainHeader(source: source, maximumScan: 0) != nil { return .arj }
        if XarHeader.isPlausibleHeader(prefix) { return .xar }
        if hasPrefix(prefix, [0x04, 0x22, 0x4d, 0x18]) || hasPrefix(prefix, [0x02, 0x21, 0x4c, 0x18]) { return .lz4 }
        if ZstdFrameHeader.hasMagic(prefix) { return try skippableStreamFormat(source: source, limits: limits) }
        if hasPrefix(prefix, [0xED, 0xAB, 0xEE, 0xDB]) { return .rpm }
        if prefix.count > 25, hasPrefix(prefix, [0x4D, 0x53, 0x43, 0x46]), prefix[25] == 1 { return .cab }
        if try LHASignatureScanner.isHeader(prefix, sourceLength: source.length) {
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
        if ArReader.isPlausibleArchive(prefix, sourceLength: source.length) { return .ar }
        if CpioHeader.detectVariant(prefix, source: source) != nil { return .cpio }
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
        if try LHASignatureScanner.findSFXSignature(source: source) != nil {
            return .lha
        }
        // ARJ の DOS SFX（MZ の後ろに main header）。
        if sfxScanSize > 0, prefix.count >= 2, prefix[0] == 0x4D, prefix[1] == 0x5A,
           try ARJReader.findMainHeader(source: source, maximumScan: min(sfxScanSize, maximumSFXScanSize)) != nil {
            return .arj
        }

        // 既存の native ZIP 復旧・SFX 判定を優先する。書庫 payload 内の CD001 が
        // 既存の検出結果を奪わないよう、ISO の固定 offset probe はその後に置く。
        // 短い入力では read を行わず、従来の拡張子判定まで到達させる。
        if source.length >= 34816 {
            let sector = try readByteRange(source: source, offset: 32768, count: 2048)
            if ISOReader.isPlausibleVolumeDescriptor(sector) { return .iso }
            // ECMA-167 2/8.3.1: CD001 を持たず BEA01 … NSR02|NSR03 … TEA01 の認識列だけがある image は
            // UDF 専用。CD001 を伴う hybrid は `.iso` として ISOReader が UDF の木を選ぶ。
            if try UDFVolume.detectRecognitionSequence(source: source, pureOnly: true) { return .udf }
            // ECMA-130 の生 sector image（BIN/CUE、.img、.mdf）: 2352 / 2448 / 2336 byte の sector から
            // user data を取り出した上で同じ判定を行う。
            if let raw = try RawSectorByteSource.wrapIfRaw(source) {
                let sector = try readByteRange(source: raw, offset: 32768, count: 2048)
                if ISOReader.isPlausibleVolumeDescriptor(sector) { return .iso }
                if try UDFVolume.detectRecognitionSequence(source: raw, pureOnly: true) { return .udf }
            }
        }
        // 生の Apple disk image: GPT / APM / bare の HFS+ volume（koly 付きは上で判定済み）。
        if try DMGReader.detect(source: source, limits: limits) { return .dmg }

        if let fileName {
            let pathExtension = URL(fileURLWithPath: fileName).pathExtension
            if pathExtension.caseInsensitiveCompare("tar") == .orderedSame {
                return .tar
            }
            if pathExtension.caseInsensitiveCompare("Z") == .orderedSame {
                return .compress
            }
            // Empty LHA has only its end marker. Require both its exact
            // one-byte representation and an explicit name hint; arbitrary
            // zero-filled data must never become an editable LHA archive.
            if ["lha", "lzh"].contains(pathExtension.lowercased()),
               source.length == 1, prefix == [0] {
                return .lha
            }
            // LZMA SDK lzma-specification.txt (2015-06-14) の header を
            // 最後に検査する。magic が無いため拡張子だけでは受理しない。
            if ["lzma", "tlz"].contains(pathExtension.lowercased()),
               LZMAAloneHeader.isPlausible(prefix, limits: limits) {
                return .lzma
            }
            // brotli (RFC 7932) にも magic が無い。`.br` / `.tbr` の名前と、有効な WBITS を持つ
            // stream header、先頭 chunk の試し復号がそろったときだけ受理する。
            if ["br", "tbr"].contains(pathExtension.lowercased()),
               BrotliDecompressor.detect(source: source, limits: limits) {
                return .brotli
            }
        }

        if CpioHeader.detectBinary(source: source, recoverDamagedArchives: recoverDamagedArchives) { return .cpio }
        throw KaitoError.unsupportedFormat
    }

    // Zstandard is recognized from a regular frame or from a leading skippable
    // frame. LZ4 and Zstandard deliberately share the skippable-frame range, so
    // the first regular frame decides between them. Seek over each payload
    // without allocating it. Malformed/pure skippable streams keep the
    // Zstandard classification and receive validation in their reader.
    private static func skippableStreamFormat(source: any ByteSource, limits: ReadLimits) throws -> ArchiveFormat {
        var position: UInt64 = 0
        var records = 0
        while source.length - position >= 4 {
            let bytes = try readByteRange(source: source, offset: position, count: 4)
            let magic = UInt64(LittleEndian.uint32(bytes, at: 0))
            if magic == LZ4FrameDecompressor.magic || magic == LZ4FrameDecompressor.legacyMagic { return .lz4 }
            guard ZstdFrameHeader.isSkippable(magic) else { return .zstd }
            guard records < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("skippable frame count")
            }
            records += 1
            guard source.length - position >= 8 else { return .zstd }
            let sizeBytes = try readByteRange(source: source, offset: position + 4, count: 4)
            let size = UInt64(LittleEndian.uint32(sizeBytes, at: 0))
            position += 8
            guard size <= source.length - position else { return .zstd }
            position += size
        }
        return .zstd
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

    /// Locates the first ZIP, RAR, 7-Zip, or CAB marker in a recognized
    /// executable prefix. The scan bound is clamped even when this internal
    /// entry point is called directly.
    static func findSFXSignature(
        source: any ByteSource,
        maximumScanSize: UInt64
    ) throws -> SFXSignatureMatch? {
        let scanSize = min(maximumScanSize, maximumSFXScanSize)
        guard scanSize > 0 else { return nil }

        let longestSignatureSize: UInt64 = 26
        let maximumRead = try Checked.add(scanSize, longestSignatureSize)
        let count = try Checked.toInt(min(source.length, maximumRead))
        guard count >= 4 else { return nil }
        let bytes = try readByteRange(source: source, offset: 0, count: count)
        guard isMachOOrPEPrefix(bytes) else { return nil }

        let zipLocal: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let zipEmpty: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let zipSpanned: [UInt8] = [0x50, 0x4B, 0x07, 0x08]
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5: [UInt8] = rar4.dropLast() + [0x01, 0x00]
        let sevenZip: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        let cabinet: [UInt8] = [0x4D, 0x53, 0x43, 0x46]

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
            // MS-CAB の CFHEADER: signature の後 reserved1 = 0、versionMinor = 3、versionMajor = 1。
            // 実行形式の中の偶然の "MSCF" を除くため、offset 0 の判定と同じ版数まで確認する。
            if matches(bytes, signature: cabinet, at: index), index + 26 <= bytes.count,
               bytes[index + 4...index + 7].allSatisfy({ $0 == 0 }),
               bytes[index + 24] == 3, bytes[index + 25] == 1 {
                return SFXSignatureMatch(offset: UInt64(index), format: .cab)
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

    private static func containsNativeZipEOCD(
        source: any ByteSource
    ) throws -> Bool {
        guard source.length >= UInt64(ZipEndRecords.endMinimumSize) else { return false }
        for end in try ZipEndRecords.findEndRecords(
            source: source,
            maximumSearchSize: ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize
                + ZipEndRecords.maximumTrailingDataSize
        ) {
            // ZIP64 の番兵は ZIP64 end record が無いと基点を出せない。通常の ZIP64 書庫は先頭に local header の印を持つ。
            if end.centralDirectorySize == UInt32.max || end.centralDirectoryOffset == UInt32.max {
                continue
            }
            // 検出側の規則はこれだけ: central directory の終端が EOCD の位置に一致する（基点 0）。
            if UInt64(end.centralDirectoryOffset) + UInt64(end.centralDirectorySize) == end.offset {
                return true
            }
        }
        return false
    }
}
