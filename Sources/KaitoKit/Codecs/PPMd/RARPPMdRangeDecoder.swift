import Foundation

// Clean-room references:
// - bitplane/rar-research PPMd behavior notes, §§12.2 and 13.
// - Public-domain LZMA SDK Ppmd7.c / Ppmd7.h for the shared variant-H
//   probability-model contract.
// No unrar, 7-Zip Rar29, XADMaster, or The Unarchiver source was used.

/// RAR 3.x/4.x's carry-less range decoder for PPMd variant H.
///
/// Unlike the 7z range coder, the RAR stream has no leading marker byte and
/// keeps a wrapping `low` register.  `remove` and `decodeBinary` only narrow
/// the interval; `PPMd7Model` invokes `normalize` at the model-defined points.
final class RARPPMdRangeDecoder: PPMd7RangeDecoding {
    private static let topValue: UInt32 = 1 << 24
    private static let bottomValue: UInt32 = 1 << 15
    private static let binaryScale: UInt32 = 1 << 14

    private let bytes: UnsafePointer<UInt8>
    private let byteCount: Int
    private(set) var byteOffset: Int

    private var range: UInt32 = UInt32.max
    private var code: UInt32 = 0
    private var low: UInt32 = 0

    init(
        bytes: UnsafePointer<UInt8>,
        byteCount: Int,
        byteOffset: Int
    ) throws {
        guard byteCount >= 0, byteOffset >= 0, byteOffset <= byteCount else {
            throw KaitoError.malformed("RAR PPMd byte cursor is outside the packed stream")
        }
        self.bytes = bytes
        self.byteCount = byteCount
        self.byteOffset = byteOffset

        // RAR initializes Code from exactly four big-endian bytes.  It does
        // not carry the zero marker used by the 7z PPMd7z range stream.
        for _ in 0..<4 {
            code = (code << 8) | UInt32(try readByte())
        }
    }

    func threshold(total: Int) throws -> Int {
        guard total > 0, total <= Int(UInt16.max) else {
            throw KaitoError.malformed("invalid RAR PPMd frequency total")
        }
        range /= UInt32(total)
        guard range != 0 else {
            throw KaitoError.malformed("RAR PPMd range collapsed")
        }
        let value = (code &- low) / range
        guard value < UInt32(total) else {
            throw KaitoError.malformed("RAR PPMd threshold is outside the model")
        }
        return Int(value)
    }

    func remove(start: Int, size: Int) throws {
        guard start >= 0, size > 0 else {
            throw KaitoError.malformed("invalid RAR PPMd subrange")
        }
        let startValue = UInt64(range) * UInt64(start)
        let sizeValue = UInt64(range) * UInt64(size)
        guard startValue <= UInt64(UInt32.max),
              sizeValue > 0,
              sizeValue <= UInt64(UInt32.max) else {
            throw KaitoError.malformed("RAR PPMd subrange is outside the range coder")
        }
        low = low &+ UInt32(startValue)
        range = UInt32(sizeValue)
    }

    // Returns true for the escape branch and false for the binary symbol.
    func decodeBinary(probability: Int) throws -> Bool {
        guard probability > 0, probability < Int(Self.binaryScale) else {
            throw KaitoError.malformed("invalid RAR PPMd binary probability")
        }
        let unit = range >> 14
        let bound = unit * UInt32(probability)
        guard unit != 0, bound > 0 else {
            throw KaitoError.malformed("RAR PPMd binary range collapsed")
        }
        if (code &- low) < bound {
            range = bound
            return false
        }

        low = low &+ bound
        // The reference multiply by (scale - probability) discards the low
        // 14 remainder bits of the pre-split range.
        let alignedRange = range & ~(Self.binaryScale - 1)
        guard alignedRange > bound else {
            throw KaitoError.malformed("RAR PPMd binary range collapsed")
        }
        range = alignedRange - bound
        return true
    }

    func normalize() throws {
        while true {
            if (low ^ (low &+ range)) >= Self.topValue {
                if range >= Self.bottomValue {
                    return
                }
                range = (0 &- low) & (Self.bottomValue - 1)
                guard range != 0 else {
                    throw KaitoError.malformed("RAR PPMd normalization range collapsed")
                }
            }
            code = (code << 8) | UInt32(try readByte())
            range <<= 8
            low <<= 8
        }
    }

    private func readByte() throws -> UInt8 {
        guard byteOffset < byteCount else { throw KaitoError.truncated }
        let result = bytes[byteOffset]
        byteOffset += 1
        return result
    }
}
