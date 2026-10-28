import Foundation
import Synchronization
@testable import KaitoKit
import XCTest

/// APPNOTE framing / traditional encryption and WinZip AES framing, using only
/// the OS PBKDF2 / AES-ECB / HMAC primitives for independently built test ZIPs.
final class ZipParallelSafetyTests: XCTestCase {
    private struct Fixture: Sendable {
        let method: UInt16
        let packed: Data
        let plain: Data
    }
    private static let fixtures = Result<[Fixture], Error> {
        let small = ParallelXZTestSupport.random(512 * 1_024)
        let large = Data(repeating: 0x61, count: 34 * 1_048_576)
        let xz = try ParallelXZTestSupport.compress(large, threads: 2, blockSize: 4 * 1_048_576)
        let bz = try CompressedTarFramingTestSupport.bzip2(small).data
        var zstd = Data()
        for start in stride(from: 0, to: small.count, by: 65_536) {
            let block = Data(small[start..<(start + 65_536)])
            // RFC 8878: one raw block per independent single-segment frame.
            zstd.append(contentsOf: [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 0, 0, 1, 0, 1, 0, 8])
            zstd.append(block)
        }
        return [Fixture(method: 12, packed: bz, plain: small), Fixture(method: 93, packed: zstd, plain: small),
                Fixture(method: 95, packed: xz, plain: large)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var value = UInt32(n)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }
    private func traditional(_ packed: Data, crc: UInt32) -> Data {
        var a: UInt32 = 0x12345678, b: UInt32 = 0x23456789, c: UInt32 = 0x34567890
        func update(_ byte: UInt8) {
            a = (a >> 8) ^ Self.crcTable[Int((a ^ UInt32(byte)) & 255)]
            b = (b &+ (a & 255)) &* 134775813 &+ 1
            c = (c >> 8) ^ Self.crcTable[Int((c ^ (b >> 24)) & 255)]
        }
        for byte in "secret".utf8 { update(byte) }
        let header = Data((0..<11).map { UInt8($0 + 17) }) + Data([UInt8(truncatingIfNeeded: crc >> 24)])
        var result = Data(); result.reserveCapacity(header.count + packed.count)
        for byte in header + packed {
            let value = (c | 2) & 0xffff
            result.append(byte ^ UInt8(truncatingIfNeeded: (value &* (value ^ 1)) >> 8))
            update(byte)
        }
        return result
    }
    private func encryptedArchive(_ fixture: Fixture, packed: Data, aes: Bool) throws -> Data {
        let crc = CRC32.checksum(fixture.plain)
        var extra = Data(), encoded: Data
        let method: UInt16
        if aes {
            let salt = Data((0..<16).map(UInt8.init))
            let material = try CommonCryptoPrimitives.pbkdf2SHA1(password: Data("secret".utf8), salt: salt,
                                                               iterations: 1_000, outputLength: 66)
            var counters = [UInt8](repeating: 0, count: ((packed.count + 15) / 16) * 16)
            for i in stride(from: 0, to: counters.count, by: 16) {
                let value = UInt64(i / 16 + 1)
                for j in 0..<8 { counters[i + j] = UInt8(truncatingIfNeeded: value >> (8 * j)) }
            }
            let keyStream = try CommonCryptoPrimitives.aesECBEncrypt(blocks: counters, key: Data(material[..<32]))
            let cipher = Data(packed.enumerated().map { $0.element ^ keyStream[$0.offset] })
            let tag = CommonCryptoPrimitives.hmacSHA1(data: cipher, key: Data(material[32..<64]))
            encoded = salt + Data(material[64..<66]) + cipher + Data(tag.prefix(10))
            extra = Data([1, 0x99, 7, 0, 2, 0, 0x41, 0x45, 3, UInt8(fixture.method), 0])
            method = 99
        } else {
            encoded = traditional(packed, crc: crc)
            method = fixture.method
        }
        return try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "payload.bin", uncompressedData: fixture.plain,
            compressedData: encoded, method: method, flags: 0x0801, localExtra: extra, centralExtra: extra,
            centralCRC32: aes ? 0 : crc, localCRC32: aes ? 0 : crc)])
    }

    private struct Outcome: Equatable {
        var bytes = Data()
        var error: KaitoError?
        var reads: UInt64 = 0
        var submissions = 0
    }
    private func outcome(_ archive: Data, threads: Int, limits: ReadLimits = ReadLimits(), password: String? = "secret") throws -> Outcome {
        let source = CountingByteSource(DataByteSource(archive)), submissions = Mutex(0)
        let reader = try ArchiveReader.open(source: source, options: ReaderOptions(limits: limits, password: password, decodeThreads: threads))
        source.reset()
        var result = Outcome(), buffer = [UInt8](repeating: 0, count: 65_537)
        LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
            do {
                let stream = try reader.stream(reader.entries[0])
                while true {
                    let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                    if count == 0 { break }
                    result.bytes.append(contentsOf: buffer.prefix(count))
                }
            } catch { result.error = error as? KaitoError; XCTAssertTrue(error is KaitoError, "\(error)") }
        }
        result.reads = source.bytesRead
        result.submissions = submissions.withLock { $0 }
        return result
    }

    func testEncryptedCodecsKeepSerialReadsAtEightThreads() throws {
        for fixture in try Self.fixtures.get() {
            for aes in [false, true] {
                let bytes = try encryptedArchive(fixture, packed: fixture.packed, aes: aes)
                let serial = try outcome(bytes, threads: 1), parallel = try outcome(bytes, threads: 8)
                XCTAssertNil(serial.error)
                XCTAssertEqual(serial.bytes, fixture.plain)
                XCTAssertEqual(parallel, serial, "method \(fixture.method), AES \(aes)")
                XCTAssertEqual(parallel.submissions, 0)
                print("KE2 encrypted method=\(fixture.method) AES=\(aes) t1=\(serial.reads) t8=\(parallel.reads) packed=\(fixture.packed.count)")
            }
        }
    }

    func testDamagedEncryptedCodecsKeepSerialErrorsAndExactPartialOutput() throws {
        for fixture in try Self.fixtures.get() {
            var flipped = fixture.packed
            if fixture.method == 93 {
                let lastFrameBlockHeader = 7 * (65_536 + 12) + 9
                flipped[lastFrameBlockHeader] |= 6 // reserved block type, after seven valid frames
            } else { flipped[flipped.count - 3] ^= 0x80 }
            for packed in [flipped, Data(fixture.packed.dropLast(5))] {
                for aes in [false, true] {
                    // Authenticate the damaged compressed bytes, so codec errors
                    // rather than an early HMAC failure exercise the routing gate.
                    let bytes = try encryptedArchive(fixture, packed: packed, aes: aes)
                    let serial = try outcome(bytes, threads: 1), parallel = try outcome(bytes, threads: 8)
                    XCTAssertNotNil(serial.error)
                    XCTAssertEqual(parallel, serial, "method \(fixture.method), AES \(aes)")
                    XCTAssertEqual(parallel.submissions, 0)
                    if fixture.method == 93 { XCTAssertGreaterThan(serial.bytes.count, 0) }
                }
            }
        }
    }

    func testMismatchedXZIndexCannotAllocateParallelJobsBeyondZIPDeclarationOrEntryLimit() throws {
        let xz = try XCTUnwrap(Self.fixtures.get().first { $0.method == 95 }?.packed)
        XCTAssertLessThan(xz.count, 65_536, "large decoded blocks have a tiny compressed fixture")
        let declared = Data(repeating: 0x61, count: 1_048_576)
        let archive = try ZipTestSupport.makeArchive(entries: [HandZipEntry(name: "small.bin", uncompressedData: declared,
                                                                         compressedData: xz, method: 95)])
        for maxEntrySize in [UInt64(2 * 1_048_576), UInt64(64 * 1_048_576)] {
            var limits = ReadLimits(maxEntrySize: maxEntrySize); limits.parallelDecodeMemory = 512 * 1_048_576
            let serial = try outcome(archive, threads: 1, limits: limits, password: nil)
            let parallel = try outcome(archive, threads: 8, limits: limits, password: nil)
            XCTAssertEqual(serial.error, .malformed("entry output exceeds its declared size"))
            XCTAssertEqual(parallel.error, serial.error)
            XCTAssertEqual(parallel.bytes, serial.bytes)
            XCTAssertEqual(parallel.submissions, 0, "No job-sized output allocation may be submitted")
            let diagnostics = ParallelXZDecompressor.Diagnostics()
            let decoder = try ParallelXZDecompressor(source: DataByteSource(xz), limits: limits, workers: 8,
                                                     expectedSize: 1_048_576, diagnostics: diagnostics)
            XCTAssertTrue(diagnostics.fellBackToSerial)
            XCTAssertEqual(diagnostics.peakHeldBytes, 0)
            XCTAssertEqual(diagnostics.peakWorkers, 0)
            if maxEntrySize < 34 * 1_048_576 { XCTAssertNil(decoder.decodedSizeHint) }
        }
    }

    func testReviewerXZBombWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["KAITO_KE2_XZ_BOMB"] else {
            throw XCTSkip("Set KAITO_KE2_XZ_BOMB to run the external 2 GiB decoded XZ probe")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        var limits = ReadLimits(maxEntrySize: 2 * 1_048_576); limits.parallelDecodeMemory = 512 * 1_048_576 * 8
        let serial = try outcome(bytes, threads: 1, limits: limits, password: nil)
        let parallel = try outcome(bytes, threads: 8, limits: limits, password: nil)
        XCTAssertEqual(serial.error, .malformed("entry output exceeds its declared size"))
        XCTAssertEqual(parallel.error, serial.error); XCTAssertEqual(parallel.bytes, serial.bytes)
        XCTAssertEqual(parallel.submissions, 0)
        print("KE2 reviewer bomb: t1 bytes=\(serial.reads), t8 bytes=\(parallel.reads), jobs=\(parallel.submissions)")
    }
    func testSingleFileXZAndOversizedStorageHintsRespectEntryLimit() throws {
        let xz = try XCTUnwrap(Self.fixtures.get().first { $0.method == 95 }?.packed)
        let limits = ReadLimits(maxEntrySize: 2 * 1_048_576)
        let reader = try SingleFileReader(source: DataByteSource(xz), format: .xz,
                                         options: ReaderOptions(limits: limits, decodeThreads: 8), fallbackFileName: nil)
        let stream = try reader.stagingStream(limits: limits, recorder: nil)
        XCTAssertNil(reader.stagingSizeHint)
        let spaceChecks = Mutex(0), submissions = Mutex(0)
        try SingleFileMaterializer.$availableTemporarySpace.withValue({ spaceChecks.withLock { $0 += 1 }; return 0 }) {
            try LeafDecodePool.$testingSubmission.withValue({ submissions.withLock { $0 += 1 } }) {
                XCTAssertThrowsError(try SingleFileMaterializer.materialize(stream, limits: limits, sizeHint: reader.stagingSizeHint)) {
                    XCTAssertEqual($0 as? KaitoError, .limitExceeded("entry size"))
                }
            }
            let body = Data(repeating: 0x61, count: 128)
            let tiny = try EntryStream(decompressor: CopyDecompressor(source: DataByteSource(body), offset: 0,
                compressedSize: UInt64(body.count)), length: nil, expectedCRC32: nil, entryIndex: 0, limits: limits)
            let staged = try SingleFileMaterializer.materialize(tiny, limits: limits, sizeHint: .max)
            XCTAssertTrue(staged is DataByteSource)
            XCTAssertEqual(staged.length, UInt64(body.count))
        }
        XCTAssertEqual(spaceChecks.withLock { $0 }, 0)
        XCTAssertEqual(submissions.withLock { $0 }, 0)
    }

    func testBzip2WorkerOutputIsBoundedByEntryAndSevenZipFolderDeclarations() throws {
        let packed = try XCTUnwrap(Self.fixtures.get().first { $0.method == 12 }?.packed)
        let smallLimits = ReadLimits(maxEntrySize: 1_024)
        let diagnostics = ParallelBzip2Decompressor.Diagnostics()
        let decoder = try ParallelBzip2Decompressor(source: DataByteSource(packed), limits: smallLimits,
                                                   workers: 8, diagnostics: diagnostics)
        XCTAssertEqual(decoder.outputBufferLimit, 1_024)
        // Force the bounded speculative decode and serial replay. The scanner's
        // fixed workspace is reserved separately; a former 16 MiB output buffer
        // would take this reservation above 40 MiB for this one-block fixture.
        _ = try drain(decoder, bufferSize: 65_536)
        XCTAssertLessThan(diagnostics.peakHeldBytes, 40 * 1_048_576)
        let folder = SevenZipFolder(coders: [SevenZipCoder(methodID: [4, 2, 2], inputCount: 1, outputCount: 1,
            properties: [], firstInput: 0, firstOutput: 0)], bindPairs: [], packedIndices: [0], inputCount: 1,
            outputCount: 1, finalOutputIndex: 0, unpackSizes: [512], digest: SevenZipDigest(value: nil))
        let factory = try SevenZipFolderDecoderFactory(source: DataByteSource(packed), folder: folder,
            packedRanges: [0: SevenZipPackRange(offset: 0, size: UInt64(packed.count), digest: SevenZipDigest(value: nil))],
            limits: ReadLimits(maxEntrySize: 1_024), password: nil, keyCache: SevenZipAESKeyCache(),
            maximumAESCyclesPower: 24, workers: 8)
        let folderDecoder = try XCTUnwrap(factory.makeDecoder() as? ParallelBzip2Decompressor)
        XCTAssertEqual(folderDecoder.outputBufferLimit, 512)
    }

}
