internal import Foundation
@_spi(TarEditLayout) @testable internal import KaitoKit
internal import XCTest

/// KaitoKit 自身の LZMA2 decoder による XZ 復号を、Apple Compression 経路と比較する。
/// 出力の同一性に加え、壊れた入力でも「エラーまでに返した byte 列」と「エラー」が一致することを確かめる。
final class XZNativeDecompressorTests: XCTestCase {
    private typealias Outcome = (bytes: Data, error: String?, replays: Int, native: Bool, jobFallbacks: Int)

    // MARK: - 補助

    private func xz(_ body: Data, _ arguments: [String]) throws -> Data {
        try ParallelXZTestSupport.requireXZ()
        return try ZipTestSupport.checkedRun(ZipTestSupport.xzPath, arguments: ["-c", "-T1"] + arguments,
                                             standardInput: body).standardOutput
    }

    /// 自然文に近い圧縮率（3〜5 倍）になるよう、擬似乱数の語を混ぜた本文。
    private func text(_ count: Int) -> Data {
        var lines = Data()
        var line = 0
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        let words = ["archive", "stream", "block", "吾輩は", "猫である", "名前は", "まだ無い", "decoder", "check", "index"]
        while lines.count < count {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            let a = words[Int(state % 10)], b = words[Int((state >> 8) % 10)]
            lines.append(Data("\(line) \(a) \(b) \(String(state >> 20, radix: 36))\n".utf8))
            line += 1
        }
        return lines.prefix(count)
    }

