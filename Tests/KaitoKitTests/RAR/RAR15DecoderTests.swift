import Foundation
@testable import KaitoKit
import XCTest

final class RAR15DecoderTests: XCTestCase {
    func testGeneratedLiteralAndShortMatchArchive() throws {
        let reader = try ArchiveReader.open(data: TestFixtures.base64("rar15/normal.rar"))
        let phrase = Data("RAR15!\r\n".utf8)
        XCTAssertEqual(reader.entries.map(\.name), ["literals.txt", "match.txt"])
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), entry.name == "match.txt" ? phrase + phrase : phrase)
        }
        let stream = try reader.stream(reader.entries[1])
        var output = Data(), buffer = [UInt8](repeating: 0, count: 1)
        while stream.remaining != 0 {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { return XCTFail("RAR15 stream made no progress") }
            output.append(buffer, count: count)
        }
        XCTAssertEqual(output, phrase + phrase)
    }

    func testGeneratedSolidArchiveSupportsForwardAndBackwardReads() throws {
        let reader = try ArchiveReader.open(data: TestFixtures.base64("rar15/solid.rar"))
        let expected = Data("RAR15!\r\n".utf8)
        XCTAssertEqual(reader.entries.count, 2)
        for entry in reader.entries {
            XCTAssertEqual(try reader.read(entry), expected, "forward \(entry.index)")
        }
        for index in [1, 0, 1, 0] {
            XCTAssertEqual(try reader.read(reader.entries[index]), expected, "read \(index)")
        }
    }

    func testRAR154NormalArchiveMatchesUnrarOutput() throws {
        let root = try fixtureRoot()
        let reader = try ArchiveReader.open(url: root.appendingPathComponent("readme_154_normal.rar"))
        let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
        XCTAssertEqual(try reader.read(entry), try Data(contentsOf: root.appendingPathComponent("expected/README.md")))
    }

    func testRAR154AudioAndDocumentCorpusMatchesUnrarOutput() throws {
        let root = try fixtureRoot()
        for name in ["audio_win_names_unpack15.rar", "doc_154_best.rar"] {
            let reader = try ArchiveReader.open(url: root.appendingPathComponent(name))
            for entry in reader.entries where entry.kind == .file {
                let expectedURL = root.appendingPathComponent("expected/\(entry.name)")
                do {
                    let actual = try reader.read(entry)
                    let expected = try Data(contentsOf: expectedURL)
                    let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    XCTAssertEqual(actual, expected, "\(name):\(entry.name) first mismatch=\(mismatch.map(String.init) ?? "none")")
                } catch {
                    XCTFail("\(name):\(entry.name): \(error)")
                }
            }
        }
    }

    func testRAR154AudioDirectDecoderMatchesUnrarOutput() throws {
        let root = try fixtureRoot()
        let actual = try readRAR15File(
            archive: root.appendingPathComponent("audio_win_names_unpack15.rar"),
            entryIndex: 0, bufferSize: 97
        )
        let expected = try Data(contentsOf: root.appendingPathComponent("expected/BoatModernEnglish.wav"))
        let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertEqual(actual, expected, "first mismatch=\(mismatch.map(String.init) ?? "none")")
    }

    func testRAR154LongDocumentDirectDecoderMatchesUnrarOutput() throws {
        let root = try fixtureRoot()
        let archive = root.appendingPathComponent("doc_154_best.rar")
        for (index, name) in [(3, "FILT~XX0.MD"), (9, "PPMD~D4Q.MD")] {
            let actual = try readRAR15File(archive: archive, entryIndex: index, bufferSize: 97)
            let expected = try Data(contentsOf: root.appendingPathComponent("expected/\(name)"))
            let mismatch = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            XCTAssertEqual(actual, expected, "\(name) first mismatch=\(mismatch.map(String.init) ?? "none")")
        }
    }

    func testTruncatedPackedInputIsRejected() throws {
        let source = DataByteSource(data: try TestFixtures.base64("rar15/normal.rar"))
        let signature = try XCTUnwrap(RARSignatureScanner.find(source: source))
        let parsed = try RAR4EntryPublisher.parse(
            source: source, sourceURL: nil, sourceDirectoryAnchor: nil,
            options: ReaderOptions(), signatureOffset: signature.offset,
            headerKeyCache: RAR3KeyCache(),
            passwordEncodings: RAR4Reader.PasswordEncodingSelection()
        )
        let record = parsed.records[0]
        let segment = try XCTUnwrap(record.packedSegments.first)
        for compressedSize in [UInt64(0), 1, record.packedSize / 2] {
            func decode() throws {
                let decoder = try RAR15Decoder(
                    source: source, offset: segment.offset, compressedSize: compressedSize,
                    expectedSize: record.unpackedSize, unpackVersion: record.unpackVersion,
                    method: record.method, dictionarySize: record.dictionarySize,
                    isSolid: false, limits: ReadLimits()
                )
                var buffer = [UInt8](repeating: 0, count: 17)
                while !decoder.isFinished {
                    let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                    guard count > 0 else { throw KaitoError.truncated }
                }
            }
            XCTAssertThrowsError(try decode(), "packed size \(compressedSize)") { error in
                XCTAssertEqual(error as? KaitoError, .truncated)
            }
        }
    }

    private func readRAR15File(archive: URL, entryIndex: Int, bufferSize: Int) throws -> Data {
        let source = DataByteSource(data: try Data(contentsOf: archive))
        let signature = try XCTUnwrap(RARSignatureScanner.find(source: source))
        let parsed = try RAR4EntryPublisher.parse(
            source: source, sourceURL: nil, sourceDirectoryAnchor: nil,
            options: ReaderOptions(), signatureOffset: signature.offset,
            headerKeyCache: RAR3KeyCache(),
            passwordEncodings: RAR4Reader.PasswordEncodingSelection()
        )
        let record = parsed.records[entryIndex]
        let segment = try XCTUnwrap(record.packedSegments.first)
        let decoder = try RAR15Decoder(
            source: source, offset: segment.offset,
            compressedSize: record.packedSize, expectedSize: record.unpackedSize,
            unpackVersion: record.unpackVersion, method: record.method,
            dictionarySize: record.dictionarySize, isSolid: false, limits: ReadLimits()
        )
        var output = Data(), buffer = [UInt8](repeating: 0, count: bufferSize)
        while output.count < record.unpackedSize {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            guard count > 0 else { throw KaitoError.truncated }
            output.append(buffer, count: count)
        }
        return output
    }

    private func fixtureRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_RAR15_FIXTURES"] else {
            throw XCTSkip("set KAITOKIT_RAR15_FIXTURES")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
