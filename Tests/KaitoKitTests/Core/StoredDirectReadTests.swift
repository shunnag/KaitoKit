import Foundation
@testable import KaitoKit
import XCTest

private struct StoredReadRecord {
    let offset: UInt64
    let requested: Int
    let returned: Int
    let destination: UInt
}

private final class StoredRecordingByteSource: ByteSource, @unchecked Sendable {
    let length: UInt64

    private let data: Data
    private let maximumChunkSize: Int?
    private let lock = NSLock()
    private var recordedReads: [StoredReadRecord] = []

    init(data: Data, maximumChunkSize: Int? = nil) {
        self.data = data
        self.length = UInt64(data.count)
        self.maximumChunkSize = maximumChunkSize
    }

    var reads: [StoredReadRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReads
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at offset: UInt64
    ) throws -> Int {
        guard !buffer.isEmpty, offset < length else { return 0 }
        let available = try Checked.toInt(try Checked.sub(length, offset))
        let count = min(buffer.count, available, maximumChunkSize ?? buffer.count)
        guard count > 0, let destination = buffer.baseAddress else { return 0 }
        let start = try Checked.toInt(offset)
        data.withUnsafeBytes { source in
            destination.copyMemory(
                from: source.baseAddress!.advanced(by: start),
                byteCount: count
            )
        }
        lock.lock()
        recordedReads.append(StoredReadRecord(
            offset: offset,
            requested: buffer.count,
            returned: count,
            destination: UInt(bitPattern: destination)
        ))
        lock.unlock()
        return count
    }
}

private final class InvalidStoredByteSource: ByteSource, @unchecked Sendable {
    enum Result {
        case negative
        case tooLarge
        case prematureEnd
    }

    let length = UInt64(CopyDecompressor.directReadMinimumSize)
    private let result: Result

    init(result: Result) {
        self.result = result
    }

    func read(
        into buffer: UnsafeMutableRawBufferPointer,
        at _: UInt64
    ) throws -> Int {
        switch result {
        case .negative: -1
        case .tooLarge: buffer.count + 1
        case .prematureEnd: 0
        }
    }
}

final class StoredDirectReadTests: XCTestCase {
    func testReadAllFillsTheFinalDataStorageInLargeDirectSlices() throws {
        let chunk = CopyDecompressor.directReadChunkSize
        let prefix = Data(repeating: 0xA1, count: 19)
        let payload = Data(repeating: 0x5C, count: chunk * 2 + 137)
        var archive = prefix
        archive.append(payload)
        archive.append(Data(repeating: 0xB2, count: 23))
        let source = StoredRecordingByteSource(data: archive)
        let stream = try EntryStream(
            source: source,
            offset: UInt64(prefix.count),
            length: UInt64(payload.count),
            limits: ReadLimits()
        )

        let result = try stream.readAll()

        XCTAssertEqual(result, payload)
        XCTAssertEqual(stream.remaining, 0)
        let reads = source.reads
        XCTAssertEqual(reads.map(\.offset), [
            UInt64(prefix.count),
            UInt64(prefix.count + chunk),
            UInt64(prefix.count + chunk * 2),
        ])
        XCTAssertEqual(reads.map(\.requested), [chunk, chunk, 137])
        XCTAssertEqual(reads.map(\.returned), [chunk, chunk, 137])
        let resultAddress = try XCTUnwrap(result.withUnsafeBytes {
            $0.baseAddress.map { UInt(bitPattern: $0) }
        })
        XCTAssertEqual(reads[0].destination, resultAddress)
        XCTAssertEqual(reads[1].destination, resultAddress + UInt(chunk))
        XCTAssertEqual(reads[2].destination, resultAddress + UInt(chunk * 2))
    }

