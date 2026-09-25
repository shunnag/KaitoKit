import Foundation

// encoded だけを一つの staging に流す。reused の image は葉の範囲として残す。
final class CompressedTarSpliceVerifier: Decompressor {
    private struct Part {
        let output: Range<UInt64>
        let reused: Range<Int>?
        let outputBlocks: Range<Int>?
    }
    private enum Fragment {
        case reused([SourceSegment])
        case encoded(Range<UInt64>)
    }
    private struct Decoding {
        let decoder: any Decompressor
        let recorder: CompressedTarMapRecorder?
        let archiveLength: UInt64
        let imageStart: UInt64
        let stagingStart: UInt64
    }

    private let output: any ByteSource
    private let base: TarEditingSnapshot
    private let baseMap: CompressedTarChunkMap
    private let limits: ReadLimits
    private let gzipHeaderLength: UInt64?
    private var baseChunks: [CompressedTarChunk] = []
    private var parts: [Part] = []
    private var payload: Range<UInt64> = 0..<0
    private var xzFraming: XZBlockMap?
    private var xzChecksums: [UInt32] = []
    private var gzipMap: TarSpliceGzipMapBuilder?
    private var bzipStreams: [Bzip2StreamMap.Stream] = []
    private var fragments: [Fragment] = []
    private var current: Decoding?
    private var partIndex = 0
    private var imageSize: UInt64 = 0
    private var stagingSize: UInt64 = 0
    private var imageCRC: UInt32 = 0
    private var window = Data()
    private var checkedBytes: UInt64 = 0
    private var retainedMemory: UInt64 = 0
    private(set) var isFinished = false
    private(set) var map: CompressedTarChunkMap?
    private(set) var mapUnavailableReason: ChunkMapUnavailableReason?

    init(output: any ByteSource, base: TarEditingSnapshot, splice: CompressedTarSplice,
         limits: ReadLimits, gzipHeaderLength: UInt64? = nil) throws {
        guard let baseMap = base.chunkMap else { throw TarSpliceVerificationError(.baseNotSpliceable) }
        self.output = output; self.base = base; self.baseMap = baseMap; self.limits = limits
        self.gzipHeaderLength = gzipHeaderLength
        try validateBaseMap()
        try tarSpliceVerification(.framingMismatch) { try prepareFraming(splice) }
        try prepareParts(splice)
    }

    func materialize(policy: TarSpliceStoragePolicy) throws -> any ByteSource {
        let stream = try EntryStream(decompressor: self, length: nil, expectedCRC32: nil, entryIndex: -1, limits: limits)
        let memory = limits.inMemorySingleFileLimit > retainedMemory ? limits.inMemorySingleFileLimit - retainedMemory : 0
        let encoded = try SingleFileMaterializer.materialize(stream, limits: limits, inMemoryLimit: memory)
        var flat: [SourceSegment] = []
        for fragment in fragments {
            switch fragment {
            case .reused(let slices): flat.append(contentsOf: slices)
            case .encoded(let range) where !range.isEmpty:
                flat.append(.init(source: encoded, offset: range.lowerBound, length: range.count64))
            case .encoded: break
            }
        }
        return try SplicedTarImage.assemble(flat, limits: limits, policy: policy)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        while partIndex < parts.count {
            let part = parts[partIndex]
            if let reused = part.reused {
                try reuse(part, chunks: reused)
                partIndex += 1
                continue
            }
            let index = partIndex
            if current == nil {
                current = try tarSpliceVerification(.encodedSegmentInvalid, segmentIndex: index) { try beginEncoded(part) }
            }
            let decoding = current!
            let count = try tarSpliceVerification(.encodedSegmentInvalid, segmentIndex: index) {
                try decoding.decoder.read(into: buffer)
            }
            if gzipMap == nil { try accept(.init(rebasing: buffer[..<count])) }
            stagingSize += UInt64(count)
            if decoding.decoder.isFinished {
                try tarSpliceVerification(.encodedSegmentInvalid, segmentIndex: index) { try finishEncoded(part, decoding) }
                fragments.append(.encoded(decoding.stagingStart..<stagingSize))
                current = nil
                partIndex += 1
            } else if count == 0 { throw failure(.encodedSegmentInvalid, underlying: .truncated) }
            if count > 0 { return count }
        }
        try finish()
        isFinished = true
        return 0
    }

