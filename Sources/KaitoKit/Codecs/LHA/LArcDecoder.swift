import Darwin
import Foundation

// Provenance:
// - Haruhiko Okumura, "Data Compression Algorithms of LARC and LHarc":
//   https://gamedev.net/tutorials/programming/general-and-gameplay-programming/data-compression-algorithms-of-larc-and-lharc-r295
// - LHa for UNIX header.doc (method/window descriptions):
//   https://github.com/jca02266/lha/blob/master/header.doc.md
// - Lhasa's user documentation and public raw-decoder API documentation:
//   https://github.com/fragglet/lhasa/blob/master/doc/lha.1
//   https://fragglet.github.io/lhasa/
// - Search results auto-displayed short LHa `larc.c` / `delharc` snippets; the
//   token and initial-window semantics were consulted, without opening a file
//   or copying code, then independently confirmed with raw liblhasa vectors.
// The installed `lha`/liblhasa executable was used only as a black-box oracle.
// No Lhasa implementation source, XADMaster, or The Unarchiver was consulted.

/// Decoder for the two LArc LZSS methods carried by LHA archives.
///
/// `-lzs-` is an MSB-first stream of a one-bit kind, followed by either an
/// eight-bit literal or an eleven-bit absolute ring position and four-bit
/// length. `-lz5-` groups eight kinds in an LSB-first flag byte and stores a
/// match as a little-endian twelve-bit position plus a four-bit length.
final class LArcDecoder: Decompressor {
    private enum Method {
        case lzs
        case lz5

        init(identifier: String) throws {
            switch identifier {
            case "-lzs-": self = Method.lzs
            case "-lz5-": self = Method.lz5
            default: throw KaitoError.unsupportedMethod(identifier)
            }
        }
    }

    private let method: Method
    private let input: LHAPackedInputStorage
    private let expectedSize: UInt64
    private let window: UnsafeMutablePointer<UInt8>
    private let windowSize: Int
    private let windowMask: Int

    private var bits: MSBFirstBitReader
    private var inputOffset = 0
    private var flagByte: UInt8 = 0
    private var flagBitsRemaining = 0
    private var windowPosition: Int
    private var produced: UInt64 = 0
    private var pendingDistance = 0
    private var pendingLength = 0
    private var finished: Bool

