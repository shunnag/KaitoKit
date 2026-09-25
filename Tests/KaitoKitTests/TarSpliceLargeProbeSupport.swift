import Darwin
import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

extension TarEditScaleProbeTests {
    func testLargeISIZEAndEOFAppend() throws {
        guard ProcessInfo.processInfo.environment["KAITOKIT_TAR_SPLICE_PROBE_LARGE"] == "1" else {
            throw XCTSkip("set KAITOKIT_TAR_SPLICE_PROBE_LARGE=1 for the 4 GiB + 1 MiB corpus")
        }
        // 比較時は base と full の二つの image を同時に保持する。
        guard try SingleFileMaterializer.availableTemporarySpace() >= 12 * 1_024 * 1_024 * 1_024 else {
            throw XCTSkip("large splice comparison needs 12 GiB free temporary space")
        }
        typealias S = TarSpliceTestSupport
        let length: UInt64 = 4 * 1_024 * 1_024 * 1_024 + 1_048_576
        var options = S.options(disk: true)
        options.limits.maxEntrySize = 8 * 1_024 * 1_024 * 1_024
        for codec in S.Codec.allCases {
            let generated = try TarSpliceLargeProbeSupport.archive(codec, length: length)
            let source = DataByteSource(generated)
            let base = try XCTUnwrap(ArchiveReader.open(source: source, sourceURL: S.hint(codec), options: options).tarEditingSnapshot())
            XCTAssertEqual(base.image.length, length)
            let result = try TarSpliceLargeProbeSupport.append(base, codec, archive: generated)
            let fullSource = DataByteSource(result.bytes)
            do {
                let actual = try S.open(result, codec, base: base, options: options)
                let full = try S.full(result.bytes, codec, options: options)
                try S.equal(actual, full)
                let after = try XCTUnwrap(actual.tarEditingSnapshot())
                XCTAssertGreaterThan(after.image.length, UInt64(UInt32.max))
                if case .gzip(let map) = after.chunkMap {
                    XCTAssertEqual(UInt32(truncatingIfNeeded: map.imageLength), GyoshukuFramingTestSupport.uint32(result.bytes, result.bytes.count - 4))
                }
            }
            var load = [Double](repeating: 0, count: 3)
            _ = getloadavg(&load, 3)
            print("KAITOKIT-PROBE\tlarge\t\(codec.rawValue)\tappend\tload1\t\(load[0])")
            for (metric, operation) in [
                ("base_ms", { try ArchiveReader.open(source: source, sourceURL: S.hint(codec), options: options) }),
                ("full_ms", { try ArchiveReader.open(source: fullSource, sourceURL: S.hint(codec), options: options) }),
                ("splice_ms", { try ArchiveReader.openSplicedCompressedTar(output: fullSource, sourceURL: S.hint(codec),
                        base: base, splice: result.splice, options: options) })
            ] {
                var samples: [Double] = []
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let reader = try operation()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    withExtendedLifetime(reader) {}
                }
                print("KAITOKIT-PROBE\tlarge\t\(codec.rawValue)\tappend\t\(metric)\t\(samples.sorted()[2])")
            }
        }
    }
}

