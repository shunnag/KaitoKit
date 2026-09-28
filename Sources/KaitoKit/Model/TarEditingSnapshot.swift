import Foundation

/// tar image を包む圧縮の形式。`other` は地図を作らない codec（zstd・lz4 など）。
@_spi(TarEditLayout)
public enum TarContainer: Sendable, Equatable {
    case plain, gzip, bzip2, xz
    case other(ArchiveFormat)
}

/// GyoshukuKit の tar 編集用に open 時に記録した、member の配置・圧縮の区切りの地図・archive の同一性。
/// `ReaderOptions.recordsTarEditLayout` を有効にした tar / 圧縮 tar の open だけが作る。
@_spi(TarEditLayout)
public struct TarEditingSnapshot: Sendable {
    /// 圧縮の形式と、元の archive の byte・復号済みの tar image。非圧縮 tar では archive と image は同じ source。
    public let container: TarContainer
    public let image: any ByteSource
    public let archive: any ByteSource
    /// member の配置。作れなかった場合は nil で、理由を layoutUnavailableReason に持つ。
    public let layout: TarArchiveLayout?
    public let layoutUnavailableReason: TarLayoutUnavailableReason?
    /// 圧縮の区切りの地図。作れなかった場合は nil で、理由を chunkMapUnavailableReason に持つ。
    public let chunkMap: CompressedTarChunkMap?
    public let chunkMapUnavailableReason: ChunkMapUnavailableReason?
    /// open の前後で一致した archive の file 同一性。取得できないか、open の間に変わった場合は nil。
    public let archiveIdentity: ByteSourceFileIdentity?
    let limits: ReadLimits

    /// archive の現在の同一性が記録時と同じか。記録がなければ false。
    public func archiveIsUnchanged() -> Bool {
        guard let archiveIdentity else { return false }
        return currentTarArchiveIdentity(archive) == archiveIdentity
    }

    /// index 番目の member の header 群を image から読み直し、既存の checksum・数値・PAX・sparse の検査と
    /// limits で検証する。layout がない・範囲外は notFound、保存した境界との食い違いは malformed。
    public func headerGroup(ofMember index: Int) throws -> TarHeaderGroup {
        guard let layout else { throw KaitoError.notFound("tar member index \(index)") }
        let member = try layout.member(at: index)
        return try TarReader.headerGroup(member, layout: layout, source: image, limits: limits)
    }

    /// image の end-of-archive 以後がすべて 0 か。1 MiB ずつ読む。layout がなければ notFound。
    public func trailingBytesAreZero() throws -> Bool {
        guard let layout else { throw KaitoError.notFound("tar layout") }
        var offset = layout.endOfArchiveOffset
        while offset < layout.imageLength {
            let count = Int(min(1_048_576, layout.imageLength - offset))
            let bytes = try readByteRange(source: image, offset: offset, count: count)
            if bytes.contains(where: { $0 != 0 }) { return false }
            offset += UInt64(count)
        }
        return true
    }
}

/// 復号済み image 上の member の配置。offset はすべて image 先頭からの byte 位置。
@_spi(TarEditLayout)
public struct TarArchiveLayout: Sendable {
    /// image の長さと、最初の zero block（end-of-archive）の offset。
    public let imageLength: UInt64
    public let endOfArchiveOffset: UInt64
    /// global PAX（g）header とその本文の範囲。以後の member にも効き続ける。
    public let globalHeaderRanges: [Range<UInt64>]
    let storage: TarLayoutStorage
    /// 書庫の順の member 数。
    public var memberCount: Int { storage.members.count }

    /// index 番目の member の範囲。範囲外は notFound。
    public func member(at index: Int) throws -> TarMemberLayout {
        guard storage.members.indices.contains(index) else { throw KaitoError.notFound("tar member index \(index)") }
        let member = storage.members[index]
        return TarMemberLayout(groupRange: member.groupStart..<member.end, headerOffset: member.headerOffset,
                               bodyRange: member.bodyStart..<(member.bodyStart + storage.records[index].size))
    }
}

