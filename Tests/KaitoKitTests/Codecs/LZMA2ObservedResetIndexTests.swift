import Foundation
import XCTest
@testable import KaitoKit

final class LZMA2ObservedResetIndexTests: XCTestCase {
    typealias RawSource = SevenZipLZMA2ResetIndexTests.RawSource
    private func decoder(_ source: any ByteSource, size: UInt64, cache: SevenZipLZMA2ResetIndexCache,
                         limit: Int = 1000, point: LZMA2ResetPoint? = nil) throws -> LZMA2Decoder {
        let value: LZMA2Decoder
        if let point {
            value = try LZMA2Decoder(source: source, originalOffset: 0, originalCompressedSize: source.length,
                properties: [8], restartingAt: point, expectedSize: size - point.uncompressedOffset,
                dictionarySizeLimit: 1 << 20)
        } else {
            value = try LZMA2Decoder(source: source, offset: 0, compressedSize: source.length,
                properties: [8], expectedSize: size, dictionarySizeLimit: 1 << 20)
        }
        value.resetObserver = LZMA2ResetObserver(cache: cache, base: point?.uncompressedOffset ?? 0, maximumPointCount: limit)
        return value
    }
    private func drain(_ decoder: LZMA2Decoder, bytes: Int? = nil) throws {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var remaining = bytes ?? Int.max
        while !decoder.isFinished, remaining > 0 {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<min($0.count, remaining)])) }
            remaining -= count
        }
    }
    func testObservedIndexEqualsScannedIndex() throws {
        let compressed = try SevenZipParallelTestSupport.compressed()
        let raw = RawSource(chunks: 702, resetChunks: [0, 3, 700])
        let vectors: [(any ByteSource, UInt64)] = [(raw, raw.outputSize),
            (DataByteSource(compressed.packed), UInt64(compressed.output.count)),
            (DataByteSource(data: Data([1, 0, 2, 97, 98, 99, 0])), 3)]
        for (source, size) in vectors {
            let expected = try LZMA2Decoder.makeDictionaryResetIndex(source: source, offset: 0,
                compressedSize: source.length, expectedSize: size, maximumPointCount: 1000)
            let cache = SevenZipLZMA2ResetIndexCache()
            try drain(decoder(source, size: size, cache: cache))
            XCTAssertEqual(cache.observedPoints, expected)
            XCTAssertEqual(cache.observedCoverage, size)
        }
        // property 付き LZMA の後に raw reset と property 付きの非 dictionary reset を置く。
        let first = try Hex.data("e00011000800003099abddc0cb0700")
        let tail = try Hex.data("c00011000800003099abddc0cb070000")
        let bytes = first + Data([1, 0, 2, 97, 98, 99]) + tail
        let source = DataByteSource(bytes), cache = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(source, size: 39, cache: cache))
        XCTAssertEqual(cache.observedPoints, try LZMA2Decoder.makeDictionaryResetIndex(source: source, offset: 0,
            compressedSize: source.length, expectedSize: 39, maximumPointCount: 100))
        XCTAssertEqual(cache.observedPoints.last?.lzmaProperties, 0)
    }
    func testPartialCoverage() throws {
        let raw = RawSource(chunks: 4, resetChunks: [0, 2]), cache = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(raw, size: raw.outputSize, cache: cache), bytes: 3 * 65536)
        let points = try LZMA2Decoder.makeDictionaryResetIndex(source: raw, offset: 0,
            compressedSize: raw.length, expectedSize: raw.outputSize)
        XCTAssertEqual(cache.observedCoverage, 3 * 65536)
        for target in stride(from: UInt64(0), to: cache.observedCoverage, by: 7919) {
            XCTAssertEqual(cache.observedRestartPoint(atOrBefore: target),
                           .covered(points.last { $0.uncompressedOffset <= target }))
        }
        XCTAssertEqual(cache.observedRestartPoint(atOrBefore: cache.observedCoverage), .uncovered)
        XCTAssertEqual(cache.observedRestartPoint(atOrBefore: raw.outputSize), .uncovered)
    }

    func testNonResetChunksDoNotAddObservedPoints() throws {
        var first = Array(try Hex.data("e00011000800003099abddc0cb070000")); first.removeLast()
        var stateOnly = first; stateOnly.remove(at: 5); stateOnly[0] = 0xa0
        let stream = Data(first + [2, 0, 0, 120] + stateOnly + [0])
        let source = DataByteSource(stream), cache = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(source, size: 37, cache: cache))
        XCTAssertEqual(cache.observedPoints.count, 1)
        XCTAssertEqual(cache.observedCoverage, 37)
        XCTAssertEqual(cache.observedPoints, try LZMA2Decoder.makeDictionaryResetIndex(source: source,
            offset: 0, compressedSize: source.length, expectedSize: 37))

        try SevenZipTestSupport.requireSevenZip()
        let directory = try SevenZipTestSupport.temporaryDirectory(), archive = directory.appendingPathComponent("state.7z")
        var seed: UInt64 = 0x0123456789abcdef, payload = Data()
        for _ in 0..<4 {
            var block = Data()
            for _ in 0..<65536 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                block.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            payload.append(block); payload.append(block)
        }
        try SevenZipTestSupport.write(payload, relativePath: "payload.bin", below: directory)
        try SevenZipTestSupport.makeArchive(sourceDirectory: directory, paths: ["payload.bin"], archiveURL: archive,
            options: ["-m0=LZMA2", "-mx=9", "-ms=off", "-mhc=off"])
        let bytes = [UInt8](try Data(contentsOf: archive))
        let size = Int(LittleEndian.uint64(bytes, at: 12))
        let packed = DataByteSource(data: Data(bytes[32..<32 + size]))
        var cursor = try ByteReader(source: packed, bufferCapacity: 1), tracker = LZMA2ResetTracker()
        var controls: [UInt8] = []
        while cursor.offset < packed.length {
            let offset = cursor.offset, control = try cursor.readUInt8()
            controls.append(control)
            switch try LZMA2ChunkHeader(control: control, controlOffset: offset, reader: &cursor, resets: &tracker) {
            case .end: break
            case .uncompressed(let size, _): try cursor.seek(to: cursor.offset + size)
            case .compressed(_, let size, _, _, _): try cursor.seek(to: cursor.offset + size)
            }
        }
        XCTAssertTrue(controls.contains { (0x80..<0xa0).contains($0) })
        let observed = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(packed, size: UInt64(payload.count), cache: observed))
        XCTAssertEqual(observed.observedPoints, try LZMA2Decoder.makeDictionaryResetIndex(source: packed, offset: 0,
            compressedSize: packed.length, expectedSize: UInt64(payload.count)))
        XCTAssertEqual(observed.observedCoverage, UInt64(payload.count))
    }

    func testRestartExtendsCoverageWithoutDuplicatesOrGaps() throws {
        let raw = RawSource(chunks: 4, resetChunks: [0, 1, 3]), cache = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(raw, size: raw.outputSize, cache: cache), bytes: 131072)
        let point = try XCTUnwrap(cache.observedPoints.last)
        try drain(decoder(raw, size: raw.outputSize, cache: cache, point: point))
        XCTAssertEqual(cache.observedCoverage, raw.outputSize)
        XCTAssertEqual(cache.observedPoints.count, 3)
        let empty = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(raw, size: raw.outputSize, cache: empty, point: point))
        XCTAssertEqual(empty.observedCoverage, 0)
        XCTAssertTrue(empty.observedPoints.isEmpty)
    }
    func testInvalidChunkDoesNotRecordPointOrCoverage() throws {
        for (bytes, size): ([UInt8], UInt64) in [([1, 0, 2, 1, 2, 3, 0], 2),
            ([1, 0, 3, 1], 4), ([0xe0, 0, 2, 0, 20, 0x5d, 0], 3),
            ([0xe0, 0, 2, 0, 20, 0x5d, 0], 2)] {
            let source = DataByteSource(data: Data(bytes)), cache = SevenZipLZMA2ResetIndexCache()
            XCTAssertThrowsError(try drain(decoder(source, size: size, cache: cache)))
            XCTAssertTrue(cache.observedPoints.isEmpty)
            XCTAssertEqual(cache.observedCoverage, 0)
        }
    }
    func testPointLimitFreezesAtThirdReset() throws {
        let raw = RawSource(chunks: 4, resetChunks: [0, 1, 2, 3]), cache = SevenZipLZMA2ResetIndexCache()
        try drain(decoder(raw, size: raw.outputSize, cache: cache, limit: 2))
        XCTAssertTrue(cache.observationFrozen)
        XCTAssertEqual(cache.observedCoverage, 2 * 65536)
        XCTAssertEqual(cache.observedPoints.count, 2)
        XCTAssertEqual(cache.observedRestartPoint(atOrBefore: 65536), .covered(cache.observedPoints[1]))
        XCTAssertEqual(cache.observedRestartPoint(atOrBefore: 2 * 65536), .uncovered)
    }
}
