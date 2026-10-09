import Foundation
@testable import KaitoKit
import XCTest

final class SingleFileParallelDecodeTests: XCTestCase {
    private let threads = [1, 2, 4, 8, 16, 36, 64]
    private struct Outcome: Equatable {
        let bytes: Data
        let error: KaitoError?
    }
    private func outcome(_ decoder: any Decompressor, chunk: Int = 65_537) -> Outcome {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: chunk)
        do {
            XCTAssertEqual(try decoder.read(into: UnsafeMutableRawBufferPointer(start: nil, count: 0)), 0)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                if count == 0 { XCTAssertTrue(decoder.isFinished); break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return Outcome(bytes: bytes, error: nil)
        } catch {
            XCTAssertTrue(error is KaitoError, "\(error)")
            // codec の terminal error は繰返し read でも同一。
            XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }) {
                XCTAssertEqual($0 as? KaitoError, error as? KaitoError)
            }
            return Outcome(bytes: bytes, error: error as? KaitoError)
        }
    }
    private func parallel(_ format: ArchiveFormat, _ data: Data, workers: Int,
                          limits: ReadLimits = ReadLimits()) throws -> any Decompressor {
        let source = DataByteSource(data)
        switch format {
        case .zstd: return try ZstdDecompressor.parallel(source: source, limits: limits, workers: workers)
        case .lzip: return try LzipDecompressor.parallel(source: source, limits: limits, workers: workers)
        case .pbzx: return try PbzxDecompressor.parallel(source: source, limits: limits, workers: workers)
        default: fatalError("unsupported test format")
        }
    }
    private func compare(_ format: ArchiveFormat, _ data: Data, chunks: [Int] = [17, 65_537],
                         expectParallel: Bool = true) throws -> Outcome {
        var last: Outcome!
        for chunk in chunks {
            let serial = try SingleFileReader.makeDecompressor(format: format, source: DataByteSource(data), limits: ReadLimits())
            let expected = outcome(serial, chunk: chunk)
            for workers in threads {
                let decoder = try parallel(format, data, workers: workers)
                XCTAssertEqual(decoder is ParallelIndependentDecompressor, workers > 1 && expectParallel)
                XCTAssertEqual(outcome(decoder, chunk: chunk), expected, "\(format) threads=\(workers) chunk=\(chunk)")
            }
            last = expected
        }
        return last
    }
    private func little(_ value: UInt64, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func big(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func rawZstd(_ body: Data, checksum: Bool = true) -> Data {
        // RFC 8878: single segment、4 byte FCS、最大 128 KiB の raw blocks。
        var result = little(ZstdFrameHeader.magic, 4) + Data([checksum ? 0xa4 : 0xa0]) + little(UInt64(body.count), 4)
        var position = 0
        repeat {
            let count = min(128 * 1_024, body.count - position)
            let last = position + count == body.count
            result.append(little(UInt64(count << 3) | (last ? 1 : 0), 3))
            result.append(body[position..<(position + count)])
            position += count
        } while position < body.count
        if checksum {
            var hash = XXH64(); body.withUnsafeBytes { hash.update($0) }
            result.append(little(hash.value, 4))
        }
        return result
    }
    private func rawPbzx(_ body: Data) -> Data { big(UInt64(body.count)) + big(UInt64(body.count)) + body }
    private var pbzxHeader: Data { Data("pbzx".utf8) + big(1 << 20) }

    private final class OrderingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        var laterFailed: Bool { lock.withLock { failed } }
        func fail() { lock.withLock { failed = true } }
    }

    func testLaterLeafFailureWaitsForEarlierBytes() throws {
        let probe = OrderingProbe(), body = Data(repeating: 97, count: 8_193)
        let first = try ParallelIndependentDecompressor.Unit(outputSize: UInt64(body.count), scratchBytes: 1_024) {
            // 第二単位は第一単位の復号開始より先に失敗する。
            let deadline = Date(timeIntervalSinceNow: 2)
            while !probe.laterFailed, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            guard probe.laterFailed else { throw KaitoError.malformed("test leaf did not start") }
            return try CopyDecompressor(source: DataByteSource(body), offset: 0, compressedSize: UInt64(body.count))
        }
        let second = try ParallelIndependentDecompressor.Unit(outputSize: 1, scratchBytes: 1_024) {
            probe.fail()
            throw KaitoError.malformed("later leaf failed")
        }
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let decoder = try XCTUnwrap(ParallelIndependentDecompressor(units: [first, second], limits: ReadLimits(),
                                                                  workers: 2, diagnostics: diagnostics))
        let decoded = outcome(decoder, chunk: 17)
        XCTAssertEqual(decoded.bytes, body)
        XCTAssertEqual(decoded.error, .malformed("later leaf failed"))
        waitForRelease(diagnostics)
    }

    func testZstdSkippableFramesIdentityAndMiddleChecksumErrorOrder() throws {
        let body = ParallelXZTestSupport.random(196_613)
        let good = rawZstd(body)
        let skip = little(0x184d2a5f, 4) + little(3, 4) + Data([1, 2, 3])
        let encoded = skip + good + skip + good + skip + good + skip
        let decoded = try compare(.zstd, encoded, chunks: [1_009, 65_537])
        XCTAssertNil(decoded.error); XCTAssertEqual(decoded.bytes, body + body + body)
        var corrupt = good; corrupt[corrupt.count - 1] ^= 1
        let failed = try compare(.zstd, skip + good + skip + corrupt + good, chunks: [17, 65_537])
        XCTAssertEqual(failed.error, .checksumMismatch(entry: 0))
        XCTAssertEqual(failed.bytes, body + body.prefix(128 * 1_024))
        // 一つの frame と unknown FCS は直列。後続構造の走査エラーも早期には出さない。
        _ = try compare(.zstd, skip + good + skip, expectParallel: false)
        _ = try compare(.zstd, good + Data([0]), expectParallel: false)
    }

    func testLzipConcatenatedMembersIdentityAndMiddleCRCErrorOrder() throws {
        let good = try TestFixtures.base64("lzip/text.lz")
        var corrupt = good; corrupt[corrupt.count - 20] ^= 1
        let expected = outcome(try LzipDecompressor(source: DataByteSource(good), limits: ReadLimits())).bytes
        let decoded = try compare(.lzip, good + good + good, chunks: [1, 17, 65_537])
        XCTAssertEqual(decoded.bytes, expected + expected + expected); XCTAssertNil(decoded.error)
        let failed = try compare(.lzip, good + corrupt + good)
        XCTAssertEqual(failed.error, .checksumMismatch(entry: 0))
        XCTAssertTrue(failed.bytes.starts(with: expected))
        _ = try compare(.lzip, good, expectParallel: false)
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/lzip") {
            let body = ParallelXZTestSupport.random(65_539)
            let member = try ZipTestSupport.checkedRun("/opt/homebrew/bin/lzip", arguments: ["-1", "-c"], standardInput: body).standardOutput
            XCTAssertEqual(try compare(.lzip, member + member + member, chunks: [1_009, 65_537]).bytes, body + body + body)
        }
    }

    func testPbzxMixedRawXZEmptyChunksAndMiddleErrorOrder() throws {
        let text = try TestFixtures.base64("pbzx/text.pbzx")
        let raw = Data("raw chunk before xz\n".utf8)
        let expected = outcome(try PbzxDecompressor(source: DataByteSource(text), limits: ReadLimits())).bytes
        let mixed = pbzxHeader + rawPbzx(raw) + big(0) + big(0) + text.dropFirst(12) + rawPbzx(raw)
        let decoded = try compare(.pbzx, mixed, chunks: [1, 17, 65_537])
        XCTAssertEqual(decoded.bytes, raw + expected + raw); XCTAssertNil(decoded.error)
        let bad = big(4) + big(3) + Data("abc".utf8)
        let failed = try compare(.pbzx, pbzxHeader + rawPbzx(raw) + bad + rawPbzx(raw))
        XCTAssertEqual(failed.bytes, raw); XCTAssertEqual(failed.error, .malformed("pbzx raw chunk sizes differ"))
        // XZ の check を変える（layout は有効）。最初の chunk の後で元のエラーが出る。
        let stored = text[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let view = try BoundedByteSource(source: DataByteSource(text), baseOffset: 28, length: stored)
        let stream = try XCTUnwrap(XZResourceValidator.validate(source: view, dictionaryLimit: ReadLimits().maxDictionarySize).streams.first)
        let block = try XCTUnwrap(stream.blocks.first)
        var changed = text
        changed[28 + Int(block.compressedRange.upperBound - stream.checkSize)] ^= 1
        let corrupt = try compare(.pbzx, pbzxHeader + rawPbzx(raw) + changed.dropFirst(12) + rawPbzx(raw))
        XCTAssertTrue(corrupt.bytes.starts(with: raw)); XCTAssertNotNil(corrupt.error)
        _ = try compare(.pbzx, pbzxHeader + rawPbzx(raw), expectParallel: false)
    }

    func testMemoryBudgetReservationAndAbandonment() throws {
        let body = ParallelXZTestSupport.random(1 << 20), frame = rawZstd(body)
        let source = DataByteSource(frame + frame + frame + frame)
        let units = try XCTUnwrap(ZstdDecompressor.parallelUnits(source: source, limits: ReadLimits()))
        let maximum = try XCTUnwrap(units.map(\.heldBytes).max())
        XCTAssertNil(ParallelIndependentDecompressor(units: units, limits: ReadLimits(parallelDecodeMemory: UInt64(3 * maximum - 1)), workers: 64))
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        var decoder: ParallelIndependentDecompressor? = try XCTUnwrap(ParallelIndependentDecompressor(
            units: units, limits: ReadLimits(parallelDecodeMemory: UInt64(3 * maximum)), workers: 64, diagnostics: diagnostics))
        var byte: UInt8 = 0
        XCTAssertEqual(try withUnsafeMutableBytes(of: &byte) { try decoder!.read(into: $0) }, 1)
        XCTAssertGreaterThan(diagnostics.peakWorkers, 0)
        XCTAssertLessThanOrEqual(diagnostics.peakWorkers, 2)
        XCTAssertLessThanOrEqual(diagnostics.peakHeldBytes, 3 * maximum)
        decoder = nil
        waitForRelease(diagnostics)
        XCTAssertEqual(diagnostics.heldBytes, 0)
        let completeDiagnostics = ParallelIndependentDecompressor.Diagnostics()
        let complete = try XCTUnwrap(ParallelIndependentDecompressor(units: units,
            limits: ReadLimits(parallelDecodeMemory: UInt64(3 * maximum)), workers: 64, diagnostics: completeDiagnostics))
        XCTAssertEqual(try drain(complete, bufferSize: 256 * 1_024), body + body + body + body)
        waitForRelease(completeDiagnostics)
        XCTAssertLessThanOrEqual(completeDiagnostics.peakHeldBytes, 3 * maximum)
        // 低予算での codec factory は必ず元の直列経路へ戻る。
        for format: ArchiveFormat in [.zstd, .lzip, .pbzx] {
            let data: Data
            switch format {
            case .zstd: data = frame + frame
            case .lzip: let member = try TestFixtures.base64("lzip/text.lz"); data = member + member
            default: data = pbzxHeader + rawPbzx(body) + rawPbzx(body)
            }
            XCTAssertFalse(try parallel(format, data, workers: 64, limits: ReadLimits(parallelDecodeMemory: 1)) is ParallelIndependentDecompressor)
        }
    }
    private func waitForRelease(_ diagnostics: ParallelIndependentDecompressor.Diagnostics) {
        let deadline = Date(timeIntervalSinceNow: 2)
        while (diagnostics.liveWorkers > 0 || diagnostics.heldBytes > 0), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(diagnostics.liveWorkers, 0)
        XCTAssertEqual(diagnostics.heldBytes, 0)
    }

    func testCancellationReleasesPoolJobs() async throws {
        let diagnostics = ParallelIndependentDecompressor.Diagnostics()
        let body = ParallelXZTestSupport.random(1 << 20), frame = rawZstd(body)
        let source = DataByteSource(frame + frame + frame + frame)
        let units = try XCTUnwrap(ZstdDecompressor.parallelUnits(source: source, limits: ReadLimits()))
        let task = Task.detached {
            let decoder = try XCTUnwrap(ParallelIndependentDecompressor(units: units, limits: ReadLimits(), workers: 4, diagnostics: diagnostics))
            var buffer = [UInt8](repeating: 0, count: 1)
            while !decoder.isFinished {
                _ = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
            }
        }
        while diagnostics.peakWorkers == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        waitForRelease(diagnostics)
    }

    func testReaderAndCompressedTarStagingUseResolvedThreads() throws {
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "hello.txt", contents: Data("hello\n".utf8))])
        let half = tar.count / 2
        let zstd = rawZstd(Data(tar.prefix(half))) + rawZstd(Data(tar.dropFirst(half)))
        let pbzx = pbzxHeader + rawPbzx(Data(tar.prefix(half))) + rawPbzx(Data(tar.dropFirst(half)))
        for (format, encoded) in [(ArchiveFormat.zstd, zstd), (.pbzx, pbzx)] {
            for workers in threads {
                let reader = try SingleFileReader(source: DataByteSource(encoded), format: format,
                                                 options: ReaderOptions(decodeThreads: workers), fallbackFileName: nil)
                XCTAssertEqual(try drain(reader.stagingStream(limits: ReadLimits(), recorder: nil), bufferSize: 17), tar)
                let archive = try ArchiveReader.open(data: encoded, options: ReaderOptions(decodeThreads: workers))
                XCTAssertEqual(archive.format, format)
                XCTAssertEqual(try archive.read(archive.entries[0]), tar)
                if format == .zstd {
                    let archive = try ArchiveReader.open(source: DataByteSource(encoded),
                        sourceURL: URL(fileURLWithPath: "/tmp/w4.tar.zst"), options: ReaderOptions(decodeThreads: workers))
                    XCTAssertEqual(archive.format, .tar)
                    XCTAssertEqual(try archive.read(try XCTUnwrap(archive.entries.first { $0.name == "hello.txt" })), Data("hello\n".utf8))
                }
            }
        }
        let member = try TestFixtures.base64("lzip/bundle.tar.lz")
        let reader = try SingleFileReader(source: DataByteSource(member + member), format: .lzip,
                                         options: ReaderOptions(decodeThreads: 8), fallbackFileName: nil)
        let expected = outcome(try LzipDecompressor(source: DataByteSource(member + member), limits: ReadLimits())).bytes
        XCTAssertEqual(try drain(reader.stagingStream(limits: ReadLimits(), recorder: nil), bufferSize: 17), expected)
    }
}
