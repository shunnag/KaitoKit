// Zstd の内部型に対するテスト専用の配列 API。本番の復号は frame 所有の scratch と
// read(_:into:) / decode(...into:) だけを使い、ここにある入口は呼ばない。
@testable import KaitoKit

extension ZstdScratchBuffer {
    /// 配列を frame と同じ前 8 / 後 32 byte の余白付き scratch に写し、有効範囲の view を body の間だけ渡す。
    /// 前余白は ZstdPaddedBitReader の word load（D5）に、後余白は literal の 16 byte copy（D2）に必要。
    static func withPaddedCopy<Result>(
        of bytes: [UInt8], _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        let storage = ZstdScratchBuffer()
        storage.reserve(bytes.count, maximum: bytes.count)
        bytes.withUnsafeBytes { source in
            if !source.isEmpty { storage.base.copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        storage.pad(after: bytes.count)
        return try withExtendedLifetime(storage) {
            try body(UnsafeRawBufferPointer(start: storage.base, count: bytes.count))
        }
    }
}

extension ZstdByteReader {
    /// `ZstdScratchBuffer.withPaddedCopy(of:_:)` の view を先頭から読む reader として渡す。
    static func withPaddedCopy<Result>(
        of bytes: [UInt8], _ body: (inout ZstdByteReader) throws -> Result
    ) rethrows -> Result {
        try ZstdScratchBuffer.withPaddedCopy(of: bytes) { padded in
            var reader = ZstdByteReader(padded)
            return try body(&reader)
        }
    }
}

extension ZstdHuffman {
    static func read(from reader: inout ZstdByteReader) throws -> ZstdHuffman {
        let result = ZstdHuffman()
        try result.readTable(from: &reader)
        return result
    }

    func decode(from reader: inout ZstdByteReader, count: Int, fourStreams: Bool,
                tuning: ZstdTuning = .default) throws -> [UInt8] {
        var result = try [UInt8](unsafeUninitializedCapacity: count + ZstdScratchBuffer.backPad) { output, initialized in
            try decode(from: &reader, count: count, fourStreams: fourStreams, tuning: tuning, into: output)
            initialized = count + ZstdScratchBuffer.backPad
        }
        result.removeLast(ZstdScratchBuffer.backPad)
        return result
    }
}

extension ZstdInput {
    /// 本番の read(_:into:) を通して count バイトを配列で返す。先読みと直接読みの切替えも本番と同じ。
    func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        guard count > 0 else { return [] }
        return try [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            try read(count, into: UnsafeMutableRawPointer(buffer.baseAddress!))
            initialized = count
        }
    }
}
