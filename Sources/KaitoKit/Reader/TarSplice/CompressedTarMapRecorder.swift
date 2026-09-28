import Foundation
private import zlib

final class CompressedTarMapRecorder {
    let format: ArchiveFormat
    let maximumChunks: Int
    let gzipStopLimit: UInt64
    private(set) var reason: ChunkMapUnavailableReason?
    var isRecording: Bool { reason == nil }

    private var gzipExpectedHeader: UInt64?
    private var gzipPoints: [GzipSyncPoint] = []
    private var gzipChecksums: [UInt32] = []
    private var gzipChecksum = CRC32()
    private var gzipStops: UInt64 = 0
    private var gzipPreviousStopOutput: UInt64 = 0
    private var gzipOutput: UInt64 = 0
    private var gzipTrailerOffset: UInt64?
    private var gzipTrailer: [UInt8] = []
    private var gzipFinalCRC: UInt32 = 0

    private var bzipStreams: [Bzip2StreamMap.Stream] = []
    private var bzipChecksum = CRC32()
    private var bzipHeader: [UInt8] = []
    private var bzipStart: UInt64?
    private var bzipOutput: UInt64 = 0
    private var bzipImageEnd: UInt64 = 0

    private var xzFlags: UInt16 = 0
    private var xzCheckSize: UInt64 = 0
    private var xzBlocks: [XZBlockMap.Block] = []
    private var xzChecksums: [CRC32] = []
    private var xzConsumed: [UInt64] = []
    private var xzCursor = 0
    private var xzIndex: Range<UInt64>?
    private var xzFooter: Range<UInt64>?

    // 同じ出力位置の空 block は後の点へまとめる。先頭を動かすと圧縮 byte の被覆に穴が開く。
    static func normalizeGzipPoints(_ points: [GzipSyncPoint]) -> [GzipSyncPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() {
            if point.imageOffset == 0 { continue }
            if result.last?.imageOffset == point.imageOffset { result[result.count - 1] = point }
            else { result.append(point) }
        }
        return result
    }

    init(format: ArchiveFormat, maximumChunks: Int = 1_048_576, gzipStopLimit: UInt64 = 1_048_576) {
        self.format = format
        self.maximumChunks = max(0, maximumChunks)
        self.gzipStopLimit = gzipStopLimit
    }

    func disable(_ reason: ChunkMapUnavailableReason) {
        guard self.reason == nil else { return }
        self.reason = reason
        gzipPoints = []; gzipChecksums = []; gzipTrailer = []
        bzipStreams = []; bzipHeader = []
        xzBlocks = []; xzChecksums = []; xzConsumed = []
    }

    func prepareGzip(headerLength: UInt64) { gzipExpectedHeader = headerLength }

    func consumeGzip(_ bytes: UnsafeRawBufferPointer, end: UInt64, produced: Int,
                     dataType: Int32, crc: UInt32, streamEnd: Bool) {
        guard isRecording else { return }
        gzipOutput += UInt64(produced)
        if gzipTrailerOffset != nil {
            guard gzipTrailer.count + bytes.count <= 8 else { disable(.inconsistent); return }
            gzipTrailer.append(contentsOf: bytes)
        } else if !gzipPoints.isEmpty {
            gzipChecksum.update(bytes)
        }
        if dataType & 128 != 0 {
            gzipStops += 1
            guard gzipStops <= gzipStopLimit + gzipOutput / 4096 else { disable(.tooManyChunks); return }
            if gzipPoints.isEmpty {
                guard gzipOutput == 0, maximumChunks > 0,
                      gzipExpectedHeader == nil || gzipExpectedHeader == end else { disable(maximumChunks == 0 ? .tooManyChunks : .inconsistent); return }
                gzipPoints.append(.init(compressedOffset: end, imageOffset: 0, crc32: 0))
            } else if dataType & 64 != 0 {
                gzipTrailerOffset = end
                gzipFinalCRC = crc
            } else if dataType & 7 == 0, gzipPreviousStopOutput == gzipOutput, gzipOutput > 0 {
                let point = GzipSyncPoint(compressedOffset: end, imageOffset: gzipOutput, crc32: crc)
                if let previous = gzipPoints.last, previous.imageOffset == gzipOutput {
                    let last = gzipChecksums.count - 1
                    gzipChecksums[last] = UInt32(truncatingIfNeeded: crc32_combine(uLong(gzipChecksums[last]),
                        uLong(gzipChecksum.value), Int(end - previous.compressedOffset)))
                    gzipPoints[gzipPoints.count - 1] = point
                } else {
                    guard gzipPoints.count < maximumChunks else { disable(.tooManyChunks); return }
                    gzipChecksums.append(gzipChecksum.value)
                    gzipPoints.append(point)
                }
                gzipChecksum = CRC32()
            }
            gzipPreviousStopOutput = gzipOutput
        }
        if streamEnd {
            guard gzipTrailerOffset != nil, gzipTrailer.count == 8 else { disable(.inconsistent); return }
            gzipChecksums.append(gzipChecksum.value)
        }
    }

