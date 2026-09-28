import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class CompressedTarChunkMapTests: XCTestCase {
    func testRepeatedEmptyBlocksKeepCoverageAndCombineDigest() throws {
        let image = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data(repeating: 65, count: 160_000))])
        let encoded = try GyoshukuFramingTestSupport.gzip(image, chunkSize: 65_536)
        var bytes = encoded.data
        bytes.insert(contentsOf: [0, 0, 0, 255, 255, 0, 0, 0, 255, 255], at: encoded.chunks[0].compressed.upperBound)
        bytes.insert(contentsOf: [0, 0, 0, 255, 255], at: 10)
        let snapshot = try TarEditTestSupport.snapshot(bytes, suffix: "tgz")
        guard case .gzip(let map) = snapshot.chunkMap else { return XCTFail("missing map") }
        XCTAssertEqual(map.points.count, encoded.chunks.count)
        XCTAssertEqual(map.points[0].compressedOffset, 10)
        XCTAssertEqual(map.points[1].compressedOffset, UInt64(encoded.chunks[0].compressed.upperBound + 15))
        try TarEditTestSupport.verify(snapshot)
    }
    func testEncoderBoundariesAndIndependentDecoding() throws {
        var state: UInt64 = 0x189c82f0
        let random = Data((0..<(1_048_576 + 4096)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17; return UInt8(truncatingIfNeeded: state)
        })
        for body in [random, Data(repeating: 0, count: random.count), Data(repeating: 65, count: random.count)] {
            let image = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "body", contents: body)])
            var variants: [(String, GyoshukuFramingTestSupport.Encoded)] = []
            for size in [65_536, 131_072, 1_048_576] { variants.append(("tgz", try GyoshukuFramingTestSupport.gzip(image, chunkSize: size))) }
            for level in [1, 9] { variants.append(("tbz", try GyoshukuFramingTestSupport.bzip2(image, level: level))) }
            for size in [262_144, 16 * 1_048_576] { variants.append(("txz", try GyoshukuFramingTestSupport.xz(image, chunkSize: size))) }
            for (suffix, encoded) in variants {
                let snapshot = try TarEditTestSupport.snapshot(encoded.data, suffix: suffix)
                let chunks = try XCTUnwrap(snapshot.chunkMap, "\(suffix): \(String(describing: snapshot.chunkMapUnavailableReason))").chunks
                XCTAssertEqual(chunks.map(\.compressedRange), encoded.chunks.map { UInt64($0.compressed.lowerBound)..<UInt64($0.compressed.upperBound) })
                XCTAssertEqual(chunks.map(\.imageRange), encoded.chunks.map { UInt64($0.image.lowerBound)..<UInt64($0.image.upperBound) })
                try TarEditTestSupport.verify(snapshot)
            }
        }
    }

    func testReasonsLimitsAndLongGzipHeader() throws {
        let inputs = try TarGoldenCorpus.inputs()
        for (name, reason) in [("gzip-multiple", ChunkMapUnavailableReason.multipleGzipMembers), ("xz-multiple", .multipleXZStreams), ("xz-padding", .xzStreamPadding)] {
            let input = try XCTUnwrap(inputs.first { $0.id == name })
            let snapshot = try TarEditTestSupport.snapshot(TarGoldenCorpus.decoded(input), suffix: input.suffix)
            XCTAssertNil(snapshot.chunkMap); XCTAssertEqual(snapshot.chunkMapUnavailableReason, reason)
        }
        let rich = try TarGoldenCorpus.decoded(XCTUnwrap(inputs.first { $0.id == "gzip-rich-header" }))
        let snapshot = try TarEditTestSupport.snapshot(rich, suffix: "tgz")
        guard case .gzip(let map) = snapshot.chunkMap else { return XCTFail("rich header: \(String(describing: snapshot.chunkMapUnavailableReason))") }
        XCTAssertEqual(map.headerLength, try GzipHeaderParser.parseFirstHeader(source: DataByteSource(rich), limits: ReadLimits()).length)
        XCTAssertGreaterThan(map.headerLength, 262_144)
        try TarEditTestSupport.verify(snapshot)

        for (name, format, stops) in [("gzip-dense-blocks", ArchiveFormat.gzip, UInt64(3)), ("gzip-rich-header", .gzip, .max), ("bzip2-level9", .bzip2, .max), ("sparse10-xz", .xz, .max)] {
            let input = try XCTUnwrap(inputs.first { $0.id == name }), source = DataByteSource(try TarGoldenCorpus.decoded(input))
            let recorder = CompressedTarMapRecorder(format: format, maximumChunks: stops == 3 ? 1000 : 0, gzipStopLimit: stops == 3 ? 3 : 1_048_576)
            let single = try SingleFileReader(source: source, format: format, options: ReaderOptions(), fallbackFileName: "test")
            let staged = try SingleFileMaterializer.materialize(single.stagingStream(limits: ReadLimits(), recorder: recorder), limits: ReadLimits())
            let original = try drain(SingleFileReader.makeDecompressor(format: format, source: source, limits: ReadLimits()), bufferSize: 65_536)
            XCTAssertEqual(try TarEditTestSupport.bytes(staged), original)
            XCTAssertEqual(recorder.finish(imageLength: staged.length, archiveLength: source.length).reason, .tooManyChunks, name)
        }
    }
}
