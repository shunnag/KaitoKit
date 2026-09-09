import Foundation
@testable import KaitoKit
import XCTest

final class SingleFileFormatTests: XCTestCase {
    func testLZMAAloneKnownAndUnknownSizes() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZipTestSupport.checkedInFixture("singlefile/alone.lzma")
        let payload = try ZipTestSupport.checkedInFixture("sevenzip/code-payload.bin")
        for knownSize in [false, true] {
            var archive = fixture
            let size: UInt64 = knownSize ? 8_192 : UInt64.max
            for index in 0..<8 {
                archive[5 + index] = UInt8(truncatingIfNeeded: size >> (index * 8))
            }
            let url = directory.appendingPathComponent("code.bin.lzma")
            try archive.write(to: url)
            let reader = try ArchiveReader.open(url: url)
            XCTAssertEqual(reader.format.rawValue, "lzma")
            XCTAssertEqual(reader.entries.map(\.name), ["code.bin"])
            XCTAssertEqual(reader.entries[0].uncompressedSize, knownSize ? 8_192 : nil)
            XCTAssertEqual(try reader.read(reader.entries[0]), payload)
            XCTAssertEqual(try reader.reopen().read(reader.entries[0]), payload)
            XCTAssertEqual(
                try drain(reader.stream(reader.entries[0]), bufferSize: 7),
                payload
            )
        }
    }

    func testLZMAAloneLimitsMalformedHeadersAndTruncation() throws {
        let format = try XCTUnwrap(ArchiveFormat(rawValue: "lzma"))
        let archive = try ZipTestSupport.checkedInFixture("singlefile/alone.lzma")
        func reader(_ bytes: Data, limits: ReadLimits = ReadLimits()) throws -> SingleFileReader {
            try SingleFileReader(
                source: DataByteSource(data: bytes), format: format,
                options: ReaderOptions(limits: limits), fallbackFileName: "code.bin.lzma"
            )
        }
        for count in [0, 12, 13, 17] {
            XCTAssertThrowsError(try reader(Data(archive.prefix(count)))) { error in
                XCTAssertEqual(error as? KaitoError, .truncated)
            }
        }
        for offset in [0, 13] {
            var bad = archive
            bad[offset] = 0xFF
            XCTAssertThrowsError(try reader(bad))
        }
        XCTAssertThrowsError(try reader(archive, limits: ReadLimits(maxDictionarySize: 4_095))) { error in
            guard case .limitExceeded = error as? KaitoError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        var known = archive
        for index in 0..<8 {
            known[5 + index] = UInt8(truncatingIfNeeded: UInt64(8_192) >> (index * 8))
        }
        for limits in [ReadLimits(maxEntrySize: 8_191), ReadLimits(maxTotalUncompressedSize: 8_191)] {
            XCTAssertThrowsError(try reader(known, limits: limits)) { error in
                guard case .limitExceeded = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        let unknown = try reader(archive)
        XCTAssertThrowsError(try unknown.stream(
            for: unknown.entries[0], limits: ReadLimits(maxEntrySize: 8_191)
        ).readAll())
        for limits in [ReadLimits(maxTotalUncompressedSize: 8_191), ReadLimits(maxInMemorySize: 8_191)] {
            let directory = try TarTestSupport.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("code.lzma")
            try archive.write(to: url)
            let bounded = try ArchiveReader.open(url: url, options: ReaderOptions(limits: limits))
            XCTAssertThrowsError(try bounded.read(bounded.entries[0]))
        }
        let truncated = try reader(Data(archive.dropLast(8)))
        XCTAssertThrowsError(try truncated.stream(for: truncated.entries[0], limits: ReadLimits()).readAll())
    }

    func testCompressTarCheckedInFixtureMemoryAndFileStaging() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZipTestSupport.checkedInFixture("singlefile/tar-compress.tar.Z")
        let payload = try ZipTestSupport.checkedInFixture("sevenzip/code-payload.bin")
        for name in ["fixture.tar.Z", "fixture.tZ"] {
            let url = directory.appendingPathComponent(name)
            try fixture.write(to: url)
            for memoryLimit: UInt64 in [1, 9_728] {
                let limits = ReadLimits(inMemorySingleFileLimit: memoryLimit)
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(limits: limits))
                XCTAssertEqual(reader.format, .tar)
                XCTAssertEqual(reader.entries.map(\.name), ["code.bin"])
                XCTAssertEqual(reader.entries[0].uncompressedSize, 8_192)
                XCTAssertEqual(try reader.read(reader.entries[0]), payload)
                XCTAssertEqual(try reader.reopen().read(reader.entries[0]), payload)
            }
        }
    }

    func testGzipAllHeaderFlagsNameAndConcatenatedMembers() throws {
        let first = Data("first member 日本語\n".utf8)
        let second = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 * 29) })
        let custom = try makeGzipWithAllHeaderFlags(
            contents: first,
            name: Array("原稿.txt".utf8),
            modificationTime: 1_700_000_000
        )
        let archive = custom + (try compress(executable: "/usr/bin/gzip", input: second))

        let reader = try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .gzip,
            options: ReaderOptions(),
            fallbackFileName: "fallback.gz"
        )
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries[0].name, "原稿.txt")
        XCTAssertEqual(reader.entries[0].modificationDate?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), first + second)
    }

    func testGzipFallbackNameAndFooterChecks() throws {
        let contents = Data("footer verification".utf8)
        let archive = try compress(executable: "/usr/bin/gzip", input: contents)
        let reader = try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .gzip,
            options: ReaderOptions(),
            fallbackFileName: "chapter.tar.gz"
        )
        XCTAssertEqual(reader.entries[0].name, "chapter.tar")
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), contents)

        for distanceFromEnd in [8, 4] {
            var changed = archive
            changed[changed.count - distanceFromEnd] ^= 0x80
            let changedReader = try SingleFileReader(
                source: DataByteSource(data: changed),
                format: .gzip,
                options: ReaderOptions(),
                fallbackFileName: nil
            )
            XCTAssertThrowsError(
                try changedReader.stream(
                    for: changedReader.entries[0],
                    limits: ReadLimits()
                ).readAll()
            )
        }
    }

    func testGzipHeaderChecksumAndTrailingBytesAreRejected() throws {
        var archive = try makeGzipWithAllHeaderFlags(
            contents: Data("header".utf8),
            name: Array("header.txt".utf8),
            modificationTime: 0
        )
        // FHCRC immediately precedes the raw DEFLATE payload. The helper's
        // fixed optional fields put it at this stable offset.
        let checksumOffset = 10 + 2 + 3 + "header.txt".utf8.count + 1
            + "KaitoKit fixture".utf8.count + 1
        archive[checksumOffset] ^= 1
        XCTAssertThrowsError(try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .gzip,
            options: ReaderOptions(),
            fallbackFileName: nil
        ))

        let valid = try compress(
            executable: "/usr/bin/gzip",
            input: Data("payload".utf8)
        )
        let withTail = valid + Data([0xaa])
        let reader = try SingleFileReader(
            source: DataByteSource(data: withTail),
            format: .gzip,
            options: ReaderOptions(),
            fallbackFileName: nil
        )
        XCTAssertThrowsError(
            try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll()
        )
    }

    func testBzip2ConcatenatedStreamsAndTrailingBytes() throws {
        let first = Data("one\n".utf8)
        let second = Data(repeating: 0x5a, count: 30_000)
        let archive = try compress(
            executable: "/usr/bin/bzip2",
            input: first
        ) + compress(executable: "/usr/bin/bzip2", input: second)
        let reader = try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .bzip2,
            options: ReaderOptions(),
            fallbackFileName: "pages.tar.bz2"
        )
        XCTAssertEqual(reader.entries[0].name, "pages.tar")
        XCTAssertEqual(try reader.stream(for: reader.entries[0], limits: ReadLimits()).readAll(), first + second)

        let withTail = archive + Data([0])
        let tailed = try SingleFileReader(
            source: DataByteSource(data: withTail),
            format: .bzip2,
            options: ReaderOptions(),
            fallbackFileName: nil
        )
        XCTAssertThrowsError(
            try tailed.stream(for: tailed.entries[0], limits: ReadLimits()).readAll()
        )
    }

    func testXZStreamingConcatenationPaddingAndFooterCompletion() throws {
        let tool = "/opt/homebrew/bin/xz"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw XCTSkip("xz command is not installed")
        }
        let first = Data("xz member one\n".utf8)
        let second = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let firstStream = try compress(executable: tool, input: first)
        let secondStream = try compress(executable: tool, input: second)
        let archive = firstStream + Data(repeating: 0, count: 4) + secondStream
        let reader = try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .xz,
            options: ReaderOptions(),
            fallbackFileName: "pages.txz"
        )
        XCTAssertEqual(reader.entries[0].name, "pages.tar")
        XCTAssertEqual(
            try drain(reader.stream(for: reader.entries[0], limits: ReadLimits()), bufferSize: 7),
            first + second
        )

        var damagedFooter = firstStream
        damagedFooter[damagedFooter.count - 3] ^= 0x40
        let damaged = try SingleFileReader(
            source: DataByteSource(data: damagedFooter),
            format: .xz,
            options: ReaderOptions(),
            fallbackFileName: nil
        )
        XCTAssertThrowsError(
            try damaged.stream(for: damaged.entries[0], limits: ReadLimits()).readAll()
        )
    }

    func testUnixCompressRoundTripAcrossCodeWidths() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") else {
            throw XCTSkip("compress command is not installed")
        }
        var contents = Data()
        contents.append(Data(repeating: 0x41, count: 20_000))
        contents.append(Data((0..<180_000).map { index in
            UInt8(truncatingIfNeeded: index &* 73 &+ index / 251)
        }))
        contents.append(Data(repeating: 0x42, count: 20_000))
        let archive = try unixCompress(contents)
        let reader = try SingleFileReader(
            source: DataByteSource(data: archive),
            format: .compress,
            options: ReaderOptions(),
            fallbackFileName: "legacy.Z"
        )
        XCTAssertEqual(reader.entries[0].name, "legacy")
        XCTAssertEqual(
            try drain(reader.stream(for: reader.entries[0], limits: ReadLimits()), bufferSize: 11),
            contents
        )
    }

    func testUnixCompressNineBitBlockModeFreezesAndClearsDictionary() throws {
        // The macOS tools do not provide a conforming maxbits-9 oracle once
        // the dictionary fills, so this stream is packed directly according
        // to the fixed 9-bit block-mode layout.
        let first = Data((0..<4_099).map { index in
            UInt8(truncatingIfNeeded: index &* 73 &+ index / 19)
        })
        let second = Data((0..<1_031).map { index in
            UInt8(truncatingIfNeeded: index &* 29 &+ 7)
        })
        let contents = first + second
        let archive = makeNineBitBlockModeStream(segments: [first, second])
        XCTAssertEqual(archive.prefix(3), Data([0x1f, 0x9d, 0x89]))

        let decoder = try LZWDecoder(source: DataByteSource(data: archive))
        XCTAssertEqual(try drain(decoder, bufferSize: 13), contents)
    }

    func testUnixCompressIncompressibleDataFillsToolMaximumWidths() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") else {
            throw XCTSkip("compress command is not installed")
        }
        var state: UInt64 = 0xd1b5_4a32_d192_ed03
        var bytes = [UInt8]()
        bytes.reserveCapacity(512 * 1_024)
        for _ in 0..<(512 * 1_024) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state >> 32))
        }
        let contents = Data(bytes)

        // `/usr/bin/compress` is a usable external oracle for these widths;
        // maxbits 9 is covered by the hand-packed fixture above.
        for maximumBits in 10...16 {
            let archive = try unixCompress(contents, maximumBits: maximumBits)
            let decoder = try LZWDecoder(source: DataByteSource(data: archive))
            XCTAssertEqual(
                try drain(decoder, bufferSize: 4_093),
                contents,
                "-b \(maximumBits)"
            )
        }
    }

    func testUnixCompressMaxbitsIsValidatedBeforeUse() {
        for maximumBits in [0, 8, 17, 31] {
            let archive = Data([0x1f, 0x9d, UInt8(maximumBits)])
            XCTAssertThrowsError(try LZWDecoder(source: DataByteSource(data: archive))) { error in
                guard case .malformed = error as? KaitoError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testCompressedTarVariantsGeneratedByBSDTar() throws {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let expected = Data("compressed tar fixture 日本語\n".utf8)
        _ = try TarTestSupport.write(expected, relativePath: "page.txt", below: sourceDirectory)

        let variants = [
            ("book.tgz", "-czf"),
            ("book.tar.gz", "-czf"),
            ("book.tbz2", "-cjf"),
            ("book.tar.bz2", "-cjf"),
            ("book.txz", "-cJf"),
            ("book.tar.xz", "-cJf")
        ]
        for (name, option) in variants {
            let url = directory.appendingPathComponent(name)
            _ = try run(
                executable: "/usr/bin/bsdtar",
                arguments: [option, url.path, "-C", sourceDirectory.path, "page.txt"],
                input: nil
            )
            var limits = ReadLimits()
            limits.inMemorySingleFileLimit = 1
            let archive = try ArchiveReader.open(
                url: url,
                options: ReaderOptions(limits: limits)
            )
            XCTAssertEqual(archive.format, .tar, name)
            XCTAssertEqual(archive.entries.map(\.name), ["page.txt"], name)
            XCTAssertEqual(try archive.read(archive.entries[0]), expected, name)
        }
    }

    func testDeterministicSingleFileMutants() throws {
        let plaintext = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 * 31) })
        var seeds: [(ArchiveFormat, Data)] = [
            (.gzip, try compress(executable: "/usr/bin/gzip", input: plaintext)),
            (.bzip2, try compress(executable: "/usr/bin/bzip2", input: plaintext))
        ]
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/xz") {
            seeds.append((.xz, try compress(
                executable: "/opt/homebrew/bin/xz",
                input: plaintext
            )))
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/compress") {
            seeds.append((.compress, try unixCompress(plaintext)))
        }

        var exercised = 0
        for index in 0..<240 {
            let (format, seed) = seeds[index % seeds.count]
            var changed = seed
            let position = (index &* 131 &+ index / seeds.count) % changed.count
            changed[position] ^= UInt8(truncatingIfNeeded: index &* 17 &+ 1)
            var limits = ReadLimits()
            limits.maxEntrySize = 1 * 1_024 * 1_024
            limits.maxTotalUncompressedSize = 1 * 1_024 * 1_024
            limits.maxInMemorySize = 1 * 1_024 * 1_024
            do {
                let reader = try SingleFileReader(
                    source: DataByteSource(data: changed),
                    format: format,
                    options: ReaderOptions(limits: limits),
                    fallbackFileName: "mutant.\(format.rawValue)"
                )
                _ = try reader.stream(for: reader.entries[0], limits: limits).readAll()
            } catch is KaitoError {
                // Both rejection and a bounded decoded result are valid outcomes.
            }
            exercised += 1
        }
        XCTAssertEqual(exercised, 240)
    }

    private func makeGzipWithAllHeaderFlags(
        contents: Data,
        name: [UInt8],
        modificationTime: UInt32
    ) throws -> Data {
        let ordinary = try compress(executable: "/usr/bin/gzip", input: contents)
        XCTAssertGreaterThanOrEqual(ordinary.count, 18)
        let rawDeflate = ordinary[10..<(ordinary.count - 8)]
        let footer = ordinary[(ordinary.count - 8)..<ordinary.count]

        var header: [UInt8] = [0x1f, 0x8b, 8, 0x1f]
        header.append(UInt8(truncatingIfNeeded: modificationTime))
        header.append(UInt8(truncatingIfNeeded: modificationTime >> 8))
        header.append(UInt8(truncatingIfNeeded: modificationTime >> 16))
        header.append(UInt8(truncatingIfNeeded: modificationTime >> 24))
        header.append(0)
        header.append(3)
        header.append(contentsOf: [3, 0, 0xaa, 0xbb, 0xcc])
        header.append(contentsOf: name)
        header.append(0)
        header.append(contentsOf: "KaitoKit fixture".utf8)
        header.append(0)
        let headerCRC = UInt16(truncatingIfNeeded: CRC32.checksum(header))
        header.append(UInt8(truncatingIfNeeded: headerCRC))
        header.append(UInt8(truncatingIfNeeded: headerCRC >> 8))

        var result = Data(header)
        result.append(contentsOf: rawDeflate)
        result.append(contentsOf: footer)
        return result
    }

    private func unixCompress(
        _ input: Data,
        maximumBits: Int = 16
    ) throws -> Data {
        let directory = try TarTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("fixture")
        try input.write(to: inputURL)
        _ = try run(
            executable: "/usr/bin/compress",
            arguments: ["-f", "-b", String(maximumBits), inputURL.path],
            input: nil
        )
        return try Data(contentsOf: inputURL.appendingPathExtension("Z"))
    }

    private func makeNineBitBlockModeStream(segments: [Data]) -> Data {
        var result = Data([0x1f, 0x9d, 0x89])
        var group: [Int] = []
        group.reserveCapacity(8)

        func flushGroup(padded: Bool) {
            guard !group.isEmpty else { return }
            var bytes = [UInt8](repeating: 0, count: 9)
            for (index, code) in group.enumerated() {
                let startBit = index * 9
                for bit in 0..<9 where code & (1 << bit) != 0 {
                    let absoluteBit = startBit + bit
                    bytes[absoluteBit >> 3] |= UInt8(1 << (absoluteBit & 7))
                }
            }
            let byteCount = padded ? 9 : (group.count * 9 + 7) / 8
            result.append(contentsOf: bytes[..<byteCount])
            group.removeAll(keepingCapacity: true)
        }

        for (segmentIndex, segment) in segments.enumerated() {
            for byte in segment {
                group.append(Int(byte))
                if group.count == 8 {
                    flushGroup(padded: true)
                }
            }
            if segmentIndex < segments.count - 1 {
                group.append(256)
                flushGroup(padded: true)
            }
        }
        flushGroup(padded: false)
        return result
    }

    private func compress(
        executable: String,
        input: Data
    ) throws -> Data {
        return try run(executable: executable, arguments: ["-c"], input: input)
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
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TarTestSupportError.commandFailed(
                String(decoding: diagnostic, as: UTF8.self)
            )
        }
        return result
    }

    private func drain(_ stream: EntryStream, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer[..<count])
        }
    }

    private func drain(_ decoder: any Decompressor, bufferSize: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = try buffer.withUnsafeMutableBytes { storage in
                try decoder.read(into: storage)
            }
            if count == 0 { return result }
            result.append(contentsOf: buffer[..<count])
        }
    }
}
