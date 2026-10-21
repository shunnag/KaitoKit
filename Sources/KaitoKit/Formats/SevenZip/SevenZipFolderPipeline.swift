import Foundation

// coder の結合と出力サイズの参照仕様: LZMA SDK 7zFormat.txt (18.06)、
// Folder / Coders Info。中間 buffer の制限は既存 ReadLimits に従う。

struct SevenZipPackRange: Sendable, Equatable {
    let offset: UInt64
    let size: UInt64
    let digest: SevenZipDigest
}

private struct SevenZipVerifiedPackKey: Hashable {
    let offset: UInt64
    let size: UInt64
    let crc32: UInt32
}

// PackInfo CRC は entry を初めて読む時に固定長 buffer で検証し、reader 内で共有する。
// 巨大 packed stream を open 時に走査せず、同じ range の再検証も避ける。
// 先行復号の葉からも使うため、検証済み集合は lock で守る（読み取り自体は lock の外）。
final class SevenZipPackedStreamVerifier: @unchecked Sendable {
    private static let bufferSize = 256 * 1_024

    private let source: any ByteSource
    private let lock = NSLock()
    private var verified = Set<SevenZipVerifiedPackKey>()

    init(source: any ByteSource) {
        self.source = source
    }

    func verify(_ ranges: [Int: SevenZipPackRange]) throws {
        for range in ranges.values {
            guard let expected = range.digest.value else { continue }
            let key = SevenZipVerifiedPackKey(
                offset: range.offset,
                size: range.size,
                crc32: expected
            )
            if lock.withLock({ verified.contains(key) }) { continue }

            var checksum = CRC32()
            var position: UInt64 = 0
            var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
            while position < range.size {
                let requested = try Checked.toInt(min(
                    UInt64(buffer.count),
                    try Checked.sub(range.size, position)
                ))
                let absoluteOffset = try Checked.add(range.offset, position)
                let count = try buffer.withUnsafeMutableBytes { storage in
                    // requested は固定 buffer と packed range 残量の双方以下。
                    try source.read(
                        into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                        at: absoluteOffset
                    )
                }
                guard count > 0, count <= requested else { throw KaitoError.truncated }
                buffer.withUnsafeBytes { storage in
                    // count は直前の read で初期化された storage 範囲内。
                    checksum.update(UnsafeRawBufferPointer(rebasing: storage[..<count]))
                }
                position = try Checked.add(position, UInt64(count))
            }
            guard checksum.value == expected else {
                throw KaitoError.checksumMismatch(entry: -1)
            }
            lock.withLock { _ = verified.insert(key) }
        }
    }
}

enum SevenZipFolderLayout {
    static func ranges(
        for streams: SevenZipStreamsInfo,
        sourceLength: UInt64,
        packedDataEnd: UInt64
    ) throws -> [[Int: SevenZipPackRange]] {
        var absoluteOffset = try Checked.add(32, streams.packInfo.position)
        var packIndex = 0
        var result: [[Int: SevenZipPackRange]] = []
        result.reserveCapacity(streams.folders.count)

        for folder in streams.folders {
            var folderRanges: [Int: SevenZipPackRange] = [:]
            for inputIndex in folder.packedIndices {
                guard packIndex < streams.packInfo.sizes.count else {
                    throw KaitoError.malformed("missing 7z packed stream")
                }
                let size = streams.packInfo.sizes[packIndex]
                let end = try Checked.add(absoluteOffset, size)
                guard end <= sourceLength else { throw KaitoError.truncated }
                guard absoluteOffset <= packedDataEnd, end <= packedDataEnd else {
                    throw KaitoError.malformed("7z packed stream overlaps the next header")
                }
                let digest = packIndex < streams.packInfo.digests.count
                    ? streams.packInfo.digests[packIndex]
                    : SevenZipDigest(value: nil)
                folderRanges[inputIndex] = SevenZipPackRange(
                    offset: absoluteOffset,
                    size: size,
                    digest: digest
                )
                absoluteOffset = end
                packIndex += 1
            }
            result.append(folderRanges)
        }
        guard packIndex == streams.packInfo.sizes.count else {
            throw KaitoError.malformed("unused 7z packed streams")
        }
        return result
    }
}