    /// Creates a decoder over one exactly bounded LArc member payload.
    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        method identifier: String,
        limits: ReadLimits
    ) throws {
        let method = try Method(identifier: identifier)
        try Checked.size(compressedSize, limit: limits.maxEntrySize)
        try Checked.size(uncompressedSize, limit: limits.maxEntrySize)
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else {
            throw KaitoError.truncated
        }
        let windowSize = method == Method.lzs ? 2_048 : 4_096
        try Checked.size(UInt64(windowSize), limit: limits.maxDictionarySize)

        let inputCount = try Checked.toInt(compressedSize)
        let input = try LHAPackedInputStorage(
            source: source,
            offset: offset,
            count: inputCount
        )
        guard let allocation = malloc(windowSize) else {
            throw KaitoError.limitExceeded("unable to allocate LArc dictionary")
        }
        let window = allocation.bindMemory(to: UInt8.self, capacity: windowSize)
        window.initialize(repeating: 0, count: windowSize)

        if method == Method.lzs {
            // LArc's original 2 KiB ring begins at N - F and is seeded with
            // spaces. Absolute positions in match tokens address this ring.
            window.update(repeating: 0x20, count: windowSize)
            self.windowPosition = windowSize - 17
        } else {
            Self.initializeLZ5Window(window)
            self.windowPosition = 0
        }

        self.method = method
        self.input = input
        self.expectedSize = uncompressedSize
        self.window = window
        self.windowSize = windowSize
        self.windowMask = windowSize - 1
        self.bits = MSBFirstBitReader(
            borrowing: UnsafePointer(input.bytes),
            count: input.logicalCount
        )
        self.finished = uncompressedSize == 0
    }

    deinit {
        window.deinitialize(count: windowSize)
        free(UnsafeMutableRawPointer(window))
    }

    var isFinished: Bool { finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let output = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw KaitoError.malformed("LArc output buffer has no storage")
        }

        let remainingOutput = try Checked.sub(expectedSize, produced)
        let outputLimit = try Checked.toInt(min(UInt64(buffer.count), remainingOutput))
        var outputPosition = 0

        while outputPosition < outputLimit {
            if pendingLength > 0 {
                let before = outputPosition
                lhaCopyMatch(
                    window: window,
                    windowMask: windowMask,
                    windowPosition: &windowPosition,
                    distance: pendingDistance,
                    remaining: &pendingLength,
                    output: output,
                    outputPosition: &outputPosition,
                    outputLimit: outputLimit
                )
                produced = try Checked.add(produced, UInt64(outputPosition - before))
                if pendingLength == 0 { pendingDistance = 0 }
                continue
            }

            switch method {
            case Method.lzs:
                try decodeLZSToken(into: output, outputPosition: &outputPosition)
            case Method.lz5:
                try decodeLZ5Token(into: output, outputPosition: &outputPosition)
            }
        }

        if produced == expectedSize {
            guard pendingLength == 0 else {
                throw KaitoError.malformed("LArc match exceeds the declared output size")
            }
            finished = true
        }
        return outputPosition
    }

    private func decodeLZSToken(
        into output: UnsafeMutablePointer<UInt8>,
        outputPosition: inout Int
    ) throws {
        let isLiteral = try readLZSBits(1) != 0
        if isLiteral {
            let byte = UInt8(truncatingIfNeeded: try readLZSBits(8))
            try emit(byte, into: output, outputPosition: &outputPosition)
            return
        }

        let sourcePosition = Int(try readLZSBits(11))
        let length = Int(try readLZSBits(4)) + 2
        try beginMatch(sourcePosition: sourcePosition, length: length)
    }

    private func decodeLZ5Token(
        into output: UnsafeMutablePointer<UInt8>,
        outputPosition: inout Int
    ) throws {
        if flagBitsRemaining == 0 {
            flagByte = try readLZ5Byte()
            flagBitsRemaining = 8
        }
        let isLiteral = (flagByte & 1) != 0
        flagByte >>= 1
        flagBitsRemaining -= 1

        if isLiteral {
            try emit(try readLZ5Byte(), into: output, outputPosition: &outputPosition)
            return
        }

        let lowPosition = Int(try readLZ5Byte())
        let packedHighAndLength = Int(try readLZ5Byte())
        let encodedPosition = lowPosition | ((packedHighAndLength & 0xF0) << 4)
        let sourcePosition = (encodedPosition + 18) & windowMask
        // LZ5 uses the classic LZSS threshold of two: the encoded nibble is
        // therefore length minus three. This differs from LZS, whose nibble
        // is length minus two.
        let length = (packedHighAndLength & 0x0F) + 3
        try beginMatch(sourcePosition: sourcePosition, length: length)
    }

    private func beginMatch(sourcePosition: Int, length: Int) throws {
        let validLengths = method == Method.lzs ? 2...17 : 3...18
        guard sourcePosition >= 0, sourcePosition < windowSize,
              validLengths.contains(length) else {
            throw KaitoError.malformed("invalid LArc match")
        }
        let remaining = try Checked.sub(expectedSize, produced)
        guard UInt64(length) <= remaining else {
            throw KaitoError.malformed("LArc match exceeds the declared output size")
        }

        let backward = (windowPosition - sourcePosition) & windowMask
        pendingDistance = backward == 0 ? windowSize : backward
        pendingLength = length
    }

    private func emit(
        _ byte: UInt8,
        into output: UnsafeMutablePointer<UInt8>,
        outputPosition: inout Int
    ) throws {
        guard produced < expectedSize else {
            throw KaitoError.malformed("LArc output exceeds the declared size")
        }
        output[outputPosition] = byte
        outputPosition += 1
        window[windowPosition] = byte
        windowPosition = (windowPosition + 1) & windowMask
        produced = try Checked.add(produced, 1)
    }

    private func readLZSBits(_ count: Int) throws -> UInt32 {
        let value = try bits.read(count)
        guard !bits.overrun else { throw KaitoError.truncated }
        return value
    }

    private func readLZ5Byte() throws -> UInt8 {
        guard inputOffset < input.logicalCount else { throw KaitoError.truncated }
        let byte = input.bytes[inputOffset]
        inputOffset += 1
        return byte
    }

    private static func initializeLZ5Window(_ window: UnsafeMutablePointer<UInt8>) {
        // The fixed seed is part of LArc's -lz5- wire format. It occupies
        // positions 18...4095; positions 0...17 start as zero and are where
        // newly produced bytes are first written.
        var position = 18
        for value in 0..<256 {
            for _ in 0..<13 {
                window[position] = UInt8(value)
                position += 1
            }
        }
        for value in 0..<256 {
            window[position] = UInt8(value)
            position += 1
        }
        for value in 0..<256 {
            window[position] = UInt8(255 - value)
            position += 1
        }
        position += 128 // This range was zeroed with the allocation.
        while position < 4_096 {
            window[position] = 0x20
            position += 1
        }
    }
}
