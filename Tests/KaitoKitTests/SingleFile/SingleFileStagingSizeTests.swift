import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class SingleFileStagingSizeTests: XCTestCase {
    func testKnownSizeSelectsMemoryAndDiskAtThreshold() throws {
        let threshold: UInt64 = 1_048_576
        for size in [threshold - 1, threshold, threshold + 1] {
            let bytes = Data(repeating: 0x61, count: Int(size))
            let stream = try EntryStream(source: DataByteSource(bytes), offset: 0, length: size, limits: ReadLimits())
            let source = try SingleFileMaterializer.materialize(stream, limits: ReadLimits(inMemorySingleFileLimit: threshold))
            XCTAssertEqual(source is DataByteSource, size <= threshold)
            XCTAssertEqual(source.length, size)
            XCTAssertEqual(Data(try readByteRange(source: source, offset: 0, count: Int(size))), bytes)
        }
    }

    func testEarlyDiskFailureDoesNotMaskPrefixDecodeError() throws {
        final class Broken: Decompressor {
            var reads = 0
            var isFinished: Bool { false }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                reads += 1
                if reads == 2 { throw KaitoError.malformed("prefix decode error") }
                buffer.initializeMemory(as: UInt8.self, repeating: 0x61)
                return buffer.count
            }
        }
        let limits = ReadLimits(inMemorySingleFileLimit: 1_048_576)
        for known in [false, true] {
            let decoder = Broken()
            let stream = try EntryStream(decompressor: decoder, length: known ? 2_097_152 : nil,
                                         expectedCRC32: nil, entryIndex: 0, limits: limits)
            try SingleFileMaterializer.$availableTemporarySpace.withValue({ 0 }) {
                XCTAssertThrowsError(try SingleFileMaterializer.materialize(stream, limits: limits)) {
                    XCTAssertEqual($0 as? KaitoError, .malformed("prefix decode error"))
                }
            }
            XCTAssertEqual(decoder.reads, 2)
        }
    }

    func testKnownLargeStreamReportsSpaceFailureAtOriginalSpillPoint() throws {
        final class Counted: Decompressor {
            var reads = 0
            var isFinished: Bool { false }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                reads += 1
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                return buffer.count
            }
        }
        let limits = ReadLimits(inMemorySingleFileLimit: 1_048_576)
        for known in [false, true] {
            let decoder = Counted()
            let stream = try EntryStream(decompressor: decoder, length: known ? 2_097_152 : nil,
                                         expectedCRC32: nil, entryIndex: 0, limits: limits)
            try SingleFileMaterializer.$availableTemporarySpace.withValue({ 0 }) {
                XCTAssertThrowsError(try SingleFileMaterializer.materialize(stream, limits: limits)) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("staging free space"))
                }
            }
            XCTAssertEqual(decoder.reads, 5)
        }
    }

    func testXZLayoutHintDoesNotAssertDecodedLength() throws {
        let bytes = try TestFixtures.base64("tar-edit/third-xz-crc64.tar.xz")
        let reader = try SingleFileReader(source: DataByteSource(bytes), format: .xz,
                                         options: ReaderOptions(), fallbackFileName: nil)
        let stream = try reader.stagingStream(limits: ReadLimits(), recorder: nil)
        XCTAssertEqual(stream.remaining, UInt64.max)
        let source = try SingleFileMaterializer.materialize(stream, limits: ReadLimits(), sizeHint: reader.stagingSizeHint)
        XCTAssertEqual(source.length, reader.stagingSizeHint)
    }

    func testBufferedOutputFlushesIOErrorBeforeLaterDecodeErrorOnlyAfterSpillPoint() throws {
        final class Failing: Decompressor {
            var remaining = 256 * 1_024 * 1_024 + 128 * 1_024
            var isFinished: Bool { false }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                guard remaining > 0 else { throw KaitoError.malformed("later decode error") }
                let count = min(buffer.count, remaining)
                UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]).initializeMemory(as: UInt8.self, repeating: 0)
                remaining -= count
                return count
            }
        }
        for memoryLimit in [UInt64(1_048_576), UInt64(512 * 1_048_576)] {
            let decoder = Failing(), checks = Mutex(0)
            let limits = ReadLimits(inMemorySingleFileLimit: memoryLimit, stagingFreeSpaceReserve: 1)
            let stream = try EntryStream(decompressor: decoder, length: 600 * 1_048_576,
                                         expectedCRC32: nil, entryIndex: 0, limits: limits)
            let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            try SingleFileMaterializer.$availableTemporarySpace.withValue({
                checks.withLock { $0 += 1; return $0 == 1 ? UInt64.max : 0 }
            }) {
                XCTAssertThrowsError(try SingleFileMaterializer.materialize(stream, limits: limits)) {
                    let expected: KaitoError = memoryLimit < 256 * 1_048_576
                        ? .limitExceeded("staging free space") : .malformed("later decode error")
                    XCTAssertEqual($0 as? KaitoError, expected)
                }
            }
            XCTAssertEqual(checks.withLock { $0 }, memoryLimit < 256 * 1_048_576 ? 2 : 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, descriptors)
        }
    }

    func testShortDecodeChunksFillAndFlushBoundedWriteBuffer() throws {
        final class Short: Decompressor {
            let bytes: Data
            var offset = 0
            var isFinished: Bool { offset == bytes.count }
            init(_ bytes: Data) { self.bytes = bytes }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                let count = min(buffer.count, 8_191, bytes.count - offset)
                bytes.withUnsafeBytes {
                    UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]).copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)]))
                }
                offset += count
                return count
            }
        }
        // Uneven chunks cross buffer boundaries; the final short tail is validated
        // and flushed without exposing uninitialized space or losing any bytes.
        let bytes = Data((0..<(9 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let limits = ReadLimits(inMemorySingleFileLimit: 1_048_576)
        let stream = try EntryStream(decompressor: Short(bytes), length: UInt64(bytes.count),
            expectedCRC32: CRC32.checksum(bytes), entryIndex: 0, limits: limits)
        let source = try SingleFileMaterializer.materialize(stream, limits: limits)
        XCTAssertTrue(source is FileByteSource)
        XCTAssertEqual(Data(try readByteRange(source: source, offset: 0, count: bytes.count)), bytes)
    }

    func testCancellationWithBufferedOutputClosesDescriptor() async throws {
        final class Cancels: Decompressor {
            var reads = 0
            var isFinished: Bool { false }
            func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
                reads += 1
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                if reads == 8 { withUnsafeCurrentTask { $0?.cancel() } }
                return buffer.count
            }
        }
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let reads = await Task.detached {
            let decoder = Cancels(), limits = ReadLimits(inMemorySingleFileLimit: 1_048_576)
            do {
                let stream = try EntryStream(decompressor: decoder, length: 16 * 1_048_576,
                    expectedCRC32: nil, entryIndex: 0, limits: limits)
                _ = try SingleFileMaterializer.materialize(stream, limits: limits)
            } catch is CancellationError { return decoder.reads }
            catch { return -1 }
            return -2
        }.value
        XCTAssertEqual(reads, 8)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, descriptors)
    }

    func testTarListingsAndExtractionAroundStagingThreshold() throws {
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "sized-tar-staging")
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(repeating: 0x61, count: 1_048_576)
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "payload.bin", contents: body)])
        let input = try SevenZipTestSupport.write(tar, relativePath: "bundle.tar", below: directory)
        let tools: [(String, [String], String)] = [
            ("/usr/bin/gzip", ["-n", "-c"], "gz"),
            (ZipTestSupport.xzPath, ["-c", "-T2", "--block-size=256KiB"], "xz"),
            (ZipTestSupport.zstdPath, ["-q", "-c"], "zst"),
            ("/opt/homebrew/bin/lzip", ["-c"], "lz"),
            ("/usr/bin/bzip2", ["-c"], "bz2")]
        for (tool, arguments, suffix) in tools {
            try ZipTestSupport.requireExecutable(tool, reason: "\(tool) unavailable")
            let packed = try ZipTestSupport.checkedRun(tool, arguments: arguments + [input.path]).standardOutput
            for threshold in [UInt64(tar.count - 1), UInt64(tar.count), UInt64(tar.count + 1)] {
                let reader = try ArchiveReader.open(source: DataByteSource(packed),
                    sourceURL: directory.appendingPathComponent("bundle.tar.\(suffix)"),
                    options: ReaderOptions(limits: ReadLimits(inMemorySingleFileLimit: threshold), decodeThreads: 2))
                XCTAssertEqual(reader.format, .tar)
                XCTAssertEqual(reader.entries.map(\.name), ["payload.bin"])
                XCTAssertEqual(try reader.read(reader.entries[0]), body)
                let reopened = try reader.reopen()
                XCTAssertEqual(reopened.entries, reader.entries)
                XCTAssertEqual(try reopened.read(reopened.entries[0]), body)
            }
        }
    }

    func testGzipISIZEIsOnlyAHintForConcatenatedMembers() throws {
        let directory = try SevenZipTestSupport.temporaryDirectory(label: "gzip-isize-hint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = Data(repeating: 0x61, count: 500_000), b = Data(repeating: 0x62, count: 17)
        let first = try ZipTestSupport.checkedRun("/usr/bin/gzip", arguments: ["-n", "-c"], standardInput: a).standardOutput
        let second = try ZipTestSupport.checkedRun("/usr/bin/gzip", arguments: ["-n", "-c"], standardInput: b).standardOutput
        let reader = try SingleFileReader(source: DataByteSource(first + second), format: .gzip,
                                         options: ReaderOptions(), fallbackFileName: nil)
        let stream = try reader.stagingStream(limits: ReadLimits(), recorder: nil)
        XCTAssertEqual(reader.stagingSizeHint, UInt64(b.count))
        XCTAssertEqual(stream.remaining, UInt64.max)
        let source = try SingleFileMaterializer.materialize(stream, limits: ReadLimits(), sizeHint: reader.stagingSizeHint)
        let decoded = Data(try readByteRange(source: source, offset: 0, count: a.count + b.count))
        XCTAssertEqual(decoded, a + b)
    }
}
