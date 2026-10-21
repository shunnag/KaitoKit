import Foundation
import XCTest
@testable import KaitoKit

final class VolumeLocalityHintTests: XCTestCase {
    private func file() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        return url
    }
    func testTemporaryFileIsLocal() throws {
        XCTAssertFalse(byteSourceIsOnNonLocalVolume(try FileByteSource(url: file())))
    }
    func testHintCapturedAtOpenNotPerRead() throws {
        let counter = HintCounter()
        let url = try file()
        let source = try FileByteSource.$testingVolumeIsLocal.withValue({ _ in counter.increment(); return false }) {
            try FileByteSource(url: url, accessPolicy: .bounded)
        }
        XCTAssertEqual(counter.value, 1)
        for _ in 0..<3 { _ = try readByteRange(source: source, offset: 0, count: 1) }
        XCTAssertEqual(counter.value, 1)
        FileAccessPolicy.releaseIdleCachedHandles()
        let renamed = url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: url, to: renamed)
        for _ in 0..<10 { XCTAssertTrue(byteSourceIsOnNonLocalVolume(source)) }
        XCTAssertEqual(counter.value, 1)
        XCTAssertThrowsError(try readByteRange(source: source, offset: 0, count: 1))
    }
    func testBoundedRebasedConcatenatedForwardHint() throws {
        let source = CallCountingByteSource(DataByteSource(data: Data([1, 2, 3])), reportsNonLocalVolume: true)
        let bounded = try BoundedByteSource(source: source, baseOffset: 0, length: 2)
        let rebased = try RebasedByteSource(source: bounded, baseOffset: 1)
        let joined = try ConcatenatedByteSource(segments: [SourceSegment(source: rebased, offset: 0, length: 1)], maximumLength: 100, label: "test")
        for view: any ByteSource in [bounded, rebased, joined] { XCTAssertTrue(byteSourceIsOnNonLocalVolume(view)) }
    }
    func testDataByteSourceIsLocal() {
        XCTAssertFalse(byteSourceIsOnNonLocalVolume(DataByteSource(data: Data())))
    }
}

private final class HintCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
