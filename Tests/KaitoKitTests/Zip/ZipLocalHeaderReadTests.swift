import Foundation
import XCTest
@testable import KaitoKit

final class ZipLocalHeaderReadTests: XCTestCase {
    func testLastOfTwoHundredStoredEntriesUsesOneHeaderReadPerEntry() throws {
        let extra = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data(repeating: 0, count: 12))
        let payload = Data(repeating: 0x56, count: 16384)
        let bytes = try ZipTestSupport.makeArchive(entries: (0..<200).map {
            HandZipEntry(name: "page-\($0).jpg", uncompressedData: payload, localExtra: extra, centralExtra: extra)
        })
        let source = CallCountingByteSource(DataByteSource(bytes))
        let reader = try ZipReader(source: source, options: ReaderOptions())
        XCTAssertEqual(reader.entries.count, 200)
        source.reset()
        let stream = try reader.stream(for: reader.entries[199], limits: ReadLimits())
        print("ZIP-LOCAL-HEADERS reads=\(source.readCount) bytes=\(source.readBytes)")
        XCTAssertEqual(source.readCount, 200)
        XCTAssertEqual(try stream.readAll(), payload)
    }

    func testDifferentLocalLengthsAndCorruptionKeepValidation() throws {
        let short = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data([1]))
        let long = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data(repeating: 2, count: 40))
        for (local, central) in [(short, long), (long, short)] {
            let payload = Data(repeating: 0x37, count: 8192)
            let bytes = try ZipTestSupport.makeArchive(entries: (0..<3).map {
                HandZipEntry(name: "entry-\($0)", uncompressedData: payload, localExtra: local, centralExtra: central)
            })
            let layout = try ZipTestSupport.layout(of: bytes)
            let source = CallCountingByteSource(DataByteSource(bytes))
            let reader = try ZipReader(source: source, options: ReaderOptions())
            source.reset()
            let stream = try reader.stream(for: reader.entries[2], limits: ReadLimits())
            XCTAssertEqual(source.readCount, local.count <= central.count ? 3 : 6)
            XCTAssertEqual(try stream.readAll(), payload)
            var corrupt = bytes
            corrupt[layout.localHeaderOffsets[0]] ^= 1
            let damaged = try ZipReader(source: DataByteSource(corrupt), options: ReaderOptions())
            XCTAssertThrowsError(try damaged.stream(for: damaged.entries[2], limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, .malformed("invalid ZIP local-header signature"))
            }
        }
    }

    func testLocalNameCanBeLongerOrShorterThanCentralName() throws {
        let extra = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data([7, 8]))
        let payload = Data(repeating: 0x45, count: 8192)
        for name in ["x", "a-much-longer-central-name"] {
            var bytes = try ZipTestSupport.makeArchive(entries: [
                HandZipEntry(name: "local-name", uncompressedData: payload, localExtra: extra, centralExtra: extra)
            ])
            let layout = try ZipTestSupport.layout(of: bytes)
            let central = layout.centralEntryOffsets[0]
            let centralName = Data(name.utf8)
            bytes.replaceSubrange(central + 46..<central + 56, with: centralName)
            try ZipTestSupport.writeUInt16(UInt16(centralName.count), to: &bytes, at: central + 28)
            try ZipTestSupport.writeUInt32(UInt32(layout.centralDirectorySize + centralName.count - 10),
                                          to: &bytes, at: bytes.count - 10)
            let source = CallCountingByteSource(DataByteSource(bytes))
            let reader = try ZipReader(source: source, options: ReaderOptions())
            XCTAssertEqual(reader.entries[0].name, name)
            source.reset()
            let stream = try reader.stream(for: reader.entries[0], limits: ReadLimits())
            XCTAssertEqual(source.readCount, name == "x" ? 2 : 1)
            XCTAssertEqual(try stream.readAll(), payload)
        }
    }

    func testCombinedReadStopsAtNextRecordAndSpeculativeFailureFallsBack() throws {
        let short = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data([1]))
        let long = try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data(repeating: 0, count: 1000))
        let bytes = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first", localExtra: short, centralExtra: long),
            HandZipEntry(name: "second", uncompressedData: Data([0x67]), localExtra: short, centralExtra: short),
        ])
        let layout = try ZipTestSupport.layout(of: bytes)
        let source = ZipWindowTestSource(DataByteSource(bytes))
        let reader = try ZipReader(source: source, options: ReaderOptions(), readAhead: .disabled)
        source.reset()
        _ = try reader.stream(for: reader.entries[0], limits: ReadLimits())
        XCTAssertEqual(source.reads, [0..<UInt64(layout.localHeaderOffsets[1])])

        let payload = Data(repeating: 0x71, count: 8192)
        let mismatched = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "payload", uncompressedData: payload, localExtra: short, centralExtra: long)
        ])
        let failing = ZipWindowTestSource(DataByteSource(mismatched))
        let fallbackReader = try ZipReader(source: failing, options: ReaderOptions(), readAhead: .disabled)
        failing.reset(fault: .throwLarge)
        let stream = try fallbackReader.stream(for: fallbackReader.entries[0], limits: ReadLimits())
        XCTAssertEqual(failing.reads.map(\.count), [1041, 30, 5])
        failing.reset()
        XCTAssertEqual(try stream.readAll(), payload)
    }
}
