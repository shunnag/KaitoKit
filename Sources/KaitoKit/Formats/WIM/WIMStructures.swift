import CryptoKit
import Foundation

// Microsoft "Windows Imaging File Format (WIM)"（2007 年の公開 whitepaper）と [MS-XCA] / [MS-PATCH] の
// 公開仕様に基づくクリーンルーム実装。whitepaper に無い点（LZX chunk の header、DIRENTRY の 102 byte 固定部、
// chunk の生格納）は黒箱で確定した。2026-09-21 の検証記録を参照。

enum WIMBytes {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    /// FILETIME（1601-01-01 からの 100 ns）。0 は未設定。
    static func fileTime(_ value: UInt64) -> Date? {
        guard value != 0, value < 0x8000_0000_0000_0000 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }
}

/// RESHDR_DISK_SHORT（24 byte）: 7 byte の格納サイズ + flags、offset、元サイズ。
struct WIMResourceHeader {
    static let size = 24
    static let flagFree: UInt8 = 0x01
    static let flagMetadata: UInt8 = 0x02
    static let flagCompressed: UInt8 = 0x04
    static let flagSpanned: UInt8 = 0x08

    let packedSize: UInt64
    let flags: UInt8
    let offset: UInt64
    let originalSize: UInt64

    init(_ b: [UInt8], _ o: Int) {
        var size: UInt64 = 0
        for index in 0..<7 { size |= UInt64(b[o + index]) << (8 * index) }
        packedSize = size
        flags = b[o + 7]
        offset = WIMBytes.u64(b, o + 8)
        originalSize = WIMBytes.u64(b, o + 16)
    }

    var isCompressed: Bool { flags & Self.flagCompressed != 0 }
    var isMetadata: Bool { flags & Self.flagMetadata != 0 }
    var isEmpty: Bool { packedSize == 0 && originalSize == 0 }
}

/// lookup table の 1 entry（50 byte）: RESHDR_DISK_SHORT + part 番号 + 参照数 + SHA-1。
struct WIMLookupEntry {
    static let size = 50
    let header: WIMResourceHeader
    let partNumber: UInt16
    let referenceCount: UInt32
    let hash: [UInt8]

    init(_ b: [UInt8], _ o: Int) {
        header = WIMResourceHeader(b, o)
        partNumber = WIMBytes.u16(b, o + 24)
        referenceCount = WIMBytes.u32(b, o + 26)
        hash = Array(b[(o + 30)..<(o + 50)])
    }
}

enum WIMCompression: String {
    case none
    case xpress = "XPRESS"
    case lzx = "LZX"
}

/// WIMHEADER_V1_PACKED（208 byte）。
struct WIMHeader {
    static let signature: [UInt8] = Array("MSWIM".utf8) + [0, 0, 0]
    static let size = 208
    static let flagCompression: UInt32 = 0x0000_0002
    static let flagSpanned: UInt32 = 0x0000_0008
    static let flagResourceOnly: UInt32 = 0x0000_0010
    static let flagMetadataOnly: UInt32 = 0x0000_0020
    static let flagCompressXpress: UInt32 = 0x0002_0000
    static let flagCompressLZX: UInt32 = 0x0004_0000
    /// 0.14（solid / ESD）の LZMS。whitepaper の範囲外で、解析できる資料が無い。
    static let flagCompressLZMS: UInt32 = 0x0008_0000
    static let defaultChunkSize: UInt32 = 32768

    let version: UInt32
    let flags: UInt32
    let chunkSize: UInt32
    let partNumber: UInt16
    let totalParts: UInt16
    let imageCount: UInt32
    let lookupTable: WIMResourceHeader
    let xmlData: WIMResourceHeader
    let bootMetadata: WIMResourceHeader
    let bootIndex: UInt32
    let integrity: WIMResourceHeader

