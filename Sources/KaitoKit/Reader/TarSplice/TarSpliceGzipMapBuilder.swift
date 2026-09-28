import Foundation
private import zlib

// gzip の継ぎで使う CRC-32 の連結: prefix の CRC と suffix の CRC から、連結した byte 列の CRC を求める。
func tarSpliceCRCCombine(_ prefix: UInt32, _ suffix: UInt32, _ length: UInt64) -> UInt32 {
    UInt32(truncatingIfNeeded: crc32_combine(uLong(prefix), uLong(suffix), Int(length)))
}

// TarSpliceGzipDecoder の停止点から gzip の区切りの地図を組む。
final class TarSpliceGzipMapBuilder {
    private(set) var points: [GzipSyncPoint]
    private var checksums: [UInt32] = []
    private var checksum = CRC32()
    private(set) var reason: ChunkMapUnavailableReason?
    private var stops: UInt64 = 1

    init(headerLength: UInt64) {
        points = [.init(compressedOffset: headerLength, imageOffset: 0, crc32: 0)]
    }

    func consume(_ bytes: UnsafeRawBufferPointer) { if reason == nil { checksum.update(bytes) } }

    func stop(imageOffset: UInt64) {
        stops += 1
        if stops > 1_048_576 + imageOffset / 4096 { reason = .tooManyChunks }
    }

    func point(_ point: GzipSyncPoint) {
        guard reason == nil, point.imageOffset > 0, let previous = points.last else { return }
        if previous.compressedOffset == point.compressedOffset { return }
        if previous.imageOffset == point.imageOffset {
            checksums[checksums.count - 1] = tarSpliceCRCCombine(checksums.last!, checksum.value,
                                                               point.compressedOffset - previous.compressedOffset)
            points[points.count - 1] = point
        } else {
            guard points.count < 1_048_576 else { reason = .tooManyChunks; return }
            checksums.append(checksum.value)
            points.append(point)
        }
        checksum = CRC32()
    }

    func finish(trailerOffset: UInt64, crc: UInt32, imageLength: UInt64) -> CompressedTarChunkMap? {
        guard reason == nil else { return nil }
        return .gzip(.init(headerLength: points[0].compressedOffset, points: CompressedTarMapRecorder.normalizeGzipPoints(points),
                           trailerOffset: trailerOffset, trailerCRC32: crc, imageLength: imageLength,
                           compressedChecksums: checksums + [checksum.value]))
    }
}
