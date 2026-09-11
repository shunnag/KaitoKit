import CryptoKit
import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class SplitVolumeTests: XCTestCase {
    func testNamingAcceptsOnlyFirstVolumesWithNonemptyStems() {
        XCTAssertEqual(SplitVolumeSet.naming(forFirstVolumeName: "comic.7z.001"),
                       .init(stem: "comic.7z", width: 3))
        XCTAssertEqual(SplitVolumeSet.naming(forFirstVolumeName: "foo.001"),
                       .init(stem: "foo", width: 3))
        XCTAssertEqual(SplitVolumeSet.naming(forFirstVolumeName: "x.7z.0001"),
                       .init(stem: "x.7z", width: 4))
        for name in [".001", "", "x.7z.002", "x.7z.01", "x.7z.000", "x.7z",
                     "x.7z.1000", "x.7z.００１", "x.7z.0０1", "x.7z.+01"] {
            XCTAssertNil(SplitVolumeSet.naming(forFirstVolumeName: name), name)
        }
    }

    func testVolumeNamesPreserveWidthAndGrowPast999() {
        let naming = SplitVolumeSet.Naming(stem: "comic.7z", width: 3)
        XCTAssertEqual(SplitVolumeSet.volumeName(naming, number: 0), "comic.7z.001")
        XCTAssertEqual(SplitVolumeSet.volumeName(naming, number: 998), "comic.7z.999")
        XCTAssertEqual(SplitVolumeSet.volumeName(naming, number: 999), "comic.7z.1000")
        XCTAssertEqual(SplitVolumeSet.volumeName(naming, number: 1000), "comic.7z.1001")
        XCTAssertEqual(SplitVolumeSet.volumeName(.init(stem: "x.7z", width: 4), number: 1),
                       "x.7z.0002")
    }

    func testTwoVolumeFixtureCrossesSignatureAndStartHeaderBoundaries() throws {
        let bytes = try sevenZipFixture()
        let expected = try ArchiveReader.open(data: bytes)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for boundary in [1, 5, 6, 7, 16, 31, 32, 33, 4096] {
            // 境界は先頭巻の長さ。残り全部を .002 に入れ、必ず 2 巻にする。
            let volumes = try writeVolumes([Data(bytes.prefix(boundary)), Data(bytes.dropFirst(boundary))],
                                          stem: "boundary-\(boundary).7z", below: directory)
            let reader = try ArchiveReader.open(url: volumes[0])
            try assertSameContents(reader, expected)
            XCTAssertEqual(try FormatDetector.detect(url: volumes[0]), .sevenZip)
        }
    }

    func testFourDigitVolumeNamesAreOpened() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ZipTestSupport.write(Data(bytes.prefix(16)), relativePath: "x.7z.0001", below: directory)
        try ZipTestSupport.write(Data(bytes.dropFirst(16)), relativePath: "x.7z.0002", below: directory)
        try assertSameContents(ArchiveReader.open(url: first), ArchiveReader.open(data: bytes))
    }

    func testSingleVolumeAndReopenMatchOrdinaryArchive() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([bytes], below: directory)[0]
        XCTAssertNil(try assemble(first))
        let reader = try ArchiveReader.open(url: first)
        try assertSameContents(reader, ArchiveReader.open(data: bytes))
        try FileManager.default.removeItem(at: first)
        try assertSameContents(reader.reopen(), reader)
    }

    func testMissingFinalOrMiddleVolumeIsTruncatedAndStopsAtGap() throws {
        let bytes = try sevenZipFixture()
        for missing in [1, 2] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let volumes = try writeVolumes([Data(bytes.prefix(64)), Data(bytes[64..<4096]),
                                            Data(bytes.dropFirst(4096))], below: directory)
            try FileManager.default.removeItem(at: volumes[missing])
            if missing == 1 {
                // 欠番より後ろの不正な巻を開いてしまうと malformed になる。
                try FileManager.default.removeItem(at: volumes[2])
                try FileManager.default.createDirectory(at: volumes[2], withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try ArchiveReader.open(url: volumes[0])) {
                XCTAssertEqual($0 as? KaitoError, .truncated)
            }
        }
    }

    func testStaleAndEmptyTrailingVolumesAreTolerated() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([Data(bytes.prefix(32)), Data(), Data(bytes.dropFirst(32)),
                                      Data([0xFA, 0xCE, 0xBE, 0xEF])], below: directory)[0]
        XCTAssertEqual(try assemble(first)?.volumeCount, 4)
        try assertSameContents(ArchiveReader.open(url: first), ArchiveReader.open(data: bytes))
    }

    func testVolumeLimitZeroOneAndExactCountAgreeForOpenAndDetect() throws {
        let bytes = try sevenZipFixture()
        for count in [1, 2, 3] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            // 末尾ゴミも巻数には含め、archive の内容とは独立に上限を検査する。
            let first = try writeVolumes([bytes] + Array(repeating: Data([0]), count: count - 1),
                                         below: directory)[0]
            for cap in [-1, 0, 1, 2, 3] {
                var limits = ReadLimits()
                limits.maxVolumeCount = cap
                let options = ReaderOptions(limits: limits)
                if cap < count {
                    XCTAssertThrowsError(try ArchiveReader.open(url: first, options: options)) {
                        XCTAssertEqual($0 as? KaitoError, .limitExceeded("split volume count"))
                    }
                    XCTAssertThrowsError(try FormatDetector.detect(url: first, options: options)) {
                        XCTAssertEqual($0 as? KaitoError, .limitExceeded("split volume count"))
                    }
                } else {
                    XCTAssertEqual(try ArchiveReader.open(url: first, options: options).format, .sevenZip)
                    XCTAssertEqual(try FormatDetector.detect(url: first, options: options), .sevenZip)
                }
            }
        }
    }

    func testDefaultVolumeLimitRejects129TinyVolumes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(ReadLimits().maxVolumeCount, 128)
        let first = try writeVolumes(Array(repeating: Data([0]), count: 129), below: directory)[0]
        XCTAssertThrowsError(try ArchiveReader.open(url: first)) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("split volume count"))
        }
    }

    func testAssemblyWithoutAnchorOrWithEmptyFirstVolumeIsSkipped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([try sevenZipFixture()], below: directory)[0]
        let opened = try FileByteSource.openAnchored(url: first)
        XCTAssertNil(try SplitVolumeSet.assemble(firstVolumeURL: first, firstVolumeSource: opened.source,
                                               directory: nil, limits: ReadLimits()))
        let empty = try writeVolumes([Data()], stem: "empty.7z", below: directory)[0]
        try FileManager.default.createDirectory(at: empty.deletingPathExtension().appendingPathExtension("002"),
                                                withIntermediateDirectories: false)
        XCTAssertNil(try assemble(empty))
    }

    func testNonSplitNameDoesNotOpenNumberedSiblings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try sevenZipFixture()
        let first = try ZipTestSupport.write(bytes, relativePath: "ordinary.7z", below: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("ordinary.002"),
                                                withIntermediateDirectories: false)
        XCTAssertNil(try assemble(first))
        XCTAssertNoThrow(try ArchiveReader.open(url: first, options: ReaderOptions(limits: ReadLimits(maxVolumeCount: 0))))
    }

    func testFIFOAndSymlinkAndDirectorySiblingsAreRejected() throws {
        for kind in ["fifo", "symlink", "directory"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = try writeVolumes([try sevenZipFixture()], below: directory)[0]
            let second = directory.appendingPathComponent("sample.7z.002")
            switch kind {
            case "fifo": XCTAssertEqual(Darwin.mkfifo(second.path, mode_t(0o600)), 0)
            case "symlink": try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
            default: try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try ArchiveReader.open(url: first)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("split volume is not a regular file"))
            }
            XCTAssertThrowsError(try FormatDetector.detect(url: first)) {
                XCTAssertEqual($0 as? KaitoError, .malformed("split volume is not a regular file"))
            }
        }
    }

    func testSymlinkFirstVolumeRemainsSingleAndNeverOpensSiblings() throws {
        let bytes = try sevenZipFixture()
        for complete in [false, true] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = try ZipTestSupport.write(complete ? bytes : Data(bytes.prefix(64)),
                                                 relativePath: "target", below: directory)
            let first = directory.appendingPathComponent("linked.7z.001")
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: target)
            XCTAssertEqual(Darwin.mkfifo(directory.appendingPathComponent("linked.7z.002").path, mode_t(0o600)), 0)
            XCTAssertNil(try assemble(first))
            if complete {
                try assertSameContents(ArchiveReader.open(url: first), ArchiveReader.open(data: bytes))
            } else {
                XCTAssertThrowsError(try ArchiveReader.open(url: first)) {
                    XCTAssertEqual($0 as? KaitoError, .truncated)
                }
            }
            XCTAssertEqual(try FormatDetector.detect(url: first), .sevenZip)
        }
    }

    func testFirstVolumeIdentityMismatchSkipsSiblings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([try sevenZipFixture()], below: directory)[0]
        let opened = try FileByteSource.openAnchored(url: first)
        try FileManager.default.removeItem(at: first)
        try Data([0]).write(to: first)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sample.7z.002"),
                                                withIntermediateDirectories: false)
        XCTAssertNil(try SplitVolumeSet.assemble(firstVolumeURL: first, firstVolumeSource: opened.source,
                                               directory: opened.directory, limits: ReadLimits()))
    }

    func testAssemblyUsesDirectoryCapturedBeforeFirstSourceOpen() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active")
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        let first = try writeVolumes([Data(bytes.prefix(16)), Data(bytes.dropFirst(16))], below: active)[0]
        let opened = try FileByteSource.openAnchored(url: first)
        try FileManager.default.moveItem(at: active, to: moved)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        try FileManager.default.linkItem(at: moved.appendingPathComponent(first.lastPathComponent), to: first)
        try Data([0]).write(to: active.appendingPathComponent("sample.7z.002"))
        let split = try XCTUnwrap(SplitVolumeSet.assemble(firstVolumeURL: first, firstVolumeSource: opened.source,
                                                         directory: opened.directory, limits: ReadLimits()))
        XCTAssertEqual(split.volumeCount, 2)
        try assertSameContents(ArchiveReader.open(source: split.source), ArchiveReader.open(data: bytes))
    }

    func testReadAndReopenRetainAllDescriptorsAfterUnlink() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volumes = try writeVolumes([Data(bytes.prefix(16)), Data(bytes.dropFirst(16))], below: directory)
        let reader = try ArchiveReader.open(url: volumes[0])
        for volume in volumes { try FileManager.default.removeItem(at: volume) }
        let expected = try ArchiveReader.open(data: bytes)
        try assertSameContents(reader, expected)
        try assertSameContents(reader.reopen(), expected)
    }

    func testDataAndArbitrarySourceDoNotResolveContinuation() throws {
        let firstBytes = Data(try sevenZipFixture().prefix(64))
        XCTAssertThrowsError(try ArchiveReader.open(data: firstBytes)) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
        XCTAssertThrowsError(try ArchiveReader.open(source: DataByteSource(firstBytes))) {
            XCTAssertEqual($0 as? KaitoError, .truncated)
        }
    }

    func testDirectContinuationOpenDoesNotRewind() throws {
        let bytes = try sevenZipFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volumes = try writeVolumes([Data(bytes.prefix(16)), Data(bytes.dropFirst(16))], below: directory)
        XCTAssertThrowsError(try ArchiveReader.open(url: volumes[1])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try FormatDetector.detect(url: volumes[1])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedFormat)
        }
    }

    func testSingleAndSplitCompressedTarUseStemHint() throws {
        let payload = Data("分割 tar の内容\n".utf8)
        let bytes = gzipStored(try TarTestSupport.makeTar(entries: [HandTarEntry(name: "page.txt", contents: payload)]))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for split in [false, true] {
            let pieces = split ? [Data(bytes.prefix(16)), Data(bytes.dropFirst(16))] : [bytes]
            let volumes = try writeVolumes(pieces, stem: "tar-\(split).tar.gz", below: directory)
            let reader = try ArchiveReader.open(url: volumes[0])
            XCTAssertEqual(reader.format, .tar)
            XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            // detect は従来どおり外側の圧縮形式を返し、open は tar 内を列挙する。
            XCTAssertEqual(try FormatDetector.detect(url: volumes[0]), .gzip)
            for volume in volumes { try FileManager.default.removeItem(at: volume) }
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.format, .tar)
            XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
        }
    }

    func testSingleAndSplitLZMAAloneUseStemForDetectionAndEntryName() throws {
        let bytes = try ZipTestSupport.checkedInFixture("singlefile/alone.lzma")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ordinary = try ZipTestSupport.write(bytes, relativePath: "ordinary.lzma", below: directory)
        let expected = try ArchiveReader.open(url: ordinary)
        let payload = try expected.read(expected.entries[0])
        for split in [false, true] {
            let pieces = split ? [Data(bytes.prefix(5)), Data(bytes.dropFirst(5))] : [bytes]
            let first = try writeVolumes(pieces, stem: "alone-\(split).lzma", below: directory)[0]
            XCTAssertEqual(try FormatDetector.detect(url: first), .lzma)
            let reader = try ArchiveReader.open(url: first)
            XCTAssertEqual(reader.format, .lzma)
            XCTAssertEqual(reader.entries.map(\.name), ["alone-\(split)"])
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        }
    }

    func testSplitSFXPreservesURLDetectionAndRebasedReads() throws {
        let archive = try sevenZipFixture()
        let bytes = ZipTestSupport.makePEPrefix(count: 1024) + archive
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([Data(bytes.prefix(1027)), Data(bytes.dropFirst(1027))],
                                     stem: "sfx.exe", below: directory)[0]
        XCTAssertEqual(try FormatDetector.detect(url: first), .sevenZip)
        try assertSameContents(ArchiveReader.open(url: first), ArchiveReader.open(data: archive))
    }

    func testRawZIPRecordsAreUnavailableOnlyForConcatenatedSets() throws {
        let bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "page.txt", uncompressedData: Data("zip".utf8))])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for split in [false, true] {
            let pieces = split ? [Data(bytes.prefix(16)), Data(bytes.dropFirst(16))] : [bytes]
            let first = try writeVolumes(pieces, stem: "zip-\(split).zip", below: directory)[0]
            let reader = try ArchiveReader.open(url: first)
            XCTAssertEqual(reader.format, .zip)
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("zip".utf8))
            for candidate in [reader, try reader.reopen()] {
                let record = try candidate.rawRecord(of: candidate.entries[0])
                if split { XCTAssertNil(record) } else { XCTAssertNotNil(record) }
            }
        }
    }

    func testByteSplitRARVolumeListsAndUsesAnonymousContinuationError() throws {
        let payload = Data("complete entry".utf8)
        let bytes = RAR5TestSupport.archive(mainFlags: 1, endFlags: 1, blocks: [
            RAR5TestSupport.storedFile(name: "complete.txt", contents: payload),
            RAR5TestSupport.storedFile(name: "split.bin", contents: Data([1, 2]), headerFlags: 0x0010),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([Data(bytes.prefix(6)), Data(bytes.dropFirst(6))],
                                     stem: "nested.rar", below: directory)[0]
        let reader = try ArchiveReader.open(url: first)
        XCTAssertEqual(reader.format, .rar)
        XCTAssertEqual(reader.entries.map(\.name), ["complete.txt", "split.bin"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
        XCTAssertThrowsError(try reader.read(reader.entries[1])) {
            XCTAssertEqual($0 as? KaitoError, .unsupportedMethod("multi-volume from Data"))
        }
        let reopened = try reader.reopen()
        XCTAssertEqual(try reopened.read(reopened.entries[0]), payload)
    }

    func testUnassembledRARFirstVolumeKeepsOriginalIdentityName() throws {
        let bytes = RAR5TestSupport.archive(mainFlags: 1, blocks: [])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeVolumes([bytes], stem: "single.rar", below: directory)[0]
        let reader = try ArchiveReader.open(url: first)
        XCTAssertEqual(reader.format, .rar)
        XCTAssertTrue(reader.entries.isEmpty)
    }

    func testGeneratedLZMA2VolumesMatchOracleAndReopenAfterUnlink() throws {
        try withGeneratedArchive(options: ["-m0=LZMA2", "-v40k"]) { first, volumes, payloads in
            XCTAssertEqual(volumes.count, 4)
            let reader = try assertGeneratedContents(first, payloads: payloads)
            for volume in volumes { try FileManager.default.removeItem(at: volume) }
            for candidate in [reader, try reader.reopen()] {
                for entry in candidate.entries { XCTAssertEqual(try candidate.read(entry), payloads[entry.name]) }
            }
        }
    }

    func testGeneratedMissingFinalAndMiddleVolumesAreTruncated() throws {
        for missing in [1, 3] {
            try withGeneratedArchive(options: ["-v40k"]) { first, volumes, _ in
                XCTAssertEqual(volumes.count, 4)
                try FileManager.default.removeItem(at: volumes[missing])
                XCTAssertThrowsError(try ArchiveReader.open(url: first)) {
                    XCTAssertEqual($0 as? KaitoError, .truncated)
                }
            }
        }
    }

    func testGeneratedStaleFifthVolumeIsTolerated() throws {
        try withGeneratedArchive(options: ["-v40k"]) { first, volumes, payloads in
            XCTAssertEqual(volumes.count, 4)
            let expected = try assertGeneratedContents(first, payloads: payloads)
            try Data([0xFA, 0xCE, 0xBE, 0xEF]).write(to: first.deletingPathExtension().appendingPathExtension("005"))
            try assertSameContents(ArchiveReader.open(url: first), expected)
        }
    }

    func testGeneratedUnequalVolumeSizesMatchOracle() throws {
        try withGeneratedArchive(options: ["-v10k", "-v15k", "-v2m"]) { first, volumes, payloads in
            XCTAssertEqual(volumes.count, 3)
            XCTAssertEqual(try Data(contentsOf: volumes[0]).count, 10 * 1024)
            XCTAssertEqual(try Data(contentsOf: volumes[1]).count, 15 * 1024)
            _ = try assertGeneratedContents(first, payloads: payloads)
        }
    }

    func testGeneratedSixteenByteVolumesStayWithinDefaultCap() throws {
        try withGeneratedArchive(options: ["-v16b"], small: true) { first, volumes, payloads in
            XCTAssertGreaterThan(volumes.count, 2)
            XCTAssertLessThanOrEqual(volumes.count, 128)
            XCTAssertEqual(try Data(contentsOf: first).count, 16)
            _ = try assertGeneratedContents(first, payloads: payloads)
        }
    }

    func testGeneratedEncryptedHeaderAndSolidVolumesMatchOracle() throws {
        try withGeneratedArchive(options: ["-v40k", "-mhe=on", "-ms=on", "-pSECRET"]) { first, volumes, payloads in
            XCTAssertGreaterThan(volumes.count, 1)
            let reader = try assertGeneratedContents(first, payloads: payloads, password: "SECRET")
            try assertSameContents(reader.reopen(), reader)
        }
    }

    func testGeneratedSolidVolumesMatchOracle() throws {
        try withGeneratedArchive(options: ["-v40k", "-ms=on"]) { first, _, payloads in
            let reader = try assertGeneratedContents(first, payloads: payloads)
            XCTAssertTrue(reader.entries.contains { $0.solidGroup >= 0 })
        }
    }

    func testGeneratedSingleVolumeMatchesOracle() throws {
        try withGeneratedArchive(options: ["-v1m"]) { first, volumes, payloads in
            XCTAssertEqual(volumes.count, 1)
            XCTAssertNil(try assemble(first))
            _ = try assertGeneratedContents(first, payloads: payloads)
        }
    }

    func testGeneratedByteSplitZIPMatchesOracle() throws {
        try withGeneratedArchive(options: ["-v40k"], zip: true) { first, volumes, payloads in
            XCTAssertEqual(volumes.count, 4)
            XCTAssertEqual(try FormatDetector.detect(url: first), .zip)
            let reader = try assertGeneratedContents(first, payloads: payloads)
            XCTAssertEqual(reader.format, .zip)
            for entry in reader.entries { XCTAssertNil(try reader.rawRecord(of: entry)) }
        }
    }

    private func sevenZipFixture() throws -> Data {
        try ZipTestSupport.checkedInFixture("sevenzip/chain-lzma-lzma-lzma2-bcj2.7z")
    }

    private func temporaryDirectory() throws -> URL {
        try ZipTestSupport.temporaryDirectory(label: "split-volumes")
    }

    private func writeVolumes(_ pieces: [Data], stem: String = "sample.7z", below directory: URL) throws -> [URL] {
        try pieces.enumerated().map { index, bytes in
            try ZipTestSupport.write(bytes, relativePath: stem + String(format: ".%03d", index + 1), below: directory)
        }
    }

    private func assemble(_ first: URL) throws -> SplitVolumeSet.Assembled? {
        let opened = try FileByteSource.openAnchored(url: first)
        return try SplitVolumeSet.assemble(firstVolumeURL: first, firstVolumeSource: opened.source,
                                           directory: opened.directory, limits: ReadLimits())
    }

    private func assertSameContents(_ actual: ArchiveReader, _ expected: ArchiveReader,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.format, expected.format, file: file, line: line)
        XCTAssertEqual(actual.entries, expected.entries, file: file, line: line)
        for entry in actual.entries {
            XCTAssertEqual(try actual.read(entry), try expected.read(entry), file: file, line: line)
        }
    }

    private func withGeneratedArchive(
        options: [String], small: Bool = false, zip: Bool = false,
        body: (URL, [URL], [String: Data]) throws -> Void
    ) throws {
        try SevenZipTestSupport.requireSevenZip()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let payloads: [String: Data] = small ? ["tiny.txt": Data("16 byte volumes\n".utf8)] : [
            "a.bin": RAR5TestSupport.deterministicPayload(count: 100_000, seed: 0x73706C6974),
            "b.bin": RAR5TestSupport.deterministicPayload(count: 30_000, seed: 0x3762797465),
            "c.txt": Data("split 7z fixture!\n".utf8),
        ]
        for (name, data) in payloads { try ZipTestSupport.write(data, relativePath: name, below: source) }
        let archive = directory.appendingPathComponent(zip ? "generated.zip" : "generated.7z")
        if zip {
            // makeArchive は -t7z 固定なので、ZIP は -tzip を一度だけ指定する別経路で生成する。
            try SevenZipTestSupport.checkedRun(arguments: ["a", "-bd", "-bb0", "-y", "-tzip"]
                                               + options + [archive.path] + payloads.keys.sorted(), currentDirectory: source)
        } else {
            try SevenZipTestSupport.makeArchive(sourceDirectory: source, paths: payloads.keys.sorted(),
                                                archiveURL: archive, options: options)
        }
        let volumes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(archive.lastPathComponent + ".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let first = try XCTUnwrap(volumes.first)
        try body(first, volumes, payloads)
    }

    private func assertGeneratedContents(_ first: URL, payloads: [String: Data], password: String? = nil) throws -> ArchiveReader {
        let reader = try ArchiveReader.open(url: first, options: ReaderOptions(password: password))
        XCTAssertEqual(reader.entries.map(\.name).sorted(), payloads.keys.sorted())
        for entry in reader.entries {
            let actual = try reader.read(entry)
            let oracle = try SevenZipTestSupport.extractedData(archiveURL: first, entryName: entry.name, password: password)
            XCTAssertEqual(actual, payloads[entry.name])
            XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: oracle))
        }
        return reader
    }

    // KaitoKit の既存テストと同じ RFC 1951 stored block / RFC 1952 envelope で、外部ツールを不要にする。
    private func gzipStored(_ input: Data) -> Data {
        precondition(input.count < 65536)
        var bytes = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255, 1])
        let size = UInt16(input.count)
        for value in [size, ~size] {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        bytes.append(input)
        for value in [CRC32.checksum(input), UInt32(input.count)] {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return bytes
    }
}
