import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class TarLayoutTests: XCTestCase {
    func testFrozenLayoutsAgainstIndependentWalk() throws {
        var options = ReaderOptions(appleDoublePolicy: .expose); options.recordsTarEditLayout = true
        for input in try TarGoldenCorpus.inputs() where input.origin == "synthetic" {
            let data = try TarGoldenCorpus.decoded(input)
            let hint = URL(fileURLWithPath: "/layout." + input.suffix)
            guard let reader = try? ArchiveReader.open(source: DataByteSource(data), sourceURL: hint, options: options), reader.format == .tar else { continue }
            let snapshot = try XCTUnwrap(reader.tarEditingSnapshot(), input.id)
            if input.id.hasPrefix("interleaved") {
                XCTAssertNil(snapshot.layout); XCTAssertEqual(snapshot.layoutUnavailableReason, .interleavedGlobalHeader)
                continue
            }
            let layout = try XCTUnwrap(snapshot.layout, input.id)
            let image = Data(try readByteRange(source: snapshot.image, offset: 0, count: Int(snapshot.image.length)))
            let expected = try walk(image, entries: reader.entries)
            XCTAssertEqual(layout.memberCount, expected.members.count, input.id)
            XCTAssertEqual(layout.globalHeaderRanges, expected.globals, input.id)
            XCTAssertEqual(layout.endOfArchiveOffset, expected.eof, input.id)
            XCTAssertEqual(layout.imageLength, UInt64(image.count), input.id)
            let reopened = try XCTUnwrap(reader.reopen().tarEditingSnapshot())
            for (index, member) in expected.members.enumerated() {
                XCTAssertEqual(try layout.member(at: index), member, "\(input.id) member \(index)")
                XCTAssertEqual(try reopened.layout?.member(at: index), member)
                XCTAssertEqual(try snapshot.headerGroup(ofMember: index), expected.groups[index], input.id)
            }
            XCTAssertEqual(try snapshot.trailingBytesAreZero(), image[Int(expected.eof)...].allSatisfy { $0 == 0 }, input.id)
            XCTAssertThrowsError(try layout.member(at: -1)) { XCTAssertEqual($0 as? KaitoError, .notFound("tar member index -1")) }
            XCTAssertThrowsError(try snapshot.headerGroup(ofMember: layout.memberCount))
        }
    }

    func testDisabledRecoveryAndWrappedEntries() throws {
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1]))])
        XCTAssertNil(try ArchiveReader.open(data: tar).tarEditingSnapshot())
        var options = ReaderOptions(recoverDamagedArchives: true); options.recordsTarEditLayout = true
        let recovered = try XCTUnwrap(ArchiveReader.open(data: tar, options: options).tarEditingSnapshot())
        XCTAssertNil(recovered.layout); XCTAssertEqual(recovered.layoutUnavailableReason, .recoveryMode)
        let path = TarGoldenCorpus.repository.appendingPathComponent("Tests/Fixtures/appledouble/mac.tar.b64")
        let data = try XCTUnwrap(Data(base64Encoded: String(contentsOf: path, encoding: .utf8), options: .ignoreUnknownCharacters))
        for policy: AppleDoublePolicy in [.merge, .hide] {
            var opts = ReaderOptions(appleDoublePolicy: policy); opts.recordsTarEditLayout = true
            let wrapped = try XCTUnwrap(ArchiveReader.open(data: data, options: opts).tarEditingSnapshot())
            XCTAssertNil(wrapped.layout); XCTAssertEqual(wrapped.layoutUnavailableReason, .wrappedEntries)
        }
        XCTAssertEqual(MemoryLayout<TarLayoutStorage.Member>.stride, 32)
    }

    func testHeaderGroupRejectsChangedImage() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("plain.tar")
        var tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "file", contents: Data([1, 2]))])
        try tar.write(to: url)
        var options = ReaderOptions(); options.recordsTarEditLayout = true
        let snapshot = try XCTUnwrap(ArchiveReader.open(url: url, options: options).tarEditingSnapshot())
        tar.replaceSubrange(124..<136, with: TarGoldenInputSupport.octal(1)); TarGoldenInputSupport.checksum(&tar)
        let handle = try FileHandle(forWritingTo: url); try handle.write(contentsOf: tar); try handle.close()
        XCTAssertThrowsError(try snapshot.headerGroup(ofMember: 0)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("tar layout does not match the image"))
        }
    }

    private func walk(_ image: Data, entries: [ArchiveEntry]) throws
        -> (members: [TarMemberLayout], groups: [TarHeaderGroup], globals: [Range<UInt64>], eof: UInt64) {
        var offset = 0, start: Int?, members: [TarMemberLayout] = [], groups: [TarHeaderGroup] = []
        var globals: [Range<UInt64>] = [], extensions: [TarHeaderGroup.Extension] = []
        while offset + 512 <= image.count {
            let h = Data(image[offset..<(offset + 512)])
            if h.allSatisfy({ $0 == 0 }) { break }
            let type = h[156]
            if [UInt8(0x78), 0x58, 0x4c, 0x4b, 0x67].contains(type) {
                let text = String(decoding: h[124..<136].prefix { $0 != 0 && $0 != 32 }, as: UTF8.self)
                let size = try XCTUnwrap(Int(text, radix: 8))
                let end = offset + 512 + (size + 511) / 512 * 512
                if type == 0x67 { globals.append(UInt64(offset)..<UInt64(end)) }
                else {
                    if start == nil { start = offset }
                    extensions.append(.init(typeFlag: type, headerOffset: UInt64(offset), payloadRange: UInt64(offset + 512)..<UInt64(offset + 512 + size), end: UInt64(end)))
                }
                offset = end; continue
            }
            var body = offset + 512
            if type == 0x53, h[482] != 0 {
                while true { let more = image[body + 504] != 0; body += 512; if !more { break } }
            }
            let size = try XCTUnwrap(entries[members.count].compressedSize)
            let end = UInt64(body) + (size + 511) / 512 * 512
            members.append(.init(groupRange: UInt64(start ?? offset)..<end, headerOffset: UInt64(offset), bodyRange: UInt64(body)..<(UInt64(body) + size)))
            groups.append(.init(extensions: extensions, headerOffset: UInt64(offset), typeFlag: type,
                                sparseExtensionRange: body > offset + 512 ? UInt64(offset + 512)..<UInt64(body) : nil))
            extensions = []; start = nil; offset = Int(end)
        }
        return (members, groups, globals, UInt64(offset))
    }
}
