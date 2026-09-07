import Foundation
import KaitoKit
import XCTest

final class ReaderAggregateLimitTests: XCTestCase {
    func testDefaultTotalUncompressedLimitIs64GiB() {
        XCTAssertEqual(
            ReadLimits().maxTotalUncompressedSize,
            64 * 1_024 * 1_024 * 1_024
        )
    }

    func testAggregateDeclaredSizeIsEnforcedAtOpen() throws {
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "first.bin",
                uncompressedData: Data(repeating: 0x11, count: 5)
            ),
            HandZipEntry(
                name: "second.bin",
                uncompressedData: Data(repeating: 0x22, count: 7)
            ),
        ])

        var exact = ReadLimits()
        exact.maxTotalUncompressedSize = 12
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: exact)
        )
        XCTAssertEqual(reader.entries.count, 2)

        var tooSmall = exact
        tooSmall.maxTotalUncompressedSize = 11
        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(limits: tooSmall)
            )
        ) { error in
            guard case .limitExceeded(let reason) = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "total uncompressed size")
        }
    }

    func testAggregateDeclaredSizeOverflowIsReportedAsLimitExceeded() throws {
        let oversized = UInt64.max / 2 + 1
        let zip64Size = try ZipTestSupport.zip64Extra(values: [oversized])
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(
                name: "first.bin",
                centralExtra: zip64Size,
                centralUncompressedSize: UInt32.max
            ),
            HandZipEntry(
                name: "second.bin",
                centralExtra: zip64Size,
                centralUncompressedSize: UInt32.max
            ),
        ])
        let limits = ReadLimits(
            maxEntrySize: UInt64.max,
            maxTotalUncompressedSize: UInt64.max
        )

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }
    }

    func testUnknownSizesAreChargedOncePerEntryAndReopenHasAnIndependentBudget() throws {
        let firstPayload = Data("1234".utf8)
        let secondPayload = Data("5678".utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "first.bin",
                contents: firstPayload,
                fileFlags: 0x0008
            ),
            RAR5TestSupport.storedFile(
                name: "second.bin",
                contents: secondPayload,
                fileFlags: 0x0008
            ),
        ])
        var limits = ReadLimits()
        limits.maxTotalUncompressedSize = 6
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )
        XCTAssertEqual(reader.entries.map(\.uncompressedSize), [nil, nil])

        XCTAssertEqual(try reader.read(reader.entries[0]), firstPayload)
        XCTAssertEqual(try reader.read(reader.entries[0]), firstPayload)
        XCTAssertThrowsError(try reader.read(reader.entries[1])) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }

        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[1]), secondPayload)
    }

    func testUnknownStreamCapsCallerBufferAndMakesExceededBudgetTerminal() throws {
        let payloads = ["1234", "5678", "WXYZ"].map { Data($0.utf8) }
        let archive = RAR5TestSupport.archive(blocks: payloads.enumerated().map { index, payload in
            RAR5TestSupport.storedFile(
                name: "entry-\(index).bin",
                contents: payload,
                fileFlags: 0x0008
            )
        })
        var limits = ReadLimits()
        limits.maxTotalUncompressedSize = 6
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )

        XCTAssertEqual(try reader.read(reader.entries[0]), payloads[0])

        let stream = try reader.stream(reader.entries[1])
        var buffer = [UInt8](repeating: 0xCC, count: 16)
        let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(buffer.prefix(count)), Array("56".utf8))
        XCTAssertTrue(buffer.dropFirst(count).allSatisfy { $0 == 0xCC })

        XCTAssertThrowsError(
            try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }
        XCTAssertThrowsError(try reader.stream(reader.entries[2])) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }
    }

    func testKnownAndUnknownEntriesShareOneAggregateBudget() throws {
        let known = Data("1234".utf8)
        let unknown = Data("567".utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(name: "known.bin", contents: known),
            RAR5TestSupport.storedFile(
                name: "unknown.bin",
                contents: unknown,
                fileFlags: 0x0008
            ),
        ])
        var limits = ReadLimits()
        limits.maxTotalUncompressedSize = 6
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )

        XCTAssertEqual(try reader.read(reader.entries[0]), known)
        let stream = try reader.stream(reader.entries[1])
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(
            try buffer.withUnsafeMutableBytes { try stream.read(into: $0) },
            2
        )
        XCTAssertThrowsError(
            try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
        ) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }
    }

    func testInterleavedReplaysCanEndExactlyAtAggregateBoundary() throws {
        let payload = Data("123456".utf8)
        let archive = RAR5TestSupport.archive(blocks: [
            RAR5TestSupport.storedFile(
                name: "replayed.bin",
                contents: payload,
                fileFlags: 0x0008
            ),
            RAR5TestSupport.storedFile(
                name: "later.bin",
                contents: Data("X".utf8),
                fileFlags: 0x0008
            ),
        ])
        var limits = ReadLimits()
        limits.maxTotalUncompressedSize = UInt64(payload.count)
        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(limits: limits)
        )

        let first = try reader.stream(reader.entries[0])
        let replay = try reader.stream(reader.entries[0])
        var prefix = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(
            try prefix.withUnsafeMutableBytes { try first.read(into: $0) },
            prefix.count
        )
        XCTAssertEqual(Data(prefix), payload.prefix(3))
        XCTAssertEqual(try replay.readAll(), payload)
        XCTAssertEqual(try first.readAll(), payload.dropFirst(3))

        XCTAssertThrowsError(try reader.read(reader.entries[1])) { error in
            XCTAssertEqual(
                error as? KaitoError,
                .limitExceeded("total uncompressed size")
            )
        }
    }
}
