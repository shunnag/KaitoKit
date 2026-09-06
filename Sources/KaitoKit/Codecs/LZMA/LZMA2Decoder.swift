import Foundation

// 参照仕様: LZMA SDK の公開ドメイン文書 lzma-specification.txt。
// 7-Zip の実装ソースは参照していない。

/// One independently restartable point in an LZMA2 byte stream.
struct LZMA2ResetPoint: Sendable, Equatable {
    /// Absolute offset of the chunk control byte.
    let compressedOffset: UInt64

    /// Output offset immediately before the reset chunk.
    let uncompressedOffset: UInt64

    // raw reset (0x01) の後で従来 property を再利用できるように保存する。
    let lzmaProperties: UInt8?

    // 0x01 は dictionary だけを reset し、LZMA 確率 state は保持する。
    // そのため次の compressed chunk が state reset しない場合は単独再開できない。
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
public final class LZMA2Decoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024
    private static let maximumUnpackedChunkSize: UInt64 = 2 * 1_024 * 1_024
    private static let maximumPackedChunkSize: UInt64 = 64 * 1_024
    private static let maximumResetPointCount = 1_000_000

    private let source: any ByteSource
    private let endOffset: UInt64
    private let expectedSize: UInt64?
    private var reader: ByteReader
    private let lzma: LZMADecoder

