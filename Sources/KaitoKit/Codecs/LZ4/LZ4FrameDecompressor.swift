import Dispatch
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
    // Internal allocation diagnostic for buffer-bound regression tests.
    var decodedCapacity: Int { decoded.capacity }
    private lazy var appleDecoder = LZ4AppleBlockDecoder()
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
                            if LZ4AppleBlockDecoder.isEligible(independent: header.independent,
                                                               blockChecksum: header.blockChecksum,
                                                               contentChecksum: header.contentChecksum) {
                                try appleDecoder.decode($0, into: decoded,
                                                        blockMaximum: header.maximumBlockSize, maximumSize: maximum)
                            } else {
                                try LZ4BlockDecoder.decode($0, into: decoded, maximumSize: maximum)
                            }
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
                    // Legacy has no checksum. A required token walk plus Apple
                    // regressed dense text in release measurements; retain Swift.
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

final class ParallelLZ4FrameDecompressor: Decompressor {
    private let decoder: ParallelIndependentDecompressor
    private let expectedChecksum: UInt32?
    private var checksum = XXH32()
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init?(units: [ParallelIndependentDecompressor.Unit], contentChecksum: UInt32?,
          limits: ReadLimits, workers: Int) {
        guard let decoder = ParallelIndependentDecompressor(
            units: units, limits: limits, workers: workers
        ) else { return nil }
        self.decoder = decoder
        expectedChecksum = contentChecksum
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            let count = try decoder.read(into: buffer)
            if count > 0 {
                if expectedChecksum != nil {
                    checksum.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                }
                return count
            }
            guard decoder.isFinished else {
                throw KaitoError.malformed("LZ4 parallel decoder made no progress")
            }
            // Match the serial reader: publish the final bytes first, then diagnose
            // a bad content checksum on the next nonempty read.
            if let expectedChecksum, checksum.value != expectedChecksum {
                throw KaitoError.checksumMismatch(entry: 0)
            }
            isFinished = true
            return 0
        } catch {
            terminalError = error
            throw error
        }
    }
}

final class LZ4FrameBlockBatch: Decompressor {
    private let units: [ParallelIndependentDecompressor.Unit]
    private var current: (any Decompressor)?
    private var index = 0
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init(units: [ParallelIndependentDecompressor.Unit]) {
        self.units = units
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while index < units.count {
                let decoder: any Decompressor
                if let current {
                    decoder = current
                } else {
                    decoder = try units[index].makeDecoder()
                    current = decoder
                }
                let count = try decoder.read(into: buffer)
                if count > 0 { return count }
                guard decoder.isFinished else {
                    throw KaitoError.malformed("LZ4 block batch made no progress")
                }
                current = nil
                index += 1
            }
            isFinished = true
            return 0
        } catch {
            terminalError = error
            throw error
        }
    }
}

private final class LZ4FrameBlockDecompressor: DirectIndependentDataDecoding {
    private let encoded: [UInt8]
    private let blockMaximum: Int
    private let maximumSize: Int
    private var decoded: LZ4BlockBuffer?
    private var offset = 0
    private var terminalError: (any Error)?

    init(encoded: [UInt8], blockMaximum: Int, maximumSize: Int) {
        self.encoded = encoded
        self.blockMaximum = blockMaximum
        self.maximumSize = maximumSize
    }

    var isFinished: Bool { decoded.map { offset == $0.outputCount } ?? false }

    private func decodeBuffer() throws -> LZ4BlockBuffer {
        if let decoded { return decoded }
        let output = LZ4BlockBuffer()
        try encoded.withUnsafeBytes { bytes in
            try LZ4AppleBlockDecoder().decodeValidated(
                bytes, into: output, blockMaximum: blockMaximum,
                maximumSize: maximumSize, expected: maximumSize
            )
        }
        decoded = output
        return output
    }

    func decodeDirect() throws -> Data {
        if let terminalError { throw terminalError }
        do {
            return try decodeBuffer().takeOutput()
        } catch {
            terminalError = error
            throw error
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            let decoded = try decodeBuffer()
            let count = min(buffer.count, decoded.outputCount - offset)
            decoded.withOutputBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)]))
            }
            offset += count
            return count
        } catch {
            terminalError = error
            throw error
        }
    }
}

private struct LZ4ParallelFramePlan {
    let units: [ParallelIndependentDecompressor.Unit]
    let contentChecksum: UInt32?
}

extension LZ4FrameDecompressor {
    static func parallel(source: any ByteSource, limits: ReadLimits, workers: Int) throws -> any Decompressor {
        if workers > 1, let plan = try? parallelPlan(source: source, limits: limits, workers: workers),
           let decoder = ParallelLZ4FrameDecompressor(
               units: plan.units, contentChecksum: plan.contentChecksum, limits: limits, workers: workers
           ) {
            return decoder
        }
        // A failed speculative scan must not move framing, grammar, or checksum
        // failures ahead of the partial output produced by the original reader.
        return try LZ4FrameDecompressor(source: source, limits: limits)
    }

    private struct PendingBlock {
        let encoded: [UInt8]
        let stored: Bool
    }