    private func validateBaseMap() throws {
        if case .gzip(let map) = baseMap {
            guard !map.points.isEmpty, map.points.count == map.compressedChecksums.count,
                  map.points[0].compressedOffset == map.headerLength, map.points[0].imageOffset == 0,
                  map.points[0].crc32 == 0, map.imageLength == base.image.length else {
                throw TarSpliceVerificationError(.inconsistentBaseMap)
            }
            for (index, point) in map.points.enumerated() {
                let nextC = index + 1 < map.points.count ? map.points[index + 1].compressedOffset : map.trailerOffset
                let nextU = index + 1 < map.points.count ? map.points[index + 1].imageOffset : map.imageLength
                guard point.compressedOffset < nextC, point.imageOffset <= nextU,
                      nextU <= base.image.length else { throw TarSpliceVerificationError(.inconsistentBaseMap) }
            }
        }
        baseChunks = baseMap.chunks
        var imageEnd: UInt64 = 0
        var compressedEnd = baseChunks.first?.compressedRange.lowerBound
        for chunk in baseChunks {
            guard !chunk.compressedRange.isEmpty, chunk.compressedRange.lowerBound == compressedEnd,
                  chunk.imageRange.lowerBound == imageEnd, chunk.imageRange.upperBound <= base.image.length else {
                throw TarSpliceVerificationError(.inconsistentBaseMap)
            }
            compressedEnd = chunk.compressedRange.upperBound; imageEnd = chunk.imageRange.upperBound
        }
        guard imageEnd == base.image.length else { throw TarSpliceVerificationError(.inconsistentBaseMap) }
    }

    private func prepareFraming(_ splice: CompressedTarSplice) throws {
        switch baseMap {
        case .gzip:
            let length = try gzipHeaderLength ?? GzipHeaderParser.parseFirstHeader(source: output, limits: limits).length
            guard output.length >= 8, length < output.length - 8 else { throw KaitoError.truncated }
            payload = length..<(output.length - 8)
            gzipMap = TarSpliceGzipMapBuilder(headerLength: length)
        case .bzip2:
            guard output.length >= 4 else { throw KaitoError.truncated }
            let signature = try readByteRange(source: output, offset: 0, count: 4)
            guard signature.prefix(3) == [0x42, 0x5a, 0x68], (0x31...0x39).contains(signature[3]) else {
                throw KaitoError.malformed("invalid bzip2 stream header")
            }
            payload = 0..<output.length
        case .xz(let baseXZ):
            let recorder = CompressedTarMapRecorder(format: .xz)
            try XZResourceValidator.validate(source: output, dictionaryLimit: limits.maxDictionarySize, recorder: recorder)
            guard let framing = recorder.xzFraming, framing.footerRange.upperBound == output.length,
                  [UInt16(0), 0x100, 0x400, 0xa00].contains(framing.streamFlags) else {
                throw KaitoError.malformed("splice requires a single XZ stream without padding")
            }
            if splice.segments.contains(where: { if case .reused = $0 { true } else { false } }),
               framing.streamFlags != baseXZ.streamFlags { throw KaitoError.malformed("XZ splice stream flags differ") }
            let end = framing.indexRange.upperBound
            let expected = try little32(at: end - 4)
            guard try checksum(source: output, range: framing.indexRange.lowerBound..<(end - 4)) == expected else {
                throw TarSpliceVerificationError(.checksumMismatch)
            }
            xzFraming = framing
            xzChecksums = Array(repeating: 0, count: framing.blocks.count)
            payload = 12..<framing.indexRange.lowerBound
        }
    }

