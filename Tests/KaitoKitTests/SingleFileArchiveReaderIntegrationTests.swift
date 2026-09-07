import Foundation
@testable import KaitoKit
import XCTest

final class SingleFileArchiveReaderIntegrationTests: XCTestCase {
    func testArchiveReaderDispatchesSingleFileFormatsAndReopens() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let payload = Data((0..<65_537).map {
            UInt8(truncatingIfNeeded: $0 &* 29 &+ $0 / 257)
        })
        var fixtures: [(ArchiveFormat, String, Data)] = [
            (.gzip, "gz", try filter("/usr/bin/gzip", input: payload)),
            (.bzip2, "bz2", try filter("/usr/bin/bzip2", input: payload)),
        ]
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/xz") {
            fixtures.append((
                .xz,
                "xz",
                try filter("/opt/homebrew/bin/xz", input: payload)
            ))
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") {
            fixtures.append((
                .compress,
                "Z",
                try unixCompress(payload, below: temporary)
            ))
        }

        for (format, suffix, bytes) in fixtures {
            let dataReader = try ArchiveReader.open(data: bytes)
            XCTAssertEqual(dataReader.format, format)
            XCTAssertEqual(dataReader.entries.map(\.name), ["data"])
            XCTAssertEqual(try dataReader.read(dataReader.entries[0]), payload)
            let reopenedData = try dataReader.reopen()
            XCTAssertEqual(
                try reopenedData.read(reopenedData.entries[0]),
                payload
            )

            let url = temporary.appendingPathComponent("payload.\(suffix)")
            try bytes.write(to: url)
            let fileReader = try ArchiveReader.open(url: url)
            XCTAssertEqual(fileReader.format, format)
            XCTAssertEqual(fileReader.entries.map(\.name), ["payload"])
            XCTAssertEqual(try fileReader.read(fileReader.entries[0]), payload)
            let reopenedFile = try fileReader.reopen()
            XCTAssertEqual(
                try reopenedFile.read(reopenedFile.entries[0]),
                payload
            )
        }
    }

    func testArchiveReaderUsesGzipFNAMEBeforeURLFallback() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = Data("named gzip payload\n".utf8)
        let ordinary = try filter("/usr/bin/gzip", input: payload)
        let named = try gzip(
            byAddingName: Array("原稿.txt".utf8),
            to: ordinary
        )
        let url = temporary.appendingPathComponent("fallback.gz")
        try named.write(to: url)

        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.format, .gzip)
        XCTAssertEqual(reader.entries.map(\.name), ["原稿.txt"])
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }

    func testUnknownSizeSingleFileLimitsAtExactBoundary() throws {
        let payload = Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let gzip = try filter("/usr/bin/gzip", input: payload)
        let exact = UInt64(payload.count)

        for keyPath in [
            \ReadLimits.maxEntrySize,
            \ReadLimits.maxInMemorySize,
            \ReadLimits.maxTotalUncompressedSize,
        ] {
            var acceptedLimits = ReadLimits()
            acceptedLimits[keyPath: keyPath] = exact
            let accepted = try ArchiveReader.open(
                data: gzip,
                options: ReaderOptions(limits: acceptedLimits)
            )
            XCTAssertEqual(try accepted.read(accepted.entries[0]), payload)

            var rejectedLimits = ReadLimits()
            rejectedLimits[keyPath: keyPath] = exact - 1
            let rejected = try ArchiveReader.open(
                data: gzip,
                options: ReaderOptions(limits: rejectedLimits)
            )
            XCTAssertThrowsError(try rejected.read(rejected.entries[0])) {
                guard case .limitExceeded = $0 as? KaitoError else {
                    return XCTFail("unexpected error for \(keyPath): \($0)")
                }
            }
        }
    }

    func testCompressedTarMemoryAndSpillSurviveUnlinkAndReopen() throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: false
        )
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 * 41) })
        _ = try TarTestSupport.write(
            payload,
            relativePath: "page.bin",
            below: source
        )

        for (label, threshold) in [("memory", UInt64.max), ("spill", UInt64(0))] {
            let url = temporary.appendingPathComponent("\(label).tgz")
            _ = try run(
                executable: "/usr/bin/bsdtar",
                arguments: ["-czf", url.path, "-C", source.path, "page.bin"],
                input: nil
            )
            var limits = ReadLimits()
            limits.inMemorySingleFileLimit = threshold
            let reader = try ArchiveReader.open(
                url: url,
                options: ReaderOptions(limits: limits)
            )
            XCTAssertEqual(reader.format, .tar, label)
            XCTAssertEqual(reader.entries.map(\.name), ["page.bin"], label)

            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload, label)
            let reopened = try reader.reopen()
            XCTAssertEqual(reopened.format, .tar, label)
            XCTAssertEqual(try reopened.read(reopened.entries[0]), payload, label)
        }
    }

    private func gzip(byAddingName name: [UInt8], to ordinary: Data) throws -> Data {
        guard ordinary.count >= 18 else { throw KaitoError.truncated }
        var header = Array(ordinary.prefix(10))
        header[3] |= 0x08
        header.append(contentsOf: name)
        header.append(0)
        var result = Data(header)
        result.append(ordinary.dropFirst(10))
        return result
    }

    private func unixCompress(_ input: Data, below directory: URL) throws -> Data {
        let inputURL = directory.appendingPathComponent("compress-input-\(UUID().uuidString)")
        try input.write(to: inputURL)
        _ = try run(
            executable: "/usr/bin/compress",
            arguments: ["-f", "-b", "16", inputURL.path],
            input: nil
        )
        return try Data(contentsOf: inputURL.appendingPathExtension("Z"))
    }

    private func filter(_ executable: String, input: Data) throws -> Data {
        try run(executable: executable, arguments: ["-c"], input: input)
    }

    @discardableResult
    private func run(
        executable: String,
        arguments: [String],
        input: Data?
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        let standardInput: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            standardInput = pipe
        } else {
            standardInput = nil
        }
        try process.run()
        if let input, let standardInput {
            standardInput.fileHandleForWriting.write(input)
            try standardInput.fileHandleForWriting.close()
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw TarTestSupportError.commandFailed(
                String(decoding: diagnostic, as: UTF8.self)
            )
        }
        return result
    }
}
