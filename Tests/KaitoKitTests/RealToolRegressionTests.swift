import Darwin
import Foundation
@testable import KaitoKit
import XCTest

final class RealToolRegressionTests: XCTestCase {
    func testLeadingCombiningScalarsExtractWithoutFalseTraversal() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let names = ["\u{FF9E}name", "\u{FF9F}name", "\u{0301}name", "\u{3099}name", "\u{FE0F}name", "\u{200D}name"]
        let payload = Data("verified".utf8)
        let archive = try TarTestSupport.makeTar(entries: names.map {
            HandTarEntry(name: $0, contents: payload)
        })
        let reader = try ArchiveReader.open(data: archive)
        for entry in reader.entries {
            let url = try reader.extract(entry, to: temporary)
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }
    }

    func testLHASeparatorsDoNotBreakCP932TrailBytes() throws {
        for level: UInt8 in [0, 1, 2, 3] {
            let leaf = Array(try XCTUnwrap("表紙.txt".data(using: .shiftJIS)))
            for separator: UInt8 in [0xFF, 0x5C] {
                let archive = try LHATestSupport.makeArchive(entries: [
                    HandLHAEntry(rawName: Array("dir".utf8) + [separator] + leaf,
                                 contents: Data([1, 2, 3]), headerLevel: level)
                ])
                let reader = try ArchiveReader.open(data: archive)
                XCTAssertEqual(reader.entries[0].name, "dir/表紙.txt", "level \(level), separator \(separator)")
                XCTAssertEqual(try reader.read(reader.entries[0]), Data([1, 2, 3]))
            }
        }
    }

    func testLHALevelZeroUnixMetadataAndSymbolicLink() throws {
        let timestamp: UInt32 = 157_766_401
        var archive = try unixLevelZero(name: "file", contents: Data([42]), mode: 0o100755, time: timestamp)
        archive.append(try unixLevelZero(name: "shortcut|file", method: "-lhd-", mode: 0o120777, time: timestamp))
        archive.append(0)
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries.map(\.kind), [.file, .symlink])
        XCTAssertEqual(reader.entries[0].posixPermissions, 0o755)
        XCTAssertEqual(reader.entries[0].formatSpecific["uid"], "1")
        XCTAssertEqual(reader.entries[0].formatSpecific["gid"], "2")
        XCTAssertEqual(reader.entries[0].modificationDate?.timeIntervalSince1970, Double(timestamp))
        XCTAssertEqual(reader.entries[1].name, "shortcut")
        XCTAssertEqual(reader.entries[1].formatSpecific["linkPath"], "file")
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for entry in reader.entries { _ = try reader.extract(entry, to: temporary) }
        let attrs = try FileManager.default.attributesOfItem(atPath: temporary.appendingPathComponent("file").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: temporary.appendingPathComponent("shortcut").path), "file")
    }

    func testJapaneseShiftPrefixIsNotConclusiveEncodingEvidence() throws {
        for (encoding, names) in [(String.Encoding.shiftJIS, ["車.jpg", "実写.txt", "社.txt", "者.txt", "写真.jpg"]),
                                  (.japaneseEUC, ["ｶﾀｶﾅ.txt", "ﾃｽﾄ.jpg", "ﾍﾟｰｼﾞ.txt"])] {
            let entries = try names.map {
                HandLHAEntry(rawName: Array(try XCTUnwrap($0.data(using: encoding))), contents: Data([42]), headerLevel: 2)
            }
            let reader = try ArchiveReader.open(data: LHATestSupport.makeArchive(entries: entries))
            XCTAssertEqual(reader.entries.map(\.name), names)
            XCTAssertEqual(reader.nameEncoding, encoding)
        }
    }

    func testEUCHalfWidthNamesWithoutAllowlistEvidence() throws {
        // Each archive must vote independently; other Japanese names must not
        // rescue the ambiguous name through archive-level encoding selection.
        for name in ["ｶﾀｶﾅ半角.txt", "ｱｲｳｴｵ.txt", "ﾊﾋﾌﾍﾎ.bin"] {
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(rawName: Array(try XCTUnwrap(name.data(using: .japaneseEUC))),
                             contents: Data([42]), headerLevel: 2)
            ])
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(reader.entries[0].name, name)
            XCTAssertEqual(reader.nameEncoding, .japaneseEUC)
        }
        for name in ["車.jpg", "実写.txt", "社.txt", "者.txt", "写真.jpg"] {
            let archive = try LHATestSupport.makeArchive(entries: [
                HandLHAEntry(rawName: Array(try XCTUnwrap(name.data(using: .shiftJIS))),
                             contents: Data([42]), headerLevel: 2)
            ])
            XCTAssertEqual(try ArchiveReader.open(data: archive).entries[0].name, name)
        }
    }

    func testSymbolicLinkMayUseParentWithinExtractionRoot() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "top.txt", contents: Data([42])),
            HandTarEntry(name: "dir/link", type: 0x32, linkName: "../top.txt"),
            HandTarEntry(name: "dir/dangling", type: 0x32, linkName: "../missing/file"),
            HandTarEntry(name: "dir/escape", type: 0x32, linkName: "../../outside"),
            HandTarEntry(name: "dir/escape-first", type: 0x32, linkName: "../../root/file"),
        ])
        let reader = try ArchiveReader.open(data: data)
        for entry in reader.entries.prefix(3) { _ = try reader.extract(entry, to: temporary) }
        XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent("dir/link")), Data([42]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: temporary.appendingPathComponent("dir/dangling").path), "../missing/file")
        for entry in reader.entries.suffix(2) { XCTAssertThrowsError(try reader.extract(entry, to: temporary)) }
    }

    func testParentTargetNeverCancelsAnExistingSymlinkPivot() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: output.appendingPathComponent("dir/pivot").path, withDestinationPath: "../../outside")
        let archive = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "dir/link", type: 0x32, linkName: "pivot/../file")])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertThrowsError(try reader.extract(reader.entries[0], to: output))
    }

    func testCombiningScalarAfterSlashKeepsEveryDirectoryBoundary() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("root")
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("pivot").path, withDestinationPath: outside.path)
        let archive = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "pivot/\u{0301}escaped.txt", contents: Data([42])),
        ])
        let reader = try ArchiveReader.open(data: archive)
        XCTAssertEqual(reader.entries[0].pathComponents, ["pivot", "\u{0301}escaped.txt"])
        XCTAssertThrowsError(try reader.extract(reader.entries[0], to: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("\u{0301}escaped.txt").path))
    }

    func testCombiningScalarPathComponentsAcrossArchiveFormats() throws {
        let name = "dir/\u{0301}page.txt"
        let payload = Data([1, 2, 3])
        let archives = [
            try TarTestSupport.makeTar(entries: [HandTarEntry(name: name, contents: payload)]),
            try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: name, uncompressedData: payload)]),
            try LHATestSupport.makeArchive(entries: [HandLHAEntry(name: name, contents: payload, headerLevel: 2)]),
        ]
        for archive in archives {
            let temporary = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let reader = try ArchiveReader.open(data: archive)
            XCTAssertEqual(reader.entries[0].pathComponents, ["dir", "\u{0301}page.txt"])
            let output = try reader.extract(reader.entries[0], to: temporary)
            XCTAssertEqual(try Data(contentsOf: output), payload)
        }
    }

    func testRealRAR3AudioFilterMatchesDeterministicPCM() throws {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/rar4/kaito-audio.rar.b64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let reader = try ArchiveReader.open(data: data)
        let expected = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 3 + $0 / 79) })
        XCTAssertEqual(try reader.read(reader.entries[0]), expected)
    }

    func testShortAndUnknownLevelZeroUnixExtensionsStayBounded() throws {
        let complete = try unixLevelZero(name: "file", mode: 0o100755, time: 157_766_401)
        for short in [true, false] {
            var bytes = Array(complete)
            if short {
                bytes.removeLast()
                bytes[0] -= 1
            } else {
                let nameLength = Int(bytes[21])
                bytes[22 + nameLength + 3] = 1 // unknown Unix minor version
            }
            bytes[1] = bytes[2..<(Int(bytes[0]) + 2)].reduce(0, &+)
            bytes.append(0)
            let reader = try ArchiveReader.open(data: Data(bytes))
            XCTAssertEqual(reader.entries[0].name, "file")
            XCTAssertNil(reader.entries[0].formatSpecific["uid"])
            XCTAssertNil(reader.entries[0].formatSpecific["gid"])
            XCTAssertEqual(try reader.read(reader.entries[0]), Data())
        }
    }

    private func unixLevelZero(name: String, contents: Data = Data(), method: String = "-lh0-", mode: UInt16, time: UInt32) throws -> Data {
        var bytes = Array(try LHATestSupport.makeMember(HandLHAEntry(name: name, contents: contents, method: method, headerLevel: 0, creatorOS: 0x55)))
        let headerEnd = Int(bytes[0]) + 2
        var extensionBytes: [UInt8] = [0]
        extensionBytes += (0..<4).map { UInt8(truncatingIfNeeded: time >> ($0 * 8)) }
        extensionBytes += [UInt8(truncatingIfNeeded: mode), UInt8(truncatingIfNeeded: mode >> 8), 1, 0, 2, 0]
        bytes.insert(contentsOf: extensionBytes, at: headerEnd)
        bytes[0] += UInt8(extensionBytes.count)
        bytes[1] = bytes[2..<(Int(bytes[0]) + 2)].reduce(0, &+)
        return Data(bytes)
    }
}
