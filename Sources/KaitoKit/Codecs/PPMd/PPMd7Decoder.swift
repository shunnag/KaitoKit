import Foundation

/// Range-coder operations consumed by the shared PPMd variant-H model.
///
/// Subrange updates deliberately do not normalize.  The model normalizes
/// after a selected symbol and before each suffix descent, which is equivalent
/// to the 7z coder's per-subrange refill and is required by RAR's carry-less
/// coder.
protocol PPMd7RangeDecoding: AnyObject {
    func threshold(total: Int) throws -> Int
    func remove(start: Int, size: Int) throws
    func decodeBinary(probability: Int) throws -> Bool
    func normalize() throws
}

// 参照仕様: 公開ドメインの LZMA SDK `C/Ppmd7.c`、`C/Ppmd7.h`、
// `C/Ppmd7Dec.c` と Dmitry Shkarin の PPMd var.H model description。
// 7z 固有の carryless range coder と 5-byte properties を境界検査付きで再実装する。

// 7z が使用する PPMd7（variant H）のストリーミング decoder。
final class PPMd7Decoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024

    private let expectedSize: UInt64
    private let rangeDecoder: PPMd7RangeDecoder
    private let model: PPMd7Model
    private var producedSize: UInt64 = 0

    // 検証済みの圧縮範囲から PPMd7 decoder を生成する。
    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        properties: [UInt8],
        expectedSize: UInt64,
        memorySizeLimit: UInt64
    ) throws {
        guard properties.count == 5 else {
            throw KaitoError.malformed("PPMd7 properties must contain five bytes")
        }
        let order = Int(properties[0])
        guard (2...64).contains(order) else {
            throw KaitoError.malformed("PPMd7 order must be in 2...64")
        }
        let memorySize = UInt64(properties[1])
            | (UInt64(properties[2]) << 8)
            | (UInt64(properties[3]) << 16)
            | (UInt64(properties[4]) << 24)
        guard memorySize >= 1 << 11,
              memorySize <= UInt64(UInt32.max) - 36 else {
            throw KaitoError.malformed("PPMd7 memory size is outside the supported format range")
        }
        try Checked.size(memorySize, limit: memorySizeLimit)
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }

        self.expectedSize = expectedSize
        self.rangeDecoder = try PPMd7RangeDecoder(
            source: source,
            offset: offset,
            endOffset: endOffset
        )
        self.model = try PPMd7Model(
            maximumOrder: order,
            memorySize: memorySize
        )
    }

    var isFinished: Bool {
        producedSize == expectedSize
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }

        let remaining = try Checked.sub(expectedSize, producedSize)
        let count = try Checked.toInt(min(
            UInt64(buffer.count),
            UInt64(Self.outputChunkSize),
            remaining
        ))
        for index in 0..<count {
            buffer[index] = try model.decodeByte(using: rangeDecoder)
        }
        producedSize = try Checked.add(producedSize, UInt64(count))
        return count
    }
}

// 7z の PPMd7z range coder。入力範囲を越える normalize は必ず truncated。
final class PPMd7RangeDecoder: PPMd7RangeDecoding {
    private static let topValue: UInt32 = 1 << 24
    private static let bufferSize = 64 * 1_024

    private let source: any ByteSource
    private let endOffset: UInt64
    private var sourceOffset: UInt64
    private var bytes = [UInt8](repeating: 0, count: bufferSize)
    private var byteOffset = 0
    private var byteCount = 0

    private var range: UInt32 = UInt32.max
    private var code: UInt32 = 0

    init(source: any ByteSource, offset: UInt64, endOffset: UInt64) throws {
        self.source = source
        self.sourceOffset = offset
        self.endOffset = endOffset

        let marker = try readByte()
        guard marker == 0 else {
            throw KaitoError.malformed("invalid PPMd7 range-coder marker")
        }
        for _ in 0..<4 {
            code = (code << 8) | UInt32(try readByte())
        }
        guard code != UInt32.max else {
            throw KaitoError.malformed("invalid PPMd7 range-coder initialization")
        }
    }

    func threshold(total: Int) throws -> Int {
        guard total > 0, total <= Int(UInt16.max) else {
            throw KaitoError.malformed("invalid PPMd7 frequency total")
        }
        range /= UInt32(total)
        guard range != 0 else {
            throw KaitoError.malformed("PPMd7 range collapsed")
        }
        let value = code / range
        guard value < UInt32(total) else {
            throw KaitoError.malformed("PPMd7 range threshold is outside the model")
        }
        return Int(value)
    }

    func remove(start: Int, size: Int) throws {
        guard start >= 0, size > 0 else {
            throw KaitoError.malformed("invalid PPMd7 subrange")
        }
        let startProduct = UInt64(range) * UInt64(start)
        let sizeProduct = UInt64(range) * UInt64(size)
        guard startProduct <= UInt64(code), sizeProduct <= UInt64(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 subrange is outside the range coder")
        }
        code -= UInt32(startProduct)
        range = UInt32(sizeProduct)
    }

    // escape 側なら true、binary symbol 側なら false を返す。
    func decodeBinary(probability: Int) throws -> Bool {
        guard probability > 0, probability < 1 << 14 else {
            throw KaitoError.malformed("invalid PPMd7 binary probability")
        }
        let unit = range >> 14
        let bound = unit * UInt32(probability)
        guard bound > 0, bound < range else {
            throw KaitoError.malformed("PPMd7 binary range collapsed")
        }
        if code < bound {
            range = bound
            return false
        }
        range -= bound
        code -= bound
        return true
    }

    func normalize() throws {
        while range < Self.topValue {
            range <<= 8
            code = (code << 8) | UInt32(try readByte())
        }
    }

    private func readByte() throws -> UInt8 {
        if byteOffset == byteCount {
            guard sourceOffset < endOffset else { throw KaitoError.truncated }
            let remaining = try Checked.sub(endOffset, sourceOffset)
            let requested = try Checked.toInt(min(UInt64(bytes.count), remaining))
            byteOffset = 0
            byteCount = try bytes.withUnsafeMutableBytes { storage in
                // source へ公開する領域は endOffset までの requested byte に限定する。
                try source.read(
                    into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                    at: sourceOffset
                )
            }
            guard byteCount > 0, byteCount <= requested else {
                throw KaitoError.truncated
            }
            sourceOffset = try Checked.add(sourceOffset, UInt64(byteCount))
        }
        let result = bytes[byteOffset]
        byteOffset += 1
        return result
    }
}
