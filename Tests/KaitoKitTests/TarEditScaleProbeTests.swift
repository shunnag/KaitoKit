import Darwin
import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class TarEditScaleProbeTests: XCTestCase {
    struct Item: Decodable {
        struct Segment: Decodable {
            let kind: String
            let output: [UInt64]
            let base: [UInt64]?
        }
        let corpus: String
        let codec: String
        let edit: String
        let base: String
        let output: String
        let hint: String
        let segments: [Segment]
        var splice: CompressedTarSplice {
            .init(segments: segments.map {
                let output = $0.output[0]..<$0.output[1]
                if let base = $0.base { return .reused(output: output, base: base[0]..<base[1]) }
                return .encoded(output: output)
            })
        }
    }

    func testPrototypeManifest() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_TAR_SPLICE_PROBE"] else {
            throw XCTSkip("set KAITOKIT_TAR_SPLICE_PROBE to the prototype segment manifest")
        }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(items.count, 75)
        for item in items {
            var load = [Double](repeating: 0, count: 3)
            _ = getloadavg(&load, 3)
            for (i, value) in zip([1, 5, 15], load) {
                print("KAITOKIT-PROBE\t\(item.corpus)\t\(item.codec)\t\(item.edit)\tload\(i)_before\t\(value)")
            }
            let baseURL = URL(fileURLWithPath: item.base), outputURL = URL(fileURLWithPath: item.output)
            let hint = URL(fileURLWithPath: "/" + item.hint), options = TarSpliceTestSupport.options()
            let baseSource = try FileByteSource(url: baseURL), outputSource = try FileByteSource(url: outputURL)
            let base = try XCTUnwrap(ArchiveReader.open(source: baseSource, sourceURL: hint, options: options).tarEditingSnapshot())
            let full = try ArchiveReader.open(source: outputSource, sourceURL: hint, options: options)
            let actual = try ArchiveReader.openSplicedCompressedTar(output: outputSource, sourceURL: hint,
                base: base, splice: item.splice, options: options)
            try TarSpliceTestSupport.equal(actual, full)
            for (metric, operation) in [
                ("base_ms", { try ArchiveReader.open(source: baseSource, sourceURL: hint, options: options) }),
                ("full_ms", { try ArchiveReader.open(source: outputSource, sourceURL: hint, options: options) }),
                ("splice_ms", { try ArchiveReader.openSplicedCompressedTar(output: outputSource, sourceURL: hint,
                        base: base, splice: item.splice, options: options) })
            ] {
                var samples: [Double] = []
                for _ in 0..<5 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let reader = try operation()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    withExtendedLifetime(reader) {}
                }
                print("KAITOKIT-PROBE\t\(item.corpus)\t\(item.codec)\t\(item.edit)\t\(metric)\t\(samples.sorted()[2])")
            }
            _ = getloadavg(&load, 3)
            for (i, value) in zip([1, 5, 15], load) {
                print("KAITOKIT-PROBE\t\(item.corpus)\t\(item.codec)\t\(item.edit)\tload\(i)_after\t\(value)")
            }
        }
    }
}
