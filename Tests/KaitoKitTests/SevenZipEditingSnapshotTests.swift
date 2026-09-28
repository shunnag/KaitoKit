import Foundation
@_spi(SevenZipEditLayout) @testable import KaitoKit
import XCTest

final class SevenZipEditingSnapshotTests: XCTestCase {
    func testEveryFrozenStructureAndReopen() throws {
        let expected = try JSONDecoder().decode(SevenZipExpectedCorpus.self,
            from: Data(contentsOf: SevenZipGolden.root.appendingPathComponent("expected-structures.json")))
        XCTAssertEqual(expected.archives.count, 33)
        for url in try SevenZipGolden.archives() {
            let name = url.lastPathComponent
            var options = ReaderOptions(password: "secret")
            options.recordsSevenZipEditLayout = true
            if name == "empty_7zz.7z" {
                XCTAssertThrowsError(try ArchiveReader.open(url: url, options: options)) {
                    XCTAssertEqual($0 as? KaitoError, .malformed("empty 7z next header"))
                }
                continue
            }
            let reader = try ArchiveReader.open(url: url, options: options)
            let value = try XCTUnwrap(reader.sevenZipEditingSnapshot(), name)
            let golden = try XCTUnwrap(expected.archives[name])
            let bytes = try Data(contentsOf: url)
            try check(value, expected: golden, bytes: bytes, name: name)
            XCTAssertEqual(value.files.map(\.rawName), reader.entries.map { $0.rawName.bytes }, name)
            let reopened = try reader.reopen()
            let reopenedValue = try XCTUnwrap(reopened.sevenZipEditingSnapshot())
            XCTAssertEqual(reopenedValue.unrepresentedReason, value.unrepresentedReason, name)
            try check(reopenedValue, expected: golden, bytes: bytes, name: name)
        }
    }

    func testUnrepresentedReasonsAndHeaderForms() throws {
        let reasons: [(String, SevenZipEditUnrepresentedReason)] = [
            ("archive_properties.7z", .archiveProperties), ("comment.7z", .unknownFileProperty(0x16)),
            ("unknown_1a.7z", .unknownFileProperty(0x1a)), ("external_names.7z", .additionalStreams)
        ]
        for (name, reason) in reasons { XCTAssertEqual(try snapshot(name).unrepresentedReason, reason) }
        let lib = try snapshot("lib.7z")
        XCTAssertEqual(lib.versionMinor, 3)
        XCTAssertEqual(lib.filePropertyOrder, [0x0e, 0x0f, 0x11, 0x14, 0x12, 0x13, 0x15])
        XCTAssertTrue(lib.header.isCompressed)
        XCTAssertEqual(try snapshot("sfx.7z").baseOffset, 4096)
        XCTAssertEqual(try snapshot("packpos16.7z").packPosition, 16)
        XCTAssertTrue(try snapshot("z_aesonlyh.7z").header.isEncrypted)
        XCTAssertFalse(try snapshot("z_aesonlyh.7z").header.isCompressed)
        for name in ["empty_gk.7z", "empty_fi0.7z"] {
            let value = try snapshot(name)
            XCTAssertTrue(value.files.isEmpty)
            XCTAssertTrue(value.folders.isEmpty)
            XCTAssertTrue(value.filePropertyOrder.isEmpty)
            XCTAssertEqual(value.mainPackEnd, 32)
        }
    }

