import Foundation
@testable import KaitoKit
import XCTest

final class ArchiveNameEncodingTests: XCTestCase {
    func testBoundedArchiveNameBatchesStayWithinByteBudget() throws {
        let names = [
            [UInt8](repeating: 0x41, count: 5),
            [UInt8](repeating: 0x42, count: 4),
            [UInt8](repeating: 0x43, count: 12),
            [UInt8](repeating: 0x44, count: 2),
            [UInt8](repeating: 0x45, count: 1),
        ]
        let budget = 10
        var start = names.startIndex
        var visited = 0

        while let batch = EncodingDetector.nextArchiveNameBatch(
            names,
            from: start,
            maximumByteCount: budget
        ) {
            if let combinedByteCount = batch.combinedByteCount {
                let expected = batch.range.reduce(batch.range.count - 1) {
                    $0 + names[$1].count
                }
                XCTAssertEqual(combinedByteCount, expected)
                XCTAssertLessThanOrEqual(combinedByteCount, budget)
            } else {
                XCTAssertEqual(batch.range.count, 1)
                XCTAssertGreaterThan(names[batch.range.lowerBound].count, budget)
            }
            visited += batch.range.count
            start = batch.range.upperBound
        }

        XCTAssertEqual(visited, names.count)
        XCTAssertEqual(
            EncodingDetector.boundedArchiveNameSample(
                names,
                separator: 0x0A,
                maximumByteCount: budget
            ).count,
            budget
        )
        XCTAssertEqual(
            EncodingDetector.decodeArchiveNames(
                names,
                as: .isoLatin1,
                maximumBatchByteCount: budget
            ),
            names.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    func testZIPChoosesOneLegacyEncodingAndFallsBackForOutlier() throws {
        let cp932Names = ["表紙.txt", "画像01.jpg", "目次.txt", "東京.png"]
        let entries = try cp932Names.map { name in
            HandZipEntry(
                rawName: Array(try XCTUnwrap(name.data(using: .shiftJIS))),
                uncompressedData: Data()
            )
        } + [
            HandZipEntry(
                rawName: Array(try XCTUnwrap("¢.txt".data(using: .japaneseEUC))),
                uncompressedData: Data()
            ),
        ]

        let reader = try ArchiveReader.open(
            data: ZipTestSupport.makeArchive(entries: entries)
        )
        XCTAssertEqual(reader.nameEncoding, .shiftJIS)
        XCTAssertEqual(reader.entries.map(\.name), cp932Names + ["¢.txt"])
    }

    func testZIPDeclaredAndStrictUTF8NamesDoNotSelectArchiveEncoding() throws {
        let unicodeRawName: [UInt8] = [0xFF, 0xFE, 0xFD]
        let unicodeExtra = try ZipTestSupport.unicodePathExtra(
            rawName: unicodeRawName,
            unicodeName: "extra-日本語.txt"
        )
        let archive = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "flag-日本語.txt"),
            HandZipEntry(rawName: Array("unflagged-日本語.txt".utf8)),
            HandZipEntry(rawName: unicodeRawName, centralExtra: unicodeExtra),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertNil(reader.nameEncoding)
        XCTAssertEqual(
            reader.entries.map(\.name),
            ["flag-日本語.txt", "unflagged-日本語.txt", "extra-日本語.txt"]
        )
    }

    func testZIPFixedAndUTF8OnlyArchiveEncodingSemantics() throws {
        let validUTF8 = Array("é.txt".utf8)
        let fixedReader = try ArchiveReader.open(
            data: ZipTestSupport.makeArchive(entries: [
                HandZipEntry(rawName: validUTF8),
            ]),
            options: ReaderOptions(encodingPolicy: .fixed(.shiftJIS))
        )
        XCTAssertEqual(fixedReader.nameEncoding, .shiftJIS)
        XCTAssertEqual(
            fixedReader.entries[0].name,
            try XCTUnwrap(EncodingDetector.decode(bytes: validUTF8, as: .shiftJIS))
        )

        let validOnly = try ArchiveReader.open(
            data: ZipTestSupport.makeArchive(entries: [
                HandZipEntry(rawName: validUTF8),
            ]),
            options: ReaderOptions(encodingPolicy: .utf8Only)
        )
        XCTAssertNil(validOnly.nameEncoding)
        XCTAssertEqual(validOnly.entries[0].name, "é.txt")

        let invalid = try ArchiveReader.open(
            data: ZipTestSupport.makeArchive(entries: [
                HandZipEntry(rawName: [0xFF]),
            ]),
            options: ReaderOptions(encodingPolicy: .utf8Only)
        )
        XCTAssertEqual(invalid.nameEncoding, .utf8)
        XCTAssertTrue(invalid.entries[0].name.contains("�"))
    }

    func testTarUstarNamesUseArchiveEncoding() throws {
        let names = ["表紙.txt", "画像.jpg", "目次.txt"]
        var archive = try TarTestSupport.makeTar(
            entries: names.map { HandTarEntry(name: $0) }
        )
        for (index, name) in names.enumerated() {
            let rawName = Array(try XCTUnwrap(name.data(using: .shiftJIS)))
            replaceTarName(in: &archive, headerOffset: index * 512, with: rawName)
        }

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.nameEncoding, .shiftJIS)
        XCTAssertEqual(reader.entries.map(\.name), names)
    }

