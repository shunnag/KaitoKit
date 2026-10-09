import Foundation

// LZ4 Frame Format v1.6.4 (2023-12-28). No third-party codec source is used.
// At most one encoded block, one decoded block, and 64 KiB of history are held.
final class LZ4FrameDecompressor: Decompressor {
    static let magic: UInt64 = 0x184d2204
    static let legacyMagic: UInt64 = 0x184c2102
    private static let legacyBlockSize = 8 * 1_024 * 1_024
    // Matches reach back at most 64 KiB, so that much history is kept between dependent blocks.
    fileprivate static let historySize = 65_536
    // The high bit of a block-size word marks a block stored without compression.
    private static let uncompressedBlockFlag: UInt64 = 0x8000_0000
    // An all-literal block adds one length byte per 255 bytes plus its token.
    // Match sequences do not exceed that bound. Keep a small framing margin.
    private static let maximumLegacyCompressedSize = legacyBlockSize + legacyBlockSize / 255 + 16
    private let input: LZ4FrameInput
    private let limits: ReadLimits
    private var header: LZ4FrameHeader?
    private var legacy = false
    private var frameCount = 0
    private var blockCount = 0
    private var produced: UInt64 = 0
    private var frameProduced: UInt64 = 0
    private var checksum = XXH32()
    private let decoded = LZ4BlockBuffer()
    private var encoded: [UInt8] = []
    private var pendingOffset = 0
    private var sawFrame = false
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init(source: any ByteSource, offset: UInt64 = 0, compressedSize: UInt64? = nil,
         limits: ReadLimits = ReadLimits()) throws {
        input = try LZ4FrameInput(source: source, offset: offset,
                                  size: compressedSize ?? Checked.sub(source.length, offset))
        self.limits = limits
    }

    static func isSkippable(_ magic: UInt64) -> Bool {
        (0x184d2a50...0x184d2a5f).contains(magic)
    }

    static func isFrameMagic(_ value: UInt64) -> Bool {
        value == magic || value == legacyMagic || isSkippable(value)
    }

    // Legacy has no footer. A known frame magic belongs to the next frame,
    // whereas a zero word is the Linux-compatible explicit end marker.
    private static func nextLegacyBlockSize(_ input: LZ4FrameInput) throws -> Int? {
        if input.remaining == 0 { return nil }
        let word = try input.peekInteger(4)
        if isFrameMagic(word) { return nil }
        try input.skip(4)
        if word == 0 { return nil }
        guard word <= UInt64(maximumLegacyCompressedSize) else {
            throw KaitoError.malformed("LZ4 legacy compressed block size")
        }
        return Int(word)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while pendingOffset == decoded.outputCount {
                try Task.checkCancellation()
                decoded.finishBlock(keepHistory: header?.independent == false)
                pendingOffset = 0
                if let header {
                    let word = try input.integer(4)
                    if word == 0 {
                        if header.contentChecksum, try input.integer(4) != UInt64(checksum.value) {
                            throw KaitoError.checksumMismatch(entry: 0)
                        }
                        if let size = header.contentSize, size != frameProduced {
                            throw KaitoError.malformed("LZ4 frame content size mismatch")
                        }
                        self.header = nil
                        decoded.reset()
                        continue
                    }
                    try Self.charge(&blockCount, limits: limits)
                    let count = try header.blockSize(word)
                    try input.read(count, into: &encoded)
                    if header.blockChecksum, try input.integer(4) != UInt64(XXH32.digest(encoded)) {
                        throw KaitoError.checksumMismatch(entry: 0)
                    }
                    let remaining = limits.maxEntrySize - produced
                    let maximum = Int(min(UInt64(header.maximumBlockSize), remaining))
                    if word & Self.uncompressedBlockFlag != 0 {
                        try Checked.size(UInt64(count), limit: remaining)
                        encoded.withUnsafeBytes { decoded.store($0) }
                    } else {
                        try encoded.withUnsafeBytes {
                            try LZ4BlockDecoder.decode($0, into: decoded, maximumSize: maximum)
                        }
                    }
                    frameProduced = try Checked.add(frameProduced, UInt64(decoded.outputCount))
                    produced = try Checked.add(produced, UInt64(decoded.outputCount))
                    if let size = header.contentSize, frameProduced > size {
                        throw KaitoError.malformed("LZ4 frame output exceeds content size")
                    }
                    if header.contentChecksum { decoded.withOutputBytes { checksum.update($0) } }
                    if decoded.outputCount > 0 { break }
                } else if legacy {
                    guard let count = try Self.nextLegacyBlockSize(input) else {
                        legacy = false
                        continue
                    }
                    try Self.charge(&blockCount, limits: limits)
                    let maximum = Int(min(UInt64(Self.legacyBlockSize), limits.maxEntrySize - produced))
                    try input.read(count, into: &encoded)
                    try encoded.withUnsafeBytes {
                        try LZ4BlockDecoder.decode($0, into: decoded, maximumSize: maximum)
                    }
                    produced = try Checked.add(produced, UInt64(decoded.outputCount))
                    if decoded.outputCount > 0 { break }
                } else {
                    if input.remaining == 0 {
                        guard sawFrame else { throw KaitoError.truncated }
                        isFinished = true
                        return 0
                    }
                    try Self.charge(&frameCount, limits: limits)
                    let magic = try input.integer(4)
                    sawFrame = true
                    if Self.isSkippable(magic) {
                        try input.skip(input.integer(4))
                        continue
                    }
                    if magic == Self.legacyMagic {
                        try Checked.size(UInt64(Self.historySize), limit: limits.maxDictionarySize)
                        legacy = true
                        continue
                    }
                    guard magic == Self.magic else { throw KaitoError.malformed("LZ4 frame magic") }
                    let next = try LZ4FrameHeader(input: input, limits: limits)
                    if let size = next.contentSize {
                        let total = try Checked.add(produced, size)
                        try Checked.size(total, limit: limits.maxEntrySize)
                    }
                    header = next
                    frameProduced = 0
                    checksum = XXH32()
                    decoded.reset()
                }
            }
            let count = min(buffer.count, decoded.outputCount - pendingOffset)
            decoded.withOutputBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[pendingOffset..<(pendingOffset + count)]))
            }
            pendingOffset += count
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    // Scan every frame and skip payload without allocating its declared size.
    // Checksums of block/content bytes are validated when the stream is read.
    static func contentSize(source: any ByteSource, limits: ReadLimits) throws -> UInt64? {
        let input = try LZ4FrameInput(source: source, offset: 0, size: source.length)
        guard input.remaining > 0 else { throw KaitoError.truncated }
        var total: UInt64 = 0
        var known = true
        var frames = 0
        var blocks = 0
        while input.remaining > 0 {
            try Task.checkCancellation()
            try charge(&frames, limits: limits)
            let magic = try input.integer(4)
            if isSkippable(magic) {
                try input.skip(input.integer(4))
                continue
            }
            if magic == Self.legacyMagic {
                try Checked.size(UInt64(Self.historySize), limit: limits.maxDictionarySize)
                known = false
                while let count = try nextLegacyBlockSize(input) {
                    try charge(&blocks, limits: limits)
                    try input.skip(UInt64(count))
                }
                continue
            }
            guard magic == Self.magic else { throw KaitoError.malformed("LZ4 frame magic") }
            let header = try LZ4FrameHeader(input: input, limits: limits)
            if let size = header.contentSize {
                total = try Checked.add(total, size)
                try Checked.size(total, limit: limits.maxEntrySize)
            } else { known = false }
            while true {
                let word = try input.integer(4)
                if word == 0 { break }
                try charge(&blocks, limits: limits)
                try input.skip(UInt64(header.blockSize(word)))
                if header.blockChecksum { try input.skip(4) }
            }
            if header.contentChecksum { try input.skip(4) }
        }
        return known ? total : nil
    }

    private static func charge(_ count: inout Int, limits: ReadLimits) throws {
        guard count < limits.maxMetadataRecordCount else {
            throw KaitoError.limitExceeded("LZ4 frame/block count")
        }
        count += 1
    }
}