private struct SevenZipByteInput {
    let source: any ByteSource
    let offset: UInt64
    let length: UInt64
}

private enum SevenZipPipelineValue {
    case bytes(SevenZipByteInput)
    case stream(any Decompressor)

    func asStream() throws -> any Decompressor {
        switch self {
        case let .bytes(input):
            return try CopyDecompressor(
                source: input.source,
                offset: input.offset,
                compressedSize: input.length
            )
        case let .stream(stream):
            return stream
        }
    }

    func asBytes(expectedSize: UInt64, limits: ReadLimits) throws -> SevenZipByteInput {
        switch self {
        case let .bytes(input):
            return input
        case let .stream(stream):
            // 単一の展開済み buffer を保持するため、readAll と同じメモリ上限を使う。
            try Checked.size(expectedSize, limit: limits.maxInMemorySize)
            try Checked.size(expectedSize, limit: limits.maxTotalUncompressedSize)
            let count = try Checked.toInt(expectedSize)
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { storage in
                var written = 0
                while written < count {
                    // written..<count は事前確保した未充填範囲だけを指す。
                    let destination = UnsafeMutableRawBufferPointer(
                        rebasing: storage[written..<count]
                    )
                    let actual = try stream.read(into: destination)
                    guard actual > 0, actual <= destination.count else {
                        throw KaitoError.truncated
                    }
                    written += actual
                }
            }
            if !stream.isFinished {
                var extra: UInt8 = 0
                let actual = try withUnsafeMutableBytes(of: &extra) {
                    try stream.read(into: $0)
                }
                guard actual == 0, stream.isFinished else {
                    throw KaitoError.malformed("7z coder output exceeds its declared size")
                }
            }
            return SevenZipByteInput(
                source: DataByteSource(data: data),
                offset: 0,
                length: expectedSize
            )
        }
    }
}

// reader 内の folder ごとに保持する。直列判定と失敗も保存し、非 solid entry の
// factory 再作成・coordinator の再開・後方 seek が同じ走査結果を共用する。
final class SevenZipLZMA2ResetIndexCache {
    // success(nil) は並列探索の上限内に第 2 の reset がなかった意味で、点がない意味ではない。
    var index: Result<[LZMA2ResetPoint]?, Error>?
    // 観測点は offset < coverage の辞書 reset 点をすべて含み、それ以外を含まない。
    // cache は reader の隔離ドメイン内だけで使うので lock は不要。並列 unit の static
    // factory は observer を持たず、prefetch の葉はそれぞれ専用 cache を作る。
    private(set) var observedPoints: [LZMA2ResetPoint] = []
    private(set) var observedCoverage: UInt64 = 0
    private(set) var observationFrozen = false

    enum ObservedLookup: Equatable { case uncovered, covered(LZMA2ResetPoint?) }

    func observe(point: LZMA2ResetPoint?, chunkStart: UInt64, chunkEnd: UInt64, maximumPointCount: Int) {
        guard !observationFrozen, chunkStart <= observedCoverage else { return }
        if let point, observedPoints.last.map({ point.uncompressedOffset > $0.uncompressedOffset }) ?? true {
            guard observedPoints.count < maximumPointCount else {
                observationFrozen = true
                return
            }
            observedPoints.append(point)
        }
        observedCoverage = max(observedCoverage, chunkEnd)
    }

    func observedRestartPoint(atOrBefore target: UInt64) -> ObservedLookup {
        guard target < observedCoverage else { return .uncovered }
        var lower = 0, upper = observedPoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if observedPoints[middle].uncompressedOffset <= target { lower = middle + 1 }
            else { upper = middle }
        }
        while lower > 0 {
            lower -= 1
            if observedPoints[lower].isRestartable { return .covered(observedPoints[lower]) }
        }
        return .covered(nil)
    }
    var parallelUnits: Result<[ParallelIndependentDecompressor.Unit]?, Error>?
}

final class SevenZipFolderDecoderFactory {
    let folder: SevenZipFolder
    let isEncrypted: Bool
    let finalSize: UInt64

