import Foundation

// 参照仕様: 公開ドメインの LZMA SDK `C/Ppmd7.c`、`C/Ppmd7.h`、
// `C/Ppmd7Dec.c` と Dmitry Shkarin の PPMd var.H model description。
// 7z 固有の carryless range coder を境界検査付きで再実装する。

// 7z の PPMd7z range coder。入力範囲を越える normalize は必ず truncated。
// 兄弟: RARPPMdRangeDecoder（RAR、marker なし・`low` あり）と PPMdVarIRangeDecoder
// （ZIP method 98、`low` と `scale`）。一覧: Core/BitReader.swift の先頭。
final class SevenZipPPMdRangeDecoder: PPMd7RangeDecoding {
    private static let topValue: UInt32 = 1 << 24
    private static let bufferSize = 64 * 1_024

    private let source: any ByteSource
    private let endOffset: UInt64
    private var sourceOffset: UInt64
    private let bytes: UnsafeMutableRawPointer = .allocate(byteCount: bufferSize, alignment: 1)
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

    @inline(__always)
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

    @inline(__always)
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
    @inline(__always)
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

    @inline(__always)
    func normalize() throws {
        while range < Self.topValue {
            range <<= 8
            code = (code << 8) | UInt32(try readByte())
        }
    }

    deinit { bytes.deallocate() }

    @inline(__always)
    private func readByte() throws -> UInt8 {
        // refill publishes only a validated count; 0 <= byteOffset < byteCount
        // covers this load even when the ByteSource returns a short read.
        if byteOffset == byteCount { try refill() }
        let result = bytes.load(fromByteOffset: byteOffset, as: UInt8.self)
        byteOffset += 1
        return result
    }

    @inline(never)
    private func refill() throws {
        guard sourceOffset < endOffset else { throw KaitoError.truncated }
        let requested = Int(min(UInt64(Self.bufferSize), endOffset - sourceOffset))
        byteOffset = 0
        byteCount = 0
        let count = try source.read(
            into: UnsafeMutableRawBufferPointer(start: bytes, count: requested),
            at: sourceOffset
        )
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        byteCount = count
        sourceOffset = try Checked.add(sourceOffset, UInt64(byteCount))
    }
}
