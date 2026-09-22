import Foundation
import Compression
private import zlib

/// com.apple.decmpfs。形式の出自と黒箱観察は 2026-09-22-hfsplus-decmpfs.md。
struct DecmpfsHeader {
    let compressionType: UInt32
    let uncompressedSize: UInt64

    init(attribute: [UInt8]) throws {
        guard attribute.count >= 16 else { throw KaitoError.malformed("hfs+ decmpfs header length") }
        guard attribute.prefix(4).elementsEqual([0x66, 0x70, 0x6D, 0x63]) else {
            throw KaitoError.malformed("hfs+ decmpfs magic")
        }
        compressionType = Self.u32(attribute, 4)
        uncompressedSize = UInt64(Self.u32(attribute, 8)) | UInt64(Self.u32(attribute, 12)) << 32
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    var usesResourceFork: Bool { [4, 8, 10, 12].contains(compressionType) }
    var isSupported: Bool { [1, 3, 4, 7, 8, 9, 10, 11, 12].contains(compressionType) }
    var methodDescription: String {
        let method: String
        switch compressionType {
        case 1, 9, 10: method = "stored"
        case 3, 4: method = "zlib"
        case 7, 8: method = "LZVN"
        case 11, 12: method = "LZFSE"
        default: method = "type \(compressionType)"
        }
        return "HFS+ decmpfs (\(method))"
    }
}

/// resource fork は 64 KiB ごとに読む。保持する本文は展開済み 1 chunk と圧縮 1 chunk だけ。
final class DecmpfsDecompressor: Decompressor {
    struct ResourceFork {
        let length: UInt64
        let read: (UInt64, Int) throws -> [UInt8]
    }

    private enum Layout {
        case inline
        case offsets
        case zlib(base: UInt64, tableEnd: UInt64, dataEnd: UInt64)
    }

    private static let chunkSize: UInt64 = 65_536
    private static let packedLimit: UInt64 = 65_536 + 4_096
    private let header: DecmpfsHeader
    private let limits: ReadLimits
    private let resourceFork: ResourceFork?
    private let layout: Layout
    private let chunkCount: UInt64
    private var inlinePayload: [UInt8]
    private var chunkIndex: UInt64 = 0
    private var decoded: [UInt8] = []
    private var decodedOffset = 0
    private var terminalError: Error?