    private func prepareParts(_ splice: CompressedTarSplice) throws {
        guard !splice.segments.isEmpty else { throw TarSpliceVerificationError(.invalidSegments) }
        var boundaries: [UInt64: Int] = [:]
        for (i, chunk) in baseChunks.enumerated() { boundaries[chunk.compressedRange.lowerBound] = i }
        if let last = baseChunks.last { boundaries[last.compressedRange.upperBound] = baseChunks.count }
        var outputBoundaries: [UInt64: Int] = [:]
        if let framing = xzFraming {
            for (i, block) in framing.blocks.enumerated() { outputBoundaries[block.compressedRange.lowerBound] = i }
            outputBoundaries[framing.indexRange.lowerBound] = framing.blocks.count
        }
        var cursor = payload.lowerBound
        var reusedFragments: [SourceSegment] = []
        for (index, segment) in splice.segments.enumerated() {
            let o = segment.outputRange
            func invalid() -> TarSpliceVerificationError { .init(.invalidSegments, segmentIndex: index) }
            guard !o.isEmpty, o.lowerBound == cursor, o.upperBound <= payload.upperBound else { throw invalid() }
            let blocks: Range<Int>?
            if xzFraming != nil {
                guard let lower = outputBoundaries[o.lowerBound], let upper = outputBoundaries[o.upperBound], lower < upper else { throw invalid() }
                blocks = lower..<upper
            } else { blocks = nil }
            var reused: Range<Int>?
            if case .reused(_, let b) = segment {
                guard o.count64 == b.count64, let lower = boundaries[b.lowerBound],
                      let upper = boundaries[b.upperBound], lower < upper else { throw invalid() }
                reused = lower..<upper
                if case .gzip(let map) = baseMap, b.upperBound == map.trailerOffset, index != splice.segments.count - 1 {
                    throw invalid()
                }
                if case .xz(let map) = baseMap, let blocks, let framing = xzFraming {
                    guard upper - lower == blocks.count else { throw invalid() }
                    for (old, new) in zip(map.blocks[lower..<upper], framing.blocks[blocks]) {
                        guard old.unpaddedSize == new.unpaddedSize, old.imageRange.count64 == new.imageRange.count64 else {
                            throw TarSpliceVerificationError(.framingMismatch, segmentIndex: index)
                        }
                    }
                }
                let range = baseChunks[lower].imageRange.lowerBound..<baseChunks[upper - 1].imageRange.upperBound
                reusedFragments.append(contentsOf: SplicedTarImage.slices(of: base.image, range: range))
            }
            parts.append(.init(output: o, reused: reused, outputBlocks: blocks))
            cursor = o.upperBound
        }
        guard cursor == payload.upperBound else { throw TarSpliceVerificationError(.invalidSegments) }
        retainedMemory = SplicedTarImage.memorySize(reusedFragments)
    }

