import Foundation
import XCTest
@testable import KaitoKit

final class OpenIORegressionTests: XCTestCase {
    func testScalarCategoriesMatchUnicodeAndTraitsArePOD() {
        XCTAssertTrue(_isPOD(NameEncodingScorer.Traits.self))
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            XCTAssertEqual(String(describing: NameEncodingScorer.ScalarCategory(scalar.properties.generalCategory)),
                           String(describing: scalar.properties.generalCategory))
        }
    }

    func testBatchDecodingMatchesIndividualIncludingEmptyInvalidAndNULNames() {
        for encoding: String.Encoding in [.shiftJIS, .japaneseEUC, .windowsCP1252, .isoLatin1] {
            let base = ["", "画像/頁.jpg", "café.txt", "が", "か\u{3099}"]
                .compactMap { $0.data(using: encoding).map(Array.init) }
                + [[0x81], [0xFF, 0xFE], []]
            let names = (0..<2000).map { base[$0 % base.count] }
            let expected = names.map { EncodingDetector.decode(bytes: $0, as: encoding) }
            let withNUL = names + [[0], [0x41, 0, 0x42]]
            XCTAssertEqual(EncodingDetector.decodeArchiveNames(withNUL, as: encoding),
                           withNUL.map { EncodingDetector.decode(bytes: $0, as: encoding) })
            for limit in [nil, 4096, 0] as [Int?] {
                let actual = limit.map { EncodingDetector.decodeArchiveNames(names, as: encoding, maximumBatchByteCount: $0) }
                    ?? EncodingDetector.decodeArchiveNames(names, as: encoding)
                XCTAssertEqual(actual, expected, "\(encoding) limit=\(String(describing: limit))")
            }
        }
    }

    func testNormalizedLookupKeyMatchesPreviousRules() throws {
        func previous(_ path: String) -> String? {
            guard !path.isEmpty, path.utf8.first != 47, !path.utf8.contains(0) else { return nil }
            let raw = path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
            guard !raw.contains("..") else { return nil }
            let parts = raw.filter { $0 != "." }
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        }
        let fragments = ["", ".", "..", "a", "...", "a.b", "画像", "か\u{3099}", "a\0b", "\\", "/"]
        var seed: UInt64 = 42
        for _ in 0..<20000 {
            var path = ""
            for _ in 0..<6 {
                seed = seed &* 6364136223846793005 &+ 1
                path += fragments[Int(seed >> 32) % fragments.count] + (seed & 1 == 0 ? "/" : "")
            }
            let parts = try ArchivePath.components(of: path, limit: 100, label: "test")
            XCTAssertEqual(ArchivePath.normalizedExtractionPath(path, components: parts), previous(path), path)
        }
    }

    func testZIP64FixedRecordAvoidsLargeReadAndKeepsFallbacks() throws {
        let payload = Data(repeating: 0x28, count: 17 << 20)
        for prefix in [Data(), Data(repeating: 0x77, count: 128)] {
            let bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "page", uncompressedData: payload)],
                                                      prefix: prefix, forceZIP64End: true)
            let layout = try ZipTestSupport.layout(of: bytes)
            let source = CallCountingByteSource(DataByteSource(bytes))
            let reader = try ZipReader(source: source, options: ReaderOptions())
            XCTAssertLessThan(source.readBytes, 128 << 10)
            XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), payload)
            // Finding the adjacent record must not accept a bad archive base.
            var badLocator = bytes
            try ZipTestSupport.writeUInt64(3, to: &badLocator, at: try XCTUnwrap(layout.zip64LocatorOffset) + 8)
            XCTAssertThrowsError(try ZipReader(source: DataByteSource(badLocator), options: ReaderOptions())) {
                XCTAssertEqual($0 as? KaitoError, .malformed("ZIP64 central directory lies outside the file"))
            }
            // Extensible data requires the existing bounded backward scan.
            var extended = bytes
            let locator = try XCTUnwrap(layout.zip64LocatorOffset)
            let record = try XCTUnwrap(layout.zip64EndRecordOffset)
            extended.insert(contentsOf: [1, 2, 3, 4], at: locator)
            try ZipTestSupport.writeUInt64(48, to: &extended, at: record + 4)
            XCTAssertEqual(try ZipReader(source: DataByteSource(extended), options: ReaderOptions()).entries, reader.entries)
        }
    }

    func testRAR5CacheEvictionDoesNotShareEntrySpecificValues() throws {
        let blocks = (0..<33).map { i in
            RAR5TestSupport.storedFile(name: "file-\(i)", contents: Data([UInt8(i)]),
                                      hostOS: UInt64(i % 2), attributes: UInt64(i % 11))
        }
        let reader = try ArchiveReader.open(data: RAR5TestSupport.archive(blocks: blocks))
        for (i, entry) in reader.entries.enumerated() {
            XCTAssertEqual(entry.formatSpecific, [
                "rarVersion": "5", "compressionInfo": "0x0", "method": "0",
                "dictionarySize": "131072", "hostOS": String(i % 2),
                "attributes": "0x" + String(i % 11, radix: 16), "solid": "false",
                "splitBefore": "false", "splitAfter": "false", "multiVolume": "false",
                "volumeSegmentCount": "1", "unpackedSizeUnknown": "false", "encryption": "none"
            ])
            XCTAssertEqual(try reader.read(entry), Data([UInt8(i)]))
        }
    }

    func testTarErrorsAndLimitsMatchAcrossLatencies() throws {
        let bytes = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "a/b", contents: Data([1]))])
        var badChecksum = bytes; badChecksum[148] ^= 1
        for variant in [bytes, badChecksum, Data(bytes.prefix(513))] {
            for metadataLimit: UInt64 in [0, 64, 1 << 20] {
                for recovery in [false, true] {
                    var listings: [[ArchiveEntry]?] = []
                    var errors: [String?] = []
                    for latency in [InputLatency.low, .high] {
                        var options = ReaderOptions(); options.inputLatency = latency
                        options.limits.maxTotalMetadataSize = metadataLimit
                        options.recoverDamagedArchives = recovery
                        do {
                            let reader = try TarReader(source: DataByteSource(variant), options: options)
                            listings.append(reader.entries)
                            errors.append(nil)
                        } catch {
                            listings.append(nil)
                            errors.append(String(reflecting: error))
                        }
                    }
                    XCTAssertEqual(listings[0], listings[1])
                    XCTAssertEqual(errors[0], errors[1])
                }
            }
        }
    }

    func testTarTinyMetadataLimitsDoNotSplitHeaderReads() throws {
        let bytes = try TarTestSupport.makeTar(entries: (0..<100).map {
            HandTarEntry(name: "page-\($0)", contents: Data(repeating: 0x62, count: 16))
        })
        for limit: UInt64 in [0, 1, 512] {
            try assertTarReadBounds(bytes, label: "metadata-\(limit)", metadataLimit: limit)
        }
    }

    func testTarMixedSmallAndLargeMembersAvoidPayloadReadAhead() throws {
        let payload = Data(repeating: 0x62, count: 4 << 20)
        for smallCount in 1...3 {
            var members: [HandTarEntry] = []
            for group in 0..<40 {
                for small in 0..<smallCount {
                    members.append(HandTarEntry(name: "small-\(group)-\(small)", contents: Data(repeating: 0x61, count: 16)))
                }
                members.append(HandTarEntry(name: "large-\(group)", contents: payload))
            }
            try assertTarReadBounds(TarTestSupport.makeTar(entries: members), label: "small-\(smallCount)-large")
        }
    }

    func testTarPAXAndAppleDoubleLikePreludeAvoidsPayloadReadAhead() throws {
        let payload = Data(repeating: 0x62, count: 4 << 20)
        // Native macOS tar also emits a directory/PAX prelude before the first
        // file. It must not prematurely train the planner into a large window.
        var members: [HandTarEntry] = [
            HandTarEntry(name: "PaxHeaders/root", contents: paxRecord("path", "."), type: UInt8(ascii: "x")),
            HandTarEntry(name: ".", type: UInt8(ascii: "5"))
        ]
        for group in 0..<40 {
            let name = "page-\(group)"
            // Three small physical records precede the large body. The metadata
            // also puts its header across the initial 4 KiB window boundary.
            members.append(HandTarEntry(name: "PaxHeaders/side-\(group)",
                contents: paxRecord("path", "._" + name) + paxRecord("comment", String(repeating: "q", count: 700)),
                type: UInt8(ascii: "x")))
            members.append(HandTarEntry(name: "._" + name, contents: Data(repeating: 0x2A, count: 700)))
            members.append(HandTarEntry(name: "PaxHeaders/main-\(group)", contents: paxRecord("path", name), type: UInt8(ascii: "x")))
            members.append(HandTarEntry(name: name, contents: payload))
        }
        try assertTarReadBounds(TarTestSupport.makeTar(entries: members), label: "pax-appledouble-large")
    }

    private func paxRecord(_ key: String, _ value: String) -> Data {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while true {
            let record = "\(length)" + body
            if record.utf8.count == length { return Data(record.utf8) }
            length = record.utf8.count
        }
    }

    private func assertTarReadBounds(_ bytes: Data, label: String,
                                     metadataLimit: UInt64 = ReadLimits().maxMetadataSize,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        var expected: [ArchiveEntry]?
        var lowReads = 0, lowBytes = 0
        for latency in [InputLatency.low, .high, .automatic] {
            let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
            var options = ReaderOptions(); options.inputLatency = latency
            options.limits.maxMetadataSize = metadataLimit
            let reader = try TarReader(source: source, options: options)
            if let expected { XCTAssertEqual(reader.entries, expected, label, file: file, line: line) }
            expected = reader.entries
            print("TAR-REVIEW case=\(label) latency=\(latency) reads=\(source.readCount) bytes=\(source.readBytes)")
            if latency == .low {
                lowReads = source.readCount; lowBytes = source.readBytes
            } else {
                XCTAssertLessThanOrEqual(source.readCount, lowReads, label, file: file, line: line)
                XCTAssertLessThanOrEqual(source.readBytes, lowBytes * 3 / 2, label, file: file, line: line)
            }
        }
    }

    func testTarDenseAndSparseHeaderWalk() throws {
        for size in [16, 256 << 10] {
            let bytes = try TarTestSupport.makeTar(entries: (0..<100).map {
                HandTarEntry(name: "page-\($0)", contents: Data(repeating: 0x62, count: size))
            })
            var expected: [ArchiveEntry]?
            var reads: [Int] = []
            for latency in [InputLatency.low, .high, .automatic] {
                let source = CallCountingByteSource(DataByteSource(bytes), reportsNonLocalVolume: true)
                var options = ReaderOptions(); options.inputLatency = latency
                let reader = try TarReader(source: source, options: options)
                if let expected { XCTAssertEqual(reader.entries, expected) }
                expected = reader.entries; reads.append(source.readCount)
                XCTAssertLessThanOrEqual(source.readBytes, size == 16 ? bytes.count : 101 * (16 << 10))
                XCTAssertEqual(try reader.stream(for: reader.entries[99], limits: ReadLimits()).readAll(), Data(repeating: 0x62, count: size))
            }
            XCTAssertEqual(reads[1], reads[2])
            if size == 16 { XCTAssertLessThan(reads[1], reads[0] / 4) }
            else { XCTAssertEqual(reads[1], reads[0]) }
        }
    }
}
