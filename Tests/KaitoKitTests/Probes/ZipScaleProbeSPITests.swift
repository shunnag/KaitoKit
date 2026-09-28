import Foundation
@_spi(ZipRawLayout) internal import KaitoKit
import XCTest

/// ZipScaleProbeTests と同じ 500,000 entry の ZIP（KAITOKIT_ZIP_SCALE_PROBE、無ければ skip）で、SPI の
/// `zipRawRecordLayout(at:)` を全 entry に引く時間と読み出し回数・byte 数を `KAITOKIT-PROBE` 行で出す。
final class ZipScaleProbeSPITests: XCTestCase {
    func testScale() throws {
        let url = try ZipScaleProbeSource.corpus()
        var times: [Double] = []
        var counts: [ZipScaleProbeSource.Counts] = []
        for _ in 0..<5 {
            let source = try ZipScaleProbeSource(url)
            let reader = try ArchiveReader.open(source: source, options: ReaderOptions(appleDoublePolicy: .expose))
            source.reset()
            let start = ContinuousClock.now
            var end: UInt64 = 0
            for index in reader.entries.indices { end = try XCTUnwrap(reader.zipRawRecordLayout(at: index)).recordRange.upperBound }
            times.append(ZipScaleProbeSource.milliseconds(start.duration(to: .now)))
            XCTAssertEqual(end, source.localRange.upperBound)
            counts.append(source.counts)
        }
        ZipScaleProbeSource.report("spi_raw", times: times, counts: counts)
    }
}