    init(_ b: [UInt8]) throws {
        guard b.count >= Self.size else { throw KaitoError.truncated }
        guard Array(b[0..<8]) == Self.signature else { throw KaitoError.unsupportedFormat }
        let headerSize = WIMBytes.u32(b, 8)
        guard headerSize >= UInt32(Self.size) else { throw KaitoError.malformed("wim header size \(headerSize)") }
        version = WIMBytes.u32(b, 12)
        flags = WIMBytes.u32(b, 16)
        let declaredChunk = WIMBytes.u32(b, 20)
        chunkSize = declaredChunk == 0 ? Self.defaultChunkSize : declaredChunk
        partNumber = WIMBytes.u16(b, 40)
        totalParts = WIMBytes.u16(b, 42)
        imageCount = WIMBytes.u32(b, 44)
        lookupTable = WIMResourceHeader(b, 48)
        xmlData = WIMResourceHeader(b, 72)
        bootMetadata = WIMResourceHeader(b, 96)
        bootIndex = WIMBytes.u32(b, 120)
        integrity = WIMResourceHeader(b, 124)
    }

    var compression: WIMCompression {
        get throws {
            if flags & Self.flagCompressLZMS != 0 || version == 0x0E00 {
                throw KaitoError.unsupportedMethod("WIM solid (LZMS) resources")
            }
            guard flags & Self.flagCompression != 0 else { return .none }
            if flags & Self.flagCompressLZX != 0 { return .lzx }
            if flags & Self.flagCompressXpress != 0 { return .xpress }
            throw KaitoError.unsupportedMethod("WIM compression flags 0x\(String(flags, radix: 16))")
        }
    }
}

/// 圧縮 resource を chunk 単位で展開する。chunk 表（元サイズが 4 GiB 超なら 8 byte、それ以外 4 byte の
/// 次 chunk 開始位置）→ chunk 列。格納サイズが展開後サイズと同じ chunk は無圧縮（黒箱で確定）。
final class WIMResourceDecompressor: Decompressor {
    private let source: any ByteSource
    private let resource: WIMResourceHeader
    private let chunkSize: Int
    private let compression: WIMCompression
    private let limits: ReadLimits
    private let chunkCount: Int
    private let tableEntrySize: Int
    private var chunkOffsets: [UInt64]?
    private var nextChunk = 0
    private var pending: [UInt8] = []
    private var pendingOffset = 0
    private var produced: UInt64 = 0

    init(source: any ByteSource, resource: WIMResourceHeader, chunkSize: UInt32, compression: WIMCompression, limits: ReadLimits) throws {
        self.source = source
        self.resource = resource
        self.chunkSize = Int(chunkSize)
        self.compression = compression
        self.limits = limits
        // XPRESS は 4〜64 KiB の 2 冪、LZX の窓は 32 KiB のまま。
        let supported = compression == .none || (compression == .xpress
            ? (4096...65536).contains(chunkSize) && chunkSize & (chunkSize - 1) == 0
            : chunkSize == WIMHeader.defaultChunkSize)
        guard supported else {
            throw KaitoError.unsupportedMethod("WIM chunk size \(chunkSize)")
        }
        guard chunkSize >= 4096, chunkSize <= 1 << 26, chunkSize & (chunkSize - 1) == 0 else {
            throw KaitoError.malformed("wim chunk size \(chunkSize)")
        }
        if compression == .xpress {
            // chunk 全体が match の履歴になる。
            try Checked.size(UInt64(chunkSize), limit: limits.maxDictionarySize)
        }
        chunkCount = resource.originalSize == 0 ? 0 : Int((resource.originalSize - 1) / UInt64(chunkSize) + 1)
        tableEntrySize = resource.originalSize > 0xFFFF_FFFF ? 8 : 4
        guard try Checked.add(resource.offset, resource.packedSize) <= source.length else { throw KaitoError.truncated }
    }

    var isFinished: Bool { produced == resource.originalSize && pendingOffset == pending.count }

