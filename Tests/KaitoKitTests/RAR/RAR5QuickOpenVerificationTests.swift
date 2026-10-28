import Foundation
import XCTest
@testable import KaitoKit

final class RAR5QuickOpenVerificationTests: XCTestCase {
    typealias Q = RAR5QuickOpenTestSupport
    private func lie(_ body: (inout [UInt8], Q.Fields) throws -> Void) throws -> RAR5Reader {
        var f = try Q.fixture()
        try f.changeHeader(0) { header in try body(&header, Q.fields(header)) }
        let reader = try Q.reader(f.data())
        XCTAssertEqual(reader.guardedHeaderCountForTesting, 3)
        return reader
    }
    func testSameLengthRenamedCopyFailsBeforeAnyByte() throws {
        Q.assertMismatch(try lie { h, f in h[f.name.lowerBound] = 120 })
    }
    func testChangedDataCRCFailsAsQuickOpenMismatchNotChecksumMismatch() throws {
        Q.assertMismatch(try lie { h, f in h[try XCTUnwrap(f.crc)] ^= 1 })
    }
    func testChangedSizeOrMethodFailsBeforeDecoding() throws {
        Q.assertMismatch(try lie { h, f in h[f.unpacked] += 1 })
        var f = try Q.fixture(blocks: [RAR5TestSupport.storedFile(name: "data", contents: Data([0]), compressionInfo: 128)])
        try f.changeHeader(0) { h in let fields = try Q.fields(h); h[fields.method + 1] = 3 }
        Q.assertMismatch(try Q.reader(f.data()))
    }
    func testFlippedSolidFlagFailsForTargetAndDrainedMembers() throws {
        let url = try Q.generated(options: ["-qo+", "-s", "-m3", "-md128k"])
        let original = try Q.decode(Data(contentsOf: url))
        for index in [1, 2] {
            var f = original
            try f.changeHeader(index) { h in let fields = try Q.fields(h); h[fields.method] ^= 64 }
            let reader = try Q.reader(f.data())
            XCTAssertGreaterThan(reader.guardedHeaderCountForTesting, 0)
            Q.assertMismatch(reader, index: index == 1 ? 3 : 2)
        }
    }
    func testSolidMemberDisguisedAsDirectoryOrServiceFailsClosed() throws {
        let url = try Q.generated(options: ["-qo+", "-s", "-m3", "-md128k"])
        let original = try Q.decode(Data(contentsOf: url))
        var directory = original
        try directory.changeHeader(1) { header in let fields = try Q.fields(header); header[fields.fileFlags] |= 1 }
        Q.assertMismatch(try Q.reader(directory.data()), index: 3)
        var service = original
        try service.changeHeader(1) { header in
            let fields = try Q.fields(header)
            header[fields.type] = 3
            header[fields.method] &= ~UInt8(64)
        }
        try Q.assertMatches(service.data())
        XCTAssertEqual(try Q.reader(service.data()).guardedHeaderCountForTesting, 0)
    }
    func testChangedEncryptionRecordFailsBeforeKeyDerivation() throws {
        var extra = [UInt8](repeating: 0, count: 35)
        extra[2] = 24
        var f = try Q.fixture(blocks: [RAR5TestSupport.storedFile(name: "data", contents: Data(repeating: 0, count: 32), extra: RAR5TestSupport.extraRecord(type: 1, payload: extra))])
        try f.changeHeader(0) { h in h[h.count - 1] ^= 1 }
        Q.assertMismatch(try Q.reader(f.data()))
    }
    private func redirected(_ type: UInt64, target: String, name: String, size: UInt64) -> Data {
        let extra = RAR5TestSupport.extraRecord(type: 5, payload: RAR5TestSupport.vint(type) + [0] + RAR5TestSupport.vint(UInt64(target.utf8.count)) + Array(target.utf8))
        return RAR5TestSupport.storedFile(name: name, contents: Data(), unpackedSize: size, includeCRC32: false, extra: extra)
    }
    func testChangedSymlinkTargetFails() throws {
        var f = try Q.fixture(blocks: [redirected(1, target: "abc", name: "link", size: 3)])
        try f.changeHeader(0) { h in h[h.count - 1] = 120 }
        Q.assertMismatch(try Q.reader(f.data()))
    }
    func testFileCopyWhoseTargetCopyLiesFails() throws {
        let blocks = [RAR5TestSupport.storedFile(name: "original", contents: Data([1, 2, 3])), redirected(5, target: "original", name: "copy", size: 3)]
        for rename in [false, true] {
            var f = try Q.fixture(blocks: blocks)
            try f.changeHeader(0) { h in
                let fields = try Q.fields(h)
                h[rename ? fields.name.lowerBound : try XCTUnwrap(fields.crc)] ^= 1
            }
            Q.assertMismatch(try Q.reader(f.data()), index: 1)
        }
    }
    func testProbeRenamedNonTargetRedirectsResolvedFileCopy() throws {
        let blocks = [
            RAR5TestSupport.storedFile(name: "x", contents: Data([1, 2, 3])),
            RAR5TestSupport.storedFile(name: "x", contents: Data([4, 5, 6])),
            redirected(5, target: "x", name: "c", size: 3),
        ]
        var fixture = try Q.fixture(blocks: blocks)
        try fixture.changeHeader(1) { header in
            let fields = try Q.fields(header)
            header[fields.name.lowerBound] = UInt8(ascii: "y")
        }
        let full = try Q.reader(fixture.data(), policy: .never)
        let fullBytes = try full.stream(for: full.entries[2], limits: ReadLimits()).readAll()
        XCTAssertEqual(full.entries[2].formatSpecific["fileCopyTargetIndex"], "1")
        XCTAssertEqual(fullBytes, Data([4, 5, 6]))

        let quick = try Q.reader(fixture.data())
        XCTAssertEqual(quick.guardedHeaderCountForTesting, 3)
        XCTAssertEqual(quick.entries[2].formatSpecific["fileCopyTargetIndex"], "0")
        do {
            let bytes = try quick.stream(for: quick.entries[2], limits: ReadLimits()).readAll()
            XCTAssertEqual(bytes, fullBytes)
        } catch {
            XCTAssertEqual(error as? KaitoError, .malformed(Q.mismatchPrefix
                + String(quick.headerOffsetForTesting(entry: quick.entries[1]))))
        }
    }
    func testLyingLaterCopyCannotRedirectHardLink() throws {
        for hidesMatch in [false, true] {
            let blocks = [
                RAR5TestSupport.storedFile(name: "x", contents: Data([1, 2, 3])),
                RAR5TestSupport.storedFile(name: hidesMatch ? "x" : "y", contents: Data([4, 5, 6])),
                redirected(4, target: "x", name: "h", size: 0),
            ]
            var fixture = try Q.fixture(blocks: blocks)
            try fixture.changeHeader(1) { header in
                let fields = try Q.fields(header)
                header[fields.name.lowerBound] = UInt8(ascii: hidesMatch ? "y" : "x")
            }
            let full = try Q.reader(fixture.data(), policy: .never)
            let quick = try Q.reader(fixture.data())
            XCTAssertEqual(quick.guardedHeaderCountForTesting, 3)
            XCTAssertEqual(full.entries[2].formatSpecific["hardLinkTargetIndex"], hidesMatch ? "1" : "0")
            XCTAssertEqual(quick.entries[2].formatSpecific["hardLinkTargetIndex"], hidesMatch ? "0" : "1")
            let expected = KaitoError.malformed(Q.mismatchPrefix
                + String(quick.headerOffsetForTesting(entry: quick.entries[1])))
            XCTAssertThrowsError(try quick.stream(for: quick.entries[2], limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, expected)
            }
            XCTAssertThrowsError(try quick.stream(for: quick.entries[0], limits: ReadLimits())) {
                XCTAssertEqual($0 as? KaitoError, expected)
            }
        }
    }
    func testUnresolvedHardLinkVerifiesEarlierCopies() throws {
        var fixture = try Q.fixture(blocks: [
            RAR5TestSupport.storedFile(name: "x", contents: Data([1])),
            redirected(4, target: "x", name: "h", size: 0),
        ])
        try fixture.changeHeader(0) { header in
            let fields = try Q.fields(header)
            header[fields.name.lowerBound] = UInt8(ascii: "y")
        }
        let quick = try Q.reader(fixture.data())
        XCTAssertNil(quick.entries[1].formatSpecific["hardLinkTargetIndex"])
        Q.assertMismatch(quick, index: 1)
    }
    func testSecondVolumeSplitFragmentCopyIsVerified() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        let data = Data(repeating: 74, count: 64)
        let firstBlock = RAR5TestSupport.storedFile(name: "split", contents: data.prefix(32), unpackedSize: 64, headerFlags: 16)
        let lastBlock = RAR5TestSupport.storedFile(name: "split", contents: data.suffix(32), unpackedSize: 64, dataCRC32: CRC32.checksum(data), headerFlags: 8)
        let first = try Q.fixture(blocks: [firstBlock], mainFlags: 1, endFlags: 1)
        var last = try Q.fixture(blocks: [lastBlock], mainFlags: 3, volumeNumber: 1)
        try last.changeHeader(0) { h in let fields = try Q.fields(h); h[try XCTUnwrap(fields.crc)] ^= 1 }
        let url = directory.appendingPathComponent("archive.part1.rar")
        try first.data().write(to: url)
        try last.data().write(to: directory.appendingPathComponent("archive.part2.rar"))
        let opened = try FileByteSource.openAnchored(url: url)
        let reader = try RAR5Reader(source: opened.source, options: Q.options(), sourceURL: url, sourceDirectoryAnchor: opened.directory)
        XCTAssertEqual(reader.guardedHeaderCountForTesting, 2)
        Q.assertMismatch(reader)
    }
    func testTimestampOnlyChangeFails() throws {
        let extra = RAR5TestSupport.extraRecord(type: 3, payload: [3, 0, 1, 0, 0])
        var f = try Q.fixture(blocks: [RAR5TestSupport.storedFile(name: "data", contents: Data([1]), extra: extra)])
        try f.changeHeader(0) { h in h[h.count - 1] ^= 1 }
        Q.assertMismatch(try Q.reader(f.data()))
    }
    func testMismatchPoisonsReaderAndReopenedReaders() throws {
        let reader = try lie { h, f in h[f.name.lowerBound] = 120 }
        let reopened = try XCTUnwrap(reader.reopened(options: Q.options()))
        Q.assertMismatch(reader)
        let expected = KaitoError.malformed(Q.mismatchPrefix + String(reader.headerOffsetForTesting(entry: reader.entries[0])))
        for index in reader.entries.indices {
            XCTAssertThrowsError(try reader.stream(for: reader.entries[index], limits: ReadLimits())) { XCTAssertEqual($0 as? KaitoError, expected) }
            XCTAssertThrowsError(try reopened.stream(for: reopened.entries[index], limits: ReadLimits())) { XCTAssertEqual($0 as? KaitoError, expected) }
        }
    }
    func testPrefetchedMemberWithLyingCopyIsNeverServed() throws {
        let url = try Q.generated(count: 8, options: ["-qo+", "-m3", "-md128k"])
        var f = try Q.decode(Data(contentsOf: url))
        try f.changeHeader(3) { h in let fields = try Q.fields(h); h[fields.name.upperBound - 1] = 120 }
        var options = Q.options(); options.decodeThreads = 4
        let reader = try RAR5Reader(source: DataByteSource(f.data()), options: options)
        _ = try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll()
        reader.prefetcherForTesting?.waitForScheduledBatchesForTesting()
        Q.assertMismatch(reader, index: 3)
    }
    func testPlantedHeaderResidualFailsWhenLiarIsRead() throws {
        var f = try Q.fixture(count: 2, size: 10)
        let first = try Q.fields(f.records[0].header)
        let skipped = f.blocks[1].count
        f.records[0].header[try XCTUnwrap(first.dataSize)] += UInt8(skipped)
        Q.repairCRC(&f.records[0].header)
        f.records.removeLast()
        let reader = try Q.reader(f.data())
        XCTAssertEqual(reader.entries.count, 1)
        Q.assertMismatch(reader)
    }
    func testVerificationIsPrimedAndAddsNoReadCall() throws {
        let data = try Q.fixture(count: 300, size: 4096).data()
        let a = CallCountingByteSource(DataByteSource(data)), b = CallCountingByteSource(DataByteSource(data))
        let full = try RAR5Reader(source: a, options: Q.options(.never))
        let quick = try RAR5Reader(source: b, options: Q.options())
        a.reset(); b.reset()
        for entry in full.entries { _ = try full.stream(for: entry, limits: ReadLimits()).readAll() }
        for entry in quick.entries { _ = try quick.stream(for: entry, limits: ReadLimits()).readAll() }
        XCTAssertLessThanOrEqual(b.readCount, a.readCount)
    }
    func testEachFragmentIsVerifiedOnce() throws {
        let f = try Q.fixture()
        let source = QOProbeSource(f.data())
        let reader = try RAR5Reader(source: source, options: Q.options())
        let before = source.requests.filter { $0.offset == f.mainEnd }.count
        for _ in 0..<3 { _ = try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll() }
        XCTAssertEqual(source.requests.filter { $0.offset == f.mainEnd }.count - before, 1)
    }
    func testIOErrorDuringVerificationDoesNotPoison() throws {
        let f = try Q.fixture()
        let source = QOProbeSource(f.data())
        let reader = try RAR5Reader(source: source, options: Q.options())
        source.fail(at: f.mainEnd)
        XCTAssertThrowsError(try reader.stream(for: reader.entries[0], limits: ReadLimits())) { XCTAssertEqual($0 as? KaitoError, .io(5)) }
        source.fail(at: nil)
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll().count, 32)
    }
    func testConcurrentReopenedReadersVerifyConsistently() async throws {
        let reader = try Q.reader(Q.fixture(count: 40).data())
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                guard let reopened = reader.reopened(options: Q.options()) else { throw KaitoError.unsupportedFormat }
                group.addTask {
                    var count = 0
                    for entry in reopened.entries { count += try reopened.stream(for: entry, limits: ReadLimits()).readAll().count }
                    return count
                }
            }
            for try await count in group { XCTAssertEqual(count, 40 * 32) }
        }
    }
    func testConcurrentReopenedReadersShareFirstPoison() async throws {
        let reader = try lie { h, fields in h[fields.name.lowerBound] = 120 }
        let expected = KaitoError.malformed(Q.mismatchPrefix + String(reader.headerOffsetForTesting(entry: reader.entries[0])))
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                guard let reopened = reader.reopened(options: Q.options()) else { throw KaitoError.unsupportedFormat }
                group.addTask {
                    do { _ = try reopened.stream(for: reopened.entries[0], limits: ReadLimits()); return false }
                    catch { return error as? KaitoError == expected }
                }
            }
            for try await consistent in group { XCTAssertTrue(consistent) }
        }
        Q.assertMismatch(reader, index: 2)
    }
    func testPrefetchSpanIncludesHeadersAndVerifiesWithoutExtraReads() throws {
        let f = try Q.fixture()
        let data = f.data()
        let directory = try TarTestSupport.temporaryDirectory()
        let url = directory.appendingPathComponent("span.rar")
        try data.write(to: url)
        let file = try FileByteSource(url: url)
        let probe = QOProbeSource(data)
        let reader = try RAR5Reader(source: probe, options: Q.options())
        let members = reader.recordsForTesting.enumerated().map { index, record in
            let segment = record.packedSegments[0]
            return IndependentEntryPrefetcher.Candidate(index: index, outputSize: 32, scratchBytes: 0,
                packedSegment: SourceSegment(source: file, offset: segment.offset, length: segment.length),
                headerOffset: record.headerOffset)
        }
        let span = try XCTUnwrap(PrefetchedPackedSpan.read(members: members))
        XCTAssertTrue(span.covers(f.mainEnd, length: UInt64(f.records[0].header.count)))
        let before = probe.requests.count
        for record in reader.recordsForTesting { _ = try record.verifyingHeaders(span: span) }
        XCTAssertEqual(probe.requests.count, before)
    }
    func testExtractorAndCLIKeepNeverPolicy() throws {
        XCTAssertEqual(ReaderOptions().rar5QuickOpenPolicy, .never)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/kaito", "Sources/KaitoKit/Reader/Extractor.swift"] {
            let url = root.appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            if url.pathExtension == "swift" {
                XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("rar5QuickOpenPolicy ="))
            } else if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let file as URL in enumerator where file.pathExtension == "swift" {
                    XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("rar5QuickOpenPolicy ="))
                }
            }
        }
    }
    func testGuardBytesAreChargedToRetainedMetadata() throws {
        let data = try Q.fixture(count: 1).data()
        var low: UInt64 = 1, high: UInt64 = 4096
        while low < high {
            let middle = (low + high) / 2
            var options = Q.options(.never); options.limits.maxTotalMetadataSize = middle
            if (try? RAR5Reader(source: DataByteSource(data), options: options)) != nil { high = middle }
            else { low = middle + 1 }
        }
        var options = Q.options(); options.limits.maxTotalMetadataSize = low
        let reader = try RAR5Reader(source: DataByteSource(data), options: options)
        XCTAssertEqual(reader.guardedHeaderCountForTesting, 0)
        options.limits.maxTotalMetadataSize = low + 1024
        XCTAssertEqual(try RAR5Reader(source: DataByteSource(data), options: options).guardedHeaderCountForTesting, 1)
    }
}
