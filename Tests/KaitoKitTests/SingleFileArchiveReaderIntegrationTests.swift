import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class SingleFileArchiveReaderIntegrationTests: XCTestCase {
    func testStagingFreeSpaceReserveRechecksAfter256MiBAndClosesFailedSpill() throws {
        let calls = Mutex(0)
        let source = StagingZeroSource(length: 256 * 1_024 * 1_024 + 1)
        let limits = ReadLimits(inMemorySingleFileLimit: 0, stagingFreeSpaceReserve: 1_024)
        let stream = try EntryStream(source: source, offset: 0, length: source.length, limits: limits)
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        try SingleFileMaterializer.$availableTemporarySpace.withValue({
            calls.withLock {
                $0 += 1
                return $0 == 1 ? UInt64.max : 0
            }
        }) {
            XCTAssertThrowsError(try SingleFileMaterializer.materialize(stream, limits: limits)) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("staging free space"))
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 2, "staging must recheck space after 256 MiB")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, descriptors)
    }

    func testStagingFreeSpaceReserveRejectsSpillWithoutLeakingDescriptor() throws {
        let bytes = try smallCompressedTar()
        let calls = Mutex(0)
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        try SingleFileMaterializer.$availableTemporarySpace.withValue({
            calls.withLock { $0 += 1 }
            return 1_023
        }) {
            XCTAssertThrowsError(try ArchiveReader.open(source: DataByteSource(bytes),
                sourceURL: URL(fileURLWithPath: "/archive.tgz"),
                options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 0,
                    stagingFreeSpaceReserve: 1_024)))) {
                XCTAssertEqual($0 as? KaitoError, .limitExceeded("staging free space"))
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1, "spilling must query available temporary space")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, descriptors)
    }

    func testStagingFreeSpaceReserveAllowsSpillAtReserve() throws {
        let bytes = try smallCompressedTar()
        for available in [UInt64(1_024), .max] {
            let calls = Mutex(0)
            let reader = try SingleFileMaterializer.$availableTemporarySpace.withValue({
                calls.withLock { $0 += 1 }
                return available
            }) {
                try ArchiveReader.open(source: DataByteSource(bytes),
                    sourceURL: URL(fileURLWithPath: "/archive.tgz"),
                    options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 0,
                        stagingFreeSpaceReserve: 1_024)))
            }
            XCTAssertEqual(calls.withLock { $0 }, 1, "small spills need one free-space check")
            XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload".utf8))
        }
    }

    func testStagingFreeSpaceReserveDoesNotQueryForMemory() throws {
        let bytes = try smallCompressedTar()
        let calls = Mutex(0)
        let reader = try SingleFileMaterializer.$availableTemporarySpace.withValue({
            calls.withLock { $0 += 1 }
            return 0
        }) {
            try ArchiveReader.open(source: DataByteSource(bytes),
                sourceURL: URL(fileURLWithPath: "/archive.tgz"),
                options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: .max)))
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(try reader.read(reader.entries[0]), Data("payload".utf8))
        XCTAssertEqual(ReadLimits().stagingFreeSpaceReserve, 1_024 * 1_024 * 1_024)
    }

    private func smallCompressedTar() throws -> Data {
        try filter("/usr/bin/gzip", input: TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "page.txt", contents: Data("payload".utf8)),
        ]))
    }

    func testCancelledCompressedTarStagingStopsBeforeSpilling() async throws {
        let payload = Data(repeating: 0x61, count: 4 * 1_024 * 1_024)
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "large.bin", contents: payload)])
        let bytes = try filter("/usr/bin/gzip", input: tar)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ArchiveReader.open(source: DataByteSource(bytes),
                    sourceURL: URL(fileURLWithPath: "/archive.tgz"),
                    options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: 0)))
                return false
            } catch is CancellationError { return true }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled, "compressed-tar staging must propagate CancellationError")
    }

    func testCompressedTarReopenReusesStagedMemoryWithoutReadingCompressedSource() throws {
        try assertCompressedTarReopenReusesStaging(threshold: .max)
    }

    func testCompressedTarReopenReusesSpilledDescriptorWithoutReadingCompressedSource() throws {
        try assertCompressedTarReopenReusesStaging(threshold: 0)
    }

    private func assertCompressedTarReopenReusesStaging(threshold: UInt64) throws {
        let temporary = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = Data("staged tar member\n".utf8)
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "page.txt", contents: payload)])
        let url = temporary.appendingPathComponent("archive.tar.gz")
        try filter("/usr/bin/gzip", input: tar).write(to: url)
        let source = CountingByteSource(try FileByteSource(url: url))
        let reader = try ArchiveReader.open(source: source, sourceURL: url,
            options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: threshold)))
        XCTAssertEqual(reader.format, .tar)
        XCTAssertEqual(reader.entries.map(\.name), ["page.txt"])
        try FileManager.default.removeItem(at: url)
        source.reset()
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count

        let second = try reader.reopen()
        XCTAssertEqual(source.bytesRead, 0, "reopen must reuse the staged tar source")
        XCTAssertEqual(second.entries, reader.entries)
        XCTAssertEqual(second.format, .tar)
        XCTAssertEqual(try second.read(second.entries[0]), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count,
                       descriptors, "reopen must not create another staging descriptor")
        let third = try second.reopen()
        XCTAssertEqual(source.bytesRead, 0, "successive reopens must keep sharing staged bytes")
        XCTAssertEqual(third.entries, reader.entries)
        XCTAssertEqual(try third.read(third.entries[0]), payload)
        withExtendedLifetime((reader, second, third)) {}
    }

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

private struct StagingZeroSource: ByteSource {
    let length: UInt64
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < length else { return 0 }
        let count = Int(min(UInt64(buffer.count), length - offset))
        UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
            .initializeMemory(as: UInt8.self, repeating: 0)
        return count
    }
}
