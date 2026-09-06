import Foundation
@testable import KaitoKit
import XCTest

private struct SourceReadRecord: Sendable {
    let offset: UInt64
    let destinationSize: Int
    let returnedSize: Int
}

private final class RecordingByteSource: ByteSource, @unchecked Sendable {
    let length: UInt64

    private let storage: Data
    private let maximumChunkSize: Int?
    private let lock = NSLock()
    private var recordedReads: [SourceReadRecord] = []

    init(data: Data, maximumChunkSize: Int? = nil) {
        self.storage = data
        self.length = UInt64(data.count)
        self.maximumChunkSize = maximumChunkSize
    }

    var reads: [SourceReadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReads
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else {
            record(offset: offset, destinationSize: buffer.count, returnedSize: 0)
            return 0
        }

        let available = try Checked.toInt(try Checked.sub(length, offset))
        let chunkLimit = maximumChunkSize ?? buffer.count
        let count = min(buffer.count, available, chunkLimit)
        let start = try Checked.toInt(offset)
        guard count > 0, let destination = buffer.baseAddress else {
            record(offset: offset, destinationSize: buffer.count, returnedSize: 0)
            return 0
        }

        let copied = storage.withUnsafeBytes { sourceBuffer -> Bool in
            guard let source = sourceBuffer.baseAddress else {
                return false
            }
            // start + count は storage.count 以下で、両ポインタとも count バイト有効。
            destination.copyMemory(
                from: source.advanced(by: start),
                byteCount: count
            )
            return true
        }
        guard copied else {
            throw KaitoError.truncated
        }

        record(offset: offset, destinationSize: buffer.count, returnedSize: count)
        return count
    }

    private func record(offset: UInt64, destinationSize: Int, returnedSize: Int) {
        lock.lock()
        recordedReads.append(
            SourceReadRecord(
                offset: offset,
                destinationSize: destinationSize,
                returnedSize: returnedSize
            )
        )
        lock.unlock()
    }
}

