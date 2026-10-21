import Foundation
import XCTest
@testable import KaitoKit

final class RAR5HeaderWalkReadTests: XCTestCase {
    private func generated(count: Int, size: Int, encrypted: Bool = false) throws -> Data {
        try RAR5TestSupport.requireRAR()
        let directory = try TarTestSupport.temporaryDirectory()
        let names = (0..<count).map { "entry-\($0).bin" }
        for name in names { try Data(repeating: 73, count: size).write(to: directory.appendingPathComponent(name)) }
        let archive = directory.appendingPathComponent("archive.rar")
        try RAR5TestSupport.makeGeneratedArchive(sourceDirectory: directory, paths: names, archiveURL: archive,
            options: ["-qo-", "-m0"] + (encrypted ? ["-hpsecret"] : []))
        return try Data(contentsOf: archive)
    }
    func testQuickOpenlessSmallMemberArchiveCoalescesReads() throws {
        let source = CallCountingByteSource(DataByteSource(try generated(count: 300, size: 3072)), reportsNonLocalVolume: true)
        let reader = try RAR5Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 300)
        XCTAssertLessThanOrEqual(source.readCount, 8)
    }
    func testQuickOpenlessLargeMemberArchiveReadsHeadersOnly() throws {
        let source = CallCountingByteSource(DataByteSource(try generated(count: 40, size: 600 << 10)), reportsNonLocalVolume: true)
        let reader = try RAR5Reader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 40)
        XCTAssertLessThanOrEqual(source.readCount, 44)
        XCTAssertLessThanOrEqual(source.readBytes, 40 * (16 << 10) + (1 << 20))
    }
    func testHeaderEncryptedArchiveListingUnchanged() throws {
        let bytes = try generated(count: 10, size: 3072, encrypted: true)
        let low = try RAR5Reader(source: DataByteSource(bytes), options: ReaderOptions(password: "secret"))
        let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
        let high = try RAR5Reader(source: source, options: ReaderOptions(password: "secret"))
        XCTAssertEqual(low.entries, high.entries)
        XCTAssertLessThanOrEqual(source.readCount, 4)
        for entry in high.entries { XCTAssertEqual(try high.stream(for: entry, limits: ReadLimits()).readAll(), Data(repeating: 73, count: 3072)) }
    }
    func testWindowIsReleasedAfterOpen() throws {
        let holder = WeakHeaderWindow()
        let bytes = RAR5TestSupport.archive(blocks: [RAR5TestSupport.storedFile(name: "a", contents: Data([42]))])
        let reader = try HeaderWindowByteSource.$testingDidCreate.withValue({ holder.set($0) }) {
            try RAR5Reader(source: DataByteSource(bytes), options: ReaderOptions())
        }
        XCTAssertTrue(holder.wasCreated)
        XCTAssertNil(holder.value)
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), Data([42]))
    }
}

private final class WeakHeaderWindow: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: HeaderWindowByteSource?
    private var created = false
    var value: HeaderWindowByteSource? { lock.withLock { stored } }
    var wasCreated: Bool { lock.withLock { created } }
    func set(_ value: HeaderWindowByteSource) { lock.withLock { stored = value; created = true } }
}