    func testExternalFlagsAreRecordedWithoutChangingErrors() throws {
        // 追加 stream が先に出る fixture では .additionalStreams が優先する。
        // parser 単体では external フラグ自身も記録されることを確かめる。
        let recorder = SevenZipEditRecorder()
        let externalName: [UInt8] = [1, 5, 1, 0x11, 2, 1, 0, 0, 0]
        XCTAssertThrowsError(try SevenZipHeaderParser.parse(bytes: externalName, limits: ReadLimits(),
            budget: SevenZipMetadataBudget(limit: .max), editRecorder: recorder,
            decodeStreams: { _, _ in [] })) {
            XCTAssertEqual($0 as? KaitoError, .malformed("invalid external 7z property stream"))
        }
        XCTAssertEqual(recorder.state.unrepresentedReason, .externalData)
        let folderRecorder = SevenZipEditRecorder()
        var cursor = SevenZipHeaderCursor([7, 0x0b, 1, 1, 0, 0])
        XCTAssertThrowsError(try SevenZipStreamsParser.parse(cursor: &cursor, limits: ReadLimits(),
            editRecorder: folderRecorder)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("invalid external 7z folder stream"))
        }
        XCTAssertEqual(folderRecorder.state.unrepresentedReason, .externalData)
    }

    func testAccessorAndReopenDoNotReadAndOptionDoesNotChangeOpenReads() throws {
        for name in ["g_plain.7z", "g_aesh.7z", "bcj2.7z", "sfx.7z"] {
            let bytes = try Data(contentsOf: SevenZipGolden.root.appendingPathComponent(name))
            var counts: [UInt64] = []
            for recording in [false, true] {
                let source = CountingByteSource(DataByteSource(bytes))
                var options = ReaderOptions(password: "secret", scanForSFXInData: true)
                options.recordsSevenZipEditLayout = recording
                let reader = try ArchiveReader.open(source: source, options: options)
                counts.append(source.bytesRead)
                source.reset()
                reader.password = nil
                XCTAssertEqual(reader.sevenZipEditingSnapshot() != nil, recording)
                let reopened = try reader.reopen()
                XCTAssertEqual(reopened.sevenZipEditingSnapshot() != nil, recording)
                XCTAssertEqual(source.bytesRead, 0, name)
            }
            XCTAssertEqual(counts[0], counts[1], name)
        }
    }

    func testSplitAndNonSevenZipHaveNoSnapshot() throws {
        let bytes = try Data(contentsOf: SevenZipGolden.root.appendingPathComponent("g_plain.7z"))
        var options = ReaderOptions()
        options.recordsSevenZipEditLayout = true
        let directory = try SevenZipTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("split.7z.001")
        try bytes.prefix(100).write(to: url)
        try bytes.dropFirst(100).write(to: directory.appendingPathComponent("split.7z.002"))
        let reader = try ArchiveReader.open(url: url, options: options)
        XCTAssertNotNil(reader.volumeSet)
        XCTAssertNil(reader.sevenZipEditingSnapshot())
        XCTAssertNil(try reader.reopen().sevenZipEditingSnapshot())
        let dataSource = DataByteSource(bytes)
        let concatenated = try ConcatenatedByteSource(segments: [
            SourceSegment(source: dataSource, offset: 0, length: dataSource.length)
        ], maximumLength: .max, label: "7z test")
        XCTAssertNil(try ArchiveReader.open(source: concatenated, options: options).sevenZipEditingSnapshot())
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "a", contents: Data())])
        XCTAssertNil(try ArchiveReader.open(data: tar, options: options).sevenZipEditingSnapshot())
    }

    func testRawFlagsPartialDigestsAndZeroSubstreams() throws {
        // 明示的 1 入出力と長さ 0 の properties は、暗黙値と区別して保持する。
        let header: [UInt8] = [1, 4, 6, 0, 2, 9, 0, 0, 0x0a, 0, 0x80, 0, 0, 0, 0, 0,
            7, 0x0b, 2, 0, 1, 0x31, 0, 1, 1, 0, 1, 1, 0, 0x0c, 0, 0, 0,
            8, 0x0d, 0, 0, 0, 0, 5, 0, 0, 0]
        var options = ReaderOptions()
        options.recordsSevenZipEditLayout = true
        let reader = try ArchiveReader.open(data: SevenZipEditTestBytes.archive(header: header), options: options)
        let value = try XCTUnwrap(reader.sevenZipEditingSnapshot())
        XCTAssertEqual(value.packs.map(\.crc32), [0, nil])
        XCTAssertEqual(value.folders.map(\.substreamIndices), [0..<0, 0..<0])
        XCTAssertTrue(value.folders[0].coders[0].isComplex)
        XCTAssertEqual(value.folders[0].coders[0].properties, [])
        XCTAssertFalse(value.folders[1].coders[0].isComplex)
        XCTAssertNil(value.folders[1].coders[0].properties)
    }

    func testEncodedHeaderRetainsMultipleFoldersAndPacks() throws {
        // substream は 1 本だが、空の folder も先行する encoded header。
        let encoded: [UInt8] = [0x17, 6, 0, 2, 9, 0, 5, 0,
            7, 0x0b, 2, 0, 1, 1, 0, 1, 1, 0, 0x0c, 0, 5, 0,
            8, 0x0d, 0, 1, 0, 0]
        var options = ReaderOptions()
        options.recordsSevenZipEditLayout = true
        let reader = try ArchiveReader.open(data: SevenZipEditTestBytes.archive(
            header: encoded, packed: [1, 5, 0, 0, 0]), options: options)
        let snapshot = try XCTUnwrap(reader.sevenZipEditingSnapshot())
        guard case let .encoded(folders, ranges) = snapshot.header else { return XCTFail("expected encoded header") }
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(ranges, [32..<32, 32..<37])
        XCTAssertEqual(folders.map(\.packIndices), [0..<1, 1..<2])
        XCTAssertEqual(folders.map(\.substreamIndices), [0..<0, 0..<1])
        XCTAssertFalse(snapshot.header.isCompressed)
        XCTAssertFalse(snapshot.header.isEncrypted)
        XCTAssertEqual(snapshot.plainHeaderLength, 5)
    }

    func testRecordingDoesNotChangeHeaderFailures() throws {
        for name in ["g_plain.7z", "z_default.7z", "z_aesh.7z"] {
            let bytes = try Data(contentsOf: SevenZipGolden.root.appendingPathComponent(name))
            var brokenStart = bytes, brokenNext = bytes
            brokenStart[12] ^= 1
            brokenNext[brokenNext.count - 1] ^= 1
            for damaged in [Data(bytes.prefix(31)), Data(bytes.dropLast()), brokenStart, brokenNext,
                            SevenZipEditTestBytes.archive(header: [1, 5, 1, 0, 0])] {
                var errors: [KaitoError] = []
                for recording in [false, true] {
                    var options = ReaderOptions(password: "secret")
                    options.recordsSevenZipEditLayout = recording
                    XCTAssertThrowsError(try ArchiveReader.open(data: damaged, options: options)) {
                        if let error = $0 as? KaitoError { errors.append(error) }
                        else { XCTFail("unexpected error: \($0)") }
                    }
                }
                XCTAssertEqual(errors.count, 2)
                XCTAssertEqual(errors.first, errors.last, name)
            }
        }
    }

    private func snapshot(_ name: String) throws -> SevenZipEditingSnapshot {
        var options = ReaderOptions(password: "secret")
        options.recordsSevenZipEditLayout = true
        return try XCTUnwrap(ArchiveReader.open(url: SevenZipGolden.root.appendingPathComponent(name),
            options: options).sevenZipEditingSnapshot())
    }

    private func check(_ actual: SevenZipEditingSnapshot, expected: SevenZipExpectedArchive,
                       bytes: Data, name: String) throws {
        XCTAssertEqual(actual.baseOffset, expected.baseOffset, name)
        XCTAssertEqual([actual.versionMajor, actual.versionMinor], expected.version, name)
        XCTAssertEqual(actual.nextHeaderRange, expected.nextHeaderRange.relative(to: expected.baseOffset), name)
        XCTAssertEqual(actual.plainHeaderLength, expected.plaintextHeader.length, name)
        XCTAssertEqual(actual.packPosition, expected.packPos ?? 0, name)
        XCTAssertEqual(actual.mainPackEnd, expected.mainPackEnd - expected.baseOffset, name)
        XCTAssertEqual(actual.filePropertyOrder, try expected.filePropertyOrder.map {
            try XCTUnwrap(UInt8($0.dropFirst(2), radix: 16))
        }, name)
        XCTAssertEqual(actual.folders, expected.main?.editFolders ?? [], name)
        XCTAssertEqual(actual.substreams, expected.main?.editSubstreams ?? [], name)
        XCTAssertEqual(actual.packs, expected.main?.packs.map {
            SevenZipEditPack(range: $0.range.relative(to: expected.baseOffset), crc32: $0.crc32)
        } ?? [], name)
        for pack in expected.main?.packs ?? [] {
            XCTAssertEqual(bytes.subdata(in: pack.range.dataRange).sha256Hex, pack.sha256, name)
        }
        if let header = expected.encodedHeader {
            XCTAssertEqual(actual.header, .encoded(folders: header.editFolders,
                packRanges: header.packs.map { $0.range.relative(to: expected.baseOffset) }), name)
            let coders = header.folders.flatMap(\.coders)
            XCTAssertEqual(actual.header.isEncrypted, coders.contains { $0.methodIDHex == "06f10701" }, name)
            XCTAssertEqual(actual.header.isCompressed,
                coders.contains { $0.methodIDHex != "06f10701" && $0.methodIDHex != "00" }, name)
            for pack in header.packs {
                XCTAssertEqual(bytes.subdata(in: pack.range.dataRange).sha256Hex, pack.sha256, name)
            }
        } else {
            XCTAssertEqual(actual.header, .plain, name)
        }
        XCTAssertEqual(actual.files, expected.files.map { file in
            let substreamIndex = file.folderIndex.flatMap { folder in
                file.substreamIndex.map { (expected.main?.editFolders[folder].substreamIndices.lowerBound ?? 0) + $0 }
            }
            return SevenZipEditFile(rawName: SevenZipEditTestBytes.hex(file.nameRawHex), substreamIndex: substreamIndex,
                isEmptyFile: file.emptyFile, isAnti: file.anti, creationTime: file.creationTime.flatMap(UInt64.init),
                accessTime: file.accessTime.flatMap(UInt64.init), modificationTime: file.modificationTime.flatMap(UInt64.init),
                attributes: file.attributes, startPosition: file.startPos.flatMap(UInt64.init))
        }, name)
        XCTAssertEqual(actual.files.map { !$0.hasStream }, expected.files.map(\.emptyStream), name)
    }
}