    private func reuse(_ part: Part, chunks indices: Range<Int>) throws {
        let chunks = baseChunks[indices]
        let imageRange = chunks.first!.imageRange.lowerBound..<chunks.last!.imageRange.upperBound
        let q = imageSize, initialCRC = imageCRC
        var reusedImageCRC: UInt32 = 0
        try checkImageSize(adding: imageRange.count64)
        for (relative, chunk) in chunks.enumerated() {
            let start = part.output.lowerBound + chunk.compressedRange.lowerBound - chunks.first!.compressedRange.lowerBound
            let crc = try checksum(source: output, range: start..<(start + chunk.compressedRange.count64)) { bytes in
                self.gzipMap?.consume(bytes)
            }
            guard crc == chunk.compressedCRC32 else { throw failure(.reusedBytesDiffer) }
            switch baseMap {
            case .gzip(let map):
                let startCRC = map.points[indices.lowerBound + relative].crc32
                let end = chunk.imageRange.upperBound
                let endCRC = indices.lowerBound + relative + 1 < map.points.count
                    ? map.points[indices.lowerBound + relative + 1].crc32 : map.trailerCRC32
                // 全区間の再利用でも、内部の点と image の食い違いを見逃さない。
                let imageCRC = try checksum(source: base.image, range: chunk.imageRange)
                guard imageCRC == endCRC ^ tarSpliceCRCCombine(startCRC, 0, chunk.imageRange.count64) else {
                    throw failure(.inconsistentBaseMap)
                }
                reusedImageCRC = tarSpliceCRCCombine(reusedImageCRC, imageCRC, chunk.imageRange.count64)
                let suffixCRC = endCRC ^ tarSpliceCRCCombine(map.points[indices.lowerBound].crc32, 0, end - imageRange.lowerBound)
                if chunk.compressedRange.upperBound != map.trailerOffset {
                    gzipMap?.point(.init(compressedOffset: start + chunk.compressedRange.count64,
                                         imageOffset: q + end - imageRange.lowerBound,
                                         crc32: tarSpliceCRCCombine(initialCRC, suffixCRC, end - imageRange.lowerBound)))
                }
            case .bzip2(let map):
                let old = map.streams[indices.lowerBound + relative]
                appendBzip(.init(compressedRange: start..<(start + chunk.compressedRange.count64),
                                 imageRange: (q + chunk.imageRange.lowerBound - imageRange.lowerBound)..<(q + chunk.imageRange.upperBound - imageRange.lowerBound),
                                 level: old.level, compressedCRC32: crc))
            case .xz(let map):
                xzChecksums[part.outputBlocks!.lowerBound + relative] = crc
                if map.checkSize == 4 {
                    let imageCRC = try checksum(source: base.image, range: chunk.imageRange)
                    guard imageCRC == (try little32(at: start + chunk.compressedRange.count64 - 4)) else {
                        throw failure(.inconsistentBaseMap)
                    }
                }
            }
        }
        if case .gzip(let map) = baseMap {
            let crc = reusedImageCRC
            let endCRC = indices.upperBound < map.points.count ? map.points[indices.upperBound].crc32 : map.trailerCRC32
            let expected = endCRC ^ tarSpliceCRCCombine(map.points[indices.lowerBound].crc32, 0, imageRange.count64)
            guard crc == expected else { throw failure(.inconsistentBaseMap) }
            let windowSize = min(imageRange.lowerBound, GzipChunkMap.windowSize)
            guard q >= windowSize, Data(window.suffix(Int(windowSize))) == Data(try readByteRange(source: base.image,
                      offset: imageRange.lowerBound - windowSize, count: Int(windowSize))) else { throw failure(.dictionaryMismatch) }
            imageCRC = tarSpliceCRCCombine(imageCRC, crc, imageRange.count64)
            let tail = min(imageRange.count64, GzipChunkMap.windowSize)
            appendWindow(Data(try readByteRange(source: base.image, offset: imageRange.upperBound - tail, count: Int(tail))))
        }
        imageSize += imageRange.count64
        fragments.append(.reused(SplicedTarImage.slices(of: base.image, range: imageRange)))
    }