    init(header: DecmpfsHeader, inlinePayload: [UInt8] = [], resourceFork: ResourceFork? = nil, limits: ReadLimits) throws {
        guard header.isSupported else {
            throw KaitoError.unsupportedMethod("HFS+ decmpfs (type \(header.compressionType))")
        }
        try Checked.size(header.uncompressedSize, limit: limits.maxEntrySize)
        guard UInt64(inlinePayload.count) <= Self.packedLimit else { throw KaitoError.malformed("hfs+ decmpfs payload size") }
        try Checked.size(UInt64(inlinePayload.count), limit: limits.maxInMemorySize)
        self.header = header
        self.limits = limits
        self.resourceFork = resourceFork
        self.inlinePayload = header.usesResourceFork ? [] : inlinePayload
        if !header.usesResourceFork {
            layout = .inline
            chunkCount = header.uncompressedSize == 0 ? 0 : 1
            if header.compressionType == 9 {
                guard inlinePayload.first == 0xCC, UInt64(inlinePayload.count - 1) == header.uncompressedSize else {
                    throw KaitoError.malformed("hfs+ decmpfs stored inline marker or size")
                }
            } else if header.compressionType == 1 || header.uncompressedSize == 0 {
                guard UInt64(inlinePayload.count) == header.uncompressedSize else {
                    throw KaitoError.malformed("hfs+ decmpfs inline size")
                }
            }
            return
        }

        chunkCount = header.uncompressedSize / Self.chunkSize + (header.uncompressedSize % Self.chunkSize == 0 ? 0 : 1)
        // 空 file は fork 自体が無くてもよい。表がある場合は count = 0 も検証する。
        if chunkCount == 0, resourceFork?.length ?? 0 == 0 { layout = .offsets; return }
        guard let fork = resourceFork else { throw KaitoError.malformed("hfs+ decmpfs missing resource fork") }
        if header.compressionType == 4 {
            let envelope = try Self.read(fork, offset: 0, count: 16, limits: limits, metadata: true)
            let dataOffset = UInt64(HFSBytes.u32(envelope, 0)), mapOffset = UInt64(HFSBytes.u32(envelope, 4))
            let dataLength = UInt64(HFSBytes.u32(envelope, 8)), mapLength = UInt64(HFSBytes.u32(envelope, 12))
            let dataEnd = try Checked.add(dataOffset, dataLength)
            guard dataOffset >= 16, dataLength >= 8, dataEnd <= fork.length,
                  try Checked.add(mapOffset, mapLength) <= fork.length else {
                throw KaitoError.malformed("hfs+ decmpfs resource envelope")
            }
            let prefix = try Self.read(fork, offset: dataOffset, count: 8, limits: limits, metadata: true)
            guard UInt64(HFSBytes.u32(prefix, 0)) == dataLength - 4,
                  UInt64(DecmpfsHeader.u32(prefix, 4)) == chunkCount else {
                throw KaitoError.malformed("hfs+ decmpfs resource chunk count or length")
            }
            let tableSize = try Checked.add(4, Checked.mul(chunkCount, 8))
            try Checked.size(tableSize, limit: limits.maxMetadataSize)
            let base = try Checked.add(dataOffset, 4)
            let tableEnd = try Checked.add(base, tableSize)
            guard tableEnd <= dataEnd else { throw KaitoError.malformed("hfs+ decmpfs descriptor table") }
            layout = .zlib(base: base, tableEnd: tableEnd, dataEnd: dataEnd)
        } else {
            let first = try Self.read(fork, offset: 0, count: 4, limits: limits, metadata: true)
            let tableSize = UInt64(DecmpfsHeader.u32(first, 0))
            guard tableSize >= 4, tableSize % 4 == 0, tableSize / 4 - 1 == chunkCount, tableSize <= fork.length else {
                throw KaitoError.malformed("hfs+ decmpfs offset table chunk count")
            }
            try Checked.size(tableSize, limit: limits.maxMetadataSize)
            layout = .offsets
        }
    }

