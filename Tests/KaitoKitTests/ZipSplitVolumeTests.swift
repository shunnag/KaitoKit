import CryptoKit
import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

// 公開 APPNOTE のフィールドだけを書き換え、任意のバイト位置で巻を区切る。
// 外部実装のソースは参照せず、既存の単巻 fixture を比較対象にする。
private struct ZipSplitFixture {
    var bytes: Data
    let layout: ZipFixtureLayout
    let starts: [Int]
    let urls: [URL]

    init(_ original: Data, below directory: URL, name: String = "split.zip",
         wide: Bool = false, sentinelDisk: Bool = false,
         boundaries: (ZipFixtureLayout) -> [Int]) throws {
        let originalLayout = try ZipTestSupport.layout(of: original)
        var bytes = Data([0x50, 0x4b, 0x07, 0x08])
        bytes.append(original[originalLayout.archiveBase..<originalLayout.centralDirectoryOffset])
        let cd = bytes.count
        var centralOffsets: [Int] = []
        var localOffsets: [Int] = []
        var wideFields: [Int?] = []
        for (index, entry) in originalLayout.centralEntryOffsets.enumerated() {
            let nameLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 28))
            let extraLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 30))
            let commentLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 32))
            let extraStart = entry + 46 + nameLength
            var record = Data(original[entry..<extraStart])
            let local = originalLayout.localHeaderOffsets[index] - originalLayout.archiveBase + 4
            localOffsets.append(local)
            var extra = Data(original[extraStart..<(extraStart + extraLength)])
            var offsetField: Int?
            if wide {
                // サイズ・位置の sentinel に応じる 0x0001 の順序を全幅の形で検証する。
                var old: Int = 0
                var preserved = Data()
                while old < extra.count {
                    let size = Int(try ZipTestSupport.readUInt16(extra, at: old + 2))
                    if try ZipTestSupport.readUInt16(extra, at: old) != 1 {
                        preserved.append(extra[old..<(old + 4 + size)])
                    }
                    old += 4 + size
                }
                var payload = Data()
                let reader = try ArchiveReader.open(data: original)
                let info = reader.entries[index]
                ZipTestSupport.appendUInt64(try XCTUnwrap(info.uncompressedSize), to: &payload)
                ZipTestSupport.appendUInt64(try XCTUnwrap(info.compressedSize), to: &payload)
                ZipTestSupport.appendUInt64(UInt64(local), to: &payload)
                ZipTestSupport.appendUInt32(0, to: &payload)
                offsetField = bytes.count + record.count + preserved.count + 4 + 16
                preserved.append(try ZipTestSupport.extraField(identifier: 1, payload: payload))
                extra = preserved
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 20)
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 24)
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 42)
                try ZipTestSupport.writeUInt16(.max, to: &record, at: 34)
            } else {
                try ZipTestSupport.writeUInt32(UInt32(local), to: &record, at: 42)
            }
            try ZipTestSupport.writeUInt16(UInt16(extra.count), to: &record, at: 30)
            centralOffsets.append(bytes.count)
            wideFields.append(offsetField)
            bytes.append(record)
            bytes.append(extra)
            bytes.append(original[(extraStart + extraLength)..<(extraStart + extraLength + commentLength)])
        }
        let cdSize = bytes.count - cd
        var zip64End: Int?
        var locator: Int?
        if wide || originalLayout.zip64EndRecordOffset != nil {
            zip64End = bytes.count
            ZipTestSupport.appendUInt32(0x0606_4b50, to: &bytes)
            ZipTestSupport.appendUInt64(44, to: &bytes)
            ZipTestSupport.appendUInt16(45, to: &bytes)
            ZipTestSupport.appendUInt16(45, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(centralOffsets.count), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(centralOffsets.count), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(cdSize), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(cd), to: &bytes)
            locator = bytes.count
            ZipTestSupport.appendUInt32(0x0706_4b50, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(zip64End!), to: &bytes)
            ZipTestSupport.appendUInt32(1, to: &bytes)
        }
        let end = bytes.count
        ZipTestSupport.appendUInt32(0x0605_4b50, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        ZipTestSupport.appendUInt16(UInt16(centralOffsets.count), to: &bytes)
        ZipTestSupport.appendUInt16(UInt16(centralOffsets.count), to: &bytes)
        ZipTestSupport.appendUInt32(UInt32(cdSize), to: &bytes)
        ZipTestSupport.appendUInt32(zip64End == nil ? UInt32(cd) : .max, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        let layout = ZipFixtureLayout(archiveBase: 0, centralDirectoryOffset: cd,
            centralDirectorySize: cdSize, centralEntryOffsets: centralOffsets,
            localHeaderOffsets: localOffsets, endRecordOffset: end,
            zip64EndRecordOffset: zip64End, zip64LocatorOffset: locator)
        let cuts = boundaries(layout)
        guard cuts == cuts.sorted(), cuts.allSatisfy({ $0 >= 0 && $0 <= (locator ?? end) }) else {
            throw ZipTestSupportError.fixture("invalid split boundaries")
        }
        let starts = [0] + cuts
        func disk(_ offset: Int) -> Int { starts.lastIndex(where: { $0 <= offset })! }
        let lastDisk = starts.count - 1
        let cdDisk = disk(cd)
        let entriesOnLastDisk = centralOffsets.filter { disk($0) == lastDisk }.count
        for (index, entry) in centralOffsets.enumerated() {
            let local = localOffsets[index]
            let number = disk(local)
            let relative = local - starts[number]
            if let field = wideFields[index] {
                try ZipTestSupport.writeUInt64(UInt64(relative), to: &bytes, at: field)
                try ZipTestSupport.writeUInt32(UInt32(number), to: &bytes, at: field + 8)
            } else {
                try ZipTestSupport.writeUInt32(UInt32(relative), to: &bytes, at: entry + 42)
                try ZipTestSupport.writeUInt16(UInt16(number), to: &bytes, at: entry + 34)
            }
        }
        try ZipTestSupport.writeUInt16(sentinelDisk ? .max : UInt16(lastDisk), to: &bytes, at: end + 4)
        try ZipTestSupport.writeUInt16(UInt16(cdDisk), to: &bytes, at: end + 6)
        try ZipTestSupport.writeUInt16(UInt16(entriesOnLastDisk), to: &bytes, at: end + 8)
        if let zip64End, let locator {
            try ZipTestSupport.writeUInt32(UInt32(lastDisk), to: &bytes, at: zip64End + 16)
            try ZipTestSupport.writeUInt32(UInt32(cdDisk), to: &bytes, at: zip64End + 20)
            try ZipTestSupport.writeUInt64(UInt64(entriesOnLastDisk), to: &bytes, at: zip64End + 24)
            try ZipTestSupport.writeUInt64(UInt64(cd - starts[cdDisk]), to: &bytes, at: zip64End + 48)
            let recordDisk = disk(zip64End)
            try ZipTestSupport.writeUInt32(UInt32(recordDisk), to: &bytes, at: locator + 4)
            try ZipTestSupport.writeUInt64(UInt64(zip64End - starts[recordDisk]), to: &bytes, at: locator + 8)
            try ZipTestSupport.writeUInt32(UInt32(starts.count), to: &bytes, at: locator + 16)
        } else {
            try ZipTestSupport.writeUInt32(UInt32(cd - starts[cdDisk]), to: &bytes, at: end + 16)
        }
        let naming = try XCTUnwrap(ZipSplitVolumeSet.naming(for: name))
        self.urls = starts.indices.map { index in
            directory.appendingPathComponent(index == lastDisk ? name
                : ZipSplitVolumeSet.volumeName(naming, number: UInt64(index + 1)))
        }
        self.bytes = bytes
        self.layout = layout
        self.starts = starts
        try write()
    }

    func write() throws {
        for index in urls.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            try Data(bytes[starts[index]..<end]).write(to: urls[index])
        }
    }
}

