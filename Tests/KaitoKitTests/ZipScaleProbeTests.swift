import Foundation
import KaitoKit
import Synchronization
import XCTest

// b518014 にこのファイルだけを写して測れる公開 API の probe。
final class ZipScaleProbeTests: XCTestCase {
    func testScale() throws {
        let url = try ZipScaleProbeSource.corpus()
        let openOnly = ProcessInfo.processInfo.environment["KAITOKIT_ZIP_SCALE_PROBE_OPEN_ONLY"] == "1"
        for eager in openOnly ? [false] : [false, true] {
            var times: [Double] = []
            var counts: [ZipScaleProbeSource.Counts] = []
            for _ in 0..<(openOnly ? 15 : 5) {
                let source = try ZipScaleProbeSource(url)
                let start = ContinuousClock.now
                let reader = try ArchiveReader.open(source: source, options: ReaderOptions(lazyLocalHeaders: !eager, appleDoublePolicy: .expose))
                times.append(ZipScaleProbeSource.milliseconds(start.duration(to: .now)))
                XCTAssertEqual(reader.entries.count, 500_000)
                counts.append(source.counts)
            }
            ZipScaleProbeSource.report(eager ? "eager_open" : "lazy_open", times: times, counts: counts)
        }
        if openOnly { return }
        var times: [Double] = []
        var counts: [ZipScaleProbeSource.Counts] = []
        for _ in 0..<5 {
            let source = try ZipScaleProbeSource(url)
            let reader = try ArchiveReader.open(source: source, options: ReaderOptions(appleDoublePolicy: .expose))
            source.reset()
            let start = ContinuousClock.now
            var end: UInt64 = 0
            for entry in reader.entries { end = try XCTUnwrap(reader.rawRecord(of: entry)).recordRange.upperBound }
            times.append(ZipScaleProbeSource.milliseconds(start.duration(to: .now)))
            XCTAssertEqual(end, source.localRange.upperBound)
            counts.append(source.counts)
        }
        ZipScaleProbeSource.report("public_raw", times: times, counts: counts)
    }
}