/// 一つの member の範囲。
@_spi(TarEditLayout)
public struct TarMemberLayout: Sendable, Equatable {
    /// 局所拡張（x / X / L / K）の先頭から、本文の 512 byte 詰め物の終わりまで。
    public let groupRange: Range<UInt64>
    /// member 自身の header block の offset。
    public let headerOffset: UInt64
    /// 格納本文（詰め物を含まない）。旧 GNU sparse の拡張 block は含まず、GNU sparse 1.0 の map は含む。
    public let bodyRange: Range<UInt64>
    /// 群の先頭から本文の先頭まで（局所拡張・header・旧 GNU sparse の拡張 block）と、その 512 byte block 数。
    public var headerRange: Range<UInt64> { groupRange.lowerBound..<bodyRange.lowerBound }
    public var headerBlockCount: Int { Int((bodyRange.lowerBound - groupRange.lowerBound) / 512) }
}

/// ``TarEditingSnapshot/headerGroup(ofMember:)`` が読み直した一つの member の header 群。
@_spi(TarEditLayout)
public struct TarHeaderGroup: Sendable, Equatable {
    /// 局所拡張 header（x / X / L / K）一つ。payloadRange は本文、end は詰め物の終わり。
    public struct Extension: Sendable, Equatable {
        public let typeFlag: UInt8
        public let headerOffset: UInt64
        public let payloadRange: Range<UInt64>
        public let end: UInt64
    }
    /// 書庫の順の局所拡張。
    public let extensions: [Extension]
    /// member 自身の header block の offset と type flag。
    public let headerOffset: UInt64
    public let typeFlag: UInt8
    /// 旧 GNU sparse（S）の拡張 block の範囲。なければ nil。
    public let sparseExtensionRange: Range<UInt64>?
}

/// layout を作らなかった理由。open の成否には影響しない。recoveryMode は損傷からの回復 open、
/// interleavedGlobalHeader は局所拡張と member の間の g、wrappedEntries は AppleDouble の統合で entry と
/// member が一対一でない場合、inconsistent は群と g が end-of-archive までを隙間なく覆わない場合。
@_spi(TarEditLayout)
public enum TarLayoutUnavailableReason: Sendable, Equatable {
    case recoveryMode, interleavedGlobalHeader, wrappedEntries, inconsistent
}

/// 圧縮の地図を作らなかった理由。復号と open は続ける。notCompressed は非圧縮 tar、unsupportedCodec は
/// gzip / bzip2 / xz 以外、multipleGzipMembers・multipleXZStreams・xzStreamPadding は地図にしない枠、
/// tooManyChunks は区間数か gzip の停止回数の上限超過、archiveChangedDuringOpen は open の前後の同一性の変化、
/// recoveryMode は回復 open、inconsistent は被覆・長さ・trailer・Index の不整合。
@_spi(TarEditLayout)
public enum ChunkMapUnavailableReason: Sendable, Equatable {
    case notCompressed, unsupportedCodec(ArchiveFormat), multipleGzipMembers, multipleXZStreams,
         xzStreamPadding, tooManyChunks, archiveChangedDuringOpen, recoveryMode, inconsistent
}