    private let source: any ByteSource
    private let packedRanges: [Int: SevenZipPackRange]
    private let limits: ReadLimits
    private let password: String?
    private let keyCache: SevenZipAESKeyCache
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private let maximumAESCyclesPower: UInt8
    private let avoidsHeaderScans: Bool
    private let scanClock: @Sendable () -> UInt64
    private(set) var lastBackwardRestartKind: BackwardRestartKind?
    private let workers: Int
    private let parallelDiagnostics: ParallelIndependentDecompressor.Diagnostics?
    private let resetIndexCache: SevenZipLZMA2ResetIndexCache

    init(
        source: any ByteSource,
        folder: SevenZipFolder,
        packedRanges: [Int: SevenZipPackRange],
        limits: ReadLimits,
        password: String?,
        keyCache: SevenZipAESKeyCache,
        maximumAESCyclesPower: UInt8,
        packedStreamVerifier: SevenZipPackedStreamVerifier? = nil,
        workers: Int = 1,
        parallelDiagnostics: ParallelIndependentDecompressor.Diagnostics? = nil,
        resetIndexCache: SevenZipLZMA2ResetIndexCache = SevenZipLZMA2ResetIndexCache(),
        avoidsHeaderScans: Bool = false,
        scanClock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        guard folder.unpackSizes.count == folder.outputCount,
              folder.finalOutputIndex >= 0,
              folder.finalOutputIndex < folder.unpackSizes.count else {
            throw KaitoError.malformed("7z folder output sizes are incomplete")
        }
        self.source = source
        self.folder = folder
        self.packedRanges = packedRanges
        self.limits = limits
        self.password = password
        self.keyCache = keyCache
        self.packedStreamVerifier = packedStreamVerifier
            ?? SevenZipPackedStreamVerifier(source: source)
        self.maximumAESCyclesPower = maximumAESCyclesPower
        self.avoidsHeaderScans = avoidsHeaderScans
        self.scanClock = scanClock
        self.workers = workers
        self.parallelDiagnostics = parallelDiagnostics
        self.resetIndexCache = resetIndexCache
        self.finalSize = folder.unpackSizes[folder.finalOutputIndex]
        self.isEncrypted = folder.coders.contains { SevenZipMethod.kind(for: $0.methodID) == .aes }
    }

    func makeDecryptedPackedDecoder(packedInput: Int) throws -> (decoder: any Decompressor, length: UInt64) {
        guard folder.packedIndices.indices.contains(packedInput) else {
            throw KaitoError.notFound("7z packed input \(packedInput)")
        }
        let inputIndex = folder.packedIndices[packedInput]
        guard let coder = folder.coders.first(where: { $0.firstInput == inputIndex
            && $0.inputCount == 1 && $0.outputCount == 1
            && SevenZipMethod.kind(for: $0.methodID) == .aes }),
              folder.boundOutput(forInput: inputIndex) == nil else {
            throw KaitoError.malformed("7z packed input is not read by AES")
        }
        guard let range = packedRanges[inputIndex] else {
            throw KaitoError.malformed("7z packed input size is missing")
        }
        try packedStreamVerifier.verify([inputIndex: range])
        let length = folder.unpackSizes[coder.firstOutput]
        let value = try decryptedBytes(coder: coder,
            input: SevenZipByteInput(source: source, offset: range.offset, length: range.size),
            expectedSize: length, chargeKDFWork: { _ in })
        return (try value.asStream(), length)
    }

    private func decryptedBytes(
        coder: SevenZipCoder, input: SevenZipByteInput, expectedSize: UInt64,
        chargeKDFWork: (UInt64) throws -> Void
    ) throws -> SevenZipPipelineValue {
        guard let password else { throw KaitoError.passwordRequired }
        let properties = try SevenZipAESProperties(
            bytes: coder.properties,
            maximumCyclesPower: maximumAESCyclesPower
        )
        let key = try keyCache.key(password: password, properties: properties,
                                  chargeKDFWork: chargeKDFWork)
        let decrypted = try SevenZipAESByteSource(
            source: input.source,
            ciphertextOffset: input.offset,
            ciphertextSize: input.length,
            plaintextSize: expectedSize,
            key: key,
            initializationVector: properties.initializationVector
        )
        return .bytes(SevenZipByteInput(
            source: decrypted,
            offset: 0,
            length: decrypted.length
        ))
    }

