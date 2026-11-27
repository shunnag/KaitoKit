import Foundation
@testable import KaitoKit
import XCTest

final class ArchiveExpansionLimitTests: XCTestCase {
    func testCeilingUsesAllowanceRatioAndAbsoluteLimitWithoutOverflow() {
        var options = ReaderOptions(limits: ReadLimits(maxTotalUncompressedSize: 12))
        options.expansionLimit = .init(minimumAllowance: 3, maximumRatio: 2)
        XCTAssertEqual(options.outputLimit(forInputBytes: 0), 3)
        XCTAssertEqual(options.outputLimit(forInputBytes: 5), 10)
        XCTAssertEqual(options.outputLimit(forInputBytes: .max), 12)
    }

    func testDeclaredAndUnknownOutputAndReopenedReaderUseSameCeiling() throws {
        let payload = Data([1, 2, 3, 4])
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "four", contents: payload)])
        var options = ReaderOptions()
        options.expansionLimit = .init(minimumAllowance: 3, maximumRatio: 0)
        XCTAssertThrowsError(try ArchiveReader.open(data: tar, options: options))
        let unknown = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "file", contents: payload, fileFlags: 0x0008)
        ])
        let reader = try ArchiveReader.open(data: unknown, options: options)
        for copy in [reader, try reader.reopen(), try reader.reopen(parallelDecodeMemory: 1024)] {
            XCTAssertEqual(copy.maximumTotalOutputSize, 3)
            XCTAssertThrowsError(try copy.read(copy.entries[0])) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("total uncompressed size"))
            }
        }
        options.expansionLimit = .init(minimumAllowance: 4, maximumRatio: 0)
        let exact = try ArchiveReader.open(data: tar, options: options)
        XCTAssertEqual(try exact.read(exact.entries[0]), payload)
    }

    func testCompressedTarBoundsTheStagedEnvelopeBeforePublishingEntries() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "a", contents: Data([1]))])
        let url = directory.appendingPathComponent("example.tar.gz")
        let gzip = try CompressedTarFramingTestSupport.gzip(tar).data
        try gzip.write(to: url)
        var options = ReaderOptions()
        options.expansionLimit = .init(minimumAllowance: UInt64(tar.count - 1), maximumRatio: 0)
        XCTAssertThrowsError(try ArchiveReader.open(url: url, options: options)) {
            guard case .limitExceeded = $0 as? KaitoError else { return XCTFail("\($0)") }
        }
        options.expansionLimit = .init(minimumAllowance: UInt64(tar.count), maximumRatio: 0)
        let reader = try ArchiveReader.open(url: url, options: options)
        XCTAssertEqual(reader.entries.map(\.name), ["a"])
        XCTAssertEqual(try reader.reopen().maximumTotalOutputSize, UInt64(tar.count))
    }
}
