import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

final class ExtractorCancellationTests: XCTestCase {
    func testMidExtractionCancellationRemovesTemporaryFileAndPreservesDestination() async throws {
        for overwrite in [false, true] {
            let temporary = try ZipTestSupport.temporaryDirectory(label: "extract-cancel")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let destination = temporary.appendingPathComponent("large.bin")
            let original = Data("existing destination".utf8)
            if overwrite { try original.write(to: destination) }
            let payload = Data(repeating: 0x61, count: 16 * 1_024 * 1_024)
            let bytes = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "large.bin", uncompressedData: payload)])
            let source = CancellingSource(bytes)
            let task = Task.detached {
                let reader = try ArchiveReader.open(source: source)
                source.arm()
                _ = try reader.extract(reader.entries[0], to: temporary,
                                       options: ExtractionOptions(overwriteExisting: overwrite))
            }
            do { try await task.value; XCTFail("expected CancellationError") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(source.extractionBytes, 2 * 1_024 * 1_024, "stop immediately after cancellation")
            XCTAssertEqual(source.extractionReads, 2, "stored entries should receive the 1 MiB copy buffer")
            let names = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            XCTAssertEqual(names, overwrite ? ["large.bin"] : [], "no temporary or final file is published")
            if overwrite { XCTAssertEqual(try Data(contentsOf: destination), original) }
        }
    }

    func testMidDirectoryDrainCancellationDoesNotCreateOutputDirectory() async throws {
        let temporary = try ZipTestSupport.temporaryDirectory(label: "drain-cancel")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output")
        let bytes = try ZipTestSupport.makeArchive(entries: [
            HandZipEntry(name: "large/", uncompressedData: Data(repeating: 0x61, count: 8 * 1_024 * 1_024)),
        ])
        let source = CancellingSource(bytes)
        let task = Task.detached {
            let reader = try ArchiveReader.open(source: source)
            source.arm()
            _ = try reader.extract(reader.entries[0], to: output)
        }
        do { try await task.value; XCTFail("expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(source.extractionBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(source.extractionReads, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}

private final class CancellingSource: ByteSource {
    private let source: DataByteSource
    private let payloadStart: UInt64
    private let bytes = Mutex<Int?>(nil)
    private let reads = Mutex(0)
    init(_ data: Data) {
        source = DataByteSource(data)
        let nameLength = Int(data[26]) | Int(data[27]) << 8
        let extraLength = Int(data[28]) | Int(data[29]) << 8
        payloadStart = UInt64(30 + nameLength + extraLength)
    }
    var length: UInt64 { source.length }
    var extractionBytes: Int { bytes.withLock { $0 ?? 0 } }
    var extractionReads: Int { reads.withLock { $0 } }
    func arm() { bytes.withLock { $0 = 0 } }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try source.read(into: buffer, at: offset)
        let cancel = bytes.withLock { value -> Bool in
            guard let current = value, offset >= payloadStart else { return false }
            reads.withLock { $0 += 1 }
            value = current + count
            return value! >= 2 * 1_024 * 1_024
        }
        // Cancel the task deterministically from inside an actual payload read.
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
}
