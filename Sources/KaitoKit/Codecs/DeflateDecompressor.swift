import Foundation
private import zlib

// 参照仕様: RFC 1951、および zlib 公式マニュアルの inflate API。

/// A streaming RFC 1951 raw-DEFLATE decompressor backed by system zlib.
public final class DeflateDecompressor: Decompressor {
    private static let chunkSize = 256 * 1024

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0
    private var stream = z_stream()
    private var streamWasInitialized = false
    private var finished = false

    /// Creates a raw-DEFLATE stream over a validated byte-source range.
    public init(source: any ByteSource, offset: UInt64, compressedSize: UInt64) throws {
        let compressedEnd = try Checked.add(offset, compressedSize)
        guard compressedEnd <= source.length else {
            throw KaitoError.truncated
        }

        self.source = source
        self.sourceOffset = offset
        self.compressedEnd = compressedEnd

        let status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw KaitoError.malformed("zlib initialization failed (\(status))")
        }
        streamWasInitialized = true
    }

    deinit {
        if streamWasInitialized {
            _ = inflateEnd(&stream)
        }
    }

    /// Indicates whether zlib reached the DEFLATE end marker.
    public var isFinished: Bool {
        finished
    }

    /// Inflates up to one 256 KiB output chunk into `buffer`.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else {
            return 0
        }

        // zlib の uInt 幅と作業単位の双方を満たす固定上限。
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
                    throw KaitoError.malformed("DEFLATE buffer has no storage")
                }

                // inputOffset/inputCount は input.count 以下、totalProduced/outputCapacity は
                // buffer.count 以下であるため、この C API 呼び出し中のポインタ範囲は有効。
                stream.next_in = inputBase
                    .assumingMemoryBound(to: Bytef.self)
                    .advanced(by: inputOffset)
                stream.avail_in = uInt(availableInput)
                stream.next_out = outputBase
                    .assumingMemoryBound(to: Bytef.self)
                    .advanced(by: totalProduced)
                stream.avail_out = uInt(availableOutput)
                // C 構造体に一時バッファの寿命を越えるポインタを残さない。
                defer {
                    stream.next_in = nil
                    stream.next_out = nil
                }
                return inflate(&stream, Z_NO_FLUSH)
            }

            let remainingInput = Int(stream.avail_in)
            let remainingOutput = Int(stream.avail_out)
            guard remainingInput <= availableInput, remainingOutput <= availableOutput else {
                throw KaitoError.malformed("zlib returned invalid buffer accounting")
            }

            let consumed = availableInput - remainingInput
            let produced = availableOutput - remainingOutput
            inputOffset += consumed
            totalProduced += produced

            if status == Z_STREAM_END {
                finished = true
                return totalProduced
            }
            guard status == Z_OK || status == Z_BUF_ERROR else {
                throw KaitoError.malformed("invalid raw DEFLATE stream (zlib \(status))")
            }

            if totalProduced > 0 {
                return totalProduced
            }
            if consumed == 0 {
                throw KaitoError.malformed("raw DEFLATE stream made no progress")
            }
        }

        return totalProduced
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