    var isFinished: Bool { terminalError == nil && chunkIndex == chunkCount && decodedOffset == decoded.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            if decodedOffset == decoded.count {
                // 次の展開前に前 chunk の storage を離す。
                decoded = []
                decodedOffset = 0
                var packed = try packedChunk()
                let rawSize = header.usesResourceFork
                    ? min(Self.chunkSize, try Checked.sub(header.uncompressedSize, Checked.mul(chunkIndex, Self.chunkSize)))
                    : header.uncompressedSize
                try Checked.size(rawSize, limit: limits.maxInMemorySize)
                try Checked.size(rawSize, limit: UInt64(UInt32.max))
                decoded = try decode(&packed, expected: Checked.toInt(rawSize))
                chunkIndex += 1
            }
            let count = min(buffer.count, decoded.count - decodedOffset)
            decoded.withUnsafeBytes { bytes in
                buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: decodedOffset), byteCount: count)
            }
            decodedOffset += count
            return count
        } catch {
            terminalError = error
            throw error
        }
    }

    private static func read(_ fork: ResourceFork, offset: UInt64, count: Int, limits: ReadLimits, metadata: Bool = false) throws -> [UInt8] {
        guard count >= 0, try Checked.add(offset, UInt64(count)) <= fork.length else {
            throw KaitoError.malformed("hfs+ decmpfs resource range")
        }
        try Checked.size(UInt64(count), limit: limits.maxInMemorySize)
        if metadata { try Checked.size(UInt64(count), limit: limits.maxMetadataSize) }
        let bytes = try fork.read(offset, count)
        guard bytes.count == count else { throw KaitoError.malformed("hfs+ decmpfs short resource read") }
        return bytes
    }

    private func packedChunk() throws -> [UInt8] {
        if case .inline = layout {
            let bytes = inlinePayload
            inlinePayload = []
            return bytes
        }
        guard let fork = resourceFork else { throw KaitoError.malformed("hfs+ decmpfs missing resource fork") }
        let offset: UInt64, length: UInt64
        switch layout {
        case .inline: preconditionFailure()
        case .offsets:
            let pair = try Self.read(fork, offset: Checked.mul(chunkIndex, 4), count: 8, limits: limits, metadata: true)
            offset = UInt64(DecmpfsHeader.u32(pair, 0))
            let end = UInt64(DecmpfsHeader.u32(pair, 4))
            let tableEnd = try Checked.mul(Checked.add(chunkCount, 1), 4)
            guard offset >= tableEnd, end >= offset, end <= fork.length else {
                throw KaitoError.malformed("hfs+ decmpfs chunk offsets")
            }
            length = end - offset
        case .zlib(let base, let tableEnd, let dataEnd):
            let descriptor = try Self.read(fork, offset: Checked.add(base, Checked.add(4, Checked.mul(chunkIndex, 8))),
                                           count: 8, limits: limits, metadata: true)
            offset = try Checked.add(base, UInt64(DecmpfsHeader.u32(descriptor, 0)))
            length = UInt64(DecmpfsHeader.u32(descriptor, 4))
            guard offset >= tableEnd, try Checked.add(offset, length) <= dataEnd else {
                throw KaitoError.malformed("hfs+ decmpfs chunk descriptor")
            }
        }
        guard length > 0, length <= Self.packedLimit else { throw KaitoError.malformed("hfs+ decmpfs chunk size") }
        return try Self.read(fork, offset: offset, count: Checked.toInt(length), limits: limits)
    }

    private func decode(_ packed: inout [UInt8], expected: Int) throws -> [UInt8] {
        let type = header.compressionType
        if type == 1 {
            guard packed.count == expected else { throw KaitoError.malformed("hfs+ decmpfs stored size") }
            return packed
        }
        let marker: UInt8 = type == 7 || type == 8 ? 0x06 : type == 9 || type == 10 ? 0xCC : 0xFF
        if packed.first == marker {
            guard packed.count - 1 == expected else { throw KaitoError.malformed("hfs+ decmpfs raw chunk size") }
            return Array(packed.dropFirst())
        }
        guard type != 9, type != 10 else { throw KaitoError.malformed("hfs+ decmpfs stored chunk marker") }
        var output = [UInt8](repeating: 0, count: expected)
        switch type {
        case 3, 4: try Self.inflate(packed, output: &output)
        case 7, 8: try decodeLZVN(&packed, output: &output)
        case 11, 12:
            guard Self.decodeLZFSE(packed, output: &output) else { throw KaitoError.malformed("hfs+ decmpfs LZFSE chunk") }
        default: throw KaitoError.unsupportedMethod("HFS+ decmpfs (type \(type))")
        }
        return output
    }

    /// CMF/FLG の後は raw Deflate。終端を必須とし、Adler-32 は有無を問わず最大 4 byte 読み飛ばす。
    private static func inflate(_ packed: [UInt8], output: inout [UInt8]) throws {
        guard packed.count > 2, packed[0] & 15 == 8, packed[0] >> 4 <= 7, packed[1] & 0x20 == 0,
              (UInt16(packed[0]) << 8 | UInt16(packed[1])) % 31 == 0 else {
            throw KaitoError.malformed("hfs+ decmpfs zlib header")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw KaitoError.malformed("hfs+ decmpfs zlib initialization")
        }
        defer { inflateEnd(&stream) }
        let expected = output.count
        let status = packed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: 2))
                stream.avail_in = uInt(packed.count - 2)
                stream.next_out = dst.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(expected)
                defer { stream.next_in = nil; stream.next_out = nil }
                var status = zlib.inflate(&stream, Z_FINISH)
                if status != Z_STREAM_END, stream.total_out == expected {
                    // 出力がちょうど満杯でも、最終 block まで進んだことを確かめる。
                    var extra: UInt8 = 0
                    status = withUnsafeMutablePointer(to: &extra) { pointer in
                        stream.next_out = pointer
                        stream.avail_out = 1
                        return zlib.inflate(&stream, Z_FINISH)
                    }
                }
                return status
            }
        }
        guard status == Z_STREAM_END, stream.total_out == expected, stream.avail_in <= 4 else {
            throw KaitoError.malformed("hfs+ decmpfs zlib chunk length or end")
        }
    }

    private static func decodeLZFSE(_ packed: [UInt8], output: inout [UInt8]) -> Bool {
        guard !packed.isEmpty, !output.isEmpty else { return false }
        let expected = output.count
        return packed.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                var stream = compression_stream(dst_ptr: dst.baseAddress!, dst_size: expected,
                                                src_ptr: src.baseAddress!, src_size: src.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) != COMPRESSION_STATUS_ERROR else { return false }
                defer { compression_stream_destroy(&stream) }
                stream.dst_ptr = dst.baseAddress!; stream.dst_size = expected
                stream.src_ptr = src.baseAddress!; stream.src_size = src.count
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                let status = compression_stream_process(&stream, flags)
                if status == COMPRESSION_STATUS_END { return stream.dst_size == 0 && stream.src_size == 0 }
                guard status == COMPRESSION_STATUS_OK, stream.dst_size == 0 else { return false }
                // buffer API は切り詰めた入力にも容量を返す。stream の END と実出力長で確定する。
                var extra: UInt8 = 0
                return withUnsafeMutablePointer(to: &extra) { pointer in
                    stream.dst_ptr = pointer; stream.dst_size = 1
                    defer { stream.dst_ptr = dst.baseAddress! }
                    return compression_stream_process(&stream, flags) == COMPRESSION_STATUS_END
                        && stream.dst_size == 1 && stream.src_size == 0
                }
            }
        }
    }

    /// 黒箱で観測した LZFSE の LZVN block envelope。容量は必ず展開長ちょうどにする。
    private func decodeLZVN(_ packed: inout [UInt8], output: inout [UInt8]) throws {
        guard output.count <= UInt32.max else { throw KaitoError.malformed("hfs+ decmpfs LZVN raw size") }
        let capacity = try Checked.add(UInt64(packed.count), 23)
        try Checked.size(capacity, limit: limits.maxInMemorySize)
        packed.reserveCapacity(try Checked.toInt(capacity))
        packed.insert(contentsOf: Array("bvxn".utf8) + [UInt8](repeating: 0, count: 8), at: 0)
        for i in 0..<4 { packed[4 + i] = UInt8(truncatingIfNeeded: output.count >> (i * 8)) }
        packed.append(contentsOf: "bvx$".utf8)
        func attempt(_ payloadEnd: Int, padding: Int = 0) -> Bool {
            packed.removeSubrange(payloadEnd..<packed.count)
            packed.append(contentsOf: repeatElement(UInt8(0), count: padding))
            for i in 0..<4 { packed[8 + i] = UInt8(truncatingIfNeeded: (payloadEnd - 12 + padding) >> (i * 8)) }
            packed.append(contentsOf: "bvx$".utf8)
            return Self.decodeLZFSE(packed, output: &output)
        }
        if attempt(packed.count - 4) { return }
        var end = packed.count - 4
        while end > 12, packed[end - 1] == 0 { end -= 1 }
        // stream API は EOS 後の 7 byte も必要（黒箱照合）。切った候補には 0 を補う。
        if attempt(end, padding: 7) { return }
        // decmpfs の長い padding を除く。EOS 候補は後ろから最大 64 個。
        var candidates = 0
        while end > 12, candidates < 64 {
            end -= 1
            if packed[end] == 0x06 {
                candidates += 1
                if attempt(end + 1, padding: 7) { return }
            }
        }
        throw KaitoError.malformed("hfs+ decmpfs LZVN chunk")
    }
}