private final class ZipDiscoveryCountingSource: ByteSource {
    private let source: any ByteSource
    private let ranges = Mutex<[Range<UInt64>]>([])

    init(_ source: any ByteSource) { self.source = source }
    var length: UInt64 { source.length }
    var readRanges: [Range<UInt64>] { ranges.withLock { $0 } }

    func totalBytesRead() throws -> UInt64 {
        try readRanges.reduce(0) { try Checked.add($0, Checked.sub($1.upperBound, $1.lowerBound)) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try source.read(into: buffer, at: offset)
        let end = try Checked.add(offset, UInt64(count))
        ranges.withLock { $0.append(offset..<end) }
        return count
    }
}

final class ZipSplitVolumeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        try ZipTestSupport.temporaryDirectory(label: "zip-split")
    }

    private func archive() throws -> Data {
        try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first.bin", uncompressedData: Data((0..<7000).map { UInt8($0 % 251) })),
            HandZipEntry(name: "second.txt", uncompressedData: Data("分割巻のテスト\n".utf8))
        ])
    }

    private func assertContents(_ reader: ArchiveReader, equalTo original: Data, password: String? = nil, expectRaw: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try ArchiveReader.open(data: original, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.format, .zip, file: file, line: line)
        XCTAssertEqual(reader.entries.map(\.name), expected.entries.map(\.name), file: file, line: line)
        for (actualEntry, expectedEntry) in zip(reader.entries, expected.entries) {
            let actual = try reader.read(actualEntry)
            let data = try expected.read(expectedEntry)
            XCTAssertEqual(actual, data, file: file, line: line)
            XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: data), file: file, line: line)
            if expectRaw { XCTAssertNotNil(try reader.rawRecord(of: actualEntry), file: file, line: line) }
        }
    }

    private func assertMalformed(_ body: () throws -> Void, contains message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case let KaitoError.malformed(reason) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(message), reason, file: file, line: line)
        }
    }

    func testNamingAndHundredthVolume() throws {
        for name in ["a.zip", "a.ZIP", "a.zipx", "a.ZiPx", "a.z01", "a.z03", "a.z100", "a.ZX01", "a.zX03"] {
            XCTAssertNotNil(ZipSplitVolumeSet.naming(for: name), name)
        }
        for name in [".zip", ".z01", "a.z1", "a.z00", "a.z-01", "a.z１２", "a.z01x", "a.zip.001"] {
            XCTAssertNil(ZipSplitVolumeSet.naming(for: name), name)
        }
        XCTAssertEqual(ZipSplitVolumeSet.naming(for: "a.z18446744073709551616")?.openedNumber, .max)
        let naming = try XCTUnwrap(ZipSplitVolumeSet.naming(for: "comic.zip"))
        XCTAssertEqual(ZipSplitVolumeSet.volumeName(naming, number: 1), "comic.z01")
        XCTAssertEqual(ZipSplitVolumeSet.volumeName(naming, number: 99), "comic.z99")
        XCTAssertEqual(ZipSplitVolumeSet.volumeName(naming, number: 100), "comic.z100")
        XCTAssertEqual(ZipSplitVolumeSet.volumeName(naming, number: 106), "comic.z106")
    }

    func testXZAndLegacyZstandardAcrossZIP32AndZIP64Volumes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd20.zip", "zstd-aes20.zip"] {
            let original = try ModernZIPFixtures.data(name)
            let payload = try ModernZIPFixtures.payloadRange(original)
            for wide in [false, true] {
                // Split a local header, compressed/encrypted payload, and central record.
                let split = try ZipSplitFixture(original, below: directory, name: name,
                    wide: wide, sentinelDisk: wide) {
                    [12, payload.lowerBound + 4 + payload.count / 2, $0.centralDirectoryOffset + 17]
                }
                let options = ReaderOptions(password: ModernZIPFixtures.password)
                for volume in split.urls {
                    let reader = try ArchiveReader.open(url: volume, options: options)
                    XCTAssertEqual(try reader.read(reader.entries[0]), ModernZIPFixtures.payload)
                }
                let retained = try ArchiveReader.open(url: split.urls.last!, options: options)
                for url in split.urls { try FileManager.default.removeItem(at: url) }
                let reopened = try retained.reopen()
                XCTAssertEqual(try reopened.read(reopened.entries[0]), ModernZIPFixtures.payload)
            }
        }
    }

    func testZIP32LocalHeaderDataAndCentralDirectoryCrossBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let split = try ZipSplitFixture(original, below: directory) {
            [12, 2000, $0.centralDirectoryOffset + 17]
        }
        for index in [0, 2, 3] {
            XCTAssertEqual(try FormatDetector.detect(url: split.urls[index]), .zip)
            for lazy in [false, true] {
                var options = ReaderOptions()
                options.lazyLocalHeaders = lazy
                let reader = try ArchiveReader.open(url: split.urls[index], options: options)
                try assertContents(reader, equalTo: original)
                try assertContents(reader.reopen(), equalTo: original)
            }
        }
        let reader = try ArchiveReader.open(url: split.urls[0])
        for url in split.urls { try FileManager.default.removeItem(at: url) }
        try assertContents(reader.reopen(), equalTo: original)
    }

    func testZIP64ExtraDiskSentinelAndEndRecordOnEarlierDisk() throws {
        for sentinel in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = try archive()
            let split = try ZipSplitFixture(original, below: directory, wide: true, sentinelDisk: sentinel) {
                [200, $0.centralDirectoryOffset + 23, $0.zip64LocatorOffset!]
            }
            XCTAssertLessThan(split.layout.zip64EndRecordOffset!, split.starts.last!)
            for url in [split.urls[0], split.urls[2], split.urls.last!] {
                try assertContents(ArchiveReader.open(url: url), equalTo: original)
                XCTAssertEqual(try FormatDetector.detect(url: url), .zip)
            }
        }
    }

    func testAbsoluteOffsetsDetermineOrderingAcrossDisks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "padding", uncompressedData: Data(repeating: 1, count: 4963)),
            HandZipEntry(name: "disk-zero", uncompressedData: Data(repeating: 2, count: 600)),
            HandZipEntry(name: "disk-one", uncompressedData: Data(repeating: 3, count: 1000))
        ])
        let split = try ZipSplitFixture(original, below: directory) { [$0.localHeaderOffsets[2] - 100] }
        let firstOffset = try ZipTestSupport.readUInt32(split.bytes, at: split.layout.centralEntryOffsets[1] + 42)
        let secondOffset = try ZipTestSupport.readUInt32(split.bytes, at: split.layout.centralEntryOffsets[2] + 42)
        XCTAssertGreaterThan(firstOffset, secondOffset)
        XCTAssertEqual(secondOffset, 100)
        try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
    }

    func test101TinySegmentsAndZIPXCaseVariants() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        for name in ["small.zip", "upper.ZIP", "extended.zipx", "upperx.ZIPX"] {
            let split = try ZipSplitFixture(original, below: directory, name: name) { _ in
                (1...100).map { $0 * 20 }
            }
            XCTAssertEqual(split.urls.count, 101)
            for index in [0, 2, 99, 100] {
                try assertContents(ArchiveReader.open(url: split.urls[index]), equalTo: original)
            }
        }
    }

    func testSingleSegmentSpanningMarkersRemainOrdinaryZIP() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        var split = try ZipSplitFixture(original, below: directory) { _ in [] }
        for marker: UInt32 in [0x0807_4b50, 0x3030_4b50] {
            try ZipTestSupport.writeUInt32(marker, to: &split.bytes, at: 0)
            try split.write()
            try assertContents(ArchiveReader.open(url: split.urls[0]), equalTo: original)
            try assertContents(ArchiveReader.open(data: split.bytes), equalTo: original)
        }
        let stray = directory.appendingPathComponent("split.z01")
        try Data([1]).write(to: stray)
        assertMalformed({ _ = try ArchiveReader.open(url: stray) }, contains: "split.z01")
    }

    func testMissingMiddleLoneLastMissingLastAndStrayExtra() throws {
        for missing in [0, 1, 3] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let split = try ZipSplitFixture(archive(), below: directory) { _ in [100, 200, 300] }
            try FileManager.default.removeItem(at: split.urls[missing])
            let opening = missing == 3 ? split.urls[0] : split.urls[3]
            assertMalformed({ _ = try ArchiveReader.open(url: opening) }, contains: split.urls[missing].lastPathComponent)
            assertMalformed({ _ = try FormatDetector.detect(url: opening) }, contains: split.urls[missing].lastPathComponent)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let split = try ZipSplitFixture(original, below: directory) { _ in [100, 200, 300] }
        let extra = directory.appendingPathComponent("split.z08")
        try Data([1]).write(to: extra)
        try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        assertMalformed({ _ = try ArchiveReader.open(url: extra) }, contains: "split.z08")
        for url in split.urls.dropLast() { try FileManager.default.removeItem(at: url) }
        assertMalformed({ _ = try ArchiveReader.open(url: split.urls.last!) }, contains: "split.z01")
    }

    func testSymlinkedSiblingRejectedAndExplicitSymlinkDoesNotDiscover() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = try ZipSplitFixture(archive(), below: directory) { _ in [100, 200] }
        let saved = directory.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: split.urls[1], to: saved)
        try FileManager.default.createSymbolicLink(at: split.urls[1], withDestinationURL: saved)
        assertMalformed({ _ = try ArchiveReader.open(url: split.urls.last!) }, contains: "regular file")
        for index in [0, 2] {
            let link = directory.appendingPathComponent(index == 0 ? "link.z01" : "link.zip")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: split.urls[index])
            let opened = try FileByteSource.openAnchored(url: link)
            XCTAssertNil(try ZipSplitVolumeSet.assemble(url: link, source: opened.source,
                directory: opened.directory, limits: ReadLimits()))
            XCTAssertThrowsError(try ArchiveReader.open(url: link))
        }
        try FileManager.default.removeItem(at: split.urls.last!)
        try FileManager.default.createSymbolicLink(at: split.urls.last!, withDestinationURL: saved)
        assertMalformed({ _ = try ArchiveReader.open(url: split.urls[0]) }, contains: "regular file")
    }

    func testDeclaredVolumeLimitPrecedesSiblingOpens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var split = try ZipSplitFixture(archive(), below: directory, wide: true, sentinelDisk: true) { _ in [100, 200] }
        for maximum in [-1, 0, 1, 2, 3] {
            var limits = ReadLimits()
            limits.maxVolumeCount = maximum
            let options = ReaderOptions(limits: limits)
            if maximum < 3 {
                XCTAssertThrowsError(try ArchiveReader.open(url: split.urls.last!, options: options)) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP split volume count"))
                }
                XCTAssertThrowsError(try FormatDetector.detect(url: split.urls[0], options: options)) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP split volume count"))
                }
            } else { try assertContents(ArchiveReader.open(url: split.urls.last!, options: options), equalTo: archive()) }
        }
        try ZipTestSupport.writeUInt32(.max, to: &split.bytes, at: split.layout.zip64LocatorOffset! + 16)
        try split.write()
        // 開けない兄弟でも、宣言された巨大巻数のエラーが先に返ることを確認する。
        for url in split.urls.dropLast() { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: split.urls[0], withIntermediateDirectories: false)
        XCTAssertThrowsError(try ArchiveReader.open(url: split.urls.last!)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP split volume count"))
        }
    }

    func testByteSplit001KeepsPrecedenceAndDataHasNoSiblingDiscovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let first = directory.appendingPathComponent("foo.zip.001")
        try Data(original.prefix(123)).write(to: first)
        try Data(original.dropFirst(123)).write(to: directory.appendingPathComponent("foo.zip.002"))
        try assertContents(ArchiveReader.open(url: first), equalTo: original, expectRaw: false)
        let split = try ZipSplitFixture(original, below: directory) { _ in [200] }
        XCTAssertThrowsError(try ArchiveReader.open(data: Data(contentsOf: split.urls.last!))) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("spanned"))
        }
    }

    func testEmptyIntermediateSegmentsAndCheckedDiskBounds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let split = try ZipSplitFixture(original, below: directory) { _ in [100, 100, 200] }
        try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        try assertContents(ArchiveReader.open(url: split.urls[1]), equalTo: original)
        let layout = try ZipDiskLayout(lengths: [100, 0, 200])
        XCTAssertThrowsError(try layout.absoluteOffset(disk: 1, relative: 0))
        XCTAssertThrowsError(try layout.absoluteOffset(disk: .max, relative: 0))
        XCTAssertThrowsError(try layout.absoluteOffset(disk: 0, relative: 101))
        XCTAssertThrowsError(try ZipDiskLayout(lengths: [.max, 1]))
        XCTAssertThrowsError(try ZipDiskLayout(lengths: []))
    }

    func testDataDescriptorCrossesBoundaryAndRawRecordWorks() throws {
        for signature in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var entry = HandZipEntry(name: "descriptor", uncompressedData: Data(repeating: 7, count: 2000), hasDataDescriptor: true)
            entry.dataDescriptorHasSignature = signature
            let original = try ZipTestSupport.makeArchive(entries: [entry])
            let split = try ZipSplitFixture(original, below: directory) { [50, $0.centralDirectoryOffset - 6] }
            try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        }
    }

    func testZipCryptoPayloadCrossesBoundary() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.infoZipPath)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 9, count: 4000).write(to: directory.appendingPathComponent("encrypted"))
        _ = try ZipTestSupport.checkedRun(ZipTestSupport.infoZipPath,
            arguments: ["-q", "-0", "-P", "secret", "original.zip", "encrypted"], currentDirectory: directory)
        let original = try Data(contentsOf: directory.appendingPathComponent("original.zip"))
        let split = try ZipSplitFixture(original, below: directory) { _ in [100, 900] }
        let reader = try ArchiveReader.open(url: split.urls[0], options: ReaderOptions(password: "secret"))
        try assertContents(reader, equalTo: original, password: "secret")
        try assertContents(reader.reopen(), equalTo: original, password: "secret")
    }

    func testRecoveryOptionDoesNotRescanSplitPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        var split = try ZipSplitFixture(original, below: directory) { _ in [100] }
        var options = ReaderOptions()
        options.recoverDamagedArchives = true
        try assertContents(ArchiveReader.open(url: split.urls.last!, options: options), equalTo: original)
        try ZipTestSupport.writeUInt32(0, to: &split.bytes, at: split.layout.centralDirectoryOffset)
        try split.write()
        XCTAssertThrowsError(try ArchiveReader.open(url: split.urls.last!, options: options))
        var noEnd = split.bytes
        try ZipTestSupport.writeUInt32(0, to: &noEnd, at: split.layout.endRecordOffset)
        XCTAssertThrowsError(try ZipReader(source: DataByteSource(data: noEnd), options: options,
            diskLayout: ZipDiskLayout(lengths: [100, UInt64(noEnd.count - 100)])))
    }

    func testMalformedDiskFieldsOffsetsAndNonZIPAssembly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        for wide in [false, true] {
            let valid = try ZipSplitFixture(original, below: directory, wide: wide) { _ in [100, 200] }
            var mutations: [(Int, UInt64, Int)] = [
                (valid.layout.endRecordOffset + 6, 3, 2),
                (valid.layout.centralEntryOffsets[0] + 34, 3, 2)
            ]
            if wide {
                mutations += [(valid.layout.zip64LocatorOffset! + 4, 3, 4),
                              (valid.layout.zip64LocatorOffset! + 16, 2, 4),
                              (valid.layout.zip64LocatorOffset! + 8, .max, 8),
                              (valid.layout.zip64EndRecordOffset! + 16, 1, 4),
                              (valid.layout.zip64EndRecordOffset! + 20, 3, 4),
                              (valid.layout.zip64EndRecordOffset! + 48, .max, 8)]
            } else {
                mutations += [(valid.layout.centralEntryOffsets[0] + 42, 101, 4),
                              (valid.layout.endRecordOffset + 16, UInt64(valid.bytes.count), 4)]
            }
            for (offset, value, width) in mutations {
                var bad = valid
                switch width {
                case 2: try ZipTestSupport.writeUInt16(UInt16(value), to: &bad.bytes, at: offset)
                case 4: try ZipTestSupport.writeUInt32(UInt32(value), to: &bad.bytes, at: offset)
                default: try ZipTestSupport.writeUInt64(value, to: &bad.bytes, at: offset)
                }
                try bad.write()
                XCTAssertThrowsError(try ArchiveReader.open(url: bad.urls.last!), "offset \(offset)")
            }
        }
        var bad = try ZipSplitFixture(original, below: directory) { _ in [100] }
        // 非 ZIP の署名が優先された連結結果を別形式として返さない。
        bad.bytes.replaceSubrange(0..<8, with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4])
        try bad.write()
        assertMalformed({ _ = try ArchiveReader.open(url: bad.urls.last!) }, contains: "not a ZIP")
        assertMalformed({ _ = try FormatDetector.detect(url: bad.urls.last!) }, contains: "not a ZIP")
    }

    func testZIP64DiskOnlyExtraAndLayoutCandidateLimitChecks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extra = try ZipTestSupport.extraField(identifier: 1, payload: Data(repeating: 0, count: 4))
        let original = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "first", uncompressedData: Data(repeating: 1, count: 200)),
            HandZipEntry(name: "second", uncompressedData: Data([2]), centralExtra: extra)
        ])
        var split = try ZipSplitFixture(original, below: directory) { _ in [100] }
        let central = split.layout.centralEntryOffsets[1]
        try ZipTestSupport.writeUInt16(.max, to: &split.bytes, at: central + 34)
        try ZipTestSupport.writeUInt32(1, to: &split.bytes, at: central + 46 + 6 + 4)
        try split.write()
        try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        for wide in [false, true] {
            let set = try ZipSplitFixture(archive(), below: directory, wide: wide) { _ in [100] }
            var limits = ReadLimits()
            limits.maxEntryCount = 1
            XCTAssertThrowsError(try ArchiveReader.open(url: set.urls.last!, options: ReaderOptions(limits: limits))) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP entry count"))
            }
        }
    }

    func testZIP64ConsistencyMutationsAndNoSplitSFX() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let valid = try ZipSplitFixture(original, below: directory, wide: true) { _ in [100] }
        let end = valid.layout.endRecordOffset
        let record = valid.layout.zip64EndRecordOffset!
        let locator = valid.layout.zip64LocatorOffset!
        let mutations: [(Int, UInt64, Int)] = [
            (end + 4, 0, 2), (end + 8, 0, 2), (end + 10, 0, 2), (end + 12, 0, 4),
            (end + 16, 0, 4), (record + 4, .max, 8), (record + 48, 101, 8),
            (locator + 16, 0, 4)
        ]
        for (offset, value, width) in mutations {
            var bad = valid
            if width == 2 { try ZipTestSupport.writeUInt16(UInt16(value), to: &bad.bytes, at: offset) }
            else if width == 4 { try ZipTestSupport.writeUInt32(UInt32(value), to: &bad.bytes, at: offset) }
            else { try ZipTestSupport.writeUInt64(value, to: &bad.bytes, at: offset) }
            try bad.write()
            XCTAssertThrowsError(try ArchiveReader.open(url: bad.urls.last!), "offset \(offset)")
        }
        // ディスク基点への加算で SFX 相当のずれを補正しない。
        let zip32 = try ZipSplitFixture(original, below: directory) { _ in [100] }
        var shifted = zip32
        let field = zip32.layout.endRecordOffset + 16
        let offset = try ZipTestSupport.readUInt32(zip32.bytes, at: field)
        try ZipTestSupport.writeUInt32(offset - 4, to: &shifted.bytes, at: field)
        try shifted.write()
        XCTAssertThrowsError(try ArchiveReader.open(url: shifted.urls.last!))
    }

    func testZIP64DescriptorAndAESAcrossBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var entry = HandZipEntry(name: "wide-descriptor", uncompressedData: Data(repeating: 8, count: 300), hasDataDescriptor: true)
        entry.dataDescriptorUsesZIP64 = true
        entry.localExtra = try ZipTestSupport.extraField(identifier: 1, payload: Data())
        let original = try ZipTestSupport.makeArchive(entries: [entry], forceZIP64End: true)
        let split = try ZipSplitFixture(original, below: directory, wide: true) { [60, $0.centralDirectoryOffset - 10] }
        try assertContents(ArchiveReader.open(url: split.urls[0]), equalTo: original)
        try ZipTestSupport.requireExecutable(ZipTestSupport.sevenZipPath)
        try Data(repeating: 5, count: 4000).write(to: directory.appendingPathComponent("aes.bin"))
        let aesURL = directory.appendingPathComponent("aes.zip")
        try ZipTestSupport.makeSevenZip(sourceDirectory: directory, paths: ["aes.bin"],
            archiveURL: aesURL, method: "Copy", password: "secret")
        let aes = try Data(contentsOf: aesURL)
        let aesSplit = try ZipSplitFixture(aes, below: directory) { _ in [100, 900] }
        try assertContents(ArchiveReader.open(url: aesSplit.urls[0], options: ReaderOptions(password: "secret")),
            equalTo: aes, password: "secret")
    }

    func testOptionalZIP64LocatorAndFalseLocatorInSingleSFXComment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        var split = try ZipSplitFixture(original, below: directory, wide: true) { _ in [100] }
        let relative = try ZipTestSupport.readUInt64(split.bytes, at: split.layout.zip64EndRecordOffset! + 48)
        try ZipTestSupport.writeUInt32(UInt32(relative), to: &split.bytes, at: split.layout.endRecordOffset + 16)
        try split.write()
        try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)

        var single = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "file", uncompressedData: Data([1]))],
            prefix: ZipTestSupport.makePEPrefix(count: 128))
        let layout = try ZipTestSupport.layout(of: single)
        var comment = Data(repeating: 0, count: 20)
        try ZipTestSupport.writeUInt32(0x0706_4b50, to: &comment, at: 0)
        try ZipTestSupport.writeUInt32(.max, to: &comment, at: 16)
        single.insert(contentsOf: comment, at: layout.endRecordOffset)
        try ZipTestSupport.writeUInt16(20, to: &single, at: layout.centralEntryOffsets[0] + 32)
        try ZipTestSupport.writeUInt32(UInt32(layout.centralDirectorySize + 20), to: &single,
            at: layout.endRecordOffset + 20 + 12)
        let url = directory.appendingPathComponent("single-sfx.zip")
        try single.write(to: url)
        let plain = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "file", uncompressedData: Data([1]))])
        try assertContents(ArchiveReader.open(url: url), equalTo: plain)
    }

    func testTrailingEOCDCandidatesDoNotChangeVolumeDiscovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        for splitCount in [1, 2] {
            var split = try ZipSplitFixture(original, below: directory) { _ in splitCount == 1 ? [] : [100] }
            var fake = Data(split.bytes.suffix(22))
            try ZipTestSupport.writeUInt16(UInt16(2 - splitCount), to: &fake, at: 4)
            try ZipTestSupport.writeUInt16(UInt16(2 - splitCount), to: &fake, at: 6)
            try ZipTestSupport.writeUInt32(46, to: &fake, at: 12)
            try ZipTestSupport.writeUInt32(0, to: &fake, at: 16)
            split.bytes.append(fake)
            try split.write()
            try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        }
    }

    func testURLDiscoveryReadsOnlyStandardTailForPlainZIP() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "large.bin", uncompressedData: Data(repeating: 7, count: 2 * 1024 * 1024))
        ])
        let standardSize = UInt64(ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize)
        for name in ["plain.zip", "plain.zipx"] {
            let url = directory.appendingPathComponent(name)
            try original.write(to: url)
            let source = ZipDiscoveryCountingSource(try FileByteSource(url: url))
            // URL open と同じ探索 helper を計測し、reader 本体の索引読取は合算しない。
            XCTAssertEqual(try ZipEndRecords.lastDiskIndex(source: source, limits: ReadLimits()), 0)
            XCTAssertEqual(source.readRanges, [(try Checked.sub(source.length, standardSize))..<source.length])
            XCTAssertLessThanOrEqual(try source.totalBytesRead(), standardSize)
            try assertContents(ArchiveReader.open(url: url), equalTo: original)
        }
    }

    func testDiscoveryExpandsForTrailingDataAndRejectedStandardCandidate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let standardSize = UInt64(ZipEndRecords.endMinimumSize + ZipEndRecords.maximumCommentSize)
        for rejectedCandidate in [false, true] {
            var split = try ZipSplitFixture(original, below: directory) { _ in [100, 200] }
            split.bytes.append(Data(repeating: 0xa5, count: 120_000))
            if rejectedCandidate { split.bytes.append(try incoherentEndRecord()) }
            try split.write()
            let source = ZipDiscoveryCountingSource(try FileByteSource(url: split.urls.last!))
            XCTAssertEqual(try ZipEndRecords.lastDiskIndex(source: source, limits: ReadLimits()), 2)
            XCTAssertEqual(source.readRanges.first, (try Checked.sub(source.length, standardSize))..<source.length)
            XCTAssertTrue(source.readRanges.contains(0..<source.length))
            for url in [split.urls[0], split.urls.last!] {
                try assertContents(ArchiveReader.open(url: url), equalTo: original)
                XCTAssertEqual(try FormatDetector.detect(url: url), .zip)
            }
        }
    }

    func testOversizedTrailingDirectoryClaimsDoNotHideSplitArchive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try archive()
        let oversized = ReadLimits().maxTotalMetadataSize + 1
        for wide in [false, true] {
            var split = try ZipSplitFixture(original, below: directory, wide: wide) {
                [$0.centralDirectoryOffset + 1]
            }
            try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)

            // A coherent archive that exceeds the real limit must still fail.
            var limits = ReadLimits()
            limits.maxTotalMetadataSize = 16
            XCTAssertThrowsError(try ArchiveReader.open(
                url: split.urls.last!, options: ReaderOptions(limits: limits)
            )) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded(
                    "size \(split.layout.centralDirectorySize) exceeds limit 16"
                ))
            }

            let tailStart = split.layout.zip64EndRecordOffset ?? split.layout.endRecordOffset
            var fake = Data(split.bytes[tailStart...])
            let fakeEnd = split.layout.endRecordOffset - tailStart
            if wide {
                try ZipTestSupport.writeUInt64(oversized, to: &fake, at: 40)
                try ZipTestSupport.writeUInt32(.max, to: &fake, at: fakeEnd + 12)
                let locator = try XCTUnwrap(split.layout.zip64LocatorOffset) - tailStart
                let lastDisk = split.starts.count - 1
                try ZipTestSupport.writeUInt32(UInt32(lastDisk), to: &fake, at: locator + 4)
                try ZipTestSupport.writeUInt64(
                    UInt64(split.bytes.count - split.starts[lastDisk]), to: &fake, at: locator + 8
                )
            } else {
                try ZipTestSupport.writeUInt32(
                    try XCTUnwrap(UInt32(exactly: oversized)), to: &fake, at: fakeEnd + 12
                )
            }
            split.bytes.append(fake)
            try split.write()
            try assertContents(ArchiveReader.open(url: split.urls.last!), equalTo: original)
        }
    }

    func testOverLimitZIP64ClaimHasBoundedReadWork() throws {
        var previousHeaderReads: Int?
        for entryCount in [4_000, 20_000] {
            let bytes = try ZipTestSupport.makeArchive(
                entries: (0..<entryCount).map { HandZipEntry(name: "entry-\($0)") },
                forceZIP64End: true
            )
            let source = ZipDiscoveryCountingSource(DataByteSource(data: bytes))
            var limits = ReadLimits()
            limits.maxEntryCount = 1
            limits.maxMetadataSize = 1_024
            limits.maxTotalMetadataSize = 128 * 1_024
            XCTAssertThrowsError(try ArchiveReader.open(
                source: source, options: ReaderOptions(limits: limits)
            )) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP entry count"))
            }
            let headerReads = source.readRanges.filter {
                $0.upperBound - $0.lowerBound == 46
            }.count
            XCTAssertLessThanOrEqual(UInt64(headerReads) * 46, 2 * limits.maxMetadataSize)
            XCTAssertLessThanOrEqual(
                try source.totalBytesRead(),
                65_557 + limits.maxTotalMetadataSize + 4 * limits.maxMetadataSize + 4_096
            )
            if let previousHeaderReads {
                XCTAssertEqual(headerReads, previousHeaderReads,
                               "claim work must not grow with the over-limit entry count")
            }
            previousHeaderReads = headerReads
        }
    }

    func testDiscoveryMetadataBudgetIsSharedAcrossBothWindows() throws {
        var bytes = Data(repeating: 0xa5, count: 100)
        bytes.append(try incoherentEndRecord())
        bytes.append(Data(repeating: 0xa5, count: 120_000))
        bytes.append(try incoherentEndRecord())
        let source = ZipDiscoveryCountingSource(DataByteSource(data: bytes))
        var limits = ReadLimits()
        // 各偽候補の固定ヘッダは 46 byte。二窓目で予算をリセットすると誤って通る。
        limits.maxMetadataSize = 23
        XCTAssertThrowsError(try ZipEndRecords.lastDiskIndex(source: source, limits: limits)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP end-record candidate metadata work"))
        }
        let newestEnd = try Checked.sub(source.length, 22)
        let newestDirectory = (try Checked.sub(newestEnd, 46))..<newestEnd
        XCTAssertEqual(source.readRanges.filter { $0 == newestDirectory }.count, 1)
    }

    func testDiscoveryAttemptCapIsSharedAcrossBothWindows() throws {
        var end = try incoherentEndRecord()
        try ZipTestSupport.writeUInt16(.max, to: &end, at: 4)
        var bytes = Data()
        for _ in 0..<8_193 { bytes.append(end) }
        let source = ZipDiscoveryCountingSource(DataByteSource(data: bytes))
        XCTAssertThrowsError(try ZipEndRecords.lastDiskIndex(source: source, limits: ReadLimits())) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP end-record candidate attempts"))
        }
        XCTAssertTrue(source.readRanges.contains(0..<source.length))
    }

    private func incoherentEndRecord() throws -> Data {
        var end = Data(repeating: 0, count: ZipEndRecords.endMinimumSize)
        try ZipTestSupport.writeUInt32(0x0605_4b50, to: &end, at: 0)
        try ZipTestSupport.writeUInt16(1, to: &end, at: 8)
        try ZipTestSupport.writeUInt16(1, to: &end, at: 10)
        try ZipTestSupport.writeUInt32(46, to: &end, at: 12)
        return end
    }

    func testInfoZipSplitAndZIP64AgreeWithSevenZipAndCLI() throws {
        try ZipTestSupport.requireExecutable(ZipTestSupport.infoZipPath)
        try ZipTestSupport.requireExecutable(ZipTestSupport.sevenZipPath)
        let help = try ZipTestSupport.run(ZipTestSupport.infoZipPath, arguments: ["-h2"])
        guard help.diagnostics.contains("-s ") else { throw XCTSkip("Info-ZIP has no split support") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data((0..<180_000).map { UInt8(truncatingIfNeeded: $0 &* 73) })
        try payload.write(to: directory.appendingPathComponent("payload.bin"))
        let cli = ZipTestSupport.repositoryRoot.appendingPathComponent(".build/debug/kaito").path
        try ZipTestSupport.requireExecutable(cli)
        for wide in [false, true] {
            let stem = wide ? "info64" : "info"
            let args = ["-q", "-0", "-s", "64k"] + (wide ? ["-fz"] : []) + [stem + ".zip", "payload.bin"]
            _ = try ZipTestSupport.checkedRun(ZipTestSupport.infoZipPath, arguments: args, currentDirectory: directory)
            let last = directory.appendingPathComponent(stem + ".zip")
            let extracted = try ZipTestSupport.checkedRun(ZipTestSupport.sevenZipPath,
                arguments: ["x", "-so", last.path, "payload.bin"]).standardOutput
            XCTAssertEqual(extracted, payload)
            let digest = SHA256.hash(data: extracted).map { String(format: "%02x", $0) }.joined()
            for name in [stem + ".zip", stem + ".z01"] {
                let url = directory.appendingPathComponent(name)
                let reader = try ArchiveReader.open(url: url)
                XCTAssertEqual(try reader.read(reader.entries[0]), extracted)
                let sha = try ZipTestSupport.checkedRun(cli, arguments: ["sha", url.path])
                XCTAssertTrue(sha.diagnostics.contains(digest), sha.diagnostics)
                _ = try ZipTestSupport.checkedRun(cli, arguments: ["detect", url.path])
                _ = try ZipTestSupport.checkedRun(cli, arguments: ["list", url.path])
                let output = directory.appendingPathComponent("extract-" + name)
                _ = try ZipTestSupport.checkedRun(cli, arguments: ["extract", url.path, "-o", output.path])
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("payload.bin")), extracted)
            }
        }
    }
}