    private func beginEncoded(_ part: Part) throws -> Decoding {
        let decoder: any Decompressor
        let recorder: CompressedTarMapRecorder?
        let archiveLength: UInt64
        switch baseMap {
        case .gzip:
            recorder = nil; archiveLength = part.output.count64
            decoder = try TarSpliceGzipDecoder(source: output, range: part.output, dictionary: window,
                                               final: partIndex == parts.count - 1) { [unowned self] bytes, decoded, end, stopped, empty in
                gzipMap?.consume(bytes)
                try accept(decoded)
                if stopped { gzipMap?.stop(imageOffset: imageSize) }
                if empty { gzipMap?.point(.init(compressedOffset: end, imageOffset: imageSize, crc32: imageCRC)) }
            }
        case .bzip2:
            let recording = CompressedTarMapRecorder(format: .bzip2)
            let source = try BoundedByteSource(source: output, baseOffset: part.output.lowerBound, length: part.output.count64)
            decoder = try Bzip2Decompressor(source: source, offset: 0, compressedSize: source.length,
                                           concatenatedStreams: true, recorder: recording)
            recorder = recording; archiveLength = source.length
        case .xz:
            let framing = xzFraming!
            let tail = DataByteSource(Self.xzIndexFooter(blocks: Array(framing.blocks[part.outputBlocks!]), flags: framing.streamFlags))
            let source = try ConcatenatedByteSource(segments: [
                .init(source: output, offset: 0, length: 12),
                .init(source: output, offset: part.output.lowerBound, length: part.output.count64),
                .init(source: tail, offset: 0, length: tail.length)
            ], maximumLength: .max, label: "encoded XZ splice")
            let recording = CompressedTarMapRecorder(format: .xz)
            decoder = try XZDecompressor(source: source, limits: limits, recorder: recording)
            recorder = recording; archiveLength = source.length
        }
        return .init(decoder: decoder, recorder: recorder, archiveLength: archiveLength,
                     imageStart: imageSize, stagingStart: stagingSize)
    }

    private func finishEncoded(_ part: Part, _ decoding: Decoding) throws {
        guard let recorder = decoding.recorder else { return }
        let recorded = recorder.finish(imageLength: imageSize - decoding.imageStart, archiveLength: decoding.archiveLength)
        switch recorded.map {
        case .bzip2(let map):
            for stream in map.streams {
                appendBzip(.init(compressedRange: stream.compressedRange.shifted(by: part.output.lowerBound),
                                 imageRange: stream.imageRange.shifted(by: decoding.imageStart),
                                 level: stream.level, compressedCRC32: stream.compressedCRC32))
            }
        case .xz(let map):
            let indices = part.outputBlocks!, expected = xzFraming!.blocks[indices]
            guard imageSize - decoding.imageStart == expected.reduce(0, { $0 + $1.imageRange.count64 }),
                  map.blocks.count == indices.count else { throw KaitoError.malformed("XZ splice decoded size mismatch") }
            for (index, block) in zip(indices, map.blocks) { xzChecksums[index] = block.compressedCRC32 }
        default:
            if recorded.reason == .tooManyChunks { mapUnavailableReason = .tooManyChunks }
            else { throw KaitoError.malformed("encoded splice map is inconsistent") }
        }
    }

    private func accept(_ bytes: UnsafeRawBufferPointer) throws {
        try checkImageSize(adding: UInt64(bytes.count))
        imageSize += UInt64(bytes.count)
        if gzipMap != nil {
            var crc = CRC32(); crc.update(bytes)
            imageCRC = tarSpliceCRCCombine(imageCRC, crc.value, UInt64(bytes.count))
            appendWindow(Data(bytes.suffix(Int(GzipChunkMap.windowSize))))
        }
    }

    private func appendWindow(_ bytes: Data) {
        if bytes.count >= Int(GzipChunkMap.windowSize) { window = Data(bytes.suffix(Int(GzipChunkMap.windowSize))) }
        else {
            let keep = min(window.count, Int(GzipChunkMap.windowSize) - bytes.count)
            window = Data(window.suffix(keep)); window.append(bytes)
        }
    }

    private func checkImageSize(adding count: UInt64) throws {
        guard imageSize <= limits.maxEntrySize, count <= limits.maxEntrySize - imageSize else {
            throw KaitoError.limitExceeded("entry size")
        }
    }

    private func appendBzip(_ stream: Bzip2StreamMap.Stream) {
        guard mapUnavailableReason == nil else { return }
        guard bzipStreams.count < 1_048_576 else { bzipStreams = []; mapUnavailableReason = .tooManyChunks; return }
        bzipStreams.append(stream)
    }

