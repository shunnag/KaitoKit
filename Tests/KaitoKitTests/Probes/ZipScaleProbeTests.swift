import Foundation
import KaitoKit
import Synchronization
import XCTest

/// 500,000 entry の ZIP（KAITOKIT_ZIP_SCALE_PROBE）を開く時間を local header の遅延読み（lazy）と一括読み（eager）で、
/// 続けて全 entry の `rawRecord(of:)` を引く時間を測り、中央値と読み出し回数・byte 数を `KAITOKIT-PROBE` 行で出す
/// （KAITOKIT_ZIP_SCALE_PROBE_OPEN_ONLY=1 なら lazy の open だけを 15 回）。公開 API だけを使うので、
/// このファイルと Support/ZipScaleProbeSource.swift を過去の版へ写して同じ条件で比べられる。
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
