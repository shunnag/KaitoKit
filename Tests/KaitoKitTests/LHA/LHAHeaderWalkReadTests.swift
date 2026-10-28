import Foundation
import XCTest
@testable import KaitoKit

final class LHAHeaderWalkReadTests: XCTestCase {
    func testFarApartMembersUseOneBoundedWindowEach() throws {
        let payload = Data(repeating: 0x52, count: 600 << 10)
        let bytes = try LHATestSupport.makeArchive(entries: (0..<40).map {
            HandLHAEntry(name: "page-\($0).jpg", contents: payload, headerLevel: 2)
        })
        var expected: [ArchiveEntry]?
        for high in [false, true] {
            let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: high)
            let reader = try LHAReader(source: source, options: ReaderOptions())
            print("LHA-HEADERS high=\(high) reads=\(source.readCount) bytes=\(source.readBytes)")
            XCTAssertEqual(source.readCount, 41)
            XCTAssertEqual(source.readBytes, 40 * (16 << 10) + 1)
            for (index, range) in source.readRanges.enumerated() {
                XCTAssertTrue(source.readRanges.prefix(index).allSatisfy { !$0.overlaps(range) })
            }
            XCTAssertEqual(reader.entries.count, 40)
            if let expected { XCTAssertEqual(reader.entries, expected) }
            expected = reader.entries
            XCTAssertEqual(try reader.stream(for: reader.entries[39], limits: ReadLimits()).readAll(), payload)
        }
    }

    func testHighLatencyCoalescesDenseHeadersAndHonorsExplicitPolicy() throws {
        let bytes = try LHATestSupport.makeArchive(entries: (0..<500).map {
            HandLHAEntry(name: "small-\($0)", contents: Data(repeating: 0x18, count: 4096), headerLevel: 2)
        })
        var counts: [Int] = []
        var expected: [ArchiveEntry]?
        for latency in [InputLatency.low, .high, .automatic] {
            let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
            var options = ReaderOptions()
            options.inputLatency = latency
            let reader = try LHAReader(source: source, options: options)
            counts.append(source.readCount)
            if let expected { XCTAssertEqual(reader.entries, expected) }
            expected = reader.entries
        }
        XCTAssertLessThan(counts[1], counts[0] / 4)
        XCTAssertEqual(counts[1], counts[2])
    }

    func testHeaderAcrossWindowBoundaryDoesNotRereadPayload() throws {
        for level: UInt8 in 0...3 {
            let empty = HandLHAEntry(name: "first", headerLevel: level)
            let headerSize = try LHATestSupport.makeMember(empty).count
            let bytes = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(name: "first", contents: Data(repeating: 0x28, count: (16 << 10) - 10 - headerSize), headerLevel: level),
                HandLHAEntry(name: "second", contents: Data(repeating: 0x61, count: 2 << 20), headerLevel: level),
            ])
            for latency in [InputLatency.low, .high] {
                let source = CallCountingByteSource(DataByteSource(bytes))
                var options = ReaderOptions()
                options.inputLatency = latency
                let reader = try LHAReader(source: source, options: options)
                XCTAssertEqual(reader.entries.map(\.name), ["first", "second"])
                let ranges = source.readRanges
                for (index, range) in ranges.enumerated() {
                    XCTAssertTrue(ranges.prefix(index).allSatisfy { !$0.overlaps(range) }, "level=\(level) latency=\(latency)")
                }
            }
        }
    }

    func testFrozenFixturesHaveIdenticalListingsAndErrorsAtBothLatencies() throws {
        for fixture in try LHAFrozenFixtures.all() where fixture.storage == "archive" {
            let bytes = try LHAFrozenFixtures.bytes(fixture)
            for corrupt in [false, true] {
                var variant = bytes
                if corrupt, variant.count > 20 { variant[20] = 4 }
                var listings: [[ArchiveEntry]?] = []
                var errors: [String?] = []
                for latency in [InputLatency.low, .high] {
                    var options = ReaderOptions()
                    options.inputLatency = latency
                    do {
                        let reader = try ArchiveReader.open(data: variant, options: options)
                        listings.append(reader.entries)
                        errors.append(nil)
                    } catch {
                        listings.append(nil)
                        errors.append(String(reflecting: error))
                    }
                }
                XCTAssertEqual(listings[0], listings[1], "\(fixture.name) corrupt=\(corrupt)")
                XCTAssertEqual(errors[0], errors[1], "\(fixture.name) corrupt=\(corrupt)")
            }
        }
    }

    func testAllHeaderLevelsAndCorruptVariantsMatchAcrossLatencies() throws {
        for level: UInt8 in 0...3 {
            let bytes = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(name: "first", contents: Data([1, 2, 3]), headerLevel: level),
                HandLHAEntry(name: "last", contents: Data([4, 5]), headerLevel: level),
            ])
            var badLevel = bytes
            badLevel[20] = 4
            var badChecksum = bytes
            badChecksum[15] ^= 1
            for variant in [bytes, badLevel, badChecksum, Data(bytes.prefix(20)), Data(bytes.dropLast(3))] {
                for recovery in [false, true] {
                    var listings: [[ArchiveEntry]?] = []
                    var errors: [String?] = []
                    for latency in [InputLatency.low, .high] {
                        var options = ReaderOptions(recoverDamagedArchives: recovery)
                        options.inputLatency = latency
                        do {
                            let reader = try LHAReader(source: DataByteSource(variant), options: options)
                            listings.append(reader.entries)
                            errors.append(nil)
                        } catch {
                            listings.append(nil)
                            errors.append(String(reflecting: error))
                        }
                    }
                    XCTAssertEqual(listings[0], listings[1], "level=\(level) recovery=\(recovery)")
                    XCTAssertEqual(errors[0], errors[1], "level=\(level) recovery=\(recovery)")
                }
            }
        }
    }
}
