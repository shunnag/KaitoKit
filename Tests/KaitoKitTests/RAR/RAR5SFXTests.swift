import Foundation
@testable import KaitoKit
import XCTest

final class RAR5SFXTests: XCTestCase {
    private let payloads: [(name: String, contents: Data)] = [
        ("first.txt", Data("RAR5 SFX の stored entry\n".utf8)),
        ("nested/payload.bin", Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0 * 37) })),
        ("empty.txt", Data()),
    ]

    func testFindRAR5SignatureAfterMachOPrefix() throws {
        let prefix = makeMachOPrefix()
        let source = DataByteSource(data: prefix + makeArchive())
        let signature = try XCTUnwrap(FormatDetector.findRARSignature(source: source))

        XCTAssertEqual(signature.offset, UInt64(prefix.count))
        XCTAssertEqual(signature.version, .rar5)
    }

    func testURLSFXReadsAllStoredEntriesBytePerfectly() throws {
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar5-sfx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.sfx")
        try (makeMachOPrefix() + makeArchive()).write(to: url)

        let reader = try ArchiveReader.open(url: url)
        try assertContents(reader)
        try assertContents(reader.reopen())
    }

    func testOptInDataSFXReadsAllStoredEntriesBytePerfectly() throws {
        let reader = try ArchiveReader.open(
            data: makeMachOPrefix() + makeArchive(),
            options: ReaderOptions(scanForSFXInData: true)
        )

        try assertContents(reader)
        try assertContents(reader.reopen())
    }

    func testPartialRAR5MarkerInPrefixIsIgnored() throws {
        var prefix = makeMachOPrefix()
        let fragment: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]
        let fragmentOffset = 128
        prefix.replaceSubrange(
            fragmentOffset..<(fragmentOffset + fragment.count),
            with: fragment
        )
        // 断片の直後を 0 にすると完全な RAR4 署名になるため、非ゼロ値で区切る。
        prefix[fragmentOffset + fragment.count] = 0xFF
        XCTAssertNil(try FormatDetector.findRARSignature(source: DataByteSource(data: prefix)))

        let data = prefix + makeArchive()
        let signature = try XCTUnwrap(
            FormatDetector.findRARSignature(source: DataByteSource(data: data))
        )
        XCTAssertEqual(signature.offset, UInt64(prefix.count))
        XCTAssertEqual(signature.version, .rar5)
        try assertContents(ArchiveReader.open(
            data: data,
            options: ReaderOptions(scanForSFXInData: true)
        ))
    }

    func testMultiVolumeSFXOpensAsSingleVolumeWithoutSiblingLookup() throws {
        let completePayload = Data("complete entry\n".utf8)
        let archive = RAR5TestSupport.archive(
            mainFlags: 0x0001,
            endFlags: 0x0001,
            blocks: [
                RAR5TestSupport.storedFile(name: "complete.txt", contents: completePayload),
                RAR5TestSupport.storedFile(
                    name: "split.bin",
                    contents: Data("first fragment".utf8),
                    headerFlags: 0x0010
                ),
            ]
        )
        let data = makeMachOPrefix() + archive
        let directory = try ZipTestSupport.temporaryDirectory(label: "rar5-sfx-volume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("archive.part1.rar")
        let second = directory.appendingPathComponent("archive.part2.rar")
        try data.write(to: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        let readers = [
            try ArchiveReader.open(url: first),
            try ArchiveReader.open(data: data, options: ReaderOptions(scanForSFXInData: true)),
        ]
        for reader in readers {
            XCTAssertEqual(reader.format, .rar)
            XCTAssertEqual(reader.entries.map(\.name), ["complete.txt", "split.bin"])
            let complete = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(try reader.read(complete), completePayload)
            let split = try XCTUnwrap(reader.entries.last)
            XCTAssertThrowsError(try reader.read(split)) { error in
                XCTAssertEqual(error as? KaitoError, .unsupportedMethod("multi-volume from Data"))
            }
        }
    }

    private func makeArchive() -> Data {
        RAR5TestSupport.archive(blocks: payloads.map {
            RAR5TestSupport.storedFile(name: $0.name, contents: $0.contents)
        })
    }

    private func makeMachOPrefix() -> Data {
        var prefix = Data(repeating: 0, count: 4_096)
        prefix.replaceSubrange(0..<4, with: [0xCF, 0xFA, 0xED, 0xFE])
        return prefix
    }

    private func assertContents(
        _ reader: ArchiveReader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(reader.format, .rar, file: file, line: line)
        XCTAssertEqual(reader.entries.count, payloads.count, file: file, line: line)
        XCTAssertEqual(reader.entries.map(\.name), payloads.map(\.name), file: file, line: line)
        for (entry, payload) in zip(reader.entries, payloads) {
            XCTAssertEqual(try reader.read(entry), payload.contents, entry.name, file: file, line: line)
        }
    }
}
