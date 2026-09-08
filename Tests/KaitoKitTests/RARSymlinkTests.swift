import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class RARSymlinkTests: XCTestCase {
    private func fixture(_ path: String) throws -> Data {
        let url = ZipTestSupport.repositoryRoot.appendingPathComponent("Tests/Fixtures/\(path).rar.b64")
        return try XCTUnwrap(Data(
            base64Encoded: String(contentsOf: url, encoding: .utf8),
            options: .ignoreUnknownCharacters
        ))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testRAR4StoredMemberPreservesSolidHistoryIncludingEncryption() throws {
        for name in ["solid-stored", "solid-stored-p", "solid-stored-hp"] {
            let reader = try ArchiveReader.open(
                data: fixture("rar4/\(name)"), options: ReaderOptions(password: "pw123")
            )
            XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "s.lnk", "b.txt"])
            XCTAssertEqual(reader.entries.map(\.solidGroup), [0, -1, 0])
            let link = reader.entries[1]
            XCTAssertEqual(link.formatSpecific["method"], "0x30")
            if name != "solid-stored" {
                XCTAssertEqual(link.formatSpecific["unpackVersion"], "29")
                XCTAssertEqual(link.compressedSize, 208)
            }
            // Seek over the stored member, restart backwards, and read it while
            // a compressed stream is active. None may change the shared state.
            for index in [2, 0, 2] {
                XCTAssertEqual(digest(try reader.read(reader.entries[index])),
                               "74afbb86e62b28d58e0ed4535792c9d2d932ae7556dd0a8e90562ba92c933a85", name)
            }
            let stream = try reader.stream(reader.entries[0])
            var byte: UInt8 = 0
            XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try stream.read(into: $0) }, 1)
            XCTAssertEqual(try reader.read(link), Data(String(repeating: "x", count: 200).utf8))
            var data = Data([byte])
            data.append(try stream.readAll())
            XCTAssertEqual(digest(data), "74afbb86e62b28d58e0ed4535792c9d2d932ae7556dd0a8e90562ba92c933a85")
        }
    }

    func testRAR5TargetsMatchRAR4SizesAndDigests() throws {
        let expected = [
            "a.txt": "18b7cb099a9ea3f50ba899b5ba81e0d377a5f3b16f8f6eeb8b3e58cd4692b993",
            "日本語.txt": "e1422b2811100c295d75af1df0724ed59039fd602ab0b653d8377f97fc239fef",
            String(repeating: "x", count: 200): "aa20c23e3201834050679e1d88941b9a6fed0557c9a705cb2c315e2e63fd486d",
        ]
        for version in [4, 5] {
            let reader = try ArchiveReader.open(data: fixture("rar\(version)/symlink-targets"))
            let links = reader.entries.filter { $0.kind == .symlink }
            XCTAssertEqual(links.count, 3)
            for entry in links {
                let data = try reader.read(entry)
                let target = String(decoding: data, as: UTF8.self)
                XCTAssertEqual(entry.uncompressedSize, UInt64(data.count))
                XCTAssertEqual(digest(data), try XCTUnwrap(expected[target]))
                let stream = try reader.stream(entry)
                var streamed = Data()
                var byte: UInt8 = 0
                while try withUnsafeMutableBytes(of: &byte, { try stream.read(into: $0) }) != 0 {
                    streamed.append(byte)
                }
                XCTAssertEqual(streamed, data)
            }
        }
    }

    func testRAR5AllSymbolicRedirectionsDirectAndSolidTraversal() throws {
        for type: UInt64 in [1, 2, 3] {
            for target in ["a.txt", "日本語.txt", String(repeating: "x", count: 200)] {
                let bytes = Data(target.utf8)
                let extra = RAR5TestSupport.extraRecord(type: 5, payload:
                    RAR5TestSupport.vint(type) + [0]
                    + RAR5TestSupport.vint(UInt64(bytes.count)) + Array(bytes))
                func archive(declared: UInt64) -> Data {
                    RAR5TestSupport.archive(mainFlags: 4, blocks: [
                        RAR5TestSupport.storedFile(name: "before", contents: Data([42])),
                        RAR5TestSupport.storedFile(name: "link", contents: Data(),
                            unpackedSize: declared, compressionInfo: 0x40, extra: extra),
                        RAR5TestSupport.storedFile(name: "after", contents: Data([43]), compressionInfo: 0x40),
                    ])
                }
                let reader = try ArchiveReader.open(data: archive(declared: UInt64(bytes.count)))
                XCTAssertEqual(try reader.read(reader.entries[2]), Data([43]))
                XCTAssertEqual(try reader.read(reader.entries[1]), bytes)
                XCTAssertEqual(try reader.read(reader.entries[0]), Data([42]))
                let malformed = try ArchiveReader.open(data: archive(declared: UInt64(bytes.count + 1)))
                for index in [1, 2] {
                    XCTAssertThrowsError(try malformed.read(malformed.entries[index])) { error in
                        XCTAssertEqual(error as? KaitoError, .malformed("RAR5 symbolic link target size differs"))
                    }
                }
                var limits = ReadLimits()
                limits.maxEntrySize = UInt64(bytes.count - 1)
                let internalReader = try RAR5Reader(
                    source: DataByteSource(data: archive(declared: UInt64(bytes.count))), options: ReaderOptions()
                )
                XCTAssertThrowsError(try internalReader.stream(for: internalReader.entries[1], limits: limits)) { error in
                    guard case .limitExceeded = error as? KaitoError else {
                        return XCTFail("unexpected error: \(error)")
                    }
                }
            }
        }
    }
}