    private var needsDictionaryReset = true
    private var needsProperties = true
    private var needsStateReset = true
    private var compressedChunkIsActive = false
    private var uncompressedChunk: [UInt8] = []
    private var uncompressedChunkPosition = 0
    private var outputPosition: UInt64 = 0
    private var finished = false

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
        self.reader = try ByteReader(
            source: LZMABoundedByteSource(source: source, endOffset: endOffset),
            offset: offset
        )
        self.lzma = try LZMADecoder(
            lzma2DictionarySize: dictionarySize,
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
        )
    }

    convenience init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        property: UInt8,
        expectedSize: UInt64?,
        dictionarySizeLimit: UInt64
    ) throws {
        try self.init(
            source: source,
            offset: offset,
            compressedSize: compressedSize,
            properties: [property],
            expectedSize: expectedSize,
            dictionarySizeLimit: dictionarySizeLimit
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
        guard control == 0x01 || control >= 0xE0 else {
            throw KaitoError.malformed("LZMA2 restart point is not a dictionary reset")
        }
        let remainingCompressedSize = try Checked.sub(
            originalEnd,
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
        if let properties = resetPoint.lzmaProperties {
            try lzma.preloadLZMA2Properties(properties)
            needsProperties = false
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
            if uncompressedChunkPosition < uncompressedChunk.count {
                let available = uncompressedChunk.count - uncompressedChunkPosition
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
                if uncompressedChunkPosition == uncompressedChunk.count {
                    uncompressedChunk.removeAll(keepingCapacity: true)
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

    // 後方 seek の初回だけ呼ぶ header scan。各 chunk の payload は確保せず seek で
    // 飛ばし、辞書 reset 制御 byte と累積出力位置だけを bounded 配列へ記録する。
    static func makeDictionaryResetIndex(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        expectedSize: UInt64?,
        maximumPointCount: Int = maximumResetPointCount
    ) throws -> [LZMA2ResetPoint] {
        guard maximumPointCount >= 0 else {
            throw KaitoError.limitExceeded("too many LZMA2 dictionary reset points")
        }
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }
        guard compressedSize > 0 else { throw KaitoError.truncated }

        var reader = try ByteReader(
            source: LZMABoundedByteSource(source: source, endOffset: endOffset),
            offset: offset
        )
        var outputOffset: UInt64 = 0
        var needsDictionaryReset = true
        var needsProperties = true
        var needsStateReset = true
        var currentLZMAProperties: UInt8?
        var result: [LZMA2ResetPoint] = []
        var pendingRawResetPointIndices: [Int] = []

        while true {
            let controlOffset = reader.offset
            let control = try reader.readUInt8()
            if control == 0 {
                // この後に LZMA chunk がない raw reset は独立再開できる。
                for index in pendingRawResetPointIndices {
                    result[index].isRestartable = true
                }
                guard reader.offset == endOffset else {
                    throw KaitoError.malformed("bytes follow the LZMA2 end control")
                }
                if let expectedSize, outputOffset != expectedSize {
                    throw KaitoError.malformed("LZMA2 output size does not match the expected size")
                }
                return result
            }

            if control < 0x80 {
                guard control == 0x01 || control == 0x02 else {
                    throw KaitoError.malformed("invalid LZMA2 control byte")
                }
                if control == 0x01 {
                    guard result.count < maximumPointCount else {
                        throw KaitoError.limitExceeded(
                            "too many LZMA2 dictionary reset points"
                        )
                    }
                    result.append(
                        LZMA2ResetPoint(
                            compressedOffset: controlOffset,
                            uncompressedOffset: outputOffset,
                            lzmaProperties: currentLZMAProperties,
                            isRestartable: false
                        )
                    )
                    pendingRawResetPointIndices.append(result.count - 1)
                    needsDictionaryReset = false
                } else if needsDictionaryReset {
                    throw KaitoError.malformed("LZMA2 stream starts without a dictionary reset")
                }

                let unpackedSize = UInt64(try reader.readUInt16BE()) + 1
                guard unpackedSize <= Self.maximumPackedChunkSize else {
                    throw KaitoError.malformed("invalid LZMA2 uncompressed chunk size")
                }
                outputOffset = try Self.checkedOutputEnd(
                    position: outputOffset,
                    adding: unpackedSize,
                    expectedSize: expectedSize
                )
                let next = try Checked.add(reader.offset, unpackedSize)
                guard next <= endOffset else { throw KaitoError.truncated }
                try reader.seek(to: next)
                continue
            }

            let unpackedSize = try Self.readCompressedUnpackedSize(
                control: control,
                reader: &reader
            )
            let packedSize = UInt64(try reader.readUInt16BE()) + 1
            guard packedSize <= Self.maximumPackedChunkSize else {
                throw KaitoError.malformed("invalid LZMA2 packed chunk size")
            }

            let resetsDictionary = control >= 0xE0
            if resetsDictionary {
                needsDictionaryReset = false
            } else if needsDictionaryReset {
                throw KaitoError.malformed("LZMA2 stream starts without a dictionary reset")
            }

            if control >= 0xC0 {
                let properties = try reader.readUInt8()
                try Self.validateLZMAProperties(properties)
                currentLZMAProperties = properties
                needsProperties = false
            } else if needsProperties {
                throw KaitoError.malformed("LZMA2 stream uses LZMA before properties")
            }

            let resetsState = control >= 0xA0
            if resetsState {
                needsStateReset = false
            } else if needsStateReset {
                throw KaitoError.malformed(
                    "LZMA2 control 0x\(String(control, radix: 16)) at byte \(controlOffset) "
                        + "uses coding state before it is initialized"
                )
            }

            // raw 0x01 自体は coding state を reset しない。最初の後続
            // compressed chunk で state が reset される場合だけ再開可能になる。
            for index in pendingRawResetPointIndices {
                result[index].isRestartable = resetsState
            }
            pendingRawResetPointIndices.removeAll(keepingCapacity: true)

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
        let controlOffset = reader.offset
        let control = try reader.readUInt8()

        if control == 0 {
            guard reader.offset == endOffset else {
                throw KaitoError.malformed("bytes follow the LZMA2 end control")
            }
            if let expectedSize, outputPosition != expectedSize {
                throw KaitoError.malformed("LZMA2 output size does not match the expected size")
            }
            finished = true
            return
        }

        if control < 0x80 {
            try beginUncompressedChunk(control: control)
        } else {
            try beginCompressedChunk(control: control, controlOffset: controlOffset)
        }
    }

    private func beginUncompressedChunk(control: UInt8) throws {
        guard control == 0x01 || control == 0x02 else {
            throw KaitoError.malformed("invalid LZMA2 control byte")
        }
        if control == 0x01 {
            lzma.resetLZMA2Dictionary()
            needsDictionaryReset = false
        } else if needsDictionaryReset {
            throw KaitoError.malformed("LZMA2 stream starts without a dictionary reset")
        }

        let unpackedSize = UInt64(try reader.readUInt16BE()) + 1
        guard unpackedSize <= Self.maximumPackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 uncompressed chunk size")
        }
        _ = try Self.checkedOutputEnd(
            position: outputPosition,
            adding: unpackedSize,
            expectedSize: expectedSize
        )
        uncompressedChunk = Array(try reader.readBytes(try Checked.toInt(unpackedSize)))
        uncompressedChunkPosition = 0
    }

    private func beginCompressedChunk(control: UInt8, controlOffset: UInt64) throws {
        let unpackedSize = try Self.readCompressedUnpackedSize(
            control: control,
            reader: &reader
        )
        let packedSize = UInt64(try reader.readUInt16BE()) + 1
        guard packedSize <= Self.maximumPackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 packed chunk size")
        }

        let resetsDictionary = control >= 0xE0
        if resetsDictionary {
            lzma.resetLZMA2Dictionary()
            needsDictionaryReset = false
        } else if needsDictionaryReset {
            throw KaitoError.malformed("LZMA2 stream starts without a dictionary reset")
        }

        let properties: UInt8?
        if control >= 0xC0 {
            let value = try reader.readUInt8()
            try Self.validateLZMAProperties(value)
            properties = value
            needsProperties = false
        } else {
            guard !needsProperties else {
                throw KaitoError.malformed("LZMA2 stream uses LZMA before properties")
            }
            properties = nil
        }

        let resetState = control >= 0xA0
        if resetState {
            needsStateReset = false
        } else if needsStateReset {
            throw KaitoError.malformed(
                "LZMA2 control 0x\(String(control, radix: 16)) at byte \(controlOffset) "
                    + "uses coding state before it is initialized"
            )
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
            resetState: resetState,
            properties: properties
        )
        compressedChunkIsActive = true
    }

    private static func readCompressedUnpackedSize(
        control: UInt8,
        reader: inout ByteReader
    ) throws -> UInt64 {
        let low = UInt64(try reader.readUInt16BE())
        let high = UInt64(control & 0x1F) << 16
        let size = try Checked.add(try Checked.add(high, low), 1)
        guard size > 0, size <= maximumUnpackedChunkSize else {
            throw KaitoError.malformed("invalid LZMA2 unpacked chunk size")
        }
        return size
    }

    private static func validateLZMAProperties(_ property: UInt8) throws {
        let packed = Int(property)
        guard packed < 9 * 5 * 5 else {
            throw KaitoError.malformed("invalid LZMA lc/lp/pb properties")
        }
        let literalContextBits = packed % 9
        let literalPositionBits = (packed / 9) % 5
        guard literalContextBits + literalPositionBits <= 4 else {
            throw KaitoError.malformed("invalid LZMA2 literal properties")
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