    func testReadAllAfterStreamingPrefixKeepsCRCAndCompletionSemantics() throws {
        let payload = Data(
            repeating: 0x73,
            count: CopyDecompressor.directReadChunkSize + 911
        )
        let source = StoredRecordingByteSource(
            data: payload,
            maximumChunkSize: 333 * 1_024
        )
        let decompressor = try CopyDecompressor(
            source: source,
            offset: 0,
            compressedSize: UInt64(payload.count)
        )
        var completionCount = 0
        let stream = try EntryStream(
            decompressor: decompressor,
            length: UInt64(payload.count),
            expectedCRC32: CRC32.checksum(payload),
            entryIndex: 17,
            limits: ReadLimits(),
            completionCheck: { completionCount += 1 }
        )
        var prefix = Data(count: 37)
        let prefixCount = try prefix.withUnsafeMutableBytes { storage in
            try stream.read(into: storage)
        }

        let suffix = try stream.readAll()

        XCTAssertEqual(prefixCount, prefix.count)
        prefix.append(suffix)
        XCTAssertEqual(prefix, payload)
        XCTAssertEqual(stream.remaining, 0)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(try stream.readAll(), Data())
        XCTAssertEqual(completionCount, 1)
        let directReads = source.reads.dropFirst()
        XCTAssertGreaterThan(directReads.count, 1)
        XCTAssertEqual(
            directReads.first?.requested,
            CopyDecompressor.directReadChunkSize
        )
        XCTAssertTrue(directReads.allSatisfy {
            $0.requested <= CopyDecompressor.directReadChunkSize
        })
    }

    func testDirectReadRejectsCRCBeforeReturningData() throws {
        let payload = Data(repeating: 0x29, count: 2 * 1_024 * 1_024)
        let decompressor = try CopyDecompressor(
            source: DataByteSource(data: payload),
            offset: 0,
            compressedSize: UInt64(payload.count)
        )
        let stream = try EntryStream(
            decompressor: decompressor,
            length: UInt64(payload.count),
            expectedCRC32: CRC32.checksum(payload) ^ 1,
            entryIndex: 4,
            limits: ReadLimits()
        )

        XCTAssertThrowsError(try stream.readAll()) { error in
            XCTAssertEqual(error as? KaitoError, .checksumMismatch(entry: 4))
        }
        XCTAssertEqual(stream.remaining, 0)
    }

