import Foundation
import KaitoKit
import XCTest

final class SymbolicLinkExtractionTests: XCTestCase {
    private func archive(_ links: [(String, String)], zip: Bool) throws -> Data {
        if zip {
            return try ZipTestSupport.makeArchive(entries: links.map {
                HandZipEntry(name: $0.0, uncompressedData: Data($0.1.utf8),
                             externalAttributes: UInt32(0o120777) << 16)
            })
        }
        return try TarTestSupport.makeTar(entries: links.map {
            HandTarEntry(name: $0.0, type: 0x32, linkName: $0.1)
        })
    }

    func testTwoEntryPivotRejectedInBothOrdersAndFormats() throws {
        try verifyPivot(parent: "x", target: "a/../canary.txt", pivot: "..")
    }

    func testThreeLevelPivotRejectedInBothOrdersAndFormats() throws {
        try verifyPivot(parent: "d1/d2", target: "a/../../../canary.txt", pivot: "../..")
    }

    private func verifyPivot(parent: String, target: String, pivot: String) throws {
        for zip in [false, true] {
            for pivotFirst in [false, true] {
                let temporary = try TarTestSupport.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temporary) }
                let root = temporary.appendingPathComponent("out")
                let canary = temporary.appendingPathComponent("canary.txt")
                try Data("canary".utf8).write(to: canary)
                let links = [(parent + "/link", target), (parent + "/a", pivot)]
                let reader = try ArchiveReader.open(data: archive(pivotFirst ? links.reversed() : links, zip: zip))
                for entry in reader.entries {
                    if entry.name.hasSuffix("/link") {
                        XCTAssertThrowsError(try reader.extract(entry, to: root))
                    } else {
                        _ = try reader.extract(entry, to: root)
                    }
                }
                // destinationOfSymbolicLink also detects dangling links (fileExists does not).
                XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(parent + "/link").path))
                XCTAssertEqual(try Data(contentsOf: canary), Data("canary".utf8))
            }
        }
    }

    func testCrossArchivePivotRejectedWithSeparateReadersAndReopen() throws {
        for zip in [false, true] {
            for reopen in [false, true] {
                for pivotFirst in [false, true] {
                    let temporary = try TarTestSupport.temporaryDirectory()
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let first = try ArchiveReader.open(data: archive([("x/link", "a/../canary.txt")], zip: zip))
                    let second = try ArchiveReader.open(data: archive([("x/a", "..")], zip: zip))
                    let linkReader = try reopen ? first.reopen() : first
                    let pivotReader = try reopen ? second.reopen() : second
                    if pivotFirst { _ = try pivotReader.extract(pivotReader.entries[0], to: temporary) }
                    XCTAssertThrowsError(try linkReader.extract(linkReader.entries[0], to: temporary))
                    if !pivotFirst { _ = try pivotReader.extract(pivotReader.entries[0], to: temporary) }
                    XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: temporary.appendingPathComponent("x/link").path))
                }
            }
        }
    }

    func testExistingSymlinkLeafRejected() throws {
        for zip in [false, true] {
            let temporary = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createSymbolicLink(atPath: temporary.appendingPathComponent("leaf").path, withDestinationPath: "../canary.txt")
            let reader = try ArchiveReader.open(data: archive([("link", "leaf")], zip: zip))
            XCTAssertThrowsError(try reader.extract(reader.entries[0], to: temporary))
            XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: temporary.appendingPathComponent("link").path))
        }
    }

    func testInRootParentAndForwardDirectoryReferences() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try ArchiveReader.open(data: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "sub/l", type: 0x32, linkName: "../top.txt"),
            HandTarEntry(name: "forward", type: 0x32, linkName: "later/nested"),
            HandTarEntry(name: "sub/forward", type: 0x32, linkName: "../later/nested"),
            HandTarEntry(name: "top.txt", contents: Data([42])),
            HandTarEntry(name: "later/nested/file", contents: Data([43])),
            HandTarEntry(name: "sub/cancel", type: 0x32, linkName: "../later/../top.txt"),
            HandTarEntry(name: "sub/root", type: 0x32, linkName: ".."),
        ]))
        for entry in reader.entries { _ = try reader.extract(entry, to: temporary) }
        for name in ["sub/l", "sub/cancel", "sub/root/top.txt"] {
            XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent(name)), Data([42]))
        }
        for name in ["forward/file", "sub/forward/file"] {
            XCTAssertEqual(try Data(contentsOf: temporary.appendingPathComponent(name)), Data([43]))
        }
    }

    func testValidatedDirectoryCannotLaterBecomePivotEvenWithOverwrite() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("x/a"), withIntermediateDirectories: true)
        let reader = try ArchiveReader.open(data: archive([("x/link", "a/../canary.txt"), ("x/a", "..")], zip: false))
        _ = try reader.extract(reader.entries[0], to: temporary)
        XCTAssertThrowsError(try reader.extract(reader.entries[1], to: temporary, options: ExtractionOptions(overwriteExisting: true)))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: temporary.appendingPathComponent("x/a").path))
    }
}
