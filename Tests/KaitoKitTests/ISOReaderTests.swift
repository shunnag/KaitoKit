import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class ISOReaderTests: XCTestCase {
    private typealias B = ISOImageBuilder
    private func open(_ builder: B, limits: ReadLimits = ReadLimits()) throws -> ArchiveReader {
        try ArchiveReader.open(data: builder.data, options: ReaderOptions(limits: limits))
    }
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/iso/\(name).iso.gz.b64")
        let base64 = try String(contentsOf: url, encoding: .utf8)
        let gzip = try ArchiveReader.open(data: XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters)))
        return try gzip.read(gzip.entries[0])
    }
    private func assertError(_ expected: String, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            let category: String
            switch error {
            case KaitoError.malformed: category = "malformed"
            case KaitoError.truncated: category = "truncated"
            case KaitoError.limitExceeded: category = "limit"
            case KaitoError.unsupportedMethod: category = "method"
            case KaitoError.unsupportedFormat: category = "format"
            case KaitoError.notFound: category = "notFound"
            default: category = String(describing: error)
            }
            XCTAssertEqual(category, expected, file: file, line: line)
        }
    }

    func testRealWritersNamesDirectoriesSymlinkAndSHA256() throws {
        let payloads: [String: Data] = [
            "a.txt": Data("hello iso 9660 test payload\n".utf8),
            "data.bin": Data((0..<4096).map { UInt8(($0 * 13) % 251) }),
            "日本語ファイル.txt": Data("日本語の内容\n".utf8),
            "sub/nested.txt": Data("nested payload\n".utf8)
        ]
        for name in ["joliet", "rr-joliet"] {
            let reader = try ArchiveReader.open(data: fixture(name))
            XCTAssertEqual(reader.format, .iso)
            XCTAssertEqual(reader.entries.count, name == "joliet" ? 5 : 6)
            for entry in reader.entries {
                if entry.kind == .file {
                    let expected = try XCTUnwrap(payloads[entry.name])
                    let actual = try reader.read(entry)
                    XCTAssertEqual(actual, expected)
                    XCTAssertEqual(SHA256.hash(data: actual), SHA256.hash(data: expected))
                } else {
                    XCTAssertEqual(entry.uncompressedSize, 0)
                    XCTAssertEqual(try reader.read(entry), Data())
                }
                XCTAssertEqual(entry.formatSpecific["nameSource"], name == "joliet" ? "joliet" : "rockRidge")
            }
            XCTAssertEqual(reader.entries.first { $0.name == "sub" }?.kind, .directory)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.entries, reader.entries)
            if name == "joliet" { XCTAssertEqual(reader.nameEncoding, .utf16BigEndian) }
            else {
                let link = try XCTUnwrap(reader.entries.first { $0.kind == .symlink })
                XCTAssertEqual(link.name, "link")
                XCTAssertEqual(link.formatSpecific["linkPath"], "sub/nested.txt")
                let temp = try TarTestSupport.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                for entry in reader.entries { _ = try reader.extract(entry, to: temp) }
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: temp.appendingPathComponent("link").path), "sub/nested.txt")
                XCTAssertEqual(try Data(contentsOf: temp.appendingPathComponent("link")), payloads["sub/nested.txt"])
            }
        }
    }

    func testDepthFirstPreOrderPreservesDirectoryRecordOrder() throws {
        var b = B()
        let rootFirst = b.file("A;1", payload: [1], su: B.nm("z-root"))
        let rootLast = b.file("C;1", payload: [2], su: B.nm("x-root"))
        let childFirst = b.file("A;1", payload: [3], su: B.nm("z-leaf"))
        let deepest = b.file("A;1", payload: [4], su: B.nm("inside"))
        let childLast = b.file("C;1", payload: [5], su: B.nm("a-leaf"))
        let siblingChild = b.file("A;1", payload: [6], su: B.nm("last"))
        b.root([
            rootFirst,
            B.record(Array("B".utf8), lba: 28, length: 2048, flags: 2, su: B.nm("y-dir")),
            rootLast,
            B.record(Array("D".utf8), lba: 30, length: 2048, flags: 2, su: B.nm("a-dir"))
        ], systemUse: B.sp())
        b.directory(28, [
            childFirst,
            B.record(Array("B".utf8), lba: 29, length: 2048, flags: 2, su: B.nm("m-deep")),
            childLast
        ])
        b.directory(29, [deepest])
        b.directory(30, [siblingChild])
        let reader = try open(b)
        // ISO 識別子は昇順だが NM 名は昇順でない。表示名の sort ではこの順序にならない。
        XCTAssertEqual(reader.entries.map(\.name), [
            "z-root", "y-dir", "y-dir/z-leaf", "y-dir/m-deep", "y-dir/m-deep/inside",
            "y-dir/a-leaf", "x-root", "a-dir", "a-dir/last"
        ])
        XCTAssertEqual(reader.entries.map(\.index), Array(0..<9))
        let expected: [Data] = [[1], [], [3], [], [4], [5], [2], [], [6]].map { Data($0) }
        XCTAssertEqual(try reader.entries.map { try reader.read($0) }, expected)
    }

    func testDetectionShortZerosHighSierraAndExistingFormats() throws {
        for size in [0, 34815, 65536] {
            assertError("format") { _ = try FormatDetector.detect(data: Data(repeating: 0, count: size)) }
        }
        var highSierra = Data(repeating: 0, count: 65536)
        highSierra.replaceSubrange(32777..<32782, with: "CDROM".utf8)
        assertError("format") { _ = try FormatDetector.detect(data: highSierra) }
        var udf = Data(repeating: 0, count: 65536)
        udf.replaceSubrange(32769..<32774, with: "BEA01".utf8)
        assertError("format") { _ = try ArchiveReader.open(data: udf) }
        var iso = B(); iso.root([])
        for magic: [UInt8] in [[80,75,3,4], [82,97,114,33,26,7,0], [55,122,188,175,39,28], [31,139], [31,157]] {
            var data = iso.data; data.replaceSubrange(0..<magic.count, with: magic)
            XCTAssertNotEqual(try FormatDetector.detect(data: data), .iso)
        }
        var tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "x", contents: Data(repeating: 0, count: 40000))])
        tar.replaceSubrange(32768..<32775, with: [1,67,68,48,48,49,1])
        XCTAssertEqual(try FormatDetector.detect(data: tar), .tar)
    }

    func testCD001DoesNotStealDamagedZIPOrSFXDetection() throws {
        var zip = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "x", uncompressedData: Data(repeating: 0, count: 40000))])
        zip.replaceSubrange(32768..<32775, with: [1,67,68,48,48,49,1])
        zip[0] = 0
        XCTAssertEqual(try FormatDetector.detect(data: zip), .zip)
        for (format, marker): (ArchiveFormat, [UInt8]) in [(.zip, [80,75,3,4]), (.rar, [82,97,114,33,26,7,0]), (.sevenZip, [55,122,188,175,39,28])] {
            var sfx = ZipTestSupport.makePEPrefix(count: 40000)
            sfx.replaceSubrange(192..<192+marker.count, with: marker)
            sfx.replaceSubrange(32768..<32775, with: [1,67,68,48,48,49,1])
            XCTAssertEqual(try FormatDetector.detect(data: sfx, options: ReaderOptions(scanForSFXInData: true)), format)
        }
    }

    func testRootSPWithSkipForOtherRecordsStillChecksRootCE() throws {
        for skip: UInt8 in [14, 255] {
            var b = B()
            let loop = B.ce(25, length: 28)
            b.write(loop, at: 25 * 2048)
            b.root([], systemUse: B.sp(skip) + loop)
            assertError("malformed") { _ = try open(b) }
        }
    }

    func testNameAndSymlinkAccumulationCaps() throws {
        for link in [false, true] {
            var b = B()
            let count = link ? 3 : 1
            for area in 0..<count {
                var bytes: [UInt8] = []
                for index in 0..<8 {
                    let continued = area != count - 1 || index != 7
                    if link {
                        bytes += B.su("SL", [continued ? 1 : 0, 0, 200] + [UInt8](repeating: 97, count: 200))
                    } else {
                        bytes += B.su("NM", [continued ? 1 : 0] + [UInt8](repeating: 97, count: 200))
                    }
                }
                if area + 1 < count { bytes += B.ce(UInt32(26 + area), length: UInt32(area + 2 == count ? 8 * 207 : 8 * 207 + 28)) }
                b.write(bytes, at: (25 + area) * 2048)
            }
            let areaLength = link ? 8 * 207 + 28 : 8 * 205
            b.root([b.file("A", su: B.ce(25, length: UInt32(areaLength)))], systemUse: B.sp())
            assertError("malformed") { _ = try open(b) }
        }
    }

    func testBlockSizesExtendedAttributesAndVersionCollision() throws {
        for size in [512, 1024, 2048] {
            var b = B(blockSize: size)
            let first = b.file("MAKEFILE.;2", payload: [1,2,3], ea: 1)
            let old = b.file("MAKEFILE.;1", payload: [4])
            b.root([first, old], ea: size == 512 ? 1 : 0)
            let r = try open(b)
            XCTAssertEqual(r.entries.map(\.name), ["MAKEFILE"])
            XCTAssertEqual(r.entries[0].formatSpecific["skippedOlderVersions"], "1")
            XCTAssertEqual(try r.read(r.entries[0]), Data([1,2,3]))
        }
    }

    func testThreeSectorDirectoryPaddingContinues() throws {
        var b = B()
        let first = b.file("A;1"), second = b.file("B;1"), third = b.file("C;1")
        b.root([first], length: 6144)
        b.write(second, at: 21 * 2048)
        b.write(third, at: 22 * 2048)
        XCTAssertEqual(try open(b).entries.map(\.name), ["A", "B", "C"])
    }

    func testBothEndianMismatchIsObservableAndLEWins() throws {
        var b = B(); var file = b.file("A;1")
        file[6] ^= 1; b.root([file])
        var r = try open(b)
        XCTAssertEqual(r.entries[0].formatSpecific["bothEndianMismatch"], "true")
        XCTAssertEqual(try r.read(r.entries[0]), Data("payload".utf8))
        b.data[32768 + 84] ^= 1
        r = try open(b)
        XCTAssertEqual(r.entries[0].formatSpecific["bothEndianMismatch"], "true")
    }

    func testJolietEscapeLevelsOddByteAndSurrogate() throws {
        for marker: UInt8 in [64, 67, 69] {
            var b = B(joliet: true)
            b.root([b.file("_.TXT;1")])
            let name = "日本語のとても長い名前のテストファイル.txt"
            b.root([B.record(B.ucs2(name + ";1") + [48], lba: 22),
                    B.record([0xD8,0,0,65], lba: 22)], joliet: true)
            b.data[17 * 2048 + 90] = marker; b.data[17 * 2048 + 91] = 127
            let r = try open(b)
            XCTAssertEqual(r.entries.map(\.name), [name, "�A"])
        }
    }

    func testTreeFallbackBothDirectionsAndLimitNeverFallsBack() throws {
        for badPVD in [false, true] {
            var b = B(joliet: true)
            b.root([b.file("PVD;1")]); b.root([B.record(B.ucs2("Joliet;1"), lba: 22)], joliet: true)
            let offset = (badPVD ? 16 : 17) * 2048 + 158
            b.write([255,255,255,255], at: offset)
            XCTAssertEqual(try open(b).entries.map(\.name), badPVD ? ["Joliet"] : ["PVD"])
        }
        var b = B(joliet: true); b.root([b.file("PVD;1")]); b.root([], joliet: true)
        assertError("limit") { _ = try open(b, limits: ReadLimits(maxEntryCount: 0)) }
    }

    func testNMChainAcrossCEAndPOSIXVersionSuffixUnchanged() throws {
        var b = B(joliet: true)
        let continuation = B.nm("後半;1")
        b.write(continuation, at: 25 * 2048)
        let su = B.nm("前半", flags: 1) + B.ce(25, length: UInt32(continuation.count))
        b.root([b.file("ISO;1", su: su)], systemUse: B.sp())
        b.root([B.record(B.ucs2("Joliet;1"), lba: 22)], joliet: true)
        let r = try open(b)
        XCTAssertEqual(r.entries.map(\.name), ["前半後半;1"])
        XCTAssertEqual(r.entries[0].formatSpecific["nameSource"], "rockRidge")
    }

    func testArchiveWideCP932AndEUCJPNames() throws {
        let names = ["日本語ファイル.txt", "表紙画像.jpg", "漫画の原稿.txt"]
        for encoding in [String.Encoding.shiftJIS, .japaneseEUC] {
            var b = B()
            var files: [[UInt8]] = []
            for (i, name) in names.enumerated() {
                let bytes = Array(try XCTUnwrap(name.data(using: encoding)))
                files.append(b.file("FILE\(i);1", su: B.su("NM", [0] + bytes)))
            }
            b.root(files, systemUse: B.sp())
            let r = try open(b)
            XCTAssertEqual(r.entries.map(\.name), names)
            XCTAssertNotNil(r.nameEncoding)
            let fixed = try ArchiveReader.open(data: b.data, options: ReaderOptions(encodingPolicy: .fixed(encoding)))
            XCTAssertEqual(fixed.entries.map(\.name), names)
        }
    }

    func testPXBothLengthsTFShortLongAndNegativeGMT() throws {
        for old in [false, true] {
            var b = B()
            let created: [UInt8] = [126,9,8,0,0,0,0]
            let modified: [UInt8] = [126,9,9,1,2,3,252] // UTC-1h
            let su = B.nm("name") + B.px(0o100640, old: old) + B.su("TF", [15] + created + modified + created + created)
            b.root([b.file("A", su: su)], systemUse: B.sp())
            let r = try open(b)
            XCTAssertEqual(r.entries[0].posixPermissions, 0o640)
            let expected = ISO8601DateFormatter().date(from: "2026-09-09T02:02:03Z")!
            XCTAssertEqual(r.entries[0].modificationDate, expected)
        }
        var b = B()
        let tf = B.su("TF", [130] + Array("2026090901020312".utf8) + [252])
        b.root([b.file("A", su: B.nm("name") + tf)], systemUse: B.sp())
        let date = try XCTUnwrap(open(b).entries[0].modificationDate)
        XCTAssertEqual(date.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-09-09T02:02:03Z")!.timeIntervalSince1970 + 0.12, accuracy: 0.0001)
    }

    func testSLTwoContinuationsRootCurrentAndParent() throws {
        var b = B()
        let first = B.su("SL", [1, 8,0, 1,3] + Array("abc".utf8))
        let last = B.su("SL", [0, 0,3] + Array("def".utf8) + [2,0, 4,0, 0,1,120])
        b.write(last, at: 25 * 2048)
        b.root([b.file("LINK", payload: [], su: B.nm("link") + B.px(0o120777) + first + B.ce(25, length: UInt32(last.count)))], systemUse: B.sp())
        let r = try open(b)
        XCTAssertEqual(r.entries[0].kind, .symlink)
        XCTAssertEqual(r.entries[0].formatSpecific["linkPath"], "/abcdef/./../x")
        XCTAssertEqual(try r.read(r.entries[0]), Data())
    }

    func testRelocationAndCLCycle() throws {
        var b = B()
        let moved = B.record(Array("MOVED".utf8), lba: 23, length: 2048, flags: 2, su: B.nm("rr_moved"))
        let placeholder = B.record(Array("DEEP".utf8), lba: .max, length: .max, su: B.nm("deep") + B.numberEntry("CL", 24))
        b.root([moved, placeholder], systemUse: B.sp())
        b.directory(23, [B.record(Array("RELOC".utf8), lba: 24, length: 2048, flags: 2, su: B.su("RE"))])
        b.directory(24, [B.record([0], lba: 24, length: 2048, flags: 2, su: B.px(0o040750)),
                         B.record([1], lba: 23, length: 2048, flags: 2, su: B.numberEntry("PL", 20)),
                         B.record(Array("FILE;1".utf8), lba: 22, su: B.nm("file")),
                         B.record(Array("LOOP".utf8), lba: .max, su: B.nm("loop") + B.numberEntry("CL", 20))])
        let r = try open(b)
        XCTAssertEqual(Set(r.entries.map(\.name)), ["rr_moved", "deep", "deep/file", "deep/loop"])
        XCTAssertEqual(r.entries.first { $0.name == "deep" }?.posixPermissions, 0o750)
        XCTAssertEqual(r.entries.first { $0.name == "deep/loop" }?.formatSpecific["cycleSkipped"], "true")
    }

    func testJolietIgnoresRelocationMarkers() throws {
        var b = B(joliet: true); b.root([])
        b.root([B.record(B.ucs2("visible"), lba: 22, su: B.su("RE") + B.numberEntry("CL", .max))], systemUse: B.sp(), joliet: true)
        XCTAssertEqual(try open(b).entries.map(\.name), ["visible"])
    }

    func testXASkipAndAppleBAAndMalformedSUSPLengths() throws {
        for stop in [B.su("BA", [6,0,0,0]), [90,90,0,1], [90,90,3,1]] {
            var b = B()
            let prefix = [UInt8](repeating: 0, count: 14)
            b.root([b.file("RAW;1", su: prefix + B.nm("before") + stop + B.nm("after"))], systemUse: prefix + B.sp(14))
            XCTAssertEqual(try open(b).entries.map(\.name), ["before"])
        }
    }

    func testCycleAndDepthAreBounded() throws {
        var cycle = B()
        cycle.root([B.record(Array("CYCLE".utf8), lba: 20, length: 2048, flags: 2)])
        let r = try open(cycle)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].formatSpecific["cycleSkipped"], "true")
        var deep = B(sectors: 1050)
        deep.root([B.record(Array("D".utf8), lba: 22, length: 2048, flags: 2)])
        for lba: UInt32 in 22..<1045 {
            deep.directory(lba, [B.record(Array("D".utf8), lba: lba + 1, length: 2048, flags: 2)])
        }
        let reader = try open(deep)
        XCTAssertEqual(reader.entries.count, 1024)
        XCTAssertEqual(reader.entries.last?.pathComponents.count, 1024)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.last)), Data())
    }

    func testDirectoryDepthUsesConfiguredPathComponentLimit() throws {
        var b = B()
        b.root([B.record(Array("A".utf8), lba: 22, length: 2048, flags: 2)])
        b.directory(22, [B.record(Array("B".utf8), lba: 23, length: 2048, flags: 2)])
        b.directory(23, [B.record(Array("C".utf8), lba: 24, length: 2048, flags: 2)])
        let options = ReaderOptions(limits: ReadLimits(maxPathComponentCount: 3))
        let boundary = try ArchiveReader.open(data: b.data, options: options)
        XCTAssertEqual(boundary.entries.map(\.name), ["A", "A/B", "A/B/C"])

        b.directory(24, [B.record(Array("D".utf8), lba: 25, length: 2048, flags: 2)])
        XCTAssertThrowsError(try ArchiveReader.open(data: b.data, options: options)) { error in
            guard case KaitoError.limitExceeded("iso directory depth") = error else {
                return XCTFail("Expected directory depth limit, got \(error)")
            }
        }
        XCTAssertEqual(try open(b).entries.map(\.name), ["A", "A/B", "A/B/C", "A/B/C/D"])
    }

    func testCECyclesBoundsAndChainCap() throws {
        for mode in 0..<4 {
            var b = B()
            var ce = B.ce(25, length: 28)
            if mode == 1 { ce = B.ce(25, offset: 2040, length: 28) }
            if mode == 2 { ce = B.ce(25, length: 3) }
            b.root([b.file("A", su: ce)], systemUse: B.sp())
            if mode == 3 {
                for i in 0..<9 { b.write(B.ce(25, offset: UInt32((i + 1) * 28), length: 28), at: 25 * 2048 + i * 28) }
            } else { b.write(ce, at: 25 * 2048) }
            assertError("malformed") { _ = try open(b) }
        }
    }

    func testBadNamesUnfinishedNMAndSLRejected() throws {
        for su in [B.nm("a/b"), B.nm(".."), B.nm("a\0b"), B.nm("x", flags: 1),
                   B.su("SL", [1,0,1,97]), B.su("SL", [0,1,1,97]),
                   B.su("NM", [1] + [UInt8](repeating: 97, count: 200)) + B.nm("x", flags: 1)] {
            var b = B(); b.root([b.file("A", su: su)], systemUse: B.sp())
            assertError("malformed") { _ = try open(b) }
        }
    }

    func testMalformedDirectoryAndExtentBounds() throws {
        for mode in 0..<5 {
            var b = B()
            var file = b.file("A")
            if mode == 0 { B.both(&file, 2, .max) }
            if mode == 1 { B.both(&file, 10, .max) }
            b.root([file])
            if mode == 2 { b.data[20 * 2048] = 33 }
            if mode == 3 { b.data[20 * 2048 + 32] = 255 }
            if mode == 4 {
                // 合法 record を詰めて sector 残り 8 byte に次の record を置く。
                let records = (0..<60).map { _ in B.record([2], lba: 22) }
                b.directory(20, records)
                b.data[20 * 2048 + 2040] = 34
            }
            assertError(mode < 2 ? "truncated" : "malformed") { _ = try open(b) }
        }
    }

    func testMultiExtentStreamingBrokenChainAndSectionCap() throws {
        var b = B()
        let parts: [[UInt8]] = [[1,2,3], [], [4,5]]
        var records: [[UInt8]] = []
        for (i, part) in parts.enumerated() { records.append(b.file("A;1", payload: part, flags: i < 2 ? 128 : 0)) }
        b.root(records)
        let r = try open(b)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].uncompressedSize, 5)
        XCTAssertEqual(try r.read(r.entries[0]), Data([1,2,3,4,5]))
        let stream = try r.stream(r.entries[0])
        var bytes: [UInt8] = []; var buffer = [UInt8](repeating: 0, count: 2)
        while true {
            let n = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if n == 0 { break }; bytes += buffer.prefix(n)
        }
        XCTAssertEqual(bytes, [1,2,3,4,5])
        b.root([records[0], B.record(Array("OTHER;1".utf8), lba: 22)])
        XCTAssertEqual(try open(b).entries.count, 2)
        var many = B()
        many.root((0..<65).map { B.record(Array("A;1".utf8), lba: 25, flags: $0 < 64 ? 128 : 0) }, length: 4096)
        assertError("limit") { _ = try open(many) }
    }

    func testFinalSectionSUSPOverridesEarlierSection() throws {
        var b = B()
        let a = b.file("A;1", payload: [1], su: B.nm("first"), flags: 128)
        let z = b.file("A;1", payload: [2], su: B.nm("last"))
        b.root([a,z], systemUse: B.sp())
        XCTAssertEqual(try open(b).entries.map(\.name), ["last"])
        b.root([a, B.record(Array("A;1".utf8), lba: 23, length: 1)], systemUse: B.sp())
        XCTAssertEqual(try open(b).entries.map(\.name), ["A"])
    }

    func testUnsupportedFeaturesListAndRejectStreams() throws {
        for feature in ["interleaved", "sparse", "zisofs", "otherVolume"] {
            var b = B()
            let su = feature == "sparse" ? B.su("SF") : (feature == "zisofs" ? B.su("ZF") : [])
            let file = B.record(Array("A".utf8), lba: feature == "otherVolume" ? .max : 22,
                                length: 7, su: su, unit: feature == "interleaved" ? 1 : 0,
                                sequence: feature == "otherVolume" ? 2 : 1)
            b.root([file], systemUse: B.sp())
            if feature == "otherVolume" { b.write([2,0,0,2], at: 32768 + 120) }
            let r = try open(b)
            XCTAssertEqual(r.entries.count, 1)
            XCTAssertEqual(r.entries[0].formatSpecific["unsupported"], feature)
            XCTAssertEqual(r.entries[0].uncompressedSize, 7)
            XCTAssertEqual(r.entries[0].isIncomplete, feature == "otherVolume")
            assertError("method") { _ = try r.stream(r.entries[0]) }
        }
        var b = B(); b.root([B.record(Array("A".utf8), lba: 22, sequence: 7)])
        XCTAssertEqual(try open(b).entries.count, 1)
    }

    func testReaderLimitsAndStreamLimits() throws {
        var b = B()
        b.root([b.file("A", su: B.nm("name")), b.file("B")], systemUse: B.sp())
        for limits in [ReadLimits(maxEntryCount: 1), ReadLimits(maxEntrySize: 6),
                       ReadLimits(maxMetadataSize: 2047), ReadLimits(maxMetadataRecordCount: 3),
                       ReadLimits(maxPathComponentCount: 0), ReadLimits(maxTotalMetadataSize: 2048),
                       ReadLimits(maxTotalUncompressedSize: 13)] {
            assertError("limit") { _ = try open(b, limits: limits) }
        }
        let r = try open(b, limits: ReadLimits(maxInMemorySize: 6))
        assertError("limit") { _ = try r.read(r.entries[0]) }
        var suLimits = B()
        suLimits.root([suLimits.file("A", su: B.nm("name") + B.px(0o100644) + B.su("PD") + B.su("PD"))], systemUse: B.sp())
        assertError("limit") { _ = try open(suLimits, limits: ReadLimits(maxMetadataRecordCount: 3)) }
    }

    func testForeignEntryIdentityAndMissingTerminatorBootDescriptor() throws {
        var b = B(); b.root([b.file("A")])
        let r = try ISOReader(source: DataByteSource(b.data), options: ReaderOptions())
        var other = B(); other.root([other.file("B")])
        let foreign = try open(other).entries[0]
        assertError("notFound") { _ = try r.stream(for: foreign, limits: ReadLimits()) }
        b.data[17 * 2048] = 0; b.data[17 * 2048 + 1] = 0
        XCTAssertEqual(try open(b).entries.count, 1)
        let pvd = Array(b.data[32768..<34816])
        b.descriptor(16, type: 0, root: 20); b.write(pvd, at: 17 * 2048)
        b.descriptor(18, type: 255, root: 20)
        XCTAssertEqual(try open(b).entries.count, 1)
    }
}
