import Foundation
import XCTest
@testable import KaitoKit

final class RAR5QuickOpenNegativeTests: XCTestCase {
    typealias Q = RAR5QuickOpenTestSupport
    private func fallback(_ fixture: Q.Fixture, limits: ReadLimits? = nil, label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var fullOptions = Q.options(.never), quickOptions = Q.options()
        if let limits { fullOptions.limits = limits; quickOptions.limits = limits }
        let data = fixture.data()
        let full = try RAR5Reader(source: DataByteSource(data), options: fullOptions)
        let quick = try RAR5Reader(source: DataByteSource(data), options: quickOptions)
        XCTAssertEqual(full.entries, quick.entries, label, file: file, line: line)
        XCTAssertEqual(quick.guardedHeaderCountForTesting, 0, label, file: file, line: line)
    }
    func testInvalidLocatorsFallBack() throws {
        let original = try Q.fixture()
        for (label, offset) in [("zero", UInt64(0)), ("EOF", UInt64(original.data().count - 8)), ("main", 1), ("file", original.mainEnd - 8)] {
            var f = original; f.locatorOffset = offset
            try fallback(f, label: label)
        }
        for (label, bytes) in [("overflow", [UInt8(1)] + Array(repeating: 255, count: 11)), ("absent bit", [0, 0]), ("cut record", [1, 128])] {
            var f = original; f.locatorBytes = bytes
            try fallback(f, label: label)
        }
    }
    // 偽の service は member データに置く。実ヘッダの検査に影響させず locator だけを細工する。
    private func plantedService(_ candidate: Q.Fixture, metadataLimit: UInt64 = 1 << 20) throws {
        let candidateData = candidate.data()
        let layouts = try RAR5TestSupport.blockLayouts(in: Array(candidateData))
        let qo = layouts[layouts.count - 2]
        let candidateBlock = Data(candidateData[qo.offset..<qo.data.upperBound])
        let payload = Data(repeating: 0, count: 80 << 10) + candidateBlock
        var base = try Q.fixture(blocks: [RAR5TestSupport.storedFile(name: "safe", contents: payload)])
        let file = try RAR5TestSupport.blockLayouts(in: Array(RAR5TestSupport.archive(blocks: base.blocks)))[1]
        let realFileHeaderSize = file.data.lowerBound - file.offset
        base.locatorOffset = base.mainEnd + UInt64(realFileHeaderSize + (80 << 10)) - 8
        // 実 QO は置かず、偽の service に向く主ヘッダだけを使う。
        let data = Data(RAR5Reader.signature) + base.main() + base.blocks[0] + RAR5TestSupport.block(type: 5, specific: [0])
        var a = Q.options(.never), b = Q.options()
        a.limits.maxMetadataSize = metadataLimit; b.limits.maxMetadataSize = metadataLimit
        let full = try RAR5Reader(source: DataByteSource(data), options: a)
        let quick = try RAR5Reader(source: DataByteSource(data), options: b)
        XCTAssertEqual(full.entries, quick.entries)
        XCTAssertEqual(quick.guardedHeaderCountForTesting, 0)
    }
    func testInvalidQuickOpenBlocksFallBack() throws {
        let original = try Q.fixture()
        let changes: [(String, (inout Q.Fixture) -> Void)] = [
            ("lowercase", { $0.qoName = "qo" }), ("long name", { $0.qoName = "QOX" }),
            ("method", { $0.qoMethod = 384 }), ("version", { $0.qoMethod = 1 }),
            ("solid", { $0.qoMethod = 64 }), ("encryption", { $0.qoExtra = RAR5TestSupport.extraRecord(type: 1) }),
            ("unpacked", { $0.unpackedDelta = 1 }), ("directory", { $0.qoFlags = 1 })
        ]
        for (_, change) in changes { var f = original; change(&f); try plantedService(f) }
        var large = original; large.dataOverride = Array(repeating: 0, count: 1024)
        try plantedService(large, metadataLimit: 128)
    }
    func testQuickOpenDataBeyondEOFFallsBack() throws {
        var f = try Q.fixture()
        let malformed = RAR5TestSupport.block(type: 3, flags: 2,
            specific: [0, 127, 0, 0, 0, 2, 81, 79], data: Data(repeating: 0, count: 127)).prefix(20)
        let suffix = f.blocks.reduce(Data(), +) + RAR5TestSupport.block(type: 5, specific: [0])
        // locator は end より後の、EOF で切れた偽 service に向く。
        f.locatorOffset = UInt64(f.main().count + suffix.count)
        let data = Data(RAR5Reader.signature) + f.main() + suffix + malformed
        try Q.assertMatches(data)
    }
    func testInvalidRecordsFallBack() throws {
        let original = try Q.fixture()
        let changes: [(String, (inout Q.Fixture) throws -> Void)] = [
            ("record CRC", { $0.records[0].corruptCRC = true }),
            ("flags", { $0.records[0].flags = 1 }),
            ("distance zero", { $0.records[0].distance = 0 }),
            ("distance before archive", { $0.records[0].distance = $0.qoOffset + 1 }),
            ("target inside main", { $0.records[0].distance = $0.qoOffset - $0.mainEnd + 1 }),
            ("header overlaps QO", { $0.records[0].distance = 1 }),
            ("data overlaps QO", { f in try f.changeHeader(2) { h in let fields = try Q.fields(h); h[try XCTUnwrap(fields.dataSize)] = 127 } }),
            ("duplicate target", { $0.records[1].distance = $0.records[0].distance }),
            ("decreasing target", { $0.records.swapAt(0, 1) }),
            ("length", { $0.records[0].length = 1 }),
            ("four byte size", { f in try f.changeHeader(0) { h in h[4] |= 128; h.insert(contentsOf: [128, 128, 0], at: 5) } }),
            ("small size", { f in try f.changeHeader(0) { h in h[4] = 1 } }),
            ("large size", { f in try f.changeHeader(0) { h in h[4] = 127 } }),
            ("inner CRC", { $0.records[0].header[0] ^= 1 }),
            ("inner main", { f in try f.changeHeader(0) { h in h[try Q.fields(h).type] = 1 } }),
            ("inner end", { f in try f.changeHeader(0) { h in h[try Q.fields(h).type] = 5 } }),
            ("inner encryption", { f in try f.changeHeader(0) { h in h[try Q.fields(h).type] = 4 } }),
            ("trailing byte", { $0.records[0].suffix = [0] }),
            ("truncated last", { $0.dataOverride = Array($0.records.flatMap { $0.encode() }.dropLast()) }),
            ("long record size", { f in var bytes = f.records[0].encode(); bytes[4] |= 128; bytes.insert(contentsOf: [128, 128, 128, 0], at: 5); f.dataOverride = bytes }),
            ("record exceeds data", { f in var bytes = f.records[0].encode(); bytes[4] = 127; f.dataOverride = bytes })
        ]
        for (label, change) in changes { var f = original; try change(&f); try fallback(f, label: label) }
        var capped = original
        capped.records = (0..<5).map { index in
            Q.Record(distance: capped.qoOffset - capped.mainEnd - UInt64(index), header: original.records[0].header)
        }
        var limits = ReadLimits(); limits.maxEntryCount = 3; limits.maxMetadataRecordCount = 1
        try fallback(capped, limits: limits, label: "record cap")
    }
    func testInconsistentChainsAndUnsafeNamesFallBack() throws {
        let original = try Q.fixture(count: 3, size: 32)
        var unconsumed = original; unconsumed.records[0].distance -= 1
        try fallback(unconsumed, label: "target in data")
        var skipped = original
        try skipped.changeHeader(0) { h in let fields = try Q.fields(h); h[try XCTUnwrap(fields.dataSize)] = 127 }
        try fallback(skipped, label: "skip next target")
        for (label, name) in [("traversal", Array("../x".utf8)), ("UTF8", [255, 255, 255, 255])] {
            var f = try Q.fixture(blocks: [RAR5TestSupport.storedFile(name: "safe", contents: Data([0]))])
            try f.changeHeader(0) { h in let fields = try Q.fields(h); h.replaceSubrange(fields.name, with: name) }
            try fallback(f, label: label)
        }
    }
    func testCorruptRealHeaderWithIntactCopyListsButFailsOnRead() throws {
        let f = try Q.fixture()
        var data = f.data(); data[Int(f.mainEnd)] ^= 1
        XCTAssertThrowsError(try Q.reader(data, policy: .never))
        let quick = try Q.reader(data)
        XCTAssertEqual(quick.entries.count, 3)
        Q.assertMismatch(quick)
    }
}
