import Compression

// Public LZ4 Block Format Description (2022-07-31), Frame Format v1.6.4,
// and Apple's compression.h buffer/scratch contract. No third-party codec source.
// Only independent blocks selected by the frame decoder reach this adapter.
final class LZ4AppleBlockDecoder {
    private let scratch: UnsafeMutableRawPointer

    init() {
        let count = compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW)
        scratch = .allocate(byteCount: max(1, count), alignment: 16)
    }

    deinit { scratch.deallocate() }

    static func isEligible(independent: Bool, blockChecksum: Bool, contentChecksum: Bool) -> Bool {
        independent && (blockChecksum || contentChecksum)
    }

    func decode(_ input: UnsafeRawBufferPointer, into buffer: LZ4BlockBuffer,
                blockMaximum: Int, maximumSize: Int) throws {
        // A checksum does not prove grammar: an attacker can recompute it, and
        // content checksums are checked after output is delivered. Walk every
        // accelerated block before publishing bytes, preserving Swift's error order.
        guard let expected = Self.scanValidSize(input, maximumSize: maximumSize) else {
            // The scanner only proves acceptance. Swift diagnoses every rejected
            // candidate, preserving all error classes and their original priority.
            try LZ4BlockDecoder.decode(input, into: buffer, maximumSize: maximumSize)
            return
        }
        // The walk proved expected <= maximumSize <= blockMaximum. The extra
        // byte distinguishes expected output from a capped decode without pinning
        // the frame maximum for short blocks or small entry limits.
        buffer.reserveOutput(expected + 1)
        let count = compression_decode_buffer(buffer.outputAddress.assumingMemoryBound(to: UInt8.self),
                                              expected + 1,
                                              input.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                              input.count, scratch, COMPRESSION_LZ4_RAW)
        if count == 0 || count != expected {
            // Zero can mean an empty block or an error. Swift remains the oracle
            // for that ambiguity (and any unexpected decoded-size disagreement).
            try LZ4BlockDecoder.decode(input, into: buffer, maximumSize: maximumSize)
        } else {
            guard count <= blockMaximum else { throw KaitoError.limitExceeded("LZ4 block output") }
            buffer.outputCount = count
        }
    }

    // Exposed internally for differential tests of the acceptance proof. Rejected
    // candidates always use the original decoder for their exact error diagnosis.
    static func validatedSize(_ input: UnsafeRawBufferPointer, maximumSize: Int) throws -> Int {
        if let count = scanValidSize(input, maximumSize: maximumSize) { return count }
        let buffer = LZ4BlockBuffer()
        try LZ4BlockDecoder.decode(input, into: buffer, maximumSize: maximumSize)
        return buffer.outputCount
    }

    // Format-only acceptance walk. Every load is guarded by cursor < input.count
    // (two remaining bytes for distances); additions are bounded by remaining
    // output. No output bytes are read or copied. Keep the cursor in locals and
    // use a raw pointer only after establishing the nonempty input range.
    private static func scanValidSize(_ input: UnsafeRawBufferPointer, maximumSize: Int) -> Int? {
        guard maximumSize >= 0, !input.isEmpty else { return nil }
        let bytes = input.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var cursor = 0
        var outputCount = 0
        var lastMatchStart: Int?
        var sequences = 0
        while cursor < input.count {
            let token = bytes[cursor]
            cursor += 1
            var literals = Int(token >> 4)
            if literals == 15 {
                guard let length = extendedLength(15, bytes: bytes, count: input.count,
                                                   cursor: &cursor, limit: maximumSize - outputCount) else { return nil }
                literals = length
            }
            guard literals <= input.count - cursor, literals <= maximumSize - outputCount else { return nil }
            outputCount += literals
            cursor += literals
            if cursor == input.count {
                if let lastMatchStart, literals < 5 || outputCount - lastMatchStart < 12 { return nil }
                return outputCount
            }
            guard input.count - cursor >= 2 else { return nil }
            let distance = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
            cursor += 2
            guard distance > 0, distance <= outputCount else { return nil }
            var match = Int(token & 15) + 4
            if match == 19 {
                guard let length = extendedLength(19, bytes: bytes, count: input.count,
                                                   cursor: &cursor, limit: maximumSize - outputCount) else { return nil }
                match = length
            }
            guard match <= maximumSize - outputCount else { return nil }
            lastMatchStart = outputCount
            outputCount += match
            sequences += 1
            // A full validation walk costs more than it saves on dense short
            // matches. Sample at most 32 sequences before committing to Apple;
            // >=64 decoded bytes/sequence amortizes the walk on measured inputs.
            // Returning nil simply runs the original Swift decoder from scratch.
            if sequences == 32, outputCount < 32 * 64 { return nil }
        }
        return nil // A block ending immediately after a match is invalid.
    }

    @inline(__always)
    private static func extendedLength(_ base: Int, bytes: UnsafePointer<UInt8>, count: Int,
                                       cursor: inout Int, limit: Int) -> Int? {
        var length = base
        while cursor < count {
            let extra = Int(bytes[cursor])
            cursor += 1
            guard length <= limit, extra <= limit - length else { return nil }
            length += extra
            if extra != 255 { return length }
        }
        return nil
    }
}