final class CoreInfrastructureTests: XCTestCase {
    func testDataByteSourceBoundsAndRetainsStorage() throws {
        let original = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) })
        let originalAddress = try XCTUnwrap(baseAddress(of: original))
        let source = DataByteSource(data: original)
        let retainedAddress = try XCTUnwrap(baseAddress(of: source.data))

        XCTAssertEqual(source.length, UInt64(original.count))
        XCTAssertEqual(retainedAddress, originalAddress)

        var output = [UInt8](repeating: 0xEE, count: 8)
        let count = try output.withUnsafeMutableBytes { storage in
            // 不変条件: storage は 8 バイトの配列全域で、source は残り 2 バイトだけを書く。
            try source.read(into: storage, at: UInt64(original.count - 2))
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(output.prefix(2)), [0xFE, 0xFF])
        XCTAssertEqual(Array(output.dropFirst(2)), [UInt8](repeating: 0xEE, count: 6))

        let atEnd = try output.withUnsafeMutableBytes { storage in
            // 不変条件: 終端読み取りでも渡す領域は output 内に限定される。
            try source.read(into: storage, at: source.length)
        }
        let beyondEnd = try output.withUnsafeMutableBytes { storage in
            // 不変条件: 範囲外オフセットでは source は storage に書き込まない。
            try source.read(into: storage, at: UInt64.max)
        }
        XCTAssertEqual(atEnd, 0)
        XCTAssertEqual(beyondEnd, 0)
        XCTAssertEqual(try XCTUnwrap(baseAddress(of: source.data)), originalAddress)
    }

    func testFileByteSourceUsesBoundedPositionalReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-FileByteSource-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("bytes.bin")
        try Data([0x10, 0x20, 0x30, 0x40, 0x50]).write(to: url)
        let source = try FileByteSource(url: url)
        XCTAssertEqual(source.length, 5)

        var output = [UInt8](repeating: 0xAA, count: 6)
        let count = try output.withUnsafeMutableBytes { storage in
            // 不変条件: storage は 6 バイト有効で、pread はファイル残量 2 バイトに制限される。
            try source.read(into: storage, at: 3)
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(output.prefix(2)), [0x40, 0x50])
        XCTAssertEqual(Array(output.dropFirst(2)), [UInt8](repeating: 0xAA, count: 4))

        let atEnd = try output.withUnsafeMutableBytes { storage in
            // 不変条件: 終端では pread を呼ばず storage を変更しない。
            try source.read(into: storage, at: 5)
        }
        XCTAssertEqual(atEnd, 0)
    }

    func testFileByteSourceURLStillFollowsAnExplicitLeafSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoKit-FileByteSource-Symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("link.bin")
        try Data([0x11, 0x22, 0x33]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let source = try FileByteSource(url: link)
        XCTAssertEqual(
            try readByteRange(source: source, offset: 0, count: 3),
            [0x11, 0x22, 0x33]
        )
    }

    func testByteReaderEndianReadsAcrossPartialSourceReads() throws {
        let bytes: [UInt8] = [
            0xAB,
            0x34, 0x12,
            0x56, 0x78,
            0x78, 0x56, 0x34, 0x12,
            0x9A, 0xBC, 0xDE, 0xF0,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        ]
        let source = RecordingByteSource(data: Data(bytes), maximumChunkSize: 3)
        var reader = try ByteReader(source: source)

        XCTAssertEqual(try reader.readUInt8(), 0xAB)
        XCTAssertEqual(try reader.readUInt16LE(), 0x1234)
        XCTAssertEqual(try reader.readUInt16BE(), 0x5678)
        XCTAssertEqual(try reader.readUInt32LE(), 0x1234_5678)
        XCTAssertEqual(try reader.readUInt32BE(), 0x9ABC_DEF0)
        XCTAssertEqual(try reader.readUInt64LE(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try reader.readUInt64BE(), 0x1122_3344_5566_7788)
        XCTAssertEqual(reader.remaining, 0)

        XCTAssertThrowsError(try reader.readUInt8()) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        assertReadsRemainWithinSource(source)
    }

    func testByteReaderReadBytesAndInvalidCounts() throws {
        let source = RecordingByteSource(
            data: Data((0..<40).map(UInt8.init)),
            maximumChunkSize: 7
        )
        var reader = try ByteReader(source: source, offset: 4)
        XCTAssertEqual(reader.offset, 4)
        XCTAssertEqual(reader.remaining, 36)
        XCTAssertEqual(try reader.readBytes(0), Data())
        XCTAssertEqual(try reader.readBytes(15), Data((4..<19).map(UInt8.init)))
        XCTAssertEqual(reader.offset, 19)

        XCTAssertThrowsError(try reader.readBytes(-1)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertThrowsError(try reader.readBytes(22)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertEqual(reader.offset, 19)
        assertReadsRemainWithinSource(source)
    }

    func testByteReaderSeekAndNeverCallsSourcePastLength() throws {
        let count = ByteReader.bufferSize + 17
        let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
        let source = RecordingByteSource(data: bytes)
        var reader = try ByteReader(source: source)

        XCTAssertEqual(try reader.readUInt8(), 0)
        XCTAssertEqual(source.reads.count, 1)

        try reader.seek(to: 10)
        XCTAssertEqual(reader.offset, 10)
        XCTAssertEqual(try reader.readUInt8(), 10)
        XCTAssertEqual(source.reads.count, 1, "an in-buffer seek should not refill")

        let secondBufferOffset = UInt64(ByteReader.bufferSize + 4)
        try reader.seek(to: secondBufferOffset)
        XCTAssertEqual(try reader.readUInt8(), UInt8(truncatingIfNeeded: secondBufferOffset))
        XCTAssertEqual(source.reads.count, 2)

        try reader.seek(to: source.length)
        let callCountAtEnd = source.reads.count
        XCTAssertEqual(reader.remaining, 0)
        XCTAssertThrowsError(try reader.readUInt8()) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertThrowsError(try reader.readBytes(1)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertThrowsError(try reader.seek(to: source.length + 1)) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }
        XCTAssertEqual(source.reads.count, callCountAtEnd)
        assertReadsRemainWithinSource(source)
    }

    func testLSBFirstBitReaderHandVectorsAndAlignment() throws {
        var reader = LSBFirstBitReader(bytes: [0xD6, 0x63])
        XCTAssertFalse(reader.isExhausted)
        XCTAssertEqual(try reader.peek(3), 0b110)
        XCTAssertEqual(try reader.peek(3), 0b110)
        XCTAssertEqual(try reader.read(3), 0b110)
        reader.byteAlign()
        XCTAssertEqual(try reader.read(8), 0x63)
        XCTAssertTrue(reader.isExhausted)
        XCTAssertFalse(reader.overrun)

        var crossing = LSBFirstBitReader(bytes: [0xD6, 0x63])
        XCTAssertEqual(try crossing.read(12), 0x3D6)
        XCTAssertEqual(try crossing.read(4), 0x6)

        var fullWidth = LSBFirstBitReader(bytes: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try fullWidth.read(0), 0)
        XCTAssertEqual(try fullWidth.read(32), 0x7856_3412)
        XCTAssertTrue(fullWidth.isExhausted)
    }

    func testMSBFirstBitReaderHandVectorsAndAlignment() throws {
        var reader = MSBFirstBitReader(bytes: [0xD6, 0x63])
        XCTAssertFalse(reader.isExhausted)
        XCTAssertEqual(try reader.peek(3), 0b110)
        XCTAssertEqual(try reader.peek(3), 0b110)
        XCTAssertEqual(try reader.read(3), 0b110)
        reader.byteAlign()
        XCTAssertEqual(try reader.read(8), 0x63)
        XCTAssertTrue(reader.isExhausted)
        XCTAssertFalse(reader.overrun)

        var crossing = MSBFirstBitReader(bytes: [0xD6, 0x63])
        XCTAssertEqual(try crossing.read(12), 0xD66)
        XCTAssertEqual(try crossing.read(4), 0x3)

        var fullWidth = MSBFirstBitReader(bytes: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try fullWidth.read(0), 0)
        XCTAssertEqual(try fullWidth.read(32), 0x1234_5678)
        XCTAssertTrue(fullWidth.isExhausted)
    }

    func testBitReaderOverrunPadsMissingBitsWithZero() throws {
        var lsb = LSBFirstBitReader(bytes: [0xA5])
        XCTAssertEqual(try lsb.read(12), 0x0A5)
        XCTAssertTrue(lsb.overrun)
        XCTAssertTrue(lsb.isExhausted)

        var msb = MSBFirstBitReader(bytes: [0xA5])
        XCTAssertEqual(try msb.peek(12), 0xA50)
        XCTAssertTrue(msb.overrun)
        XCTAssertFalse(msb.isExhausted)
        try msb.consume(12)
        XCTAssertTrue(msb.isExhausted)

        var empty = LSBFirstBitReader(bytes: [])
        XCTAssertEqual(try empty.read(0), 0)
        XCTAssertFalse(empty.overrun)
        XCTAssertEqual(try empty.read(1), 0)
        XCTAssertTrue(empty.overrun)
        XCTAssertTrue(empty.isExhausted)
    }

    func testBitReaderRejectsCountsOutsideZeroThroughThirtyTwo() throws {
        var lsb = LSBFirstBitReader(bytes: [0x5A])
        XCTAssertThrowsError(try lsb.peek(-1)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertThrowsError(try lsb.consume(33)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try lsb.read(8), 0x5A)

        var msb = MSBFirstBitReader(bytes: [0xA5])
        XCTAssertThrowsError(try msb.read(33)) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
        XCTAssertEqual(try msb.read(8), 0xA5)
    }

    func testCheckedArithmeticAndConversions() throws {
        XCTAssertEqual(try Checked.add(40, 2), 42)
        XCTAssertEqual(try Checked.sub(44, 2), 42)
        XCTAssertEqual(try Checked.mul(6, 7), 42)
        XCTAssertEqual(try Checked.shiftLeft(1, by: 63), UInt64(1) << 63)
        XCTAssertEqual(try Checked.shiftLeft(0, by: 63), 0)
        XCTAssertEqual(try Checked.toInt(UInt64(Int.max)), Int.max)
        XCTAssertEqual(try Checked.size(42, limit: 42), 42)

        assertMalformed { try Checked.add(UInt64.max, 1) }
        assertMalformed { try Checked.sub(0, 1) }
        assertMalformed { try Checked.mul(UInt64.max, 2) }
        assertMalformed { try Checked.shiftLeft(2, by: 63) }
        assertMalformed { try Checked.shiftLeft(1, by: 64) }
        XCTAssertThrowsError(try Checked.toInt(UInt64(Int.max) + 1)) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
        XCTAssertThrowsError(try Checked.size(43, limit: 42)) { error in
            guard case KaitoError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testCRC32KnownVectorAndIncrementalUpdates() {
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(bytes), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data(bytes)), 0xCBF4_3926)

        var checksum = CRC32()
        checksum.update(Array("1234".utf8))
        checksum.update(Data("567".utf8))
        checksum.update(Array("89".utf8))
        checksum.update(Data())
        XCTAssertEqual(checksum.value, 0xCBF4_3926)
    }

    private func baseAddress(of data: Data) -> UInt? {
        data.withUnsafeBytes { buffer in
            // アドレス値だけをクロージャ内で整数化し、寿命外へポインタを持ち出さない。
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        }
    }

    private func assertReadsRemainWithinSource(
        _ source: RecordingByteSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(source.reads.isEmpty, file: file, line: line)
        for read in source.reads {
            XCTAssertGreaterThan(read.destinationSize, 0, file: file, line: line)
            XCTAssertLessThan(read.offset, source.length, file: file, line: line)
            let end = read.offset + UInt64(read.returnedSize)
            XCTAssertLessThanOrEqual(end, source.length, file: file, line: line)
        }
    }

    private func assertMalformed<T>(
        _ operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)", file: file, line: line)
            }
        }
    }
}