    func makeDecoder(chargeKDFWork: (UInt64) throws -> Void = { _ in }) throws -> any Decompressor {
        var activeOutputs = Set<Int>()

        func inputSize(_ inputIndex: Int) throws -> UInt64 {
            if let bound = folder.boundOutput(forInput: inputIndex) {
                guard folder.unpackSizes.indices.contains(bound) else {
                    throw KaitoError.malformed("7z bound output size is missing")
                }
                return folder.unpackSizes[bound]
            }
            guard let range = packedRanges[inputIndex] else {
                throw KaitoError.malformed("7z packed input size is missing")
            }
            return range.size
        }

        func inputValue(_ inputIndex: Int) throws -> SevenZipPipelineValue {
            if let bound = folder.boundOutput(forInput: inputIndex) {
                return try outputValue(bound)
            }
            guard let range = packedRanges[inputIndex] else {
                throw KaitoError.malformed("7z coder input is neither bound nor packed")
            }
            return .bytes(SevenZipByteInput(
                source: source,
                offset: range.offset,
                length: range.size
            ))
        }

        func byteInput(_ inputIndex: Int) throws -> SevenZipByteInput {
            try inputValue(inputIndex).asBytes(
                expectedSize: inputSize(inputIndex),
                limits: limits
            )
        }

        func outputValue(_ outputIndex: Int) throws -> SevenZipPipelineValue {
            guard activeOutputs.insert(outputIndex).inserted else {
                throw KaitoError.malformed("cyclic 7z coder graph")
            }
            defer { activeOutputs.remove(outputIndex) }
            guard let coderIndex = folder.coderIndex(containingOutput: outputIndex) else {
                throw KaitoError.malformed("7z output does not belong to a coder")
            }
            let coder = folder.coders[coderIndex]
            guard coder.outputCount == 1, outputIndex == coder.firstOutput else {
                throw KaitoError.unsupportedMethod("multi-output 7z coder")
            }
            let expectedSize = folder.unpackSizes[outputIndex]
            let kind = SevenZipMethod.kind(for: coder.methodID)

            switch kind {
            case .copy:
                try requireArity(coder, inputs: 1)
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z Copy input and output sizes differ")
                }
                return .stream(try inputValue(coder.firstInput).asStream())

            case .lzma:
                try requireArity(coder, inputs: 1)
                let input = try byteInput(coder.firstInput)
                return .stream(try LZMADecoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    dictionarySizeLimit: limits.maxDictionarySize
                ))

            case .lzma2:
                try requireArity(coder, inputs: 1)
                let input = try byteInput(coder.firstInput)
                // 高遅延入力の初回要求では走査しない。次の順方向要求が作った unit だけを使う。
                if workers > 1, (!avoidsHeaderScans || resetIndexCache.parallelUnits != nil),
                   let units = try parallelUnitsIfAvailable(),
                   let parallel = ParallelIndependentDecompressor(
                    units: units, limits: limits, workers: workers,
                    diagnostics: parallelDiagnostics, coalescingReads: true
                   ) {
                    return .stream(parallel)
                }
                parallelDiagnostics?.serialFallback()
                let decoder = try LZMA2Decoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    dictionarySizeLimit: limits.maxDictionarySize
                )
                if folder.coders.count == 1 {
                    decoder.resetObserver = LZMA2ResetObserver(cache: resetIndexCache, base: 0,
                                                              maximumPointCount: try observedPointLimit())
                }
                return .stream(decoder)

            case .ppmd7:
                try requireArity(coder, inputs: 1)
                let input = try byteInput(coder.firstInput)
                return .stream(try PPMd7Decoder(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    properties: coder.properties,
                    expectedSize: expectedSize,
                    memorySizeLimit: limits.maxDictionarySize
                ))

