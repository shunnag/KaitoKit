import Compression
import Foundation

// Implementation input: the public XZ container description and Apple's
// Compression framework streaming API. COMPRESSION_LZMA decodes XZ streams.

/// A streaming XZ decoder backed by Apple Compression.
final class XZDecompressor: Decompressor {
    private static let chunkSize = 256 * 1_024
    private static let signature: [UInt8] = [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
        dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
        src_size: 0,
        state: nil
    )
    private var streamWasInitialized = false
    private var finished = false

    init(source: any ByteSource, offset: UInt64 = 0, compressedSize: UInt64? = nil) throws {
        let size: UInt64
        if let compressedSize {
            size = compressedSize
        } else {
            size = try Checked.sub(source.length, offset)
        }
        let end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        self.compressedEnd = end
        self.sourceOffset = offset
        try initializeStream()
    }

    deinit {
        if streamWasInitialized {
            compression_stream_destroy(&stream)
        }
    }

    var isFinished: Bool { finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        let outputCapacity = min(buffer.count, Self.chunkSize)
        var totalProduced = 0

        while totalProduced < outputCapacity {
            if inputOffset == inputCount {
                try refillInput()
            }
            let availableInput = inputCount - inputOffset
            guard availableInput > 0 else { throw KaitoError.truncated }
            let availableOutput = outputCapacity - totalProduced
            let flags = sourceOffset == compressedEnd
                ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                : 0

            let status: compression_status = try input.withUnsafeMutableBytes { inputBytes in
                guard let inputBase = inputBytes.baseAddress,
                      let outputBase = buffer.baseAddress else {
                    throw KaitoError.malformed("XZ buffer has no storage")
                }
                stream.src_ptr = UnsafePointer(
                    inputBase
                        .assumingMemoryBound(to: UInt8.self)
                        .advanced(by: inputOffset)
                )
                stream.src_size = availableInput
                stream.dst_ptr = outputBase
                    .assumingMemoryBound(to: UInt8.self)
                    .advanced(by: totalProduced)
                stream.dst_size = availableOutput
                defer {
                    stream.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
                    stream.dst_ptr = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
                }
                return compression_stream_process(&stream, flags)
            }

            guard stream.src_size <= availableInput,
                  stream.dst_size <= availableOutput else {
                throw KaitoError.malformed("Compression returned invalid XZ buffer accounting")
            }
            let consumed = availableInput - stream.src_size
            let produced = availableOutput - stream.dst_size
            inputOffset += consumed
            totalProduced += produced

            switch status {
            case COMPRESSION_STATUS_END:
                let nextOffset = try currentCompressedOffset()
                if let nextStream = try nextStreamOffset(after: nextOffset) {
                    try restartStream(at: nextStream)
                    continue
                }
                finished = true
                return totalProduced

            case COMPRESSION_STATUS_OK:
                if totalProduced > 0 { return totalProduced }
                if consumed == 0 {
                    throw KaitoError.malformed("XZ stream made no progress")
                }

            case COMPRESSION_STATUS_ERROR:
                throw KaitoError.malformed("invalid XZ stream")

            default:
                throw KaitoError.malformed("Compression returned an unknown XZ status")
            }
        }
        return totalProduced
    }

    private func initializeStream() throws {
        let status = compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_LZMA
        )
        guard status != COMPRESSION_STATUS_ERROR else {
            throw KaitoError.malformed("Compression could not initialize XZ decoding")
        }
        streamWasInitialized = true
    }

    private func restartStream(at offset: UInt64) throws {
        if streamWasInitialized {
            compression_stream_destroy(&stream)
            streamWasInitialized = false
        }
        stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        sourceOffset = offset
        inputOffset = 0
        inputCount = 0
        try initializeStream()
    }

    private func currentCompressedOffset() throws -> UInt64 {
        try Checked.sub(sourceOffset, UInt64(inputCount - inputOffset))
    }

    /// Returns the next concatenated stream offset, or nil when only valid XZ
    /// stream padding remains. XZ padding is zero-filled and four-byte aligned.
    private func nextStreamOffset(after offset: UInt64) throws -> UInt64? {
        guard offset <= compressedEnd else {
            throw KaitoError.malformed("XZ decoder consumed beyond its source range")
        }
        var cursor = offset
        var paddingCount: UInt64 = 0
        while cursor < compressedEnd {
            let remaining = try Checked.sub(compressedEnd, cursor)
            let count = try Checked.toInt(min(UInt64(Self.chunkSize), remaining))
            let bytes = try readByteRange(source: source, offset: cursor, count: count)
            if let firstNonzero = bytes.firstIndex(where: { $0 != 0 }) {
                paddingCount = try Checked.add(paddingCount, UInt64(firstNonzero))
                cursor = try Checked.add(cursor, UInt64(firstNonzero))
                break
            }
            paddingCount = try Checked.add(paddingCount, UInt64(count))
            cursor = try Checked.add(cursor, UInt64(count))
        }
        guard paddingCount % 4 == 0 else {
            throw KaitoError.malformed("XZ stream padding is not four-byte aligned")
        }
        guard cursor < compressedEnd else { return nil }
        let remaining = try Checked.sub(compressedEnd, cursor)
        guard remaining >= UInt64(Self.signature.count),
              try readByteRange(
                source: source,
                offset: cursor,
                count: Self.signature.count
              ) == Self.signature else {
            throw KaitoError.malformed("XZ stream has trailing bytes")
        }
        return cursor
    }

    private func refillInput() throws {
        guard sourceOffset < compressedEnd else {
            inputOffset = 0
            inputCount = 0
            return
        }
        let remaining = try Checked.sub(compressedEnd, sourceOffset)
        let requested = try Checked.toInt(min(UInt64(Self.chunkSize), remaining))
        let count = try input.withUnsafeMutableBytes { storage in
            try source.read(
                into: UnsafeMutableRawBufferPointer(rebasing: storage[..<requested]),
                at: sourceOffset
            )
        }
        guard count > 0, count <= requested else { throw KaitoError.truncated }
        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        inputOffset = 0
        inputCount = count
    }
}
