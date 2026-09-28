import Foundation
private import zlib

// Z_BLOCK の消費位置で digest を区切る。先読みした入力は数えない。
final class TarSpliceGzipDecoder: Decompressor {
    typealias Observer = (UnsafeRawBufferPointer, UnsafeRawBufferPointer, UInt64, Bool, Bool) throws -> Void
    private let source: any ByteSource
    private let end: UInt64
    private let final: Bool
    private let observer: Observer
    private var stream = z_stream()
    private var initialized = false
    private var input = [UInt8](repeating: 0, count: 262_144)
    private var inputCount = 0
    private var inputOffset = 0
    private var cursor: UInt64
    private var produced: UInt64 = 0
    private var previousStopOutput: UInt64 = 0
    private var emptyStops = 0
    private(set) var isFinished = false

    init(source: any ByteSource, range: Range<UInt64>, dictionary: Data, final: Bool,
         observer: @escaping Observer) throws {
        self.source = source; end = range.upperBound; cursor = range.lowerBound
        self.final = final; self.observer = observer
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw KaitoError.malformed("zlib could not initialize raw gzip decoding")
        }
        initialized = true
        if !dictionary.isEmpty {
            let status = dictionary.withUnsafeBytes {
                inflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
            }
            guard status == Z_OK else { throw KaitoError.malformed("invalid gzip splice dictionary") }
        }
    }

    deinit { if initialized { inflateEnd(&stream) } }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !isFinished, !buffer.isEmpty else { return 0 }
        while true {
            if inputOffset == inputCount, cursor < end {
                let requested = Int(min(UInt64(input.count), end - cursor))
                inputCount = try input.withUnsafeMutableBytes {
                    try source.read(into: .init(rebasing: $0[..<requested]), at: cursor)
                }
                guard inputCount > 0, inputCount <= requested else { throw KaitoError.truncated }
                cursor += UInt64(inputCount); inputOffset = 0
            }
            let available = inputCount - inputOffset
            let capacity = min(buffer.count, 262_144)
            let status = input.withUnsafeMutableBytes { bytes in
                stream.next_in = bytes.bindMemory(to: Bytef.self).baseAddress!.advanced(by: inputOffset)
                stream.avail_in = uInt(available)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(capacity)
                defer { stream.next_in = nil; stream.next_out = nil }
                return inflate(&stream, Z_BLOCK)
            }
            guard stream.avail_in <= available, stream.avail_out <= capacity else {
                throw KaitoError.malformed("invalid raw gzip buffer accounting")
            }
            let consumed = available - Int(stream.avail_in), count = capacity - Int(stream.avail_out)
            produced += UInt64(count)
            let offset = cursor - UInt64(available) + UInt64(consumed)
            let stopped = stream.data_type & 128 != 0
            let empty = stopped && stream.data_type & 64 == 0 && stream.data_type & 7 == 0
                && produced == previousStopOutput
            try input.withUnsafeBytes { bytes in
                try observer(.init(rebasing: bytes[inputOffset..<(inputOffset + consumed)]),
                             .init(rebasing: buffer[..<count]), offset, stopped, empty)
            }
            inputOffset += consumed
            if stopped { previousStopOutput = produced }
            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                let message = stream.msg.map { String(cString: $0) } ?? "zlib status \(status)"
                throw KaitoError.malformed("invalid raw gzip stream (\(message))")
            }
            if status == Z_STREAM_END {
                guard final, offset == end else { throw KaitoError.malformed("gzip splice final block position") }
                isFinished = true
                return count
            }
            if offset == end, empty {
                guard !final else { throw KaitoError.truncated }
                isFinished = true
                return count
            }
            if consumed == 0, count == 0 {
                emptyStops += 1
                guard stopped, emptyStops <= 64 else { throw KaitoError.malformed("raw gzip stream made no progress") }
            } else { emptyStops = 0 }
            if count > 0 { return count }
        }
    }
}