    func testDirectReadRunsAuthenticationCompletionBeforeReturningData() throws {
        enum AuthenticationFailure: Error { case rejected }

        let payload = Data(repeating: 0x91, count: 2 * 1_024 * 1_024)
        let decompressor = try CopyDecompressor(
            source: DataByteSource(data: payload),
            offset: 0,
            compressedSize: UInt64(payload.count)
        )
        let stream = try EntryStream(
            decompressor: decompressor,
            length: UInt64(payload.count),
            expectedCRC32: CRC32.checksum(payload),
            entryIndex: 8,
            limits: ReadLimits(),
            completionCheck: { throw AuthenticationFailure.rejected }
        )

        XCTAssertThrowsError(try stream.readAll()) { error in
            guard case AuthenticationFailure.rejected = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(stream.remaining, 0)
    }

    func testDirectReadPreservesDeclaredSizeMismatchErrors() throws {
        let minimum = CopyDecompressor.directReadMinimumSize
        let source = DataByteSource(data: Data(repeating: 0x18, count: minimum + 1))
        let shortDecompressor = try CopyDecompressor(
            source: source,
            offset: 0,
            compressedSize: UInt64(minimum)
        )
        let shortStream = try EntryStream(
            decompressor: shortDecompressor,
            length: UInt64(minimum + 1),
            expectedCRC32: nil,
            entryIndex: 0,
            limits: ReadLimits()
        )
        XCTAssertThrowsError(try shortStream.readAll()) { error in
            XCTAssertEqual(error as? KaitoError, .truncated)
        }

        let longDecompressor = try CopyDecompressor(
            source: source,
            offset: 0,
            compressedSize: UInt64(minimum + 1)
        )
        let longStream = try EntryStream(
            decompressor: longDecompressor,
            length: UInt64(minimum),
            expectedCRC32: nil,
            entryIndex: 0,
            limits: ReadLimits()
        )
        XCTAssertThrowsError(try longStream.readAll()) { error in
            guard case KaitoError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testDirectReadRejectsInvalidByteSourceCountsAndPrematureEnd() throws {
        for result in [
            InvalidStoredByteSource.Result.negative,
            .tooLarge,
            .prematureEnd,
        ] {
            let source = InvalidStoredByteSource(result: result)
            let stream = try EntryStream(
                source: source,
                offset: 0,
                length: source.length,
                limits: ReadLimits()
            )
            XCTAssertThrowsError(try stream.readAll()) { error in
                switch result {
                case .negative, .tooLarge:
                    guard case KaitoError.malformed = error else {
                        return XCTFail("expected malformed, got \(error)")
                    }
                case .prematureEnd:
                    XCTAssertEqual(error as? KaitoError, .truncated)
                }
            }
        }
    }

    func testZeroLengthStillVerifiesCompletion() throws {
        var completionCount = 0
        let decompressor = try CopyDecompressor(
            source: DataByteSource(data: Data()),
            offset: 0,
            compressedSize: 0
        )
        let stream = try EntryStream(
            decompressor: decompressor,
            length: 0,
            expectedCRC32: CRC32.checksum(Data()),
            entryIndex: 0,
            limits: ReadLimits(),
            completionCheck: { completionCount += 1 }
        )

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(try stream.readAll(), Data())
        XCTAssertEqual(completionCount, 1)
    }

    func testEncryptedStoredDirectReadVerifiesAESAuthentication() throws {
        try ZipTestSupport.requireExecutable(
            ZipTestSupport.sevenZipPath,
            reason: "7zz is unavailable; stored direct-read AES fixture skipped"
        )
        let temporary = try ZipTestSupport.temporaryDirectory(label: "stored-direct-aes")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let payload = Data(repeating: 0xD3, count: 2 * 1_024 * 1_024 + 19)
        _ = try ZipTestSupport.write(
            payload,
            relativePath: "payload.bin",
            below: sourceDirectory
        )
        let archiveURL = temporary.appendingPathComponent("aes.zip")
        try ZipTestSupport.makeSevenZip(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: archiveURL,
            method: "Copy",
            password: "fixed-password"
        )

        let validReader = try ArchiveReader.open(
            url: archiveURL,
            options: ReaderOptions(password: "fixed-password")
        )
        XCTAssertEqual(try validReader.read(validReader.entries[0]), payload)

        var damagedArchive = try Data(contentsOf: archiveURL)
        let layout = try ZipTestSupport.layout(of: damagedArchive)
        let central = try XCTUnwrap(layout.centralEntryOffsets.first)
        let local = try XCTUnwrap(layout.localHeaderOffsets.first)
        let compressedSize = Int(
            try ZipTestSupport.readUInt32(damagedArchive, at: central + 20)
        )
        let nameLength = Int(
            try ZipTestSupport.readUInt16(damagedArchive, at: local + 26)
        )
        let extraLength = Int(
            try ZipTestSupport.readUInt16(damagedArchive, at: local + 28)
        )
        let dataOffset = local + 30 + nameLength + extraLength
        guard compressedSize >= WinZipAESPayload.authenticationCodeSize,
              dataOffset <= damagedArchive.count,
              compressedSize <= damagedArchive.count - dataOffset else {
            return XCTFail("7zz AES fixture has an invalid payload range")
        }
        damagedArchive[dataOffset + compressedSize - 1] ^= 1

        let damagedReader = try ArchiveReader.open(
            data: damagedArchive,
            options: ReaderOptions(password: "fixed-password")
        )
        XCTAssertThrowsError(try damagedReader.read(damagedReader.entries[0])) { error in
            XCTAssertEqual(error as? KaitoError, .wrongPassword)
        }
    }

    func testEncryptedStoredDirectReadHandlesTraditionalZipCrypto() throws {
        let temporary = try ZipTestSupport.temporaryDirectory(
            label: "stored-direct-zipcrypto"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceDirectory = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: false
        )
        let payload = Data(
            repeating: 0x6A,
            count: CopyDecompressor.directReadMinimumSize + 73
        )
        _ = try ZipTestSupport.write(
            payload,
            relativePath: "payload.bin",
            below: sourceDirectory
        )
        let archiveURL = temporary.appendingPathComponent("zipcrypto.zip")
        try ZipTestSupport.makeInfoZip(
            sourceDirectory: sourceDirectory,
            paths: ["payload.bin"],
            archiveURL: archiveURL,
            options: ["-0", "-e", "-P", "fixed-password"]
        )

        let reader = try ArchiveReader.open(
            url: archiveURL,
            options: ReaderOptions(password: "fixed-password")
        )
        XCTAssertEqual(try reader.read(reader.entries[0]), payload)
    }
}