private struct SevenZipExpectedCorpus: Decodable { let archives: [String: SevenZipExpectedArchive] }
private struct SevenZipExpectedArchive: Decodable {
    let baseOffset: UInt64
    let version: [UInt8]
    let nextHeaderRange: SevenZipExpectedRange
    struct Plaintext: Decodable { let length: UInt64 }
    let plaintextHeader: Plaintext
    let packPos: UInt64?
    let mainPackEnd: UInt64
    let main: SevenZipExpectedStreams?
    let encodedHeader: SevenZipExpectedStreams?
    let filePropertyOrder: [String]
    struct File: Decodable {
        let nameRawHex: String
        let emptyStream: Bool, emptyFile: Bool, anti: Bool
        let creationTime: String?, accessTime: String?, modificationTime: String?, startPos: String?
        let attributes: UInt32?
        let folderIndex: Int?, substreamIndex: Int?
    }
    let files: [File]
}
private struct SevenZipExpectedRange: Decodable {
    let offset: UInt64, length: UInt64
    func relative(to base: UInt64) -> Range<UInt64> { (offset - base)..<(offset - base + length) }
    var dataRange: Range<Int> { Int(offset)..<Int(offset + length) }
}
private struct SevenZipExpectedStreams: Decodable {
    struct Pack: Decodable {
        let range: SevenZipExpectedRange
        let crc32: UInt32?
        let sha256: String
    }
    struct Folder: Decodable {
        struct Coder: Decodable {
            let methodIDHex: String
            let numInputs: Int, numOutputs: Int
            let isComplex: Bool
            let propertiesHex: String?
        }
        struct Bind: Decodable { let inputIndex: Int, outputIndex: Int }
        struct Substream: Decodable { let size: UInt64; let crc32: UInt32? }
        let coders: [Coder]
        let binds: [Bind]
        let packedInputs: [Int], packIndices: [Int]
        let numOutputsTotal: Int
        let unpackSizes: [UInt64]
        let crc32: UInt32?
        let substreams: [Substream]
    }
    let packs: [Pack]
    let folders: [Folder]
    var editFolders: [SevenZipEditFolder] {
        var substreamIndex = 0
        return folders.map { folder in
            defer { substreamIndex += folder.substreams.count }
            return SevenZipEditFolder(coders: folder.coders.map {
                SevenZipEditCoder(methodID: SevenZipEditTestBytes.hex($0.methodIDHex), inputCount: $0.numInputs,
                    outputCount: $0.numOutputs, isComplex: $0.isComplex,
                    properties: $0.propertiesHex.map(SevenZipEditTestBytes.hex))
            }, bindPairs: folder.binds.map { SevenZipEditBindPair(input: $0.inputIndex, output: $0.outputIndex) },
            packedInputs: folder.packedInputs, unpackSizes: folder.unpackSizes,
            finalOutput: (0..<folder.numOutputsTotal).first { output in !folder.binds.contains { $0.outputIndex == output } }!,
            crc32: folder.crc32, packIndices: folder.packIndices[0]..<(folder.packIndices.last! + 1),
            substreamIndices: substreamIndex..<(substreamIndex + folder.substreams.count))
        }
    }
    var editSubstreams: [SevenZipEditSubstream] {
        folders.enumerated().flatMap { index, folder in
            var offset: UInt64 = 0
            return folder.substreams.map { stream in
                defer { offset += stream.size }
                return SevenZipEditSubstream(folderIndex: index, offset: offset, size: stream.size, crc32: stream.crc32)
            }
        }
    }
}

enum SevenZipEditTestBytes {
    static func hex(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        }
    }
    static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func archive(header: [UInt8], packed: [UInt8] = []) -> Data {
        let start = little(UInt64(packed.count)) + little(UInt64(header.count)) + little(CRC32.checksum(header))
        return Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4] + little(CRC32.checksum(start)) + start + packed + header)
    }
}
