import Foundation
@testable import KaitoKit
import Synchronization
import XCTest

private final class MetadataCancellingSource: ByteSource {
    private let base: DataByteSource
    private let cancellationOffset: UInt64
    private let state = Mutex((cancelled: false, subsequentReads: 0))

    init(_ data: Data, cancellationOffset: UInt64) {
        base = DataByteSource(data)
        self.cancellationOffset = cancellationOffset
    }

    var length: UInt64 { base.length }
    var didCancel: Bool { state.withLock { $0.cancelled } }
    var subsequentReads: Int { state.withLock { $0.subsequentReads } }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        state.withLock {
            if $0.cancelled {
                $0.subsequentReads += 1
            } else if offset == cancellationOffset {
                // sleep を使わず、メタデータ読取中に確実にキャンセルする。
                withUnsafeCurrentTask { $0?.cancel() }
                $0.cancelled = true
            }
        }
        return try base.read(into: buffer, at: offset)
    }
}

/// 大きな書庫のメタデータを読む途中の中断（ZIP の central directory・ZIP64・tar の header 走査）が再試行や変換をされず、すぐ止まることを検査する。
final class MetadataParseCancellationTests: XCTestCase {
    // 旧名: MetadataParsingTests（printf 形式の flag の検査は ZipRawRecordLayoutTests へ移した）
    func testLargeZIPOpenPropagatesCancellation() async throws {
        let data = try ZipTestSupport.makeZIP64ManyEmptyArchive(entryCount: 200_000)
        let layout = try ZipTestSupport.layout(of: data)
        let source = MetadataCancellingSource(data, cancellationOffset: UInt64(layout.centralDirectoryOffset))
        let task = Task.detached {
            do {
                _ = try ArchiveReader.open(source: source)
                return false
            } catch is CancellationError { return true }
        }
        let cancelled = try await task.value
        XCTAssertTrue(source.didCancel)
        XCTAssertTrue(cancelled, "ZIP metadata cancellation must not be retried or translated")
    }

    func testTarHeaderWalkStopsWithinOneCancellationInterval() async throws {
        let data = try TarTestSupport.makeTar(entries: (0..<4_096).map {
            HandTarEntry(name: "entry-\($0)")
        })
        let source = MetadataCancellingSource(data, cancellationOffset: 32 * 512)
        let task = Task.detached {
            do {
                _ = try ArchiveReader.open(source: source)
                return false
            } catch is CancellationError { return true }
        }
        let cancelled = try await task.value
        XCTAssertTrue(source.didCancel)
        XCTAssertTrue(cancelled)
        XCTAssertLessThanOrEqual(source.subsequentReads, 1_024)
    }

    func testZIP64CancellationDoesNotRetryZIP32Interpretation() async throws {
        var data = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "entry")], forceZIP64End: true)
        let layout = try ZipTestSupport.layout(of: data)
        // sentinel のない ZIP64 は通常 ZIP32 へフォールバックできるが、中断は再試行しない。
        try ZipTestSupport.writeUInt16(1, to: &data, at: layout.endRecordOffset + 8)
        try ZipTestSupport.writeUInt16(1, to: &data, at: layout.endRecordOffset + 10)
        try ZipTestSupport.writeUInt32(UInt32(layout.centralDirectorySize), to: &data, at: layout.endRecordOffset + 12)
        try ZipTestSupport.writeUInt32(UInt32(layout.centralDirectoryOffset), to: &data, at: layout.endRecordOffset + 16)
        XCTAssertEqual(try ArchiveReader.open(data: data).entries.count, 1)
        let source = MetadataCancellingSource(data, cancellationOffset: UInt64(layout.centralDirectoryOffset))
        let task = Task.detached {
            do {
                _ = try ArchiveReader.open(source: source)
                return false
            } catch is CancellationError { return true }
        }
        let cancelled = try await task.value
        XCTAssertTrue(source.didCancel)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(source.subsequentReads, 0)
    }
}
