import Foundation

// 参照仕様: LZMA SDK の公開ドメイン文書 lzma-specification.txt。
// 7-Zip の実装ソースは参照していない。

/// One independently restartable point in an LZMA2 byte stream.
struct LZMA2ResetPoint: Sendable, Equatable {
    /// Absolute offset of the chunk control byte.
    let compressedOffset: UInt64

    /// Output offset immediately before the reset chunk.
    let uncompressedOffset: UInt64

    // reset 点から再開する decoder へ先に読み込む LZMA property。raw reset (0x01) の点では
    // 直前の chunk の値を保存する。
    let lzmaProperties: UInt8?

    // 0x01 の後の LZMA chunk は property 付きの 0xC0 以上でなければならず
    // （`LZMA2ResetTracker`）、index 走査が完走した点はすべて単独で再開できる。
    var isRestartable: Bool

    init(
        compressedOffset: UInt64,
        uncompressedOffset: UInt64,
        lzmaProperties: UInt8? = nil,
        isRestartable: Bool = true
    ) {
        self.compressedOffset = compressedOffset
        self.uncompressedOffset = uncompressedOffset
        self.lzmaProperties = lzmaProperties
        self.isRestartable = isRestartable
    }
}

/// A streaming decoder for the raw LZMA2 stream used by 7z folders.
///
/// The single property byte describes the dictionary size. Compressed and
/// uncompressed chunks are decoded incrementally without retaining the whole
/// output.
///
/// Failures are not latched: after `read(into:)` throws, the state is
/// unspecified and the instance must be discarded.
public final class LZMA2Decoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024
    private static let maximumResetPointCount = 1_000_000

    private let source: any ByteSource
    private let endOffset: UInt64
    private let expectedSize: UInt64?
    private var reader: ByteReader
    private let lzma: LZMADecoder

    private var resets = LZMA2ResetTracker()
    private var compressedChunkIsActive = false
    // 非圧縮 chunk の一時保管。最大 64 KiB を一度だけ確保し、count と position で使用範囲を追う。
    private var uncompressedChunk: [UInt8] = []
    private var uncompressedChunkCount = 0
    private var uncompressedChunkPosition = 0
    private var outputPosition: UInt64 = 0
    private var finished = false
    private var endsAtDictionaryReset = false

    /// Creates an LZMA2 decoder over a validated byte-source range.
    ///
    /// - Parameters:
    ///   - source: Source containing the raw LZMA2 byte stream.
    ///   - offset: Absolute offset of the first LZMA2 control byte.
    ///   - compressedSize: Number of bytes in the raw LZMA2 stream.
    ///   - properties: Exactly one LZMA2 dictionary property byte.
    ///   - expectedSize: Known output size, or `nil` to use the end control.
    ///   - dictionarySizeLimit: Maximum accepted dictionary allocation.
    public init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        properties: [UInt8],
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64
    ) throws {
        guard properties.count == 1 else {
            throw KaitoError.malformed("LZMA2 properties must contain one byte")
        }
        let dictionarySize = try Self.dictionarySize(for: properties[0])
        try Checked.size(dictionarySize, limit: dictionarySizeLimit)

        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else {
            throw KaitoError.truncated
        }
        guard compressedSize > 0 else {
            throw KaitoError.truncated
        }

        self.source = source
        self.endOffset = endOffset
        self.expectedSize = expectedSize
        // 外側の ByteReader も folder の検証済み packed 範囲だけを読み、後続 member を消費しない。
        // buffer は stream 全長を超えて確保しない（小さな folder を大量に開く場合の確保と zero 埋めを省く）。
        self.reader = try ByteReader(
            source: BoundedByteSource(source: source, baseOffset: 0, length: endOffset),
            offset: offset,
            bufferCapacity: Int(min(UInt64(ByteReader.bufferSize), compressedSize))
        )
        self.lzma = try LZMADecoder(
            lzma2DictionarySize: dictionarySize,
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit,
            compressedSizeHint: compressedSize
        )
    }

    // 元 stream の範囲と header-only index の点から、dictionary reset chunk を
    // 先頭として再開する。expectedSize は reset 点以後の残り出力 byte 数。
    convenience init(
        source: any ByteSource,
        originalOffset: UInt64,
        originalCompressedSize: UInt64,
        properties: [UInt8],
        restartingAt resetPoint: LZMA2ResetPoint,
        endingAt nextResetPoint: LZMA2ResetPoint? = nil,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64
    ) throws {
        let originalEnd = try Checked.add(originalOffset, originalCompressedSize)
        guard originalEnd <= source.length else { throw KaitoError.truncated }
        guard resetPoint.compressedOffset >= originalOffset,
              resetPoint.compressedOffset < originalEnd else {
            throw KaitoError.malformed("LZMA2 reset point is outside the stream")
        }
        guard resetPoint.isRestartable else {
            throw KaitoError.malformed("LZMA2 reset point requires prior coding state")
        }
        let control = try readByteRange(
            source: source,
            offset: resetPoint.compressedOffset,
            count: 1
        )[0]
        guard LZMA2ChunkHeader.resetsDictionary(control: control) else {
            throw KaitoError.malformed("LZMA2 restart point is not a dictionary reset")
        }
        let end = nextResetPoint?.compressedOffset ?? originalEnd
        guard end > resetPoint.compressedOffset, end <= originalEnd else {
            throw KaitoError.malformed("LZMA2 reset range is outside the stream")
        }
        let remainingCompressedSize = try Checked.sub(
            end,
            resetPoint.compressedOffset
        )
        try self.init(
            source: source,
            offset: resetPoint.compressedOffset,
            compressedSize: remainingCompressedSize,
            properties: properties,
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
        )
        // index で検証した次の reset 直前を単位の終端とする。最後の単位は
        // 元 stream の end control を読み、従来どおり終端とサイズを確かめる。
        endsAtDictionaryReset = nextResetPoint != nil
        if let properties = resetPoint.lzmaProperties {
            try lzma.preloadLZMA2Properties(properties)
            resets.acceptPreloadedProperties()
        }
    }

    /// Indicates whether the end control and the expected output size were reached.
    public var isFinished: Bool {
        finished
    }

    /// Decodes at most one 256 KiB output piece into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let destination = buffer.baseAddress else {
            throw KaitoError.malformed("LZMA2 output buffer has no storage")
        }

        let capacity = min(buffer.count, Self.outputChunkSize)
        var written = 0

        while written < capacity, !finished {
            if uncompressedChunkPosition < uncompressedChunkCount {
                let available = uncompressedChunkCount - uncompressedChunkPosition
                let amount = min(available, capacity - written)
                let end = uncompressedChunkPosition + amount
                let bytes = uncompressedChunk[uncompressedChunkPosition..<end]
                try lzma.appendLZMA2Uncompressed(bytes)
                bytes.withUnsafeBytes { sourceBytes in
                    guard let sourceAddress = sourceBytes.baseAddress else { return }
                    // written..<written+amount は呼び出し側の検証済み出力領域内で、
                    // bytes は同じ amount バイトを保持している copy primitive。
                    destination.advanced(by: written).copyMemory(
                        from: sourceAddress,
                        byteCount: amount
                    )
                }
                uncompressedChunkPosition = end
                written += amount
                outputPosition = try Checked.add(outputPosition, UInt64(amount))
                if uncompressedChunkPosition == uncompressedChunkCount {
                    uncompressedChunkCount = 0
                    uncompressedChunkPosition = 0
                }
                continue
            }

            if compressedChunkIsActive {
                let remaining = capacity - written
                // destination の written 以降 remaining バイトだけを LZMA hot loop に渡す。
                let output = UnsafeMutableRawBufferPointer(
                    start: destination.advanced(by: written),
                    count: remaining
                )
                let count = try lzma.read(into: output)
                guard count >= 0, count <= remaining else {
                    throw KaitoError.malformed("LZMA2 decoder returned an invalid byte count")
                }
                written += count
                outputPosition = try Checked.add(outputPosition, UInt64(count))
                if lzma.isFinished {
                    try lzma.finishLZMA2Chunk()
                    compressedChunkIsActive = false
                } else if count == 0 {
                    throw KaitoError.malformed("LZMA2 compressed chunk made no progress")
                }
                continue
            }

            try beginNextChunk()
        }

        return written
    }

    // 後方 seek の header scan は task の cancellation 状態に依存しない。
    static func makeDictionaryResetIndex(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64?,
        maximumPointCount: Int = maximumResetPointCount
    ) throws -> [LZMA2ResetPoint] {
        try scanDictionaryResetIndex(
            source: source, offset: offset, compressedSize: compressedSize,
            expectedSize: expectedSize, maximumPointCount: maximumPointCount,
            singleResetOutputLimit: nil, checksCancellation: false
        ) ?? []
    }

    // 二つ目の dictionary reset が探索上限までに現れなければ nil（直列）を返す。
    // 現れた場合だけ終端まで検証し、後方 seek と共用できる完全な index を作る。
    static func makeParallelDictionaryResetIndex(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64?,
        maximumPointCount: Int,
        singleResetOutputLimit: UInt64
    ) throws -> [LZMA2ResetPoint]? {
        try scanDictionaryResetIndex(
            source: source, offset: offset, compressedSize: compressedSize,
            expectedSize: expectedSize, maximumPointCount: maximumPointCount,
            singleResetOutputLimit: singleResetOutputLimit, checksCancellation: true
        )
    }

    // payload は seek で飛ばし、header byte だけを位置指定で読む。通常の 256 KiB
    // 先読みを使わず、live decoder と同じ parser・reset tracker の検査順を保つ。
    private static func scanDictionaryResetIndex(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64?,
        maximumPointCount: Int,
        singleResetOutputLimit: UInt64?,
        checksCancellation: Bool
    ) throws -> [LZMA2ResetPoint]? {
        guard maximumPointCount >= 0 else {
            throw KaitoError.limitExceeded("too many LZMA2 dictionary reset points")
        }
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }
        guard compressedSize > 0 else { throw KaitoError.truncated }

        var reader = try ByteReader(
            source: BoundedByteSource(source: source, baseOffset: 0, length: endOffset),
            offset: offset,
            bufferCapacity: 1
        )
        var outputOffset: UInt64 = 0
        var resets = LZMA2ResetTracker()
        var currentLZMAProperties: UInt8?
        var result: [LZMA2ResetPoint] = []

        while true {
            if checksCancellation { try Task.checkCancellation() }
            if let singleResetOutputLimit, result.count < 2,
               outputOffset > singleResetOutputLimit {
                return nil
            }
            let controlOffset = reader.offset
            let control = try reader.readUInt8()
            // raw dictionary reset の点の上限は size より先に確かめる。上限超過（呼出元は先頭からの
            // 再開へ退避する）を、続く size の切断より先に報告する。
            if control == LZMA2ChunkHeader.rawDictionaryResetControl,
               result.count >= maximumPointCount {
                throw KaitoError.limitExceeded("too many LZMA2 dictionary reset points")
            }
            let header = try LZMA2ChunkHeader(
                control: control,
                controlOffset: controlOffset,
                reader: &reader,
                resets: &resets
            )

            switch header {
            case .end:
                guard reader.offset == endOffset else {
                    throw KaitoError.malformed("bytes follow the LZMA2 end control")
                }
                if let expectedSize, outputOffset != expectedSize {
                    throw KaitoError.malformed("LZMA2 output size does not match the expected size")
                }
                return result

            case let .uncompressed(size, resetsDictionary):
                if resetsDictionary {
                    // raw 0x01 の後の LZMA chunk は property と coding state を持つ 0xC0 以上に
                    // 限られる（reset tracker が検査する）ので、この点から単独で再開できる。
                    result.append(
                        LZMA2ResetPoint(
                            compressedOffset: controlOffset,
                            uncompressedOffset: outputOffset,
                            lzmaProperties: currentLZMAProperties
                        )
                    )
                }
                outputOffset = try Self.checkedOutputEnd(
                    position: outputOffset,
                    adding: size,
                    expectedSize: expectedSize
                )
                let next = try Checked.add(reader.offset, size)
                guard next <= endOffset else { throw KaitoError.truncated }
                try reader.seek(to: next)

            case let .compressed(unpackedSize, packedSize, resetsDictionary, _, properties):
                if let properties {
                    currentLZMAProperties = properties
                }

                if resetsDictionary {
                    guard result.count < maximumPointCount else {
                        throw KaitoError.limitExceeded(
                            "too many LZMA2 dictionary reset points"
                        )
                    }
                    result.append(
                        LZMA2ResetPoint(
                            compressedOffset: controlOffset,
                            uncompressedOffset: outputOffset,
                            lzmaProperties: currentLZMAProperties
                        )
                    )
                }

                outputOffset = try Self.checkedOutputEnd(
                    position: outputOffset,
                    adding: unpackedSize,
                    expectedSize: expectedSize
                )
                let next = try Checked.add(reader.offset, packedSize)
                guard next <= endOffset else { throw KaitoError.truncated }
                try reader.seek(to: next)
            }
        }
    }

    static func dictionarySize(for property: UInt8) throws -> UInt64 {
        let value = UInt64(property)
        guard value <= 40 else {
            throw KaitoError.malformed("invalid LZMA2 dictionary property")
        }
        if value == 40 {
            return UInt64(UInt32.max)
        }
        return try Checked.shiftLeft(2 | (value & 1), by: value / 2 + 11)
    }

    private func beginNextChunk() throws {
        if endsAtDictionaryReset, reader.offset == endOffset {
            guard outputPosition == expectedSize else {
                throw KaitoError.malformed("LZMA2 output size does not match the expected size")
            }
            finished = true
            return
        }
        let controlOffset = reader.offset
        let control = try reader.readUInt8()
        let header = try LZMA2ChunkHeader(
            control: control,
            controlOffset: controlOffset,
            reader: &reader,
            resets: &resets
        )

        switch header {
        case .end:
            guard reader.offset == endOffset else {
                throw KaitoError.malformed("bytes follow the LZMA2 end control")
            }
            if let expectedSize, outputPosition != expectedSize {
                throw KaitoError.malformed("LZMA2 output size does not match the expected size")
            }
            finished = true

        case let .uncompressed(size, resetsDictionary):
            if resetsDictionary {
                lzma.resetLZMA2Dictionary()
            }
            _ = try Self.checkedOutputEnd(
                position: outputPosition,
                adding: size,
                expectedSize: expectedSize
            )
            let count = try Checked.toInt(size)
            if uncompressedChunk.count < count {
                uncompressedChunk = [UInt8](repeating: 0, count: Int(LZMA2ChunkHeader.maximumRawChunkSize))
            }
            // readBytes と同じ truncated 条件で、Data を介さず一時保管へ直接写す。
            try uncompressedChunk.withUnsafeMutableBytes { storage in
                try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: storage[..<count]))
            }
            uncompressedChunkCount = count
            uncompressedChunkPosition = 0

        case let .compressed(unpackedSize, packedSize, resetsDictionary, resetsState, properties):
            if resetsDictionary {
                lzma.resetLZMA2Dictionary()
            }
            _ = try Self.checkedOutputEnd(
                position: outputPosition,
                adding: unpackedSize,
                expectedSize: expectedSize
            )
            let packedOffset = reader.offset
            let next = try Checked.add(packedOffset, packedSize)
            guard next <= endOffset else { throw KaitoError.truncated }
            try reader.seek(to: next)

            try lzma.beginLZMA2Chunk(
                source: source,
                offset: packedOffset,
                compressedSize: packedSize,
                unpackedSize: unpackedSize,
                resetState: resetsState,
                properties: properties
            )
            compressedChunkIsActive = true
        }
    }

    private static func checkedOutputEnd(
        position: UInt64,
        adding size: UInt64,
        expectedSize: UInt64?
    ) throws -> UInt64 {
        let result = try Checked.add(position, size)
        if let expectedSize, result > expectedSize {
            throw KaitoError.malformed("LZMA2 output exceeds the expected size")
        }
        return result
    }
}