            case .deflate:
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z Deflate has unexpected properties")
                }
                let input = try byteInput(coder.firstInput)
                return .stream(try DeflateDecompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length
                ))

            case .deflate64:
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z Deflate64 has unexpected properties")
                }
                let input = try byteInput(coder.firstInput)
                return .stream(try Deflate64Decompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    expectedSize: expectedSize
                ))

            case .bzip2:
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z BZip2 has unexpected properties")
                }
                let input = try byteInput(coder.firstInput)
                return .stream(try Bzip2Decompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length
                ))

            case .zstd:
                try requireArity(coder, inputs: 1)
                // 7-Zip ZS 系の writer は version 2 byte + level 1 byte (+ 予約 2 byte) を
                // properties に書く (libarchive 3.8.9 は `01 05 03 00 00`)。復号には使わない。
                guard coder.properties.count == 3 || coder.properties.count == 5 else {
                    throw KaitoError.malformed("7z Zstandard properties must be three or five bytes")
                }
                let input = try byteInput(coder.firstInput)
                // folder 全体の出力が 1 stream なので、entry 上限ではなく folder の宣言サイズで
                // frame の content size と累積出力を検査する。entry ごとの上限は reader が別に見る。
                var codecLimits = limits
                codecLimits.maxEntrySize = expectedSize
                return .stream(try ZstdDecompressor(
                    source: input.source,
                    offset: input.offset,
                    compressedSize: input.length,
                    expectedSize: expectedSize,
                    limits: codecLimits
                ))

            case .aes:
                try requireArity(coder, inputs: 1)
                let input = try byteInput(coder.firstInput)
                return try decryptedBytes(coder: coder, input: input, expectedSize: expectedSize,
                                          chargeKDFWork: chargeKDFWork)

            case let .swap(width):
                try requireArity(coder, inputs: 1)
                guard coder.properties.isEmpty else {
                    throw KaitoError.malformed("7z Swap has unexpected properties")
                }
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z Swap input and output sizes differ")
                }
                return .stream(try SwapFilterDecompressor(
                    input: inputValue(coder.firstInput).asStream(), width: width, expectedSize: expectedSize
                ))

            case .delta:
                try requireArity(coder, inputs: 1)
                guard coder.properties.count == 1 else {
                    throw KaitoError.malformed("7z Delta properties must contain one byte")
                }
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z Delta input and output sizes differ")
                }
                let distance = Int(coder.properties[0]) + 1
                return .stream(try DeltaFilterDecompressor(
                    input: inputValue(coder.firstInput).asStream(),
                    distance: distance,
                    expectedSize: expectedSize
                ))

            case let .branch(filter):
                try requireArity(coder, inputs: 1)
                guard try inputSize(coder.firstInput) == expectedSize else {
                    throw KaitoError.malformed("7z BCJ input and output sizes differ")
                }
                let startOffset = try branchStartOffset(coder.properties)
                return .stream(try BCJFilterDecompressor(
                    input: inputValue(coder.firstInput).asStream(),
                    filter: filter,
                    startOffset: startOffset,
                    expectedSize: expectedSize
                ))

            case .bcj2:
                guard coder.inputCount == 4, coder.outputCount == 1,
                      coder.properties.isEmpty else {
                    throw KaitoError.malformed("invalid 7z BCJ2 coder structure")
                }
                return .stream(try BCJ2Decompressor(
                    main: inputValue(coder.firstInput).asStream(),
                    call: inputValue(coder.firstInput + 1).asStream(),
                    jump: inputValue(coder.firstInput + 2).asStream(),
                    range: inputValue(coder.firstInput + 3).asStream(),
                    expectedSize: expectedSize
                ))

            case let .unsupported(name):
                throw KaitoError.unsupportedMethod(name)
            }
        }

        // PackInfo CRC は暗号化前の packed byte を対象とし、password と無関係。
        // ここで検証してから、復号・coder 由来の失敗だけを password error に変換する。
        try packedStreamVerifier.verify(packedRanges)
        do {
            return try outputValue(folder.finalOutputIndex).asStream()
        } catch {
            throw translateEncryptedError(error)
        }
    }

    // 並列化する graph は一つの packed LZMA2 と、その出力に続く単純 filter 列だけ。
    // filter は outputValue が入力順の stream を包むので、state を共有せず直列に動く。
    private var parallelLZMA2Coder: SevenZipCoder? {
        guard !isEncrypted, folder.packedIndices.count == 1 else { return nil }
        var output = folder.finalOutputIndex, visited = Set<Int>()
        while let index = folder.coderIndex(containingOutput: output), visited.insert(index).inserted {
            let coder = folder.coders[index]
            guard coder.inputCount == 1, coder.outputCount == 1 else { return nil }
            switch SevenZipMethod.kind(for: coder.methodID) {
            case .lzma2:
                guard visited.count == folder.coders.count,
                      folder.boundOutput(forInput: coder.firstInput) == nil,
                      folder.packedIndices == [coder.firstInput] else { return nil }
                return coder
            case .branch, .delta, .swap:
                guard let bound = folder.boundOutput(forInput: coder.firstInput) else { return nil }
                output = bound
            default:
                return nil
            }
        }
        return nil
    }

    // seek は filter state を復元できないので、従来どおり単一 coder だけに限定する。
    func makeDictionaryResetIndex(
        includingFilters: Bool = false, forParallelDecode: Bool = false
    ) throws -> [LZMA2ResetPoint]? {
        guard includingFilters || folder.coders.count == 1,
              let coder = parallelLZMA2Coder,
              coder.properties.count == 1,
              let range = packedRanges[coder.firstInput] else {
            return nil
        }
        if let index = resetIndexCache.index { return try index.get() }
        do {
            let maximumPointCount = try observedPointLimit()
            let index: [LZMA2ResetPoint]?
            if forParallelDecode {
                let dictionarySize = try LZMA2Decoder.dictionarySize(for: coder.properties[0])
                let searchLimit = max(try Checked.mul(dictionarySize, 4), 64 * 1_024 * 1_024)
                let scanSource: any ByteSource = avoidsHeaderScans
                    ? LZMA2TimedScanSource(source: source, clock: scanClock) : source
                index = try LZMA2Decoder.makeParallelDictionaryResetIndex(
                    source: scanSource, offset: range.offset, compressedSize: range.size,
                    expectedSize: finalSize, maximumPointCount: maximumPointCount,
                    singleResetOutputLimit: searchLimit,
                    observer: avoidsHeaderScans
                        ? LZMA2ResetObserver(cache: resetIndexCache, base: 0,
                                            maximumPointCount: maximumPointCount) : nil
                )
            } else {
                index = try LZMA2Decoder.makeDictionaryResetIndex(
                    source: source, offset: range.offset, compressedSize: range.size,
                    expectedSize: finalSize, maximumPointCount: maximumPointCount
                )
            }
            resetIndexCache.index = .success(index)
            return index
        } catch is LZMA2TimedScanSource.TooSlow {
            // 完全な index にはしない。中断前にヘッダから観測した reset 点は後方 seek に残す。
            resetIndexCache.index = .success(nil)
            return nil
        } catch is CancellationError {
            // 中断した走査は未完了なので、次の要求が改めて作れるようにする。
            throw CancellationError()
        } catch {
            resetIndexCache.index = .failure(error)
            throw error
        }
    }

    private func observedPointLimit() throws -> Int {
        min(limits.maxMetadataRecordCount,
            try Checked.toInt(min(limits.maxTotalMetadataSize / UInt64(MemoryLayout<LZMA2ResetPoint>.stride), UInt64(Int.max))))
    }

    func backwardRestartPoint(atOrBefore target: UInt64) throws -> LZMA2ResetPoint? {
        lastBackwardRestartKind = .head
        guard folder.coders.count == 1, parallelLZMA2Coder != nil else { return nil }
        if case .success(let points?) = resetIndexCache.index,
           let point = points.last(where: { $0.isRestartable && $0.uncompressedOffset <= target }) {
            lastBackwardRestartKind = .fullIndex
            return point
        }
        if case .covered(let point) = resetIndexCache.observedRestartPoint(atOrBefore: target) {
            lastBackwardRestartKind = .observed
            return point
        }
        // 通常は target < position ≤ coverage。未観測への退避は観測上限超過や
        // observer がない場合だけで、高遅延では走査せず先頭から再開する。
        guard !avoidsHeaderScans else { return nil }
        do {
            let point = try makeDictionaryResetIndex()?.last(where: { $0.isRestartable && $0.uncompressedOffset <= target })
            lastBackwardRestartKind = .scanned
            return point
        } catch KaitoError.limitExceeded { return nil }
    }

    private func parallelUnitsIfAvailable() throws -> [ParallelIndependentDecompressor.Unit]? {
        do { return try parallelUnits() }
        catch is CancellationError { throw CancellationError() }
        catch {
            // index は最適化だけに使う。後続 chunk の破損・上限超過は元の decoder に
            // 任せ、先行 entry の返却とエラーの検査順を変えない。
            return nil
        }
    }

    // 初回の直列ページを返した後、次の順方向要求で一度だけ並列化を試す。
    // 同じ隔離ドメインで同期実行し、観測 cache を worker と共有しない。
    func prepareDeferredParallelDecode() throws -> Bool {
        guard avoidsHeaderScans, workers > 1, resetIndexCache.parallelUnits == nil else { return false }
        return try parallelUnitsIfAvailable() != nil
    }

    func parallelUnits() throws -> [ParallelIndependentDecompressor.Unit]? {
        if let units = resetIndexCache.parallelUnits { return try units.get() }
        do {
            let units = try makeParallelUnits()
            resetIndexCache.parallelUnits = .success(units)
            return units
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            resetIndexCache.parallelUnits = .failure(error)
            throw error
        }
    }

    private func makeParallelUnits() throws -> [ParallelIndependentDecompressor.Unit]? {
        guard let coder = parallelLZMA2Coder, coder.properties.count == 1,
              let range = packedRanges[coder.firstInput] else { return nil }
        let dictionarySize = try LZMA2Decoder.dictionarySize(for: coder.properties[0])
        try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
        // 宣言辞書 + ByteReader、raw chunk、一時 copy、確率表、range coder の先読み。
        // 出力と終端検査の 1 byte は Unit 自身が加算し、再実行用の一単位分も pool が予約する。
        let scratch = try Checked.add(dictionarySize, 1_048_576)
        let budget = UInt64(limits.resolvedParallelDecodeMemory())
        guard scratch <= budget / 3,
              let index = try makeDictionaryResetIndex(includingFilters: true, forParallelDecode: true) else { return nil }
        let points = index.filter(\.isRestartable)
        guard points.count >= 2, points.first?.uncompressedOffset == 0 else { return nil }
        let source = self.source, properties = coder.properties, limits = self.limits
        var units: [ParallelIndependentDecompressor.Unit] = []
        units.reserveCapacity(points.count)
        for (id, point) in points.enumerated() {
            try Task.checkCancellation()
            let next = id + 1 < points.count ? points[id + 1] : nil
            let size = try Checked.sub(next?.uncompressedOffset ?? finalSize, point.uncompressedOffset)
            // 単位出力の一括確保も readAll と同じ上限に従う。巨大な単位は直列へ戻す。
            guard size <= limits.maxInMemorySize,
                  try Checked.add(Checked.add(size, 1), scratch) <= budget / 3 else { return nil }
            units.append(try .init(outputSize: size, scratchBytes: scratch) {
                try Self.makeDecoder(
                    restartingAt: point, endingAt: next, source: source, range: range,
                    properties: properties, expectedSize: size, dictionarySizeLimit: limits.maxDictionarySize
                )
            })
        }
        return units
    }

    func makeDecoder(restartingAt point: LZMA2ResetPoint) throws -> (any Decompressor)? {
        guard folder.coders.count == 1,
              let coder = folder.coders.first,
              SevenZipMethod.kind(for: coder.methodID) == .lzma2,
              coder.inputCount == 1,
              coder.outputCount == 1,
              coder.properties.count == 1,
              let range = packedRanges[coder.firstInput],
              point.uncompressedOffset <= finalSize else {
            return nil
        }
        let remaining = try Checked.sub(finalSize, point.uncompressedOffset)
        let decoder = try Self.makeDecoder(
            restartingAt: point, endingAt: nil, source: source, range: range,
            properties: coder.properties, expectedSize: remaining, dictionarySizeLimit: limits.maxDictionarySize
        )
        if let decoder = decoder as? LZMA2Decoder {
            decoder.resetObserver = LZMA2ResetObserver(cache: resetIndexCache, base: point.uncompressedOffset,
                                                      maximumPointCount: try observedPointLimit())
        }
        return decoder
    }

    // seek と並列単位で同じ再開 decoder を使う。capture は不変の入力範囲だけで、
    // verifier・AES cache・coordinator の可変状態を worker へ渡さない。
    private static func makeDecoder(
        restartingAt point: LZMA2ResetPoint, endingAt next: LZMA2ResetPoint?,
        source: any ByteSource, range: SevenZipPackRange, properties: [UInt8],
        expectedSize: UInt64, dictionarySizeLimit: UInt64
    ) throws -> any Decompressor {
        return try LZMA2Decoder(
            source: source,
            originalOffset: range.offset,
            originalCompressedSize: range.size,
            properties: properties,
            restartingAt: point,
            endingAt: next,
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
        )
    }

    func decodeAll(limit: UInt64, chargeKDFWork: (UInt64) throws -> Void = { _ in }) throws -> Data {
        try Checked.size(finalSize, limit: limit)
        let count = try Checked.toInt(finalSize)
        var result = Data(count: count)
        let decoder: any Decompressor
        do {
            decoder = try makeDecoder(chargeKDFWork: chargeKDFWork)
        } catch {
            throw translateEncryptedError(error)
        }
        var written = 0
        do {
            try result.withUnsafeMutableBytes { storage in
                while written < count {
                    let destination = UnsafeMutableRawBufferPointer(
                        rebasing: storage[written..<count]
                    )
                    let actual = try decoder.read(into: destination)
                    guard actual > 0, actual <= destination.count else {
                        throw KaitoError.truncated
                    }
                    written += actual
                }
            }
            if !decoder.isFinished {
                var extra: UInt8 = 0
                let count = try withUnsafeMutableBytes(of: &extra) {
                    try decoder.read(into: $0)
                }
                guard count == 0, decoder.isFinished else {
                    throw KaitoError.malformed("7z folder output exceeds its declared size")
                }
            }
            if let expected = folder.digest.value,
               CRC32.checksum(result) != expected {
                throw KaitoError.checksumMismatch(entry: -1)
            }
            return result
        } catch {
            throw translateEncryptedError(error)
        }
    }

    /// 暗号化 folder の失敗だけを `wrongPasswordIfStructural` で読み替える。
    func translateEncryptedError(_ error: Error) -> Error {
        guard isEncrypted else { return error }
        return Self.wrongPasswordIfStructural(error)
    }

    /// 暗号化された入力では、構造の破損（malformed・truncated・CRC 不一致）は誤った password と
    /// 区別できないので `wrongPassword` にする。それ以外の error はそのまま返す。
    static func wrongPasswordIfStructural(_ error: Error) -> Error {
        guard let kaito = error as? KaitoError else { return error }
        switch kaito {
        case .malformed, .truncated, .checksumMismatch:
            return KaitoError.wrongPassword
        default:
            return kaito
        }
    }

    private func requireArity(
        _ coder: SevenZipCoder,
        inputs: Int
    ) throws {
        guard coder.inputCount == inputs, coder.outputCount == 1 else {
            throw KaitoError.malformed("invalid 7z coder stream arity")
        }
    }

    private func branchStartOffset(_ properties: [UInt8]) throws -> UInt64 {
        if properties.isEmpty { return 0 }
        guard properties.count == 4 else {
            throw KaitoError.malformed("7z BCJ properties must be empty or four bytes")
        }
        return UInt64(properties[0])
            | UInt64(properties[1]) << 8
            | UInt64(properties[2]) << 16
            | UInt64(properties[3]) << 24
    }
}