    // 各 lane は別々の block と結果欄だけを書き換える。
    private struct SizeWork: @unchecked Sendable {
        let blocks: [PendingBlock]
        let maximumSize: Int
        let results: UnsafeMutablePointer<Result<Int, any Error>?>

        func run(lane: Int, lanes: Int) {
            let quotient = blocks.count / lanes
            let remainder = blocks.count % lanes
            let start = lane * quotient + min(lane, remainder)
            let end = start + quotient + (lane < remainder ? 1 : 0)
            for index in start..<end {
                let block = blocks[index]
                if block.stored {
                    results[index] = .success(block.encoded.count)
                } else {
                    results[index] = Result {
                        try block.encoded.withUnsafeBytes {
                            try LZ4AppleBlockDecoder.validatedSize($0, maximumSize: maximumSize, complete: true)
                        }
                    }
                }
            }
        }
    }

    private static func parallelPlan(source: any ByteSource, limits: ReadLimits, workers: Int) throws -> LZ4ParallelFramePlan? {
        let encodedBudget = min(UInt64(256 * 1_024 * 1_024), UInt64(limits.resolvedParallelDecodeMemory() / 2))
        guard source.length <= encodedBudget else { return nil }
        let input = try LZ4FrameInput(source: source, offset: 0, size: source.length)
        guard try input.integer(4) == magic else { return nil }
        let header = try LZ4FrameHeader(input: input, limits: limits)
        guard header.independent else { return nil }
        let outputLimit = header.contentSize ?? limits.maxEntrySize
        var blocks: [PendingBlock] = []
        var blockCount = 0
        while true {
            try Task.checkCancellation()
            let word = try input.integer(4)
            if word == 0 { break }
            try charge(&blockCount, limits: limits)
            let count = try header.blockSize(word)
            let encoded = try input.read(count)
            if header.blockChecksum {
                guard try input.integer(4) == UInt64(XXH32.digest(encoded)) else {
                    throw KaitoError.checksumMismatch(entry: 0)
                }
            }
            blocks.append(PendingBlock(encoded: encoded, stored: word & uncompressedBlockFlag != 0))
        }
        let contentChecksum = header.contentChecksum
            ? UInt32(truncatingIfNeeded: try input.integer(4)) : nil
        guard blocks.count >= 2, input.remaining == 0 else { return nil }

        let maximum = Int(min(UInt64(header.maximumBlockSize), outputLimit))
        let results = UnsafeMutablePointer<Result<Int, any Error>?>.allocate(capacity: blocks.count)
        results.initialize(repeating: nil, count: blocks.count)
        defer { results.deinitialize(count: blocks.count); results.deallocate() }
        let lanes = min(workers, blocks.count)
        let work = SizeWork(blocks: blocks, maximumSize: maximum, results: results)
        DispatchQueue.concurrentPerform(iterations: lanes) { work.run(lane: $0, lanes: lanes) }

        var units: [ParallelIndependentDecompressor.Unit] = []
        units.reserveCapacity(blocks.count)
        var total: UInt64 = 0
        for (index, block) in blocks.enumerated() {
            let outputSize = try results[index]!.get()
            total = try Checked.add(total, UInt64(outputSize))
            guard total <= outputLimit else {
                throw KaitoError.malformed("LZ4 frame output exceeds content size")
            }
            let scratch = try Checked.add(UInt64(block.encoded.count), UInt64(outputSize))
            if block.stored {
                let data = Data(block.encoded)
                units.append(try .init(outputSize: UInt64(outputSize), scratchBytes: scratch) {
                    try CopyDecompressor(source: DataByteSource(data), offset: 0, compressedSize: UInt64(data.count))
                })
            } else {
                // 文法と展開後サイズを検証済みなので、checksum がなくても Apple を使う。
                units.append(try .init(outputSize: UInt64(outputSize), scratchBytes: scratch) {
                    LZ4FrameBlockDecompressor(
                        encoded: block.encoded, blockMaximum: header.maximumBlockSize,
                        maximumSize: outputSize
                    )
                })
            }
        }
        guard header.contentSize == nil || header.contentSize == total else { return nil }
        return LZ4ParallelFramePlan(units: try batchedUnits(units), contentChecksum: contentChecksum)
    }

    private static func batchedUnits(_ units: [ParallelIndependentDecompressor.Unit]) throws
        -> [ParallelIndependentDecompressor.Unit] {
        let target: UInt64 = 256 * 1_024
        var result: [ParallelIndependentDecompressor.Unit] = []
        var batch: [ParallelIndependentDecompressor.Unit] = []
        var output: UInt64 = 0
        var held: UInt64 = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            let scratch = try Checked.sub(held, output)
            let captured = batch
            result.append(try .init(outputSize: output, scratchBytes: scratch) {
                LZ4FrameBlockBatch(units: captured)
            })
            batch.removeAll(keepingCapacity: true)
            output = 0
            held = 0
        }
        for unit in units {
            batch.append(unit)
            output = try Checked.add(output, UInt64(unit.outputSize))
            held = try Checked.add(held, UInt64(unit.heldBytes))
            if output >= target { try flush() }
        }
        try flush()
        return result.count >= 2 ? result : units
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
