import Foundation
private import zlib

// Implementation input: RFC 1952 and the public zlib streaming API.

struct GzipHeader {
    let originalName: [UInt8]?
    let modificationDate: Date?
}

enum GzipHeaderParser {
    private struct Cursor {
        var reader: ByteReader
        var captured: [UInt8] = []
        let metadataLimit: UInt64

        mutating func readCapturedByte() throws -> UInt8 {
            let nextCount = try Checked.add(UInt64(captured.count), 1)
            try Checked.size(nextCount, limit: metadataLimit)
            let byte = try reader.readUInt8()
            captured.append(byte)
            return byte
        }

        mutating func readCapturedUInt16LE() throws -> UInt16 {
            let low = UInt16(try readCapturedByte())
            let high = UInt16(try readCapturedByte())
            return low | (high << 8)
        }

        mutating func readCapturedUInt32LE() throws -> UInt32 {
            var value: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) {
                value |= UInt32(try readCapturedByte()) << shift
            }
            return value
        }

        mutating func readCapturedBytes(_ count: Int) throws {
            guard count >= 0 else {
                throw KaitoError.malformed("negative gzip metadata length")
            }
            for _ in 0..<count {
                _ = try readCapturedByte()
            }
        }

        mutating func readZeroTerminatedValue() throws -> [UInt8] {
            var value: [UInt8] = []
            while true {
                let byte = try readCapturedByte()
                if byte == 0 { return value }
                value.append(byte)
            }
        }
    }

    static func parseFirstHeader(
        source: any ByteSource,
        limits: ReadLimits
    ) throws -> GzipHeader {
        var cursor = Cursor(
            reader: try ByteReader(source: source),
            metadataLimit: limits.maxMetadataSize
        )
        guard try cursor.readCapturedByte() == 0x1f,
              try cursor.readCapturedByte() == 0x8b else {
            throw KaitoError.unsupportedFormat
        }
        guard try cursor.readCapturedByte() == 8 else {
            throw KaitoError.unsupportedMethod("gzip compression method")
        }

        let flags = try cursor.readCapturedByte()
        guard flags & 0xe0 == 0 else {
            throw KaitoError.malformed("gzip header uses reserved flags")
        }
        let modificationTime = try cursor.readCapturedUInt32LE()
        _ = try cursor.readCapturedByte() // Extra flags.
        _ = try cursor.readCapturedByte() // Originating system.

        if flags & 0x04 != 0 {
            let extraLength = Int(try cursor.readCapturedUInt16LE())
            try cursor.readCapturedBytes(extraLength)
        }

        let originalName: [UInt8]?
        if flags & 0x08 != 0 {
            let bytes = try cursor.readZeroTerminatedValue()
            originalName = bytes.isEmpty ? nil : bytes
        } else {
            originalName = nil
        }

        if flags & 0x10 != 0 {
            _ = try cursor.readZeroTerminatedValue()
        }

        if flags & 0x02 != 0 {
            let nextCount = try Checked.add(UInt64(cursor.captured.count), 2)
            try Checked.size(nextCount, limit: limits.maxMetadataSize)
            let expected = try cursor.reader.readUInt16LE()
            let actual = UInt16(truncatingIfNeeded: CRC32.checksum(cursor.captured))
            guard actual == expected else {
                throw KaitoError.malformed("gzip header checksum does not match")
            }
        }

        let date = modificationTime == 0
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(modificationTime))
        return GzipHeader(originalName: originalName, modificationDate: date)
    }
}

/// A streaming RFC 1952 decoder that accepts concatenated gzip members.
final class GzipDecompressor: Decompressor {
    private static let chunkSize = 256 * 1_024
    private static let signature: [UInt8] = [0x1f, 0x8b]

    private let source: any ByteSource
    private let compressedEnd: UInt64
    private var sourceOffset: UInt64
    private var input = [UInt8](repeating: 0, count: chunkSize)
    private var inputOffset = 0
    private var inputCount = 0
    private var stream = z_stream()
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

        let status = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
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

            let status: Int32 = try input.withUnsafeMutableBytes { inputBytes in
                guard let inputBase = inputBytes.baseAddress,
                      let outputBase = buffer.baseAddress else {
                    throw KaitoError.malformed("gzip buffer has no storage")
                }
                stream.next_in = inputBase
                    .assumingMemoryBound(to: Bytef.self)
                    .advanced(by: inputOffset)
                stream.avail_in = uInt(availableInput)
                stream.next_out = outputBase
                    .assumingMemoryBound(to: Bytef.self)
                    .advanced(by: totalProduced)
                stream.avail_out = uInt(availableOutput)
                defer {
                    stream.next_in = nil
                    stream.next_out = nil
                }
                return inflate(&stream, Z_NO_FLUSH)
            }

            let remainingInput = Int(stream.avail_in)
            let remainingOutput = Int(stream.avail_out)
            guard remainingInput <= availableInput,
                  remainingOutput <= availableOutput else {
                throw KaitoError.malformed("zlib returned invalid gzip buffer accounting")
            }
            let consumed = availableInput - remainingInput
            let produced = availableOutput - remainingOutput
            inputOffset += consumed
            totalProduced += produced

            if status == Z_STREAM_END {
                let nextOffset = try currentCompressedOffset()
                if nextOffset == compressedEnd {
                    finished = true
                    return totalProduced
                }
                guard try hasMemberSignature(at: nextOffset) else {
                    throw KaitoError.malformed("gzip stream has trailing bytes")
                }
                let resetStatus = inflateReset2(&stream, MAX_WBITS + 16)
                guard resetStatus == Z_OK else {
                    throw KaitoError.malformed("zlib gzip reset failed (\(resetStatus))")
                }
                continue
            }

            guard status == Z_OK || status == Z_BUF_ERROR else {
                throw gzipError(status)
            }
            if totalProduced > 0 { return totalProduced }
            if consumed == 0 {
                throw KaitoError.malformed("gzip stream made no progress")
            }
        }
        return totalProduced
    }

    private func currentCompressedOffset() throws -> UInt64 {
        try Checked.sub(sourceOffset, UInt64(inputCount - inputOffset))
    }

    private func hasMemberSignature(at offset: UInt64) throws -> Bool {
        let remaining = try Checked.sub(compressedEnd, offset)
        guard remaining >= UInt64(Self.signature.count) else { return false }
        return try readByteRange(
            source: source,
            offset: offset,
            count: Self.signature.count
        ) == Self.signature
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

    private func gzipError(_ status: Int32) -> KaitoError {
        if status == Z_DATA_ERROR, let message = stream.msg {
            let text = String(cString: message)
            if text.contains("incorrect data check") ||
                text.contains("incorrect length check") ||
                text.contains("header crc mismatch") {
                return .checksumMismatch(entry: 0)
            }
            return .malformed("invalid gzip stream (\(text))")
        }
        return .malformed("invalid gzip stream (zlib \(status))")
    }
}