    private func loadTable() throws -> [UInt64] {
        if let chunkOffsets { return chunkOffsets }
        let tableBytes = try Checked.mul(UInt64(max(chunkCount - 1, 0)), UInt64(tableEntrySize))
        try Checked.size(tableBytes, limit: limits.maxMetadataSize)
        guard tableBytes <= resource.packedSize else { throw KaitoError.malformed("wim chunk table exceeds the resource") }
        let b = try readByteRange(source: source, offset: resource.offset, count: Int(tableBytes))
        var offsets: [UInt64] = [0]
        offsets.reserveCapacity(chunkCount + 1)
        for index in 0..<max(chunkCount - 1, 0) {
            let value = tableEntrySize == 4 ? UInt64(WIMBytes.u32(b, index * 4)) : WIMBytes.u64(b, index * 8)
            guard value >= offsets[index], value <= resource.packedSize - tableBytes else {
                throw KaitoError.malformed("wim chunk table offset")
            }
            offsets.append(value)
        }
        offsets.append(resource.packedSize - tableBytes)
        chunkOffsets = offsets
        return offsets
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        if pendingOffset == pending.count {
            try decodeNextChunk()
        }
        let count = min(buffer.count, pending.count - pendingOffset)
        pending.withUnsafeBytes { bytes in
            buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: pendingOffset), byteCount: count)
        }
        pendingOffset += count
        return count
    }

    private func decodeNextChunk() throws {
        let offsets = try loadTable()
        guard nextChunk < chunkCount else { throw KaitoError.truncated }
        let tableBytes = UInt64(max(chunkCount - 1, 0) * tableEntrySize)
        let start = try Checked.add(Checked.add(resource.offset, tableBytes), offsets[nextChunk])
        let length = offsets[nextChunk + 1] - offsets[nextChunk]
        let remaining = resource.originalSize - produced
        let outputSize = Int(min(UInt64(chunkSize), remaining))
        guard length <= UInt64(chunkSize) + 1024 * 64 else { throw KaitoError.malformed("wim compressed chunk too large") }
        let input = try readByteRange(source: source, offset: start, count: Int(length))
        let output: [UInt8]
        if input.count == outputSize {
            output = input
        } else {
            switch compression {
            case .none:
                throw KaitoError.malformed("wim stored chunk size")
            case .lzx:
                // 黒箱で確定した WIM 変種: E8 header bit 無し、変換サイズ 12,000,000、window 32 KiB。
                let decoder = try LZXDecoder(windowBits: 15, outputSize: UInt64(outputSize), dictionarySizeLimit: limits.maxDictionarySize,
                                             intelHeader: false, fixedTranslationSize: 12_000_000, wimVariant: true)
                output = try decoder.decodeFrame(input: input, outputSize: outputSize)
            case .xpress:
                output = try XpressHuffmanDecoder.decode(input, outputSize: outputSize)
            }
        }
        guard output.count == outputSize else { throw KaitoError.malformed("wim chunk expanded to \(output.count) bytes") }
        pending = output
        pendingOffset = 0
        produced += UInt64(outputSize)
        nextChunk += 1
    }
}

/// 出力の SHA-1 を数え、完了時に lookup table の hash と照合する。
final class WIMHashingDecompressor: Decompressor {
    private let inner: any Decompressor
    private var hasher = Insecure.SHA1()
    private(set) var digest: [UInt8]?

    init(_ inner: any Decompressor) { self.inner = inner }
    var isFinished: Bool { inner.isFinished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try inner.read(into: buffer)
        if count > 0 { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count])) }
        if inner.isFinished, digest == nil { digest = Array(hasher.finalize()) }
        return count
    }

    func verify(expected: [UInt8], entryIndex: Int) throws {
        if digest == nil { digest = Array(hasher.finalize()) }
        guard digest == expected else { throw KaitoError.checksumMismatch(entry: entryIndex) }
    }
}