    func testTarFixedEncodingChunksNamesAtMetadataLimit() throws {
        let rawNames = [UInt8(0xE9), UInt8(0xF1)].map { leadingByte in
            [leadingByte] + [UInt8](repeating: 0x61, count: 99)
        }
        var archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "one"),
            HandTarEntry(name: "two"),
        ])
        for (index, rawName) in rawNames.enumerated() {
            replaceTarName(in: &archive, headerOffset: index * 512, with: rawName)
        }
        var limits = ReadLimits()
        limits.maxMetadataSize = 128

        let reader = try ArchiveReader.open(
            data: archive,
            options: ReaderOptions(
                encodingPolicy: .fixed(.isoLatin1),
                limits: limits
            )
        )

        XCTAssertEqual(reader.nameEncoding, .isoLatin1)
        XCTAssertEqual(
            reader.entries.map(\.name),
            try rawNames.map {
                try XCTUnwrap(String(data: Data($0), encoding: .isoLatin1))
            }
        )
    }

    func testTarPAXUTF8NameDoesNotSelectArchiveEncoding() throws {
        let path = "pax-日本語.txt"
        let pax = makePAXRecord(key: "path", value: Array(path.utf8))
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "PaxHeader", contents: pax, type: 0x78),
            HandTarEntry(name: "placeholder"),
        ])

        let reader = try ArchiveReader.open(data: archive)
        XCTAssertNil(reader.nameEncoding)
        XCTAssertEqual(reader.entries.map(\.name), [path])
        XCTAssertEqual(reader.entries[0].rawName.declaredEncoding, .utf8)
    }

    func testTarPendingGlobalPAXMetadataHonorsAggregateLimit() throws {
        let charset = [UInt8](repeating: 0x41, count: 600)
        let pax = makePAXRecord(key: "hdrcharset", value: charset)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "GlobalHead", contents: pax, type: 0x67),
            HandTarEntry(name: "one"),
            HandTarEntry(name: "two"),
            HandTarEntry(name: "three"),
        ])
        let limits = ReadLimits(
            maxEntrySize: 4_096,
            maxInMemorySize: 4_096,
            maxEntryCount: 10,
            maxMetadataSize: 4_096,
            maxMetadataRecordCount: 10,
            maxPathComponentCount: 10,
            maxTotalMetadataSize: 1_500
        )

        XCTAssertThrowsError(
            try ArchiveReader.open(
                data: archive,
                options: ReaderOptions(limits: limits)
            )
        ) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    private func replaceTarName(
        in archive: inout Data,
        headerOffset: Int,
        with name: [UInt8]
    ) {
        precondition(name.count <= 100)
        archive.replaceSubrange(
            headerOffset..<(headerOffset + 100),
            with: repeatElement(UInt8(0), count: 100)
        )
        archive.replaceSubrange(
            headerOffset..<(headerOffset + name.count),
            with: name
        )
        archive.replaceSubrange(
            (headerOffset + 148)..<(headerOffset + 156),
            with: repeatElement(UInt8(0x20), count: 8)
        )
        let checksum = archive[headerOffset..<(headerOffset + 512)]
            .reduce(UInt64(0)) { $0 + UInt64($1) }
        let digits = Array(String(checksum, radix: 8).utf8)
        let checksumField = [UInt8](repeating: 0x30, count: 6 - digits.count)
            + digits + [0, 0x20]
        archive.replaceSubrange(
            (headerOffset + 148)..<(headerOffset + 156),
            with: checksumField
        )
    }

    private func makePAXRecord(key: String, value: [UInt8]) -> Data {
        let body = Array("\(key)=".utf8) + value + [0x0A]
        var length = body.count + 2
        while true {
            let prefix = Array("\(length) ".utf8)
            let corrected = prefix.count + body.count
            if corrected == length {
                return Data(prefix + body)
            }
            length = corrected
        }
    }
}
