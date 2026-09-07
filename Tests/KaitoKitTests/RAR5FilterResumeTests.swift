import Foundation
@testable import KaitoKit
import XCTest

final class RAR5FilterResumeTests: XCTestCase {
    func testGeneratedSolidExecutableFilterResumesDuringRandomAccess() throws {
        try RAR5TestSupport.requireRAR()
        let executableURL = URL(fileURLWithPath: "/bin/bash")
        let secondExecutableURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: executableURL.path),
              FileManager.default.isReadableFile(atPath: secondExecutableURL.path) else {
            throw XCTSkip("system executable fixtures are unavailable")
        }

        let temporary = try ZipTestSupport.temporaryDirectory(label: "rar5-filter-resume")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

        let predecessor = Data(repeating: 0x5a, count: 12 * 1_024 * 1_024 + 1)
        let executable = try Data(contentsOf: executableURL)
        let secondExecutable = try Data(contentsOf: secondExecutableURL)
        _ = try ZipTestSupport.write(predecessor, relativePath: "00-prefix.bin", below: source)
        _ = try ZipTestSupport.write(secondExecutable, relativePath: "01-executable", below: source)
        _ = try ZipTestSupport.write(executable, relativePath: "02-executable", below: source)

        let archive = temporary.appendingPathComponent("executables-solid.rar")
        try RAR5TestSupport.makeGeneratedArchive(
            sourceDirectory: source,
            paths: ["00-prefix.bin", "01-executable", "02-executable"],
            archiveURL: archive,
            options: ["-m5", "-s", "-qo-", "-md32m"]
        )

        let listing = try ArchiveReader.open(url: archive)
        XCTAssertEqual(listing.entries.map(\.solidGroup), [0, 0, 0])
        let listedExecutable = try XCTUnwrap(
            listing.entries.first { $0.name == "02-executable" }
        )
        XCTAssertNotEqual(listedExecutable.formatSpecific["method"], "0")

        // Opening a fresh reader and requesting the final solid member first
        // exercises the coordinator's predecessor drain before the caller's
        // arbitrary-size reads resume any filtered output.
        for bufferSize in [4_096, 100_000, 65_537] {
            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first { $0.name == "02-executable" })
            XCTAssertEqual(
                try drain(try reader.stream(entry), bufferSize: bufferSize),
                executable
            )
        }
    }

    private func drain(_ stream: EntryStream, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
