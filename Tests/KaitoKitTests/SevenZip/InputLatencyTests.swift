import Foundation
import XCTest
@testable import KaitoKit

final class InputLatencyTests: XCTestCase {
    func testDefaultIsAutomatic() { XCTAssertEqual(ReaderOptions().inputLatency, .automatic) }
    func testDataResolvesLow() throws {
        let source = DataByteSource(SevenZipParallelTestSupport.raw().archive())
        XCTAssertEqual(ReaderOptions().resolvedInputLatency(for: source), .low)
        XCTAssertFalse(try SevenZipReader(source: source, options: ReaderOptions()).avoidsHeaderScans)
        _ = try ArchiveReader.open(data: SevenZipParallelTestSupport.raw().archive())
    }
    func testLocalFileResolvesLow() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try SevenZipParallelTestSupport.raw().archive().write(to: url)
        let source = try FileByteSource(url: url)
        XCTAssertEqual(ReaderOptions().resolvedInputLatency(for: source), .low)
    }
    func testNonLocalOverrideResolvesHigh() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try SevenZipParallelTestSupport.raw().archive().write(to: url)
        let source = try FileByteSource.$testingVolumeIsLocal.withValue({ _ in false }) { try FileByteSource(url: url) }
        XCTAssertEqual(ReaderOptions().resolvedInputLatency(for: source), .high)
        XCTAssertTrue(try SevenZipReader(source: source, options: ReaderOptions()).avoidsHeaderScans)
    }
    func testBoundedRebasedConcatenatedForward() throws {
        let base = CallCountingByteSource(DataByteSource(SevenZipParallelTestSupport.raw().archive()), reportsNonLocalVolume: true)
        let bounded = try BoundedByteSource(source: base, baseOffset: 0, length: base.length)
        let rebased = try RebasedByteSource(source: bounded, baseOffset: 0)
        let joined = try ConcatenatedByteSource(segments: [SourceSegment(source: rebased, offset: 0, length: base.length)], maximumLength: base.length, label: "test")
        XCTAssertEqual(ReaderOptions().resolvedInputLatency(for: joined), .high)
    }
    func testExplicitValueWins() {
        for value in [InputLatency.low, .high] {
            for hint in [false, true] {
                var options = ReaderOptions(); options.inputLatency = value
                let base = CallCountingByteSource(DataByteSource(data: Data()), reportsNonLocalVolume: hint)
                XCTAssertEqual(options.resolvedInputLatency(for: base), value)
            }
        }
    }
    func testReopenKeepsSnapshot() throws {
        let local = DataByteSource(SevenZipParallelTestSupport.raw().archive())
        let hinted = CallCountingByteSource(local, reportsNonLocalVolume: true)
        let snapshot = ReaderOptions().resolvingInputLatency(for: hinted)
        XCTAssertEqual(snapshot.resolvedInputLatency(for: local), .high)
        let reader = try SevenZipReader(source: local, options: snapshot)
        let reopened = try XCTUnwrap(reader.reopened(options: snapshot) as? SevenZipReader)
        XCTAssertTrue(reopened.avoidsHeaderScans)
    }
}
