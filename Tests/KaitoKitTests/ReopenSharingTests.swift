import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ReopenSharingTests: XCTestCase {
    private let payload = Data("payload".utf8)

    func testZIPReopenShares10kParsedEntries() throws {
        let bytes = try ZipTestSupport.makeArchive(entries: (0..<10_000).map {
            HandZipEntry(name: "entry-\($0)", uncompressedData: payload)
        })
        try checkReopen(bytes, format: .zip, count: 10_000, expected: payload)
    }

    func testZIPReopenShares100kParsedEntries() throws {
        let start = ContinuousClock.now
        let bytes = try ZipTestSupport.makeZIP64ManyEmptyArchive(entryCount: 100_000)
        #if DEBUG
        if start.duration(to: .now) > .seconds(10) {
            throw XCTSkip("100k ZIP fixture construction exceeded 10 seconds in Debug")
        }
        #endif
        try checkReopen(bytes, format: .zip, count: 100_000, expected: Data())
    }

    func testTarReopenSharesParsedEntries() throws {
        let bytes = try TarTestSupport.makeTar(entries: (0..<10_000).map {
            HandTarEntry(name: "entry-\($0)", contents: payload)
        })
        try checkReopen(bytes, format: .tar, count: 10_000, expected: payload)
    }

    func testLHAReopenSharesParsedEntries() throws {
        let bytes = try LHATestSupport.makeArchive(entries: (0..<10_000).map {
            HandLHAEntry(name: "entry-\($0)", contents: payload, headerLevel: 2)
        })
        try checkReopen(bytes, format: .lha, count: 10_000, expected: payload)
    }

    private func checkReopen(_ bytes: Data, format: ArchiveFormat, count: Int, expected: Data,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let source = CountingByteSource(DataByteSource(bytes))
        let start = ContinuousClock.now
        let reader = try ArchiveReader.open(source: source)
        let openTime = start.duration(to: .now)
        XCTAssertEqual(reader.format, format, file: file, line: line)
        XCTAssertEqual(reader.entries.count, count, file: file, line: line)
        // Populate the original's first-member cache before measuring reopen.
        XCTAssertEqual(try reader.read(reader.entries[0]), expected, file: file, line: line)
        source.reset()
        let reopenStart = ContinuousClock.now
        let reopened = try reader.reopen()
        let reopenTime = reopenStart.duration(to: .now)
        print("K9 TIMING \(format) entries=\(count) open_ms=\(milliseconds(openTime)) reopen_ms=\(milliseconds(reopenTime)) bytes=\(source.bytesRead)")
        XCTAssertEqual(source.bytesRead, 0, "\(format) reopen must share parsed state without source reads", file: file, line: line)
        // Record the relative improvement, but allow a generous absolute bound
        // on loaded Debug runners instead of a flaky per-call ratio assertion.
        XCTAssertLessThan(reopenTime, .milliseconds(50), "\(format) reopen must finish within 50 ms", file: file, line: line)
        XCTAssertEqual(reopened.entries, reader.entries, file: file, line: line)
        XCTAssertEqual(reopened.nameEncoding, reader.nameEncoding, file: file, line: line)
        XCTAssertEqual(try reopened.read(reopened.entries[0]), expected, file: file, line: line)
        XCTAssertEqual(try reader.read(reader.entries[0]), expected, file: file, line: line)
        source.reset()
        let again = try reopened.reopen()
        XCTAssertEqual(source.bytesRead, 0, "\(format) successive reopen must not parse", file: file, line: line)
        XCTAssertEqual(try again.read(again.entries[count - 1]), expected, file: file, line: line)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    func testZIPReopenHasFreshLocalCachesAndCarriesCurrentPassword() throws {
        let source = CountingByteSource(DataByteSource(try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "a", uncompressedData: payload, hasDataDescriptor: true)
        ])))
        let reader = try ArchiveReader.open(source: source)
        XCTAssertNotNil(try reader.rawRecord(of: reader.entries[0]))
        source.reset()
        let reopened = try reader.reopen()
        XCTAssertEqual(source.bytesRead, 0, "ZIP cached-reader reopen must not read headers")
        source.reset()
        XCTAssertNotNil(try reopened.rawRecord(of: reopened.entries[0]))
        XCTAssertGreaterThan(source.bytesRead, 0, "reopened ZIP must validate its own local records and descriptors")
        source.reset()
        XCTAssertNotNil(try reader.rawRecord(of: reader.entries[0]))
        XCTAssertEqual(source.bytesRead, 0, "reopen must leave the original ZIP local/raw caches intact")

        for fixture in ["xz-aes.zip", "xz-zipcrypto.zip"] {
            let encryptedSource = CountingByteSource(DataByteSource(try ModernZIPFixtures.data(fixture)))
            let original = try ArchiveReader.open(source: encryptedSource,
                options: ReaderOptions(password: ModernZIPFixtures.password))
            XCTAssertEqual(try original.read(original.entries[0]), ModernZIPFixtures.payload)
            encryptedSource.reset()
            let correct = try original.reopen()
            XCTAssertEqual(encryptedSource.bytesRead, 0, "encrypted ZIP reopen must not parse")
            XCTAssertEqual(correct.password, ModernZIPFixtures.password)
            original.password = "wrong"
            let wrong = try original.reopen()
            XCTAssertEqual(wrong.password, "wrong")
            XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
            XCTAssertEqual(try correct.read(correct.entries[0]), ModernZIPFixtures.payload)
            original.password = ModernZIPFixtures.password
            let restored = try original.reopen()
            XCTAssertEqual(try restored.read(restored.entries[0]), ModernZIPFixtures.payload)
            XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
        }
    }

    func testSevenZipSolidReopenStartsIndependentCoordinator() throws {
        try checkSevenZip(solid: true)
    }

    func testSevenZipNonSolidReopenHasFreshPackVerification() throws {
        try checkSevenZip(solid: false)
    }

    private func checkSevenZip(solid: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = CountingByteSource(DataByteSource(sevenZipFixture(solid: solid)))
        let reader = try ArchiveReader.open(source: source)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(reader.entries[0].solidGroup >= 0, solid)
        let active = try reader.stream(reader.entries[0])
        var prefix = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(try prefix.withUnsafeMutableBytes { try active.read(into: $0) }, 3)
        XCTAssertEqual(prefix, [0x41, 0x41, 0x41])
        source.reset()
        let reopened = try reader.reopen()
        XCTAssertEqual(source.bytesRead, 0, "7z \(solid ? "solid" : "non-solid") reopen must not parse", file: file, line: line)
        XCTAssertEqual(reader.entries, reopened.entries)
        if !solid {
            source.reset()
            XCTAssertEqual(try reopened.read(reopened.entries[0]), Data(repeating: 0x41, count: 32))
            XCTAssertEqual(source.bytesRead, 64,
                           "reopened 7z must have a fresh packed-stream verifier")
        }
        // The clone starts from an empty coordinator/verifier cache. Reading
        // its last member must not invalidate or advance the original stream.
        XCTAssertEqual(try reopened.read(reopened.entries[1]), Data(repeating: 0x42, count: 16))
        XCTAssertGreaterThan(source.bytesRead, 0)
        XCTAssertEqual(try active.readAll(), Data(repeating: 0x41, count: 29))
        XCTAssertEqual(try reader.read(reader.entries[1]), Data(repeating: 0x42, count: 16))
        XCTAssertEqual(try reopened.read(reopened.entries[0]), Data(repeating: 0x41, count: 32))
        source.reset()
        let again = try reopened.reopen()
        XCTAssertEqual(source.bytesRead, 0, "7z successive reopen must not parse", file: file, line: line)
        XCTAssertEqual(try again.read(again.entries[0]), Data(repeating: 0x41, count: 32))
    }

    private func sevenZipFixture(solid: Bool) -> Data {
        let a = [UInt8](repeating: 0x41, count: 32), b = [UInt8](repeating: 0x42, count: 16)
        let packs = solid ? [[1, 0, 47] + a + b + [0]] : [a, b]
        var header: [UInt8] = [0x01, 0x04, 0x06, 0, UInt8(packs.count), 0x09]
        header += packs.map { UInt8($0.count) }
        header += [0x0A, 1]
        for pack in packs { header += littleEndian(CRC32.checksum(pack)) }
        header += [0, 0x07, 0x0B, UInt8(packs.count), 0]
        header += solid ? [1, 0x21, 0x21, 1, 0] : [1, 1, 0, 1, 1, 0]
        header += [0x0C] + (solid ? [48] : [32, 16]) + [0]
        if solid { header += [0x08, 0x0D, 2, 0x09, 32, 0] }
        header += [0, 0x05, 2, 0x11, 9, 0, 0x61, 0, 0, 0, 0x62, 0, 0, 0, 0, 0]
        let packed = packs.flatMap { $0 }
        let start = littleEndian(UInt64(packed.count)) + littleEndian(UInt64(header.count)) + littleEndian(CRC32.checksum(header))
        return Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4]
            + littleEndian(CRC32.checksum(start)) + start + packed + header)
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    func testSevenZipEncryptedReopenRetainsPasswordWithFreshKeys() throws {
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "k9-password")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SevenZipTestSupport.write(payload, relativePath: "entry", below: directory)
        for encryptedHeader in [false, true] {
            let url = directory.appendingPathComponent("archive-\(encryptedHeader).7z")
            try SevenZipTestSupport.makeArchive(sourceDirectory: directory, paths: ["entry"], archiveURL: url,
                options: ["-m0=Copy", "-psecret", "-mhe=\(encryptedHeader ? "on" : "off")"])
            let source = CountingByteSource(try FileByteSource(url: url))
            let derivations = Mutex(0)
            try SevenZipAESKeyCache.$didDeriveKey.withValue({ derivations.withLock { $0 += 1 } }) {
                let reader = try ArchiveReader.open(source: source, options: ReaderOptions(password: "secret"))
                XCTAssertEqual(try reader.read(reader.entries[0]), payload)
                let before = derivations.withLock { $0 }
                source.reset()
                let reopened = try reader.reopen()
                XCTAssertEqual(source.bytesRead, 0, "encrypted 7z reopen must reuse its parsed header")
                XCTAssertEqual(derivations.withLock { $0 }, before, "7z reopen must not derive header keys")
                XCTAssertEqual(reopened.password, "secret")
                XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
                XCTAssertGreaterThan(derivations.withLock { $0 }, before, "reopened 7z must derive its own entry keys")
                let after = derivations.withLock { $0 }
                XCTAssertEqual(try reader.read(reader.entries[0]), payload)
                XCTAssertEqual(derivations.withLock { $0 }, after, "original 7z key cache must remain warm")
                reader.password = "wrong"
                let wrong = try reader.reopen()
                XCTAssertEqual(wrong.password, "wrong")
                XCTAssertThrowsError(try wrong.read(wrong.entries[0])) { XCTAssertEqual($0 as? KaitoError, .wrongPassword) }
                reader.password = nil
                let locked = try reader.reopen()
                XCTAssertNil(locked.password)
                XCTAssertThrowsError(try locked.read(locked.entries[0])) { XCTAssertEqual($0 as? KaitoError, .passwordRequired) }
                reader.password = "secret"
                XCTAssertEqual(try reader.reopen().read(reader.entries[0]), payload)
                XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
            }
        }
    }

    func testDocumentationRecordsK9SharingAndTimings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let record = try String(contentsOf: root.appendingPathComponent("Documentation/verification/2026-09-19-release-review.md"), encoding: .utf8)
        XCTAssertTrue(changelog.contains("（K9）"), "Unreleased must document K9 parsed-state sharing")
        XCTAssertTrue(record.contains("## K9."), "verification record must cover K9 and reopen timings")
    }
}