    /// `native` を切り替えて同じ入力を同じ buffer 幅で読み切り、結果と観測値を返す。
    private func outcome(_ bytes: Data, native: Bool, bufferSize: Int, workers: Int = 1,
                         targetJobOutput: Int = 16 * 1_048_576) -> Outcome {
        let diagnostics = ParallelXZDecompressor.Diagnostics()
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        do {
            let decoder = try ParallelXZDecompressor(source: DataByteSource(bytes), limits: ReadLimits(), workers: workers,
                                                     targetJobOutput: targetJobOutput, diagnostics: diagnostics,
                                                     useNativeDecoder: native)
            while !decoder.isFinished {
                let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                guard count > 0 || decoder.isFinished else { throw KaitoError.malformed("XZ test made no progress") }
                output.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }, 0)
            return (output, nil, diagnostics.compressionReplays, diagnostics.usedNativeDecoder, diagnostics.nativeJobFallbacks)
        } catch {
            return (output, String(describing: error), diagnostics.compressionReplays, diagnostics.usedNativeDecoder,
                    diagnostics.nativeJobFallbacks)
        }
    }

    /// 両経路の byte 列とエラーが一致することを確かめ、native 側の観測値を返す。
    @discardableResult
    private func assertSameOutcome(_ bytes: Data, bufferSize: Int, workers: Int = 1, targetJobOutput: Int = 16 * 1_048_576,
                                   _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Outcome {
        let expected = outcome(bytes, native: false, bufferSize: bufferSize, workers: workers, targetJobOutput: targetJobOutput)
        let actual = outcome(bytes, native: true, bufferSize: bufferSize, workers: workers, targetJobOutput: targetJobOutput)
        XCTAssertFalse(expected.native, file: file, line: line)
        XCTAssertEqual(actual.error, expected.error, "\(message) buffer=\(bufferSize)", file: file, line: line)
        XCTAssertEqual(actual.bytes.count, expected.bytes.count, "\(message) buffer=\(bufferSize)", file: file, line: line)
        XCTAssertEqual(actual.bytes, expected.bytes, "\(message) buffer=\(bufferSize)", file: file, line: line)
        return actual
    }

    private static let bufferSizes = [1, 4_099, 65_536, 1_048_576]

    // MARK: - CRC-64

    func testCRC64MatchesReferenceVectorAndIsSplitInvariant() {
        XCTAssertEqual(CRC64.checksum(Data("123456789".utf8)), 0x995D_C9BB_DF19_39FA)
        XCTAssertEqual(CRC64.checksum(Data()), 0)
        let body = ParallelXZTestSupport.random(1_000_003)
        let whole = CRC64.checksum(body)
        for pieces in [[1, 7, 13, 1_000_003], [8, 16, 64 * 1_024], [3, 5, 8, 65_537]] {
            var crc = CRC64(), offset = 0, index = 0
            while offset < body.count {
                let count = min(pieces[index % pieces.count], body.count - offset)
                body.withUnsafeBytes { crc.update(UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)])) }
                offset += count; index += 1
            }
            XCTAssertEqual(crc.value, whole)
        }
        // 非整列の先頭から始めても同じ値になる。
        let shifted = Data([0]) + body
        shifted.withUnsafeBytes { XCTAssertEqual(CRC64.checksum(UnsafeRawBufferPointer(rebasing: $0[1...])), whole) }
    }

    // MARK: - 正常な stream の同一性

    func testSingleBlockStreamsOfEveryCheckTypeAndPresetMatchCompression() throws {
        // 保留分（256 KiB）と復号単位を越える長さにし、hold-back を跨いだ返却を確かめる。
        let bodies = [("text", text(700_007)), ("random", ParallelXZTestSupport.random(400_001)),
                      ("mixed", text(200_000) + ParallelXZTestSupport.random(150_000) + text(200_000))]
        for (name, body) in bodies {
            for check in ["none", "crc32", "crc64", "sha256"] {
                let bytes = try xz(body, ["-3", "--check=\(check)"])
                XCTAssertEqual(try ParallelXZTestSupport.layout(bytes).streams.first?.blocks.count, 1)
                for bufferSize in Self.bufferSizes {
                    let result = assertSameOutcome(bytes, bufferSize: bufferSize, "\(name) \(check)")
                    XCTAssertTrue(result.native); XCTAssertEqual(result.replays, 0); XCTAssertNil(result.error)
                    XCTAssertEqual(result.bytes, body)
                }
            }
        }
        let body = bodies[0].1
        for options in [["-0"], ["-9e"], ["--lzma2=preset=3,lc=4,lp=0,pb=0"], ["--lzma2=preset=3,lc=0,lp=4,pb=4"],
                        ["--lzma2=preset=1,dict=64KiB"], ["--lzma2=preset=3,nice=273,mf=bt2"]] {
            let bytes = try xz(body, options)
            let result = assertSameOutcome(bytes, bufferSize: 4_099, options.joined(separator: " "))
            XCTAssertTrue(result.native); XCTAssertEqual(result.replays, 0); XCTAssertEqual(result.bytes, body)
        }
    }

    func testConcatenatedStreamsPaddingEmptyAndTinyStreamsMatchCompression() throws {
        let a = try xz(text(400_001), ["-1", "--check=crc32"])
        let b = try xz(ParallelXZTestSupport.random(300_001), ["-0", "--check=sha256"])
        let c = try xz(text(100_000), ["-2", "--check=none"])
        let empty = try xz(Data(), ["-1"])
        let one = try xz(Data("a".utf8), ["-1"])
        let variants: [(String, Data)] = [
            ("two streams", a + b),
            ("three streams", a + b + c),
            ("padding between and after", a + Data(count: 8) + c + Data(count: 4)),
            ("empty", empty),
            ("empty then stream", empty + a),
            ("one byte", one),
            ("stream then empty", a + empty),
            ("misaligned padding", a + Data(count: 3)),
            ("trailing garbage", a + Data(count: 4) + Data("xyzw".utf8)),
        ]
        for (name, bytes) in variants {
            for bufferSize in Self.bufferSizes {
                assertSameOutcome(bytes, bufferSize: bufferSize, name)
            }
        }
    }

    func testFilterChainsAndReservedCheckTypesStayOnCompression() throws {
        let body = text(200_000) + ParallelXZTestSupport.random(100_000)
        for filters in [["--x86", "--lzma2=preset=1"], ["--delta=dist=4", "--lzma2=preset=1"], ["--powerpc", "--lzma2=preset=1"]] {
            let bytes = try xz(body, filters)
            XCTAssertFalse(XZNativeDecompressor.isEligible(try ParallelXZTestSupport.layout(bytes)))
            let result = assertSameOutcome(bytes, bufferSize: 4_099, filters.joined(separator: " "))
            XCTAssertFalse(result.native); XCTAssertEqual(result.bytes, body)
        }
        // 予約された check 種別（2）。header CRC を直して validator を通し、Compression 経路の判断に従う。
        var reserved = [UInt8](try xz(body, ["-1", "--check=crc32"]))
        reserved[7] = 2
        let headerCRC = CRC32.checksum(Array(reserved[6..<8]))
        for byte in 0..<4 { reserved[8 + byte] = UInt8(truncatingIfNeeded: headerCRC >> (8 * byte)) }
        reserved[reserved.count - 3] = 2
        let footerCRC = CRC32.checksum(Array(reserved[(reserved.count - 8)..<(reserved.count - 2)]))
        for byte in 0..<4 { reserved[reserved.count - 12 + byte] = UInt8(truncatingIfNeeded: footerCRC >> (8 * byte)) }
        let layout = try ParallelXZTestSupport.layout(Data(reserved))
        XCTAssertEqual(layout.streams.first?.checkType, 2)
        XCTAssertFalse(XZNativeDecompressor.isEligible(layout))
        let result = assertSameOutcome(Data(reserved), bufferSize: 65_536, "reserved check")
        XCTAssertFalse(result.native)
    }

    // MARK: - 壊れた入力

    func testCorruptSingleBlockStreamsDeliverTheSameBytesBeforeTheSameError() throws {
        // 複数の LZMA2 chunk（packed 64 KiB ごと）と複数の 256 KiB 片を持つ単一 block。
        let body = text(1_000_000)
        let valid = try xz(body, ["-6", "--check=crc64"])
        let layout = try ParallelXZTestSupport.layout(valid)
        let block = try XCTUnwrap(layout.streams.first?.blocks.first)
        let payloadStart = Int(block.payloadOffset), payloadEnd = Int(block.payloadOffset + block.payloadSize)
        let checkOffset = Int(block.compressedRange.upperBound) - 8
        let indexCRC = Int(layout.streams[0].indexRange.upperBound) - 1
        XCTAssertGreaterThan(payloadEnd - payloadStart, 150_000, "payload \(payloadEnd - payloadStart)")
        var offsets = [payloadStart + 1, payloadStart + 6, payloadStart + 40, payloadStart + 5_000,
                       (payloadStart + payloadEnd) / 2, payloadEnd - 3, payloadEnd - 1,
                       checkOffset, checkOffset + 7, indexCRC]
        // 二つ目以降の chunk の header 直後と末尾付近も崩す。
        var cursor = payloadStart, chunkIndex = 0
        while cursor < payloadEnd, valid[cursor] != 0 {
            let control = valid[cursor]
            if control < 0x80 {
                let size = Int(valid[cursor + 1]) << 8 | Int(valid[cursor + 2])
                if chunkIndex > 0 { offsets.append(cursor + 3 + size / 2) }
                cursor += 3 + size + 1
            } else {
                let packed = Int(valid[cursor + 3]) << 8 | Int(valid[cursor + 4])
                let headerSize = control >= 0xc0 ? 6 : 5
                if chunkIndex > 0 { offsets.append(cursor); offsets.append(cursor + headerSize + 100); offsets.append(cursor + headerSize + packed - 2) }
                cursor += headerSize + packed + 1
            }
            chunkIndex += 1
        }
        XCTAssertGreaterThan(chunkIndex, 2)
        var replays = 0
        for (index, offset) in Set(offsets).sorted().enumerated() where offset >= payloadStart && offset < valid.count {
            var mutant = valid
            mutant[offset] ^= offset % 2 == 0 ? 0x01 : 0x80
            // 四つの buffer 幅は交互に半分ずつ使い、debug build の実行時間を抑える。
            for bufferSize in index % 2 == 0 ? [1, 65_536] : [4_099, 1_048_576] {
                let result = assertSameOutcome(mutant, bufferSize: bufferSize, "offset=\(offset)")
                replays += result.replays
            }
        }
        XCTAssertGreaterThan(replays, 0)
    }

    func testCorruptRawChunkStreamsMatchCompression() throws {
        let body = ParallelXZTestSupport.random(900_000)
        let valid = try xz(body, ["-0", "--check=crc64"])
        // 先頭 chunk の data、二つ目の chunk header（control・size）、末尾付近、check。
        for offset in [30, 65_561, 65_562, 65_563, 600_000, valid.count - 40, valid.count - 29] {
            var mutant = valid
            mutant[offset] ^= 1
            for bufferSize in Self.bufferSizes {
                assertSameOutcome(mutant, bufferSize: bufferSize, "offset=\(offset)")
            }
        }
    }

    func testLZMAChunkWithoutPropertiesAfterRawDictionaryResetFailsLikeCompression() throws {
        // xz は非圧縮性データの後に本文が続くと [0x02 raw][0xA0 LZMA, property なし] を書く。
        // raw chunk の control を 0x01（dictionary reset）へ変えると、liblzma も 7-Zip も 0xA0 を拒否する。
        // 自身の decoder は辞書を reset しても raw chunk の byte を保持するため、ここで止めなければ
        // 以後の chunk が同じ byte 列に復号され check も通ってしまう。
        // 先頭の raw chunk は 0x01 で、その後の LZMA chunk は 0xC0 になるので、本文を先に置く。
        let body = text(400_000) + ParallelXZTestSupport.random(200_000) + text(400_000)
        let valid = try xz(body, ["-6", "--check=crc64"])
        let layout = try ParallelXZTestSupport.layout(valid)
        let block = try XCTUnwrap(layout.streams.first?.blocks.first)
        let payloadStart = Int(block.payloadOffset), payloadEnd = Int(block.payloadOffset + block.payloadSize)
        var rawControls: [Int] = []
        var cursor = payloadStart
        var previousRawControl: Int?
        var rawBeforeLZMAWithoutProperties: Int?
        while cursor < payloadEnd, valid[cursor] != 0 {
            let control = valid[cursor]
            if control < 0x80 {
                rawControls.append(cursor)
                previousRawControl = cursor
                let size = Int(valid[cursor + 1]) << 8 | Int(valid[cursor + 2])
                cursor += 3 + size + 1
            } else {
                if control < 0xc0, let raw = previousRawControl, rawBeforeLZMAWithoutProperties == nil {
                    rawBeforeLZMAWithoutProperties = raw
                }
                previousRawControl = nil
                let packed = Int(valid[cursor + 3]) << 8 | Int(valid[cursor + 4])
                cursor += (control >= 0xc0 ? 6 : 5) + packed + 1
            }
        }
        guard let rawOffset = rawBeforeLZMAWithoutProperties else {
            // xz 5.8 は [0x02 raw][0xA0...] を書く。別の xz がこの並びを作らなければ、
            // 規則そのものは LZMA2DecoderTests が決定的に検証しているので skip する。
            throw XCTSkip("xz did not emit a raw 0x02 chunk followed by an LZMA chunk without properties")
        }
        XCTAssertEqual(valid[rawOffset], 0x02)
        var mutant = valid
        mutant[rawOffset] = 0x01
        XCTAssertEqual(outcome(valid, native: true, bufferSize: 65_536).bytes, body)
        for bufferSize in Self.bufferSizes {
            let result = assertSameOutcome(mutant, bufferSize: bufferSize, "raw 0x01 at \(rawOffset)")
            XCTAssertNotNil(result.error)
            XCTAssertGreaterThan(result.replays, 0)
            XCTAssertLessThan(result.bytes.count, body.count)
        }
        // 先頭の raw chunk を 0x01 にした場合も同じ（直後の LZMA chunk が 0xE0 なら有効なまま）。
        var leading = valid
        leading[rawControls[0]] = 0x01
        for bufferSize in [1, 65_536] {
            assertSameOutcome(leading, bufferSize: bufferSize, "leading raw 0x01")
        }
    }

    func testTruncationMatchesCompression() throws {
        let valid = try xz(text(500_000), ["-3"])
        for end in [24, 25, 100, valid.count / 2, valid.count - 13, valid.count - 12, valid.count - 4, valid.count - 1] {
            let truncated = valid.prefix(end)
            for bufferSize in [1, 4_099] {
                assertSameOutcome(Data(truncated), bufferSize: bufferSize, "end=\(end)")
            }
        }
    }

    func testCorruptMultiBlockJobsFallBackToCompressionForTheSameError() throws {
        let body = text(900_000) + ParallelXZTestSupport.random(300_000) + text(600_000)
        let valid = try xz(body, ["-1", "--block-size=200000"])
        let stream = try XCTUnwrap(ParallelXZTestSupport.layout(valid).streams.first)
        XCTAssertGreaterThan(stream.blocks.count, 4)
        var fallbacks = 0
        for blockIndex in [0, 2, stream.blocks.count - 1] {
            let block = stream.blocks[blockIndex]
            for offset in [Int(block.payloadOffset) + 7, Int(block.payloadOffset + block.payloadSize / 2),
                           Int(block.compressedRange.upperBound) - 1] {
                var mutant = valid
                mutant[offset] ^= 1
                for (workers, target) in [(1, 16 * 1_048_576), (3, 200_000), (8, 400_000)] {
                    for bufferSize in [4_099, 1_048_576] {
                        let result = assertSameOutcome(mutant, bufferSize: bufferSize, workers: workers, targetJobOutput: target,
                                                       "block=\(blockIndex) offset=\(offset) workers=\(workers)")
                        XCTAssertNotNil(result.error)
                        fallbacks += result.jobFallbacks
                    }
                }
            }
        }
        XCTAssertGreaterThan(fallbacks, 0)
        for (workers, target) in [(3, 200_000), (8, 400_000)] {
            let result = assertSameOutcome(valid, bufferSize: 65_536, workers: workers, targetJobOutput: target, "valid parallel")
            XCTAssertTrue(result.native); XCTAssertEqual(result.jobFallbacks, 0); XCTAssertEqual(result.bytes, body)
        }
    }

    // MARK: - recorder と中断

    func testSingleBlockRecorderChunkMapMatchesCompression() throws {
        let image = try TarTestSupport.makeTar(entries: [
            HandTarEntry(name: "text.txt", contents: text(700_001)),
            HandTarEntry(name: "random.bin", contents: ParallelXZTestSupport.random(300_003))
        ])
        let bytes = try xz(image, ["-3"])
        let source = DataByteSource(bytes)
        func map(native: Bool) throws -> (CompressedTarChunkMap?, ChunkMapUnavailableReason?, Data) {
            let recorder = CompressedTarMapRecorder(format: .xz)
            let decoder = try ParallelXZDecompressor(source: source, limits: ReadLimits(), recorder: recorder,
                                                     useNativeDecoder: native)
            let output = try drain(decoder, bufferSize: 65_536)
            let finished = recorder.finish(imageLength: UInt64(output.count), archiveLength: source.length)
            return (finished.map, finished.reason, output)
        }
        let expected = try map(native: false), actual = try map(native: true)
        XCTAssertNil(expected.1); XCTAssertNotNil(expected.0)
        XCTAssertEqual(actual.0, expected.0)
        XCTAssertEqual(actual.1, expected.1)
        XCTAssertEqual(actual.2, image)
        let snapshot = try TarEditTestSupport.snapshot(bytes, suffix: "txz")
        XCTAssertEqual(snapshot.chunkMap, expected.0)
    }

    func testCancelledTaskStopsNativeSerialDecoding() async throws {
        let bytes = try xz(text(2_000_000), ["-1"])
        let task = Task.detached {
            let decoder = try ParallelXZDecompressor(source: DataByteSource(bytes), limits: ReadLimits(), workers: 1)
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var total = 0
            while !decoder.isFinished {
                total += try buffer.withUnsafeMutableBytes { try decoder.read(into: $0) }
                if total >= 300_000 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return total
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
