import Foundation

@_spi(TarEditLayout)
public enum TarContainer: Sendable, Equatable {
    case plain, gzip, bzip2, xz
    case other(ArchiveFormat)
}

@_spi(TarEditLayout)
public struct TarEditingSnapshot: Sendable {
    public let container: TarContainer
    public let image: any ByteSource
    public let archive: any ByteSource
    public let layout: TarArchiveLayout?
    public let layoutUnavailableReason: TarLayoutUnavailableReason?
    public let chunkMap: CompressedTarChunkMap?
    public let chunkMapUnavailableReason: ChunkMapUnavailableReason?
    public let archiveIdentity: ByteSourceFileIdentity?
    let limits: ReadLimits

    public func archiveIsUnchanged() -> Bool {
        guard let archiveIdentity else { return false }
        return currentTarArchiveIdentity(archive) == archiveIdentity
    }

    public func headerGroup(ofMember index: Int) throws -> TarHeaderGroup {
        guard let layout else { throw KaitoError.notFound("tar member index \(index)") }
        let member = try layout.member(at: index)
        return try TarReader.headerGroup(member, layout: layout, source: image, limits: limits)
    }

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

@_spi(TarEditLayout)
public struct TarArchiveLayout: Sendable {
    public let imageLength: UInt64
    public let endOfArchiveOffset: UInt64
    public let globalHeaderRanges: [Range<UInt64>]
    let storage: TarLayoutStorage
    public var memberCount: Int { storage.members.count }

    public func member(at index: Int) throws -> TarMemberLayout {
        guard storage.members.indices.contains(index) else { throw KaitoError.notFound("tar member index \(index)") }
        let member = storage.members[index]
        return TarMemberLayout(groupRange: member.groupStart..<member.end, headerOffset: member.headerOffset,
                               bodyRange: member.bodyStart..<(member.bodyStart + storage.records[index].size))
    }
}

@_spi(TarEditLayout)
public struct TarMemberLayout: Sendable, Equatable {
    public let groupRange: Range<UInt64>
    public let headerOffset: UInt64
    public let bodyRange: Range<UInt64>
    public var headerRange: Range<UInt64> { groupRange.lowerBound..<bodyRange.lowerBound }
    public var headerBlockCount: Int { Int((bodyRange.lowerBound - groupRange.lowerBound) / 512) }
}

@_spi(TarEditLayout)
public struct TarHeaderGroup: Sendable, Equatable {
    public struct Extension: Sendable, Equatable {
        public let typeFlag: UInt8
        public let headerOffset: UInt64
        public let payloadRange: Range<UInt64>
        public let end: UInt64
    }
    public let extensions: [Extension]
    public let headerOffset: UInt64
    public let typeFlag: UInt8
    public let sparseExtensionRange: Range<UInt64>?
}

@_spi(TarEditLayout)
public enum TarLayoutUnavailableReason: Sendable, Equatable {
    case recoveryMode, interleavedGlobalHeader, wrappedEntries, inconsistent
}

@_spi(TarEditLayout)
public enum ChunkMapUnavailableReason: Sendable, Equatable {
    case notCompressed, unsupportedCodec(ArchiveFormat), multipleGzipMembers, multipleXZStreams,
         xzStreamPadding, tooManyChunks, archiveChangedDuringOpen, recoveryMode, inconsistent
}

@_spi(TarEditLayout)
public enum CompressedTarChunkMap: Sendable, Equatable {
    case gzip(GzipChunkMap), bzip2(Bzip2StreamMap), xz(XZBlockMap)
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
    public var hasInteriorBoundaries: Bool {
        switch self {
        case .gzip(let map): map.points.count > 1
        case .bzip2(let map): map.streams.count > 1
        case .xz(let map): map.blocks.count > 1
        }
    }
}

@_spi(TarEditLayout)
public struct CompressedTarChunk: Sendable, Equatable {
    public let compressedRange: Range<UInt64>
    public let imageRange: Range<UInt64>
    public let compressedCRC32: UInt32
}

@_spi(TarEditLayout)
public struct GzipChunkMap: Sendable, Equatable {
    public static let windowSize: UInt64 = 32_768
    public let headerLength: UInt64
    public let points: [GzipSyncPoint]
    public let trailerOffset: UInt64
    public let trailerCRC32: UInt32
    public let imageLength: UInt64
    let compressedChecksums: [UInt32]
}

@_spi(TarEditLayout)
public struct GzipSyncPoint: Sendable, Equatable {
    public let compressedOffset: UInt64
    public let imageOffset: UInt64
    public let crc32: UInt32
}

@_spi(TarEditLayout)
public struct Bzip2StreamMap: Sendable, Equatable {
    public struct Stream: Sendable, Equatable {
        public let compressedRange: Range<UInt64>
        public let imageRange: Range<UInt64>
        public let level: UInt8
        public let compressedCRC32: UInt32
    }
    public let streams: [Stream]
}

@_spi(TarEditLayout)
public struct XZBlockMap: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public let compressedRange: Range<UInt64>
        public let headerSize: UInt64
        public let compressedPayloadSize: UInt64
        public let unpaddedSize: UInt64
        public let imageRange: Range<UInt64>
        public let compressedCRC32: UInt32
    }
    public let streamFlags: UInt16
    public let checkSize: UInt64
    public let blocks: [Block]
    public let indexRange: Range<UInt64>
    public let footerRange: Range<UInt64>
}

func currentTarArchiveIdentity(_ source: any ByteSource) -> ByteSourceFileIdentity? {
    if let file = source as? FileByteSource { return try? file.fileIdentity() }
    return try? (source as? any ByteSourceFileIdentityProviding)?.currentFileIdentity()
}
