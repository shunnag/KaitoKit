import Foundation
@testable import KaitoKit
import XCTest

final class ZipParseSharingTests: XCTestCase {
    func testSplitterPreservesBridgedAndCanonicalNameBytes() {
        let bridged = NSMutableString(string: String(repeating: "日本語/", count: 32) + "bridged-leaf")
        let names = ["", "a", "a/", "/a", "a//b", "/", "//", "a/b/c.txt",
                     "café/a", "cafe\u{301}/b", "café/c", "cafe\u{301}/d",
                     "x/a", "y/a", "x/b", "y/b", "x/", "x/c",
                     String(repeating: "d/", count: 63) + "leaf",
                     "abcdefghijklmnopq/abcdefghijklmnopq", bridged as String,
                     String(repeating: "日本語/", count: 32) + "next-leaf"]
        var splitter = ZipPathComponentSplitter()
        for name in names {
            let oracle = name.utf8.split(separator: 0x2f, omittingEmptySubsequences: true).map { Array($0) }
            XCTAssertEqual(splitter.split(name).map { Array($0.utf8) }, oracle)
        }
    }

    func testAdjacentMetadataVariantsAndCacheEviction() throws {
        var entries: [HandZipEntry] = []
        var expected: [[String: String]] = []
        for _ in 0..<3 {
            for variant in 0..<14 {
                let host: UInt16 = [0, 3, 19][variant % 3]
                let made = host << 8 | 20
                let method: UInt16 = variant == 1 ? 8 : 0
                let flags: UInt16 = variant == 10 ? 0x0808 : (variant == 11 ? 0 : 0x0800)
                var entry = HandZipEntry(name: variant == 9 ? "empty/" : "d/f\(entries.count)",
                    method: method, flags: flags, versionMadeBy: made)
                var encryption = "none"
                if variant == 2 { entry.flags |= 1; encryption = "ZipCrypto" }
                if (3...6).contains(variant) {
                    let strength: UInt8 = variant < 5 ? 1 : 3
                    let version: UInt8 = variant % 2 == 1 ? 1 : 2
                    let extra = try ZipTestSupport.extraField(identifier: 0x9901,
                        payload: Data([version, 0, 0x41, 0x45, strength, 0, 0]))
                    entry.method = 99; entry.flags |= 1
                    entry.localExtra = extra; entry.centralExtra = extra
                    entry.centralCRC32 = 0
                    encryption = strength == 1 ? "AES-128" : "AES-256"
                }
                if variant == 8 { entry.externalAttributes = UInt32(0o120777) << 16 }
                if variant == 10 { entry.hasDataDescriptor = true }
                if variant >= 12 { entry.flags |= UInt16(variant - 11) << 4 }
                var specific = ["method": String(method), "versionMadeBy": String(made),
                    "flags": String(format: "0x%04x", entry.flags), "hostOS": String(host), "encryption": encryption]
                if variant == 8 { specific["linkTargetStoredAsData"] = "true" }
                entries.append(entry); expected.append(specific)
            }
        }
        let reader = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: entries))
        XCTAssertEqual(reader.entries.map(\.formatSpecific), expected)
        // rawRecord の COW 挿入が共有元の辞書を書き換えない。
        for entry in reader.entries { _ = try reader.rawRecord(of: entry) }
        XCTAssertEqual(reader.entries.map(\.formatSpecific), expected)
    }

    func testUniformThousandEntriesShareDictionaryStorage() throws {
        XCTAssertEqual(MemoryLayout<[String: String]>.size, 8)
        let bytes = try ZipTestSupport.makeArchive(entries: (0..<1000).map { HandZipEntry(name: "d/f\($0)") })
        let reader = try ArchiveReader.open(data: bytes)
        let identities = Set(reader.entries.map { entry in
            withUnsafeBytes(of: entry.formatSpecific) { Data($0) }
        })
        XCTAssertLessThanOrEqual(identities.count, 8)
        print("ZIP-SHARING entries=1000 dictionary-storages=\(identities.count)")
    }

    func testLogicalMetadataBudgetIsUnchangedAtBoundary() throws {
        let bytes = try ZipTestSupport.makeArchive(entries: (0..<20).map { HandZipEntry(name: "d/f\($0)") })
        let entries = try ArchiveReader.open(data: bytes).entries
        let cost = entries.reduce(UInt64(0)) { total, entry in
            total + 256 + UInt64(entry.rawName.bytes.count + entry.name.utf8.count)
                + UInt64(entry.pathComponents.count * MemoryLayout<String>.stride)
                + UInt64(entry.pathComponents.reduce(0) { $0 + $1.utf8.count })
                + UInt64(entry.formatSpecific.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count })
        }
        XCTAssertEqual(try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxTotalMetadataSize: cost))).entries, entries)
        XCTAssertThrowsError(try ArchiveReader.open(data: bytes, options: ReaderOptions(limits: ReadLimits(maxTotalMetadataSize: cost - 1)))) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("size \(cost) exceeds limit \(cost - 1)"))
        }
    }

    func testPathAndNameBytesMatchOriginalExpressionAndFoundation() throws {
        let names = ["a", "a/", "/a", "a//b", "/", "//", "a/b/c.txt",
                     String(repeating: "d/", count: 63) + "f", "abcdefghijklmnopq/long-leaf-name",
                     "日本語/葉", "café/a", "cafe\u{301}/b", "x/a", "y/a", "x/b", "y/b"]
        let entries = names.map { HandZipEntry(name: $0) } + [
            HandZipEntry(rawName: [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea], flags: 0),
            HandZipEntry(rawName: Array(1...127), flags: 0x800),
            HandZipEntry(rawName: [0xef, 0xbb, 0xbf, 0x61], flags: 0x800),
            HandZipEntry(rawName: [0xc0, 0xaf, 0xff], flags: 0x800)]
        let reader = try ArchiveReader.open(data: ZipTestSupport.makeArchive(entries: entries))
        for entry in reader.entries {
            let oracle = entry.name.utf8.split(separator: 0x2f, omittingEmptySubsequences: true).map { Array($0) }
            XCTAssertEqual(entry.pathComponents.map { Array($0.utf8) }, oracle)
            if entry.rawName.declaredEncoding == .utf8,
               let decoded = EncodingDetector.decode(bytes: entry.rawName.bytes, as: .utf8) {
                XCTAssertEqual(Array(entry.name.utf8), Array(decoded.utf8))
            }
        }
        let nested = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "a/b/c")])
        XCTAssertEqual(try ArchiveReader.open(data: nested, options: ReaderOptions(limits: ReadLimits(maxPathComponentCount: 3))).entries.count, 1)
        XCTAssertThrowsError(try ArchiveReader.open(data: nested, options: ReaderOptions(limits: ReadLimits(maxPathComponentCount: 2)))) {
            XCTAssertEqual($0 as? KaitoError, .limitExceeded("ZIP path component count"))
        }
    }
}