    func consumeBzip2(_ bytes: UnsafeRawBufferPointer, start: UInt64, produced: Int, streamEnd: Bool) {
        guard isRecording else { return }
        if bzipStart == nil { bzipStart = start }
        if bzipHeader.count < 4 { bzipHeader.append(contentsOf: bytes.prefix(4 - bzipHeader.count)) }
        bzipChecksum.update(bytes)
        bzipOutput += UInt64(produced)
        if streamEnd {
            guard bzipHeader.count == 4, (0x31...0x39).contains(bzipHeader[3]), let lower = bzipStart else { disable(.inconsistent); return }
            appendBzip2(compressedRange: lower..<(start + UInt64(bytes.count)), outputSize: bzipOutput,
                        level: bzipHeader[3] - 0x30, crc: bzipChecksum.value)
            bzipChecksum = CRC32(); bzipHeader = []; bzipOutput = 0; bzipStart = nil
        }
    }

    func appendBzip2(compressedRange: Range<UInt64>, outputSize: UInt64, level: UInt8, crc: UInt32) {
        guard isRecording else { return }
        guard bzipStreams.count < maximumChunks else { disable(.tooManyChunks); return }
        bzipStreams.append(.init(compressedRange: compressedRange, imageRange: bzipImageEnd..<(bzipImageEnd + outputSize),
                                 level: level, compressedCRC32: crc))
        bzipImageEnd += outputSize
    }

    func beginXZ(at offset: UInt64, flags: UInt16, checkSize: UInt64) {
        if offset != 0 { disable(.multipleXZStreams); return }
        xzFlags = flags; xzCheckSize = checkSize
    }
    func appendXZ(compressedRange: Range<UInt64>, headerSize: UInt64, payloadSize: UInt64,
                  unpaddedSize: UInt64, outputSize: UInt64) {
        guard isRecording else { return }
        guard xzBlocks.count < maximumChunks else { disable(.tooManyChunks); return }
        let outputStart = xzBlocks.last?.imageRange.upperBound ?? 0
        xzBlocks.append(.init(compressedRange: compressedRange, headerSize: headerSize, compressedPayloadSize: payloadSize,
                              unpaddedSize: unpaddedSize, imageRange: outputStart..<(outputStart + outputSize), compressedCRC32: 0))
        xzChecksums.append(CRC32()); xzConsumed.append(0)
    }
    func endXZ(index: Range<UInt64>, footer: Range<UInt64>) {
        xzIndex = index; xzFooter = footer
    }
    // K5 は枠の walk 後に payload の digest を別途検める。
    var xzFraming: XZBlockMap? {
        guard isRecording, let index = xzIndex, let footer = xzFooter else { return nil }
        return .init(streamFlags: xzFlags, checkSize: xzCheckSize, blocks: xzBlocks,
                     indexRange: index, footerRange: footer)
    }
    func consumeXZ(_ bytes: UnsafeRawBufferPointer, at offset: UInt64) {
        guard isRecording else { return }
        let end = offset + UInt64(bytes.count)
        while xzCursor < xzBlocks.count {
            let range = xzBlocks[xzCursor].compressedRange
            if range.lowerBound >= end { break }
            let lower = max(offset, range.lowerBound), upper = min(end, range.upperBound)
            if lower < upper {
                xzChecksums[xzCursor].update(UnsafeRawBufferPointer(rebasing: bytes[Int(lower - offset)..<Int(upper - offset)]))
                xzConsumed[xzCursor] += upper - lower
            }
            if range.upperBound <= end { xzCursor += 1 } else { break }
        }
    }