    private func finish() throws {
        switch baseMap {
        case .gzip:
            if let reused = parts.last?.reused, reused.upperBound != baseChunks.count {
                throw TarSpliceVerificationError(.encodedSegmentInvalid, segmentIndex: parts.count - 1)
            }
            guard try little32(at: payload.upperBound) == imageCRC,
                  try little32(at: payload.upperBound + 4) == UInt32(truncatingIfNeeded: imageSize) else {
                throw TarSpliceVerificationError(.checksumMismatch)
            }
            map = gzipMap!.finish(trailerOffset: payload.upperBound, crc: imageCRC, imageLength: imageSize)
            mapUnavailableReason = gzipMap!.reason
        case .bzip2:
            if mapUnavailableReason == nil { map = .bzip2(.init(streams: bzipStreams)) }
        case .xz:
            let framing = xzFraming!
            let blocks = zip(framing.blocks, xzChecksums).map { block, crc in
                XZBlockMap.Block(compressedRange: block.compressedRange, headerSize: block.headerSize,
                                 compressedPayloadSize: block.compressedPayloadSize, unpaddedSize: block.unpaddedSize,
                                 imageRange: block.imageRange, compressedCRC32: crc)
            }
            map = .xz(.init(streamFlags: framing.streamFlags, checkSize: framing.checkSize, blocks: blocks,
                            indexRange: framing.indexRange, footerRange: framing.footerRange))
        }
    }

    private func checksum(source: any ByteSource, range: Range<UInt64>,
                          consume: ((UnsafeRawBufferPointer) -> Void)? = nil) throws -> UInt32 {
        var cursor = range.lowerBound, crc = CRC32()
        while cursor < range.upperBound {
            let count = Int(min(1_048_576, range.upperBound - cursor))
            let bytes = try readByteRange(source: source, offset: cursor, count: count)
            bytes.withUnsafeBytes { crc.update($0); consume?($0) }
            cursor += UInt64(count); checkedBytes += UInt64(count)
            if checkedBytes >= 64 * 1_048_576 {
                try Task.checkCancellation(); checkedBytes %= 64 * 1_048_576
            }
        }
        return crc.value
    }

    private func little32(at offset: UInt64) throws -> UInt32 {
        let bytes = try readByteRange(source: output, offset: offset, count: 4)
        return (0..<4).reduce(0) { $0 | UInt32(bytes[$1]) << (8 * $1) }
    }

    private func failure(_ reason: TarSpliceVerificationError.Reason, underlying: KaitoError? = nil) -> TarSpliceVerificationError {
        .init(reason, segmentIndex: partIndex, underlying: underlying)
    }

    static func xzIndexFooter(blocks: [XZBlockMap.Block], flags: UInt16) -> Data {
        func integer(_ number: UInt64) -> Data {
            var number = number, bytes = Data()
            repeat { bytes.append(UInt8(number & 127) | (number >= 128 ? 128 : 0)); number >>= 7 } while number > 0
            return bytes
        }
        func little(_ number: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: number >> (8 * $0)) }) }
        var index = Data([0]); index.append(integer(UInt64(blocks.count)))
        for block in blocks { index.append(integer(block.unpaddedSize)); index.append(integer(block.imageRange.count64)) }
        while index.count % 4 != 0 { index.append(0) }
        index.append(little(CRC32.checksum(index)))
        var footer = little(UInt32(index.count / 4 - 1))
        footer.append(contentsOf: [UInt8(truncatingIfNeeded: flags), UInt8(truncatingIfNeeded: flags >> 8)])
        index.append(little(CRC32.checksum(footer))); index.append(footer); index.append(contentsOf: [0x59, 0x5a])
        return index
    }
}

private extension Range<UInt64> {
    var count64: UInt64 { upperBound - lowerBound }
    func shifted(by offset: UInt64) -> Self { (lowerBound + offset)..<(upperBound + offset) }
}
