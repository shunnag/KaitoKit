import CBzip2
import Compression
import Foundation
import XCTest
import zlib

/// 圧縮 tar の chunk の区切りを、reader の内部実装に依存せず符号化側で決める oracle。
/// gzip は chunk ごとに直前 32 KiB を辞書にした raw deflate、bzip2 は chunk ごとに独立した stream、
/// xz は chunk ごとの block と index で包み、各 chunk の圧縮側と展開側の範囲（`Encoded.chunks`）を返す。
/// CRC-32・little endian・xz の VLI の小さな helper も持つ。
enum CompressedTarFramingTestSupport {
    // 旧名: GyoshukuFramingTestSupport（GyoshukuKit の枠組みを写したため利用側の名前が付いていた）
    struct Chunk {
        let compressed: Range<Int>
        let image: Range<Int>
    }
    struct Encoded {
        let data: Data
        let chunks: [Chunk]
    }
    static func crc(_ data: Data, initial: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { UInt32(zlib.crc32(uLong(initial), $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
    static func le(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func uint32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
    }
    static func vli(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat {
            result.append(UInt8(value & 127) | (value >= 128 ? 128 : 0))
            value >>= 7
        } while value > 0
        return result
    }
    static func readVLI(_ bytes: Data, _ position: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 7) {
            guard position < bytes.count else { throw TarTestSupportError.commandFailed("XZ VLI") }
            let byte = bytes[position]; position += 1
            result |= UInt64(byte & 127) << shift
            if byte < 128 { return result }
        }
        throw TarTestSupportError.commandFailed("XZ VLI overflow")
    }
    static func gzip(_ image: Data, chunkSize: Int = 1_048_576, level: Int = 6,
                     flush: Int32 = Z_SYNC_FLUSH) throws -> Encoded {
        var output = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, level == 9 ? 2 : level <= 1 ? 4 : 0, 3])
        var chunks: [Chunk] = []
        for start in stride(from: 0, to: max(1, image.count), by: chunkSize) {
            let end = min(image.count, start + chunkSize)
            var stream = z_stream()
            guard deflateInit2_(&stream, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                               ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw TarTestSupportError.commandFailed("deflate init")
            }
            defer { deflateEnd(&stream) }
            if start > 0 {
                let dictionary = Data(image[max(0, start - 32_768)..<start])
                let status = dictionary.withUnsafeBytes {
                    deflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
                }
                guard status == Z_OK else { throw TarTestSupportError.commandFailed("dictionary") }
            }
            let input = Data(image[start..<end]), size = end - start
            var encoded = Data(count: size + (size >> 12) + (size >> 14) + (size >> 25) + 20)
            let status = input.withUnsafeBytes { src in
                encoded.withUnsafeMutableBytes { dst in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(src.count)
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dst.count)
                    return deflate(&stream, end == image.count ? Z_FINISH : flush)
                }
            }
            guard status == (end == image.count ? Z_STREAM_END : Z_OK), stream.avail_in == 0, stream.avail_out > 0 else {
                throw TarTestSupportError.commandFailed("deflate \(status)")
            }
            encoded.removeLast(Int(stream.avail_out))
            let c0 = output.count; output.append(encoded)
            chunks.append(Chunk(compressed: c0..<output.count, image: start..<end))
        }
        output.append(le(crc(image))); output.append(le(UInt32(truncatingIfNeeded: image.count)))
        return Encoded(data: output, chunks: chunks)
    }
    static func bzip2(_ image: Data, level: Int = 9, chunkSize: Int? = nil) throws -> Encoded {
        var output = Data(), chunks: [Chunk] = []
        let step = chunkSize ?? 5 * level * 100_000
        for start in stride(from: 0, to: max(1, image.count), by: step) {
            let end = min(image.count, start + step), input = Data(image[start..<min(image.count, start + step)])
            var stream = bz_stream()
            guard BZ2_bzCompressInit(&stream, Int32(level), 0, 30) == BZ_OK else {
                throw TarTestSupportError.commandFailed("bzip2 init")
            }
            defer { BZ2_bzCompressEnd(&stream) }
            var encoded = Data(count: input.count + input.count / 100 + 601)
            let status = input.withUnsafeBytes { src in
                encoded.withUnsafeMutableBytes { dst in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: CChar.self).baseAddress)
                    stream.avail_in = UInt32(src.count)
                    stream.next_out = dst.bindMemory(to: CChar.self).baseAddress
                    stream.avail_out = UInt32(dst.count)
                    return BZ2_bzCompress(&stream, BZ_FINISH)
                }
            }
            guard status == BZ_STREAM_END else { throw TarTestSupportError.commandFailed("bzip2 \(status)") }
            encoded.removeLast(Int(stream.avail_out))
            let c0 = output.count; output.append(encoded)
            chunks.append(Chunk(compressed: c0..<output.count, image: start..<end))
        }
        return Encoded(data: output, chunks: chunks)
    }
    static func xz(_ image: Data, chunkSize: Int = 16 * 1_048_576, check: UInt8 = 1) throws -> Encoded {
        let flags = Data([0, check])
        var output = Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) + flags + le(crc(flags))
        var chunks: [Chunk] = [], records = Data()
        for start in stride(from: 0, to: image.count, by: chunkSize) {
            let end = min(image.count, start + chunkSize), input = Data(image[start..<min(image.count, start + chunkSize)])
            var capacity = input.count + max(1024, input.count / 16)
            var native = Data()
            while true {
                native = Data(count: capacity)
                let count = input.withUnsafeBytes { src in
                    native.withUnsafeMutableBytes { dst in
                        compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZMA)
                    }
                }
                if count > 0 { native.removeLast(native.count - count); break }
                guard capacity < input.count * 2 + 65_536 else { throw TarTestSupportError.commandFailed("LZMA encode") }
                capacity = min(capacity * 2, input.count * 2 + 65_536)
            }
            let footer = native.count - 12
            let indexStart = footer - Int(uint32(native, footer + 4) + 1) * 4
            var cursor = indexStart + 1
            guard try readVLI(native, &cursor) == 1 else { throw TarTestSupportError.commandFailed("native XZ blocks") }
            let unpadded = try readVLI(native, &cursor)
            let nativeHeaderSize = (Int(native[12]) + 1) * 4
            let nativeCheck = native[7] == 0 ? 0 : 1 << ((Int(native[7]) - 1) / 3 + 2)
            cursor = 14
            if native[13] & 0x40 != 0 { _ = try readVLI(native, &cursor) }
            if native[13] & 0x80 != 0 { _ = try readVLI(native, &cursor) }
            guard try readVLI(native, &cursor) == 0x21, try readVLI(native, &cursor) == 1 else {
                throw TarTestSupportError.commandFailed("native XZ filter")
            }
            let props = native[cursor]
            let payloadStart = 12 + nativeHeaderSize
            let payload = Data(native[payloadStart..<(payloadStart + Int(unpadded) - nativeHeaderSize - nativeCheck)])
            var header = Data([0, 0xc0]) + vli(UInt64(payload.count)) + vli(UInt64(input.count)) + Data([0x21, 1, props])
            while header.count % 4 != 0 { header.append(0) }
            header[0] = UInt8(header.count / 4)
            header.append(le(crc(header)))
            let c0 = output.count
            output.append(header); output.append(payload)
            output.append(Data(count: (4 - payload.count % 4) % 4))
            if check == 1 { output.append(le(crc(input))) }
            records.append(vli(UInt64(header.count + payload.count + (check == 1 ? 4 : 0))))
            records.append(vli(UInt64(input.count)))
            chunks.append(Chunk(compressed: c0..<output.count, image: start..<end))
        }
        var index = Data([0]) + vli(UInt64(chunks.count)) + records
        while index.count % 4 != 0 { index.append(0) }
        index.append(le(crc(index))); output.append(index)
        let footer = le(UInt32(index.count / 4 - 1)) + flags
        output.append(le(crc(footer)) + footer + Data([0x59, 0x5a]))
        return Encoded(data: output, chunks: chunks)
    }
}
