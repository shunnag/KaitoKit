import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest
import zlib

enum TarEditTestSupport {
    static func decodeOutcome(_ decoder: any Decompressor, limit: UInt64 = 64 * 1_048_576) -> (bytes: Data, error: String?) {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while !decoder.isFinished {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                guard UInt64(bytes.count) + UInt64(count) <= limit else { throw KaitoError.limitExceeded("fuzz output") }
                guard count > 0 || decoder.isFinished else { throw KaitoError.truncated }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return (bytes, nil)
        } catch { return (bytes, String(describing: error)) }
    }
    static func fixture(_ name: String) throws -> Data { try TestFixtures.base64("tar-edit/" + name) }
    static func snapshot(_ data: Data, suffix: String, disk: Bool = false) throws -> TarEditingSnapshot {
        var limits = ReadLimits(); if disk { limits.inMemorySingleFileLimit = 0 }
        var options = ReaderOptions(limits: limits, appleDoublePolicy: .expose); options.recordsTarEditLayout = true
        return try XCTUnwrap(ArchiveReader.open(source: DataByteSource(data), sourceURL: URL(fileURLWithPath: "/fixture." + suffix), options: options).tarEditingSnapshot())
    }
    static func bytes(_ source: any ByteSource) throws -> Data {
        Data(try readByteRange(source: source, offset: 0, count: Int(source.length)))
    }
    static func rawInflate(_ compressed: Data, dictionary: Data, expectedCount: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw KaitoError.truncated }
        defer { inflateEnd(&stream) }
        if !dictionary.isEmpty {
            let status = dictionary.withUnsafeBytes { inflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard status == Z_OK else { throw KaitoError.truncated }
        }
        var output = Data(count: expectedCount + 1)
        let status = compressed.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count); stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(dst.count)
            return inflate(&stream, Z_NO_FLUSH)
        } }
        guard [Z_OK, Z_STREAM_END].contains(status), stream.avail_in == 0 else { throw KaitoError.malformed("chunk inflate \(status)") }
        output.removeLast(Int(stream.avail_out))
        return output
    }
    static func isolatedXZ(_ bytes: Data, block: XZBlockMap.Block, flags: UInt16) -> Data {
        let f = Data([UInt8(truncatingIfNeeded: flags), UInt8(truncatingIfNeeded: flags >> 8)])
        var result = Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) + f + CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(f)) + bytes
        var index = Data([0, 1]) + CompressedTarFramingTestSupport.vli(block.unpaddedSize) + CompressedTarFramingTestSupport.vli(block.imageRange.upperBound - block.imageRange.lowerBound)
        while index.count % 4 != 0 { index.append(0) }
        index.append(CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(index))); result.append(index)
        let footer = CompressedTarFramingTestSupport.le(UInt32(index.count / 4 - 1)) + f
        result.append(CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(footer)) + footer + Data([0x59, 0x5a]))
        return result
    }
    static func verify(_ snapshot: TarEditingSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let map = try XCTUnwrap(snapshot.chunkMap, "\(String(describing: snapshot.chunkMapUnavailableReason))", file: file, line: line)
        let archive = try bytes(snapshot.archive), image = try bytes(snapshot.image)
        var imageOffset: UInt64 = 0
        for (index, chunk) in map.chunks.enumerated() {
            let compressed = Data(archive[Int(chunk.compressedRange.lowerBound)..<Int(chunk.compressedRange.upperBound)])
            let expected = Data(image[Int(chunk.imageRange.lowerBound)..<Int(chunk.imageRange.upperBound)])
            XCTAssertEqual(chunk.imageRange.lowerBound, imageOffset, file: file, line: line)
            imageOffset = chunk.imageRange.upperBound
            XCTAssertEqual(chunk.compressedCRC32, CompressedTarFramingTestSupport.crc(compressed), file: file, line: line)
            let decoded: Data
            switch map {
            case .gzip(let gzip):
                let lower = Int(chunk.imageRange.lowerBound)
                decoded = try rawInflate(compressed, dictionary: Data(image[max(0, lower - 32_768)..<lower]), expectedCount: expected.count)
                XCTAssertEqual(gzip.points[index].crc32, CompressedTarFramingTestSupport.crc(Data(image.prefix(lower))), file: file, line: line)
                XCTAssertEqual(gzip.trailerOffset, UInt64(archive.count - 8), file: file, line: line)
                XCTAssertEqual(gzip.trailerCRC32, CompressedTarFramingTestSupport.crc(image), file: file, line: line)
            case .bzip2:
                decoded = try drain(Bzip2Decompressor(source: DataByteSource(compressed), offset: 0, compressedSize: UInt64(compressed.count)), bufferSize: 65_536)
            case .xz(let xz):
                decoded = try drain(XZDecompressor(source: DataByteSource(isolatedXZ(compressed, block: xz.blocks[index], flags: xz.streamFlags)), limits: ReadLimits()), bufferSize: 65_536)
            }
            XCTAssertEqual(decoded, expected, "chunk \(index)", file: file, line: line)
        }
        XCTAssertEqual(imageOffset, snapshot.image.length, file: file, line: line)
    }
}

/// `options` に tar 編集用の配置の記録（`recordsTarEditLayout`）の有無だけを加えたもの。
func tarGoldenOptions(_ options: ReaderOptions, recording: Bool) -> ReaderOptions {
    var result = options
    result.recordsTarEditLayout = recording
    return result
}
