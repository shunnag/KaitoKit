import Foundation
@_spi(TarEditLayout) internal import KaitoKit
import XCTest

/// Tests/Fixtures/tar-edit の圧縮 tar（tgz / tbz / txz）の chunk map と EOF をまたぐ chunk を、expected-maps.json（符号化側で記録した区切り）と照合する。
final class CompressedTarChunkMapFixtureTests: XCTestCase {
    // 旧名: GyoshukuFixtureMapTests
    func testPrototypeMapsAndEOFStraddles() throws {
        struct Row: Decodable {
            let c0: UInt64, c1: UInt64, u0: UInt64
            let u1: UInt64?
            let ccrc: UInt32
            let crc0: UInt32?
            let level: UInt8?
            let hdr: UInt64?, payload: UInt64?, unpadded: UInt64?
        }
        let url = TarGoldenCorpus.repository.appendingPathComponent("Tests/Fixtures/tar-edit/expected-maps.json")
        let oracle = try JSONDecoder().decode([String: [String: [Row]]].self, from: Data(contentsOf: url))
        for (name, formats) in oracle {
            let data = try TarEditTestSupport.fixture(name)
            let snapshot = try TarEditTestSupport.snapshot(data, suffix: String(name.split(separator: ".").last!))
            let map = try XCTUnwrap(snapshot.chunkMap, "\(name): \(String(describing: snapshot.chunkMapUnavailableReason))")
            let rows = try XCTUnwrap(formats.values.first)
            XCTAssertEqual(map.chunks.count, rows.count, name)
            guard map.chunks.count == rows.count else { continue }
            for (index, row) in rows.enumerated() {
                let chunk = map.chunks[index]
                XCTAssertEqual(chunk.compressedRange, row.c0..<row.c1, name)
                XCTAssertEqual(chunk.imageRange, row.u0..<(row.u1 ?? snapshot.image.length), name)
                XCTAssertEqual(chunk.compressedCRC32, row.ccrc, name)
                switch map {
                case .gzip(let gzip):
                    XCTAssertEqual(gzip.points[index].crc32, row.crc0, name)
                    if index > 0 { XCTAssertEqual(Data(data[(Int(row.c0) - 4)..<Int(row.c0)]), Data([0, 0, 255, 255])) }
                case .bzip2(let bz): XCTAssertEqual(bz.streams[index].level, row.level, name)
                case .xz(let xz):
                    XCTAssertEqual(xz.blocks[index].headerSize, row.hdr, name)
                    XCTAssertEqual(xz.blocks[index].compressedPayloadSize, row.payload, name)
                    XCTAssertEqual(xz.blocks[index].unpaddedSize, row.unpadded, name)
                }
            }
            if name.hasPrefix("str") {
                let eof = try XCTUnwrap(snapshot.layout).endOfArchiveOffset
                XCTAssertEqual(map.chunks.firstIndex { $0.imageRange.contains(eof) }, map.chunks.count - 2, name)
            }
            try TarEditTestSupport.verify(snapshot)
        }
    }
    func testFrozenWriterBytes() throws {
        let root = TarGoldenCorpus.repository.appendingPathComponent("Tests/Fixtures/tar-edit")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers"); process.arguments = ["-productVersion"]
        process.standardOutput = pipe; try process.run(); process.waitUntilExit()
        let os = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let fixtureOS = try String(contentsOf: root.appendingPathComponent("macos-version.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        for name in ["gz.tgz", "strgz.tgz", "bz.tbz", "strbz.tbz", "xz.txz", "strxz.txz"] {
            if name.hasSuffix("txz"), os != fixtureOS { print("TAR-FRAMING skip xz byte identity: OS \(os) != \(fixtureOS)"); continue }
            let text = try String(contentsOf: root.appendingPathComponent(name + ".b64"), encoding: .utf8)
            let archive = try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))
            let reader = try ArchiveReader.open(data: archive)
            let tar = try reader.read(XCTUnwrap(reader.entries.first))
            let actual: Data
            if name.hasSuffix("tgz") { actual = try CompressedTarFramingTestSupport.gzip(tar).data }
            else if name.hasSuffix("tbz") { actual = try CompressedTarFramingTestSupport.bzip2(tar).data }
            else { actual = try CompressedTarFramingTestSupport.xz(tar).data }
            XCTAssertEqual(actual, archive, name)
        }
    }
}