private enum TarSpliceLargeProbeSupport {
    typealias S = TarSpliceTestSupport
    static func archive(_ codec: S.Codec, length: UInt64) throws -> Data {
        var header = try S.member("large-zero-body", Data())
        let size = String(length - 1536, radix: 8)
        header.replaceSubrange(124..<136, with: Data((String(repeating: "0", count: 11 - size.count) + size + "\0").utf8))
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let check = String(header.reduce(UInt64(0)) { $0 + UInt64($1) }, radix: 8)
        header.replaceSubrange(148..<156, with: Data((String(repeating: "0", count: 6 - check.count) + check + "\0 ").utf8))
        let stride: UInt64 = codec == .tgz ? 1_048_576 : codec == .tbz ? 4_500_000 : 16 * 1_048_576
        var output = codec == .tgz ? Data([31, 139, 8, 0, 0, 0, 0, 0, 0, 3]) : Data()
        var crc: UInt32 = 0, records: [(UInt64, UInt64)] = [], offset: UInt64 = 0
        while offset < length {
            let count = Int(min(stride, length - offset))
            var bytes = Data(count: count)
            if offset == 0 { bytes.replaceSubrange(0..<512, with: header) }
            crc = tarSpliceCRCCombine(crc, GyoshukuFramingTestSupport.crc(bytes), UInt64(count))
            if codec == .tgz {
                output.append(try S.rawGzip(bytes, dictionary: offset == 0 ? Data() : Data(count: 32_768), final: offset + UInt64(count) == length))
            } else {
                let encoded = try S.encode(bytes, codec, chunkSize: count)
                if codec == .tbz { output.append(encoded.data) }
                else {
                    if offset == 0 { output.append(encoded.data.prefix(12)) }
                    let range = S.payload(encoded.data, codec)
                    output.append(encoded.data[Int(range.lowerBound)..<Int(range.upperBound)])
                    records.append(contentsOf: try S.xzRecords(encoded.data))
                }
            }
            offset += UInt64(count)
        }
        if codec == .tgz {
            output.append(GyoshukuFramingTestSupport.le(crc)); output.append(GyoshukuFramingTestSupport.le(UInt32(truncatingIfNeeded: length)))
        } else if codec == .txz { S.appendTail(&output, image: Data(), codec: codec, records: records, flags: Data([0, 1])) }
        return output
    }

    static func append(_ base: TarEditingSnapshot, _ codec: S.Codec, archive: Data) throws -> S.Output {
        let map = try XCTUnwrap(base.chunkMap), chunks = map.chunks
        let eof = try XCTUnwrap(base.layout).endOfArchiveOffset
        let first = try XCTUnwrap(chunks.indices.last { chunks[$0].imageRange.lowerBound <= eof })
        let chunk = chunks[first]
        var bridge = Data(try readByteRange(source: base.image, offset: chunk.imageRange.lowerBound, count: Int(eof - chunk.imageRange.lowerBound)))
        bridge.append(try S.member("large-append", Data([1, 2, 3])) + Data(count: 1024))
        var output = Data(archive.prefix(Int(chunk.compressedRange.lowerBound)))
        let newLength = chunk.imageRange.lowerBound + UInt64(bridge.count)
        let bridgeRecords: [(UInt64, UInt64)]
        if codec == .tgz {
            let w = min(32_768, chunk.imageRange.lowerBound)
            let dictionary = Data(try readByteRange(source: base.image, offset: chunk.imageRange.lowerBound - w, count: Int(w)))
            output.append(try S.rawGzip(bridge, dictionary: dictionary, final: true))
            bridgeRecords = []
        } else {
            let encoded = try S.encode(bridge, codec, chunkSize: codec == .tbz ? 4_500_000 : 16 * 1_048_576)
            let range = S.payload(encoded.data, codec)
            output.append(encoded.data[Int(range.lowerBound)..<Int(range.upperBound)])
            bridgeRecords = codec == .txz ? try S.xzRecords(encoded.data) : []
        }
        let payloadEnd = UInt64(output.count)
        if case .gzip(let gz) = map {
            let crc = tarSpliceCRCCombine(gz.points[first].crc32, GyoshukuFramingTestSupport.crc(bridge), UInt64(bridge.count))
            output.append(GyoshukuFramingTestSupport.le(crc)); output.append(GyoshukuFramingTestSupport.le(UInt32(truncatingIfNeeded: newLength)))
        } else if case .xz(let xz) = map {
            let records = xz.blocks[..<first].map { ($0.unpaddedSize, $0.imageRange.upperBound - $0.imageRange.lowerBound) } + bridgeRecords
            S.appendTail(&output, image: Data(), codec: codec, records: records, flags: Data(archive[6..<8]))
        }
        let lower = chunks[0].compressedRange.lowerBound, middle = chunk.compressedRange.lowerBound
        return .init(name: "large-append", bytes: output, splice: .init(segments: [
            .reused(output: lower..<middle, base: lower..<middle), .encoded(output: middle..<payloadEnd)
        ]), image: Data())
    }
}