private struct LZ4FrameHeader {
    let independent: Bool
    let blockChecksum: Bool
    let contentChecksum: Bool
    let contentSize: UInt64?
    let maximumBlockSize: Int

    init(input: LZ4FrameInput, limits: ReadLimits) throws {
        var descriptor = try input.read(2)
        let flags = descriptor[0], blockDescriptor = descriptor[1]
        guard flags >> 6 == 1, flags & 2 == 0, blockDescriptor & 0x8f == 0,
              (4...7).contains(blockDescriptor >> 4) else {
            throw KaitoError.malformed("LZ4 frame descriptor")
        }
        independent = flags & 32 != 0
        blockChecksum = flags & 16 != 0
        contentChecksum = flags & 4 != 0
        maximumBlockSize = 1 << (8 + 2 * Int(blockDescriptor >> 4))
        if flags & 8 != 0 {
            let bytes = try input.read(8)
            descriptor += bytes
            contentSize = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        } else { contentSize = nil }
        let dictionary: UInt64?
        if flags & 1 != 0 {
            let bytes = try input.read(4)
            descriptor += bytes
            dictionary = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        } else { dictionary = nil }
        let check = try input.integer(1)
        guard check == UInt64((XXH32.digest(descriptor) >> 8) & 255) else {
            throw KaitoError.checksumMismatch(entry: 0)
        }
        if let dictionary {
            throw KaitoError.unsupportedMethod("LZ4 external dictionary \(dictionary)")
        }
        let historySize = UInt64(LZ4FrameDecompressor.historySize)
        try Checked.size(min(historySize, contentSize ?? historySize), limit: limits.maxDictionarySize)
        if let contentSize {
            try Checked.size(contentSize, limit: limits.maxEntrySize)
        }
    }

    func blockSize(_ word: UInt64) throws -> Int {
        let count = word & 0x7fffffff  // the low 31 bits; the high bit is uncompressedBlockFlag
        guard count <= UInt64(maximumBlockSize) else { throw KaitoError.malformed("LZ4 block size") }
        return Int(count)
    }
}

private final class LZ4FrameInput {
    private let source: any ByteSource
    private let end: UInt64
    private var position: UInt64

    init(source: any ByteSource, offset: UInt64, size: UInt64) throws {
        end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        position = offset
    }

    var remaining: UInt64 { end - position }

    func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        let result = try readByteRange(source: source, offset: position, count: count)
        position += UInt64(count)
        return result
    }

    // Keep the encoded block allocation for the next block; honor short reads.
    func read(_ count: Int, into result: inout [UInt8]) throws {
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        if result.count > count { result.removeLast(result.count - count) }
        if result.count < count { result.append(contentsOf: repeatElement(0, count: count - result.count)) }
        var filled = 0
        try result.withUnsafeMutableBytes { bytes in
            while filled < count {
                let offset = try Checked.add(position, UInt64(filled))
                let actual = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<count]), at: offset)
                guard actual > 0, actual <= count - filled else { throw KaitoError.truncated }
                filled += actual
            }
        }
        position += UInt64(count)
    }

    func peekInteger(_ count: Int) throws -> UInt64 {
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        return try readByteRange(source: source, offset: position, count: count)
            .enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    func integer(_ count: Int) throws -> UInt64 {
        try read(count).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    func skip(_ count: UInt64) throws {
        guard count <= remaining else { throw KaitoError.truncated }
        position += count
    }
}
