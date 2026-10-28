import Foundation
@testable import KaitoKit
import XCTest

final class SevenZipLZMA2IOTests: XCTestCase {
    func testCompressedPayloadReadOnceInSerialParallelAndBackwardSeek() throws {
        try SevenZipTestSupport.requireSevenZip()
        let temporary = try SevenZipTestSupport.temporaryDirectory(label: "7z-lzma2-io")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url: URL, expected: Data
        if let path = ProcessInfo.processInfo.environment["KAITO_7Z_IO_ARCHIVE"] {
            url = URL(fileURLWithPath: path)
            expected = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("payload.bin"))
        } else {
            // 同じ乱数 block を二度ずつ置き、raw chunk に逃げず大きな packed stream を作る。
            var payload = Data(), state: UInt64 = 741
            var block = [UInt8](repeating: 0, count: 32_768)
            for _ in 0..<384 {
                for index in block.indices {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    block[index] = UInt8(truncatingIfNeeded: state >> 32)
                }
                payload.append(contentsOf: block); payload.append(contentsOf: block)
            }
            expected = payload
            try SevenZipTestSupport.write(payload, relativePath: "payload.bin", below: temporary)
            url = temporary.appendingPathComponent("io.7z")
            try SevenZipTestSupport.makeArchive(sourceDirectory: temporary, paths: ["payload.bin"], archiveURL: url,
                options: ["-m0=LZMA2:c=8m", "-mmt=8", "-mhc=off"])
        }
        let input = try FileByteSource(url: url)
        let next = try SevenZipHeaderDecoder.readNextHeader(source: input, limits: ReadLimits(), editRecorder: nil)
        let headerDecoder = SevenZipHeaderDecoder(source: input, packedDataEnd: next.absoluteOffset,
            options: ReaderOptions(password: "secret"), keyCache: SevenZipAESKeyCache(),
            packedStreamVerifier: SevenZipPackedStreamVerifier(source: input),
            metadataBudget: SevenZipMetadataBudget(limit: ReadLimits().maxTotalMetadataSize), editRecorder: nil)
        let header = try headerDecoder.parseHeader(headerDecoder.decodeNextHeader(next.bytes))
        let streams = try XCTUnwrap(header.streams)
        let folder = try XCTUnwrap(streams.folders.first)
        let ranges = try SevenZipFolderLayout.ranges(for: streams, sourceLength: input.length, packedDataEnd: next.absoluteOffset)[0]
        let packed = try XCTUnwrap(ranges.values.first).size
        for workers in [1, 8] {
            let source = CountingByteSource(input)
            let diagnostics = ParallelIndependentDecompressor.Diagnostics()
            let factory = try SevenZipFolderDecoderFactory(source: source, folder: folder, packedRanges: ranges,
                limits: ReadLimits(), password: "secret", keyCache: SevenZipAESKeyCache(), maximumAESCyclesPower: 24,
                workers: workers, parallelDiagnostics: diagnostics)
            XCTAssertEqual(try factory.decodeAll(limit: 64 << 20), expected)
            let reads = source.bytesRead
            print("7Z-IO \(url.lastPathComponent) workers=\(workers) read=\(reads) packed=\(packed) ratio=\(Double(reads) / Double(packed)) peakWorkers=\(diagnostics.peakWorkers)")
            XCTAssertLessThanOrEqual(reads, packed * 102 / 100)
            if workers > 1 { XCTAssertGreaterThan(diagnostics.peakWorkers, 1) }
            do {
                let points = try XCTUnwrap(factory.makeDictionaryResetIndex())
                let point = try XCTUnwrap(points.last)
                XCTAssertGreaterThan(point.uncompressedOffset, 0)
                source.reset()
                let decoder = try XCTUnwrap(factory.makeDecoder(restartingAt: point))
                XCTAssertEqual(try drain(decoder, bufferSize: 65_537), Data(expected[Int(point.uncompressedOffset)...]))
                let originalOffset = factory.isEncrypted ? 0 : try XCTUnwrap(ranges.values.first).offset
                let remaining = packed - (point.compressedOffset - originalOffset)
                print("7Z-IO backward read=\(source.bytesRead) packed=\(remaining)")
                XCTAssertLessThanOrEqual(source.bytesRead, remaining * 102 / 100)
            }
        }
    }
}
