import Foundation
import KaitoKit
import KaitoKitCompat
import XCTest

final class MigrationGuideSnippetCompileTests: XCTestCase {
    func testDocumentedCompatibilitySnippetsCompile() {
        let opener: (String) -> XADArchive? = { path in
            guard let archive = XADArchive(file: path) else { return nil }
            _ = archive.numberOfEntries()
            _ = archive.name(ofEntry: 0)
            _ = archive.dataForEntry(0)
            _ = archive.attributesOfEntry(0)
            return archive
        }
        let urlOpener: (URL) -> KaitoArchive? = { url in
            KaitoArchive(fileURL: url)
        }
        let dataOpener: (Data) -> KaitoArchive? = { data in
            KaitoArchive(data: data)
        }
        _ = (opener, urlOpener, dataOpener)
    }

    func testDocumentedModernSnippetCompiles() throws {
        func inspect(_ url: URL) throws -> [(String, UInt64?)] {
            let reader = try ArchiveReader.open(url: url)
            return reader.entries.map { ($0.name, $0.uncompressedSize) }
        }

        func extractArchive(_ reader: ArchiveReader, destination: URL) throws {
            for entry in reader.entries where entry.kind != .directory {
                _ = try reader.extract(entry, to: destination)
            }
            for directory in reader.entries.filter({ $0.kind == .directory }).sorted(by: {
                $0.pathComponents.count > $1.pathComponents.count
            }) {
                _ = try reader.extract(directory, to: destination)
            }
        }

        func stream(_ reader: ArchiveReader, entry: ArchiveEntry) throws -> Data {
            let stream = try reader.stream(entry)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
            while true {
                let count = try buffer.withUnsafeMutableBytes { bytes in
                    try stream.read(into: bytes)
                }
                if count == 0 { break }
                result.append(contentsOf: buffer[0..<count])
            }
            return result
        }

        _ = (inspect, extractArchive, stream)
    }

    func testDocumentedDelegateSnippetCompiles() {
        final class Delegate: KaitoArchiveDelegate {
            func archiveNeedsPassword(_ archive: KaitoArchive) {
                archive.setPassword("example")
            }

            func archive(
                _ archive: KaitoArchive,
                nameEncodingForData data: Data,
                guess: String.Encoding,
                confidence: Double
            ) -> String.Encoding? {
                confidence < 0.5 ? .shiftJIS : nil
            }

            func archive(
                _ archive: KaitoArchive,
                extractionProgressForEntry entry: Int32,
                bytes: Int64,
                of total: Int64
            ) {}
        }

        func configure(_ archive: KaitoArchive, password: String?) -> Delegate {
            let delegate = Delegate()
            archive.delegate = delegate
            archive.setPassword(password)
            archive.setNameEncoding(.shiftJIS)
            return delegate
        }

        _ = configure
    }

    func testDocumentedCooViewerArchiveSourceShapeCompiles() {
        struct ArchiveSource: Sendable {
            enum Backing: Sendable {
                case file(URL)
                case data(Data)
            }

            let backing: Backing
            var options = ReaderOptions()

            func open() throws -> ArchiveReader {
                switch backing {
                case let .file(url):
                    try ArchiveReader.open(url: url, options: options)
                case let .data(data):
                    try ArchiveReader.open(data: data, options: options)
                }
            }
        }

        func makeReaders(source: ArchiveSource, workerCount: Int) throws -> [ArchiveReader] {
            let primary = try source.open()
            return try (0..<workerCount).map { index in
                index == 0 ? primary : try primary.reopen()
            }
        }

        _ = makeReaders
    }
}