    func finish(imageLength: UInt64, archiveLength: UInt64) -> (map: CompressedTarChunkMap?, reason: ChunkMapUnavailableReason?) {
        guard isRecording else { return (nil, reason) }
        let map: CompressedTarChunkMap
        let compressedStart: UInt64, compressedEnd: UInt64
        switch format {
        case .gzip:
            guard let first = gzipPoints.first, let trailerOffset = gzipTrailerOffset,
                  archiveLength >= 8, trailerOffset == archiveLength - 8,
                  gzipTrailer.count == 8, gzipChecksums.count == gzipPoints.count,
                  gzipOutput == imageLength, gzipPoints.last!.compressedOffset < trailerOffset,
                  LittleEndian.uint32(gzipTrailer, at: 0) == gzipFinalCRC,
                  LittleEndian.uint32(gzipTrailer, at: 4) == UInt32(truncatingIfNeeded: imageLength),
                  Self.normalizeGzipPoints(gzipPoints) == gzipPoints else { disable(.inconsistent); return (nil, reason) }
            map = .gzip(.init(headerLength: first.compressedOffset, points: gzipPoints, trailerOffset: trailerOffset,
                              trailerCRC32: gzipFinalCRC, imageLength: imageLength, compressedChecksums: gzipChecksums))
            compressedStart = first.compressedOffset; compressedEnd = trailerOffset
        case .bzip2:
            map = .bzip2(.init(streams: bzipStreams))
            compressedStart = 0; compressedEnd = archiveLength
        case .xz:
            guard let index = xzIndex, let footer = xzFooter, footer.upperBound == archiveLength,
                  index.upperBound == footer.lowerBound else { disable(.inconsistent); return (nil, reason) }
            var blocks: [XZBlockMap.Block] = []
            blocks.reserveCapacity(xzBlocks.count)
            for (i, block) in xzBlocks.enumerated() {
                guard xzConsumed[i] == block.compressedRange.upperBound - block.compressedRange.lowerBound else { disable(.inconsistent); return (nil, reason) }
                blocks.append(.init(compressedRange: block.compressedRange, headerSize: block.headerSize,
                                    compressedPayloadSize: block.compressedPayloadSize, unpaddedSize: block.unpaddedSize,
                                    imageRange: block.imageRange, compressedCRC32: xzChecksums[i].value))
            }
            map = .xz(.init(streamFlags: xzFlags, checkSize: xzCheckSize, blocks: blocks, indexRange: index, footerRange: footer))
            compressedStart = 12; compressedEnd = index.lowerBound
        default: return (nil, .unsupportedCodec(format))
        }
        var c = compressedStart, u: UInt64 = 0
        for chunk in map.chunks {
            guard chunk.compressedRange.lowerBound == c, chunk.imageRange.lowerBound == u,
                  !chunk.compressedRange.isEmpty else { disable(.inconsistent); return (nil, reason) }
            c = chunk.compressedRange.upperBound; u = chunk.imageRange.upperBound
        }
        guard c == compressedEnd, u == imageLength else { disable(.inconsistent); return (nil, reason) }
        return (map, nil)
    }
}