/// 圧縮 byte と image の対応。区間は圧縮 payload と image をそれぞれ隙間なく覆う。
@_spi(TarEditLayout)
public enum CompressedTarChunkMap: Sendable, Equatable {
    case gzip(GzipChunkMap), bzip2(Bzip2StreamMap), xz(XZBlockMap)
    /// 形式によらない区間の列。gzip は同期点の間、bzip2 は独立 stream、xz は block。
    public var chunks: [CompressedTarChunk] {
        switch self {
        case .gzip(let map):
            return map.points.indices.map { i in
                let next = i + 1 < map.points.count ? map.points[i + 1] : nil
                return CompressedTarChunk(compressedRange: map.points[i].compressedOffset..<(next?.compressedOffset ?? map.trailerOffset),
                                          imageRange: map.points[i].imageOffset..<(next?.imageOffset ?? map.imageLength),
                                          compressedCRC32: map.compressedChecksums[i])
            }
        case .bzip2(let map):
            return map.streams.map { CompressedTarChunk(compressedRange: $0.compressedRange, imageRange: $0.imageRange, compressedCRC32: $0.compressedCRC32) }
        case .xz(let map):
            return map.blocks.map { CompressedTarChunk(compressedRange: $0.compressedRange, imageRange: $0.imageRange, compressedCRC32: $0.compressedCRC32) }
        }
    }
    /// 区間が二つ以上あるか（内部に継ぎ目を置けるか）。
    public var hasInteriorBoundaries: Bool {
        switch self {
        case .gzip(let map): map.points.count > 1
        case .bzip2(let map): map.streams.count > 1
        case .xz(let map): map.blocks.count > 1
        }
    }
}

/// 一つの区間。archive 上の圧縮 byte の範囲、image 上の範囲、open で消費した圧縮 byte の CRC-32。
@_spi(TarEditLayout)
public struct CompressedTarChunk: Sendable, Equatable {
    public let compressedRange: Range<UInt64>
    public let imageRange: Range<UInt64>
    public let compressedCRC32: UInt32
}

/// 単一 member の gzip の地図。
@_spi(TarEditLayout)
public struct GzipChunkMap: Sendable, Equatable {
    /// deflate の窓の大きさ。継ぎ目の直前のこの長さの image が一致しなければ再利用できない。
    public static let windowSize: UInt64 = 32_768
    /// gzip header の長さ。最初の同期点は (headerLength, 0, 0)。
    public let headerLength: UInt64
    /// deflate block の境界のうち、非最終・byte 境界・空 block で止まった同期点。image offset の昇順。
    public let points: [GzipSyncPoint]
    /// 8 byte の trailer の offset と、trailer の image CRC-32、image の長さ。
    public let trailerOffset: UInt64
    public let trailerCRC32: UInt32
    public let imageLength: UInt64
    let compressedChecksums: [UInt32]
}

/// 同期点。圧縮 offset、対応する image offset、image の先頭からそこまでの CRC-32。
@_spi(TarEditLayout)
public struct GzipSyncPoint: Sendable, Equatable {
    public let compressedOffset: UInt64
    public let imageOffset: UInt64
    public let crc32: UInt32
}

/// 独立した bzip2 stream の連結の地図。
@_spi(TarEditLayout)
public struct Bzip2StreamMap: Sendable, Equatable {
    /// 一つの stream の圧縮・image の範囲、`BZh` の block size level（1〜9）、圧縮 byte の CRC-32。
    public struct Stream: Sendable, Equatable {
        public let compressedRange: Range<UInt64>
        public let imageRange: Range<UInt64>
        public let level: UInt8
        public let compressedCRC32: UInt32
    }
    public let streams: [Stream]
}

/// 単一 xz stream（padding なし）の block の地図。
@_spi(TarEditLayout)
public struct XZBlockMap: Sendable, Equatable {
    /// 一つの block。compressedRange は block 全体（header・payload・padding・check）、headerSize と
    /// compressedPayloadSize はその内訳、unpaddedSize は Index に記録する padding を除いた長さ。
    /// imageRange と compressedCRC32 は ``CompressedTarChunk`` と同じ。
    public struct Block: Sendable, Equatable {
        public let compressedRange: Range<UInt64>
        public let headerSize: UInt64
        public let compressedPayloadSize: UInt64
        public let unpaddedSize: UInt64
        public let imageRange: Range<UInt64>
        public let compressedCRC32: UInt32
    }
    /// stream header の flags 2 byte（check の種類を含む）と check の byte 数。
    public let streamFlags: UInt16
    public let checkSize: UInt64
    public let blocks: [Block]
    /// Index と stream footer の範囲。
    public let indexRange: Range<UInt64>
    public let footerRange: Range<UInt64>
}
