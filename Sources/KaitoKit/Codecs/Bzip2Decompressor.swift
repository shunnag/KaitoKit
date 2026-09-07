private import CBzip2
import Foundation

// 参照仕様: bzip2 公式マニュアルの high-level streaming API。

/// A streaming bzip2 decompressor backed by the system libbz2.
public final class Bzip2Decompressor: Decompressor {
    private static let chunkSize = 256 * 1024

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private let acceptsConcatenatedStreams: Bool
    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0
    private var stream = bz_stream()
    private var streamWasInitialized = false
    private var finished = false

    /// Creates a bzip2 stream over a validated byte-source range.
    public init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        concatenatedStreams: Bool = false
    ) throws {
        let compressedEnd = try Checked.add(offset, compressedSize)
        guard compressedEnd <= source.length else {
            throw KaitoError.truncated
        }

        self.source = source
        self.sourceOffset = offset
        self.compressedEnd = compressedEnd
        self.acceptsConcatenatedStreams = concatenatedStreams

        let status = BZ2_bzDecompressInit(&stream, 0, 0)
        guard status == BZ_OK else {
            throw KaitoError.malformed("libbz2 initialization failed (\(status))")
        }
        streamWasInitialized = true
    }

    deinit {
        if streamWasInitialized {
            _ = BZ2_bzDecompressEnd(&stream)
        }
    }

    /// Indicates whether libbz2 reached the compressed stream end marker.
    public var isFinished: Bool {
        finished
    }

    /// Decompresses up to one 256 KiB output chunk into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else {
            return 0
        }

        // libbz2 の unsigned int 幅と作業単位の双方を満たす固定上限。
        let outputCapacity = min(buffer.count, Self.chunkSize)
        var totalProduced = 0

        while totalProduced < outputCapacity {
            if inputOffset == inputCount {
                try refillInput()
            }

            let availableInput = inputCount - inputOffset
            guard availableInput > 0 else {
                throw KaitoError.truncated
            }

            let availableOutput = outputCapacity - totalProduced
            let status: Int32 = try input.withUnsafeMutableBytes { inputBytes in
                guard let inputBase = inputBytes.baseAddress,
                      let outputBase = buffer.baseAddress else {
                    throw KaitoError.malformed("bzip2 buffer has no storage")
                }

                // inputOffset/inputCount は input.count 以下、totalProduced/outputCapacity は
                // buffer.count 以下であるため、この C API 呼び出し中のポインタ範囲は有効。
                stream.next_in = inputBase
                    .assumingMemoryBound(to: CChar.self)
                    .advanced(by: inputOffset)
                stream.avail_in = UInt32(availableInput)
                stream.next_out = outputBase
                    .assumingMemoryBound(to: CChar.self)
                    .advanced(by: totalProduced)
                stream.avail_out = UInt32(availableOutput)
                // C 構造体に一時バッファの寿命を越えるポインタを残さない。
                defer {
                    stream.next_in = nil
                    stream.next_out = nil
                }
                return BZ2_bzDecompress(&stream)
            }

            let remainingInput = Int(stream.avail_in)
            let remainingOutput = Int(stream.avail_out)
            guard remainingInput <= availableInput, remainingOutput <= availableOutput else {
                throw KaitoError.malformed("libbz2 returned invalid buffer accounting")
            }

            let consumed = availableInput - remainingInput
            let produced = availableOutput - remainingOutput
            inputOffset += consumed
            totalProduced += produced

            if status == BZ_STREAM_END {
                guard acceptsConcatenatedStreams else {
                    finished = true
                    return totalProduced
                }
                let nextOffset = try currentCompressedOffset()
                if nextOffset == compressedEnd {
                    finished = true
                    return totalProduced
                }
                guard try hasStreamHeader(at: nextOffset) else {
                    throw KaitoError.malformed("bzip2 stream has trailing bytes")
                }
                try restartStream()
                continue
            }
            guard status == BZ_OK else {
                throw KaitoError.malformed("invalid bzip2 stream (libbz2 \(status))")
            }

            if totalProduced > 0 {
                return totalProduced
            }
            if consumed == 0 {
                throw KaitoError.malformed("bzip2 stream made no progress")
            }
        }

        return totalProduced
    }

    private func currentCompressedOffset() throws -> UInt64 {
        try Checked.sub(sourceOffset, UInt64(inputCount - inputOffset))
    }

    private func hasStreamHeader(at offset: UInt64) throws -> Bool {
        let remaining = try Checked.sub(compressedEnd, offset)
        guard remaining >= 4 else { return false }
        let header = try readByteRange(source: source, offset: offset, count: 4)
        return header[0] == 0x42 && header[1] == 0x5a && header[2] == 0x68
            && (0x31...0x39).contains(header[3])
    }

    private func restartStream() throws {
        guard streamWasInitialized else {
            throw KaitoError.malformed("bzip2 stream is not initialized")
        }
        let endStatus = BZ2_bzDecompressEnd(&stream)
        streamWasInitialized = false
        guard endStatus == BZ_OK else {
            throw KaitoError.malformed("libbz2 finalization failed (\(endStatus))")
        }
        stream = bz_stream()
        let initStatus = BZ2_bzDecompressInit(&stream, 0, 0)
        guard initStatus == BZ_OK else {
            throw KaitoError.malformed("libbz2 initialization failed (\(initStatus))")
        }
        streamWasInitialized = true
    }

    private func refillInput() throws {
        guard sourceOffset < compressedEnd else {
            inputOffset = 0
            inputCount = 0
            return
        }

        let remaining = try Checked.sub(compressedEnd, sourceOffset)
        let requested = try Checked.toInt(min(UInt64(Self.chunkSize), remaining))
        let count = try input.withUnsafeMutableBytes { bytes -> Int in
            // requested <= input.count なので、ByteSource が書き込める範囲だけを公開する。
            let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[..<requested])
            return try source.read(into: destination, at: sourceOffset)
        }
        guard count >= 0, count <= requested else {
            throw KaitoError.malformed("ByteSource returned an invalid byte count")
        }
        guard count != 0 else {
            throw KaitoError.truncated
        }

        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        inputOffset = 0
        inputCount = count
    }
}
