import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest

final class TarEditDifferentialFuzzTests: XCTestCase {
    func testFixedSeedMutations() throws {
        let start = Date()
        let image = try TarTestSupport.makeTar(entries: (0..<4).map {
            HandTarEntry(name: "f\($0)", contents: Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 * 37) }))
        })
        var seeds: [(String, Data)] = [
            ("tar.gz", try GyoshukuFramingTestSupport.gzip(image, chunkSize: 2048).data),
            ("tar.bz2", try GyoshukuFramingTestSupport.bzip2(image, level: 1, chunkSize: 2048).data),
            ("tar.xz", try GyoshukuFramingTestSupport.xz(image, chunkSize: 2048).data)]
        let root = TarGoldenCorpus.repository.appendingPathComponent("Tests/Fixtures/tar-edit")
        for (name, ext) in [("third-gzip.tar.gz", "tar.gz"), ("third-bzip2.tar.bz2", "tar.bz2"),
                            ("third-bsdtar.tar.xz", "tar.xz"), ("third-xz-crc32.tar.xz", "tar.xz"), ("third-xz-crc64.tar.xz", "tar.xz")] {
            let text = try String(contentsOf: root.appendingPathComponent(name + ".b64"), encoding: .utf8)
            seeds.append((ext, try XCTUnwrap(Data(base64Encoded: text, options: .ignoreUnknownCharacters))))
        }
        var state: UInt64 = 0x7351_2a9c_e82b_106d
        func next(_ limit: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(max(1, limit)))
        }
        var limits = ReadLimits(); limits.maxEntrySize = 8 * 1_048_576; limits.maxTotalUncompressedSize = 16 * 1_048_576
        let off = ReaderOptions(limits: limits, appleDoublePolicy: .expose)
        let on = tarGoldenOptions(off, recording: true)
        for (seedIndex, seed) in seeds.enumerated() {
            for mutation in 0..<300 {
                var bytes = seed.1
                let position = next(bytes.count)
                switch mutation % (seed.0 == "tar.bz2" ? 5 : 4) {
                case 0: bytes[position] ^= UInt8(1 << next(8))
                case 1:
                    for i in position..<min(bytes.count, position + next(8) + 1) { bytes[i] = UInt8(next(256)) }
                case 2: bytes = Data(bytes.prefix(position))
                case 3: bytes.insert(contentsOf: (0..<next(8) + 1).map { _ in UInt8(next(256)) }, at: position)
                default: bytes.insert(contentsOf: [0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59], at: position)
                }
                let hint = URL(fileURLWithPath: "/fuzz." + seed.0)
                let old: Outcome
                if seed.0 == "tar.bz2", bytes.count >= 4, bytes.prefix(3) == Data("BZh".utf8), (0x31...0x39).contains(bytes[3]) {
                    old = serialBzip2Reference(bytes, hint: hint, options: off)
                } else {
                    old = outcome { try ArchiveReader.open(source: DataByteSource(bytes), sourceURL: hint, options: off) }
                }
                let new = outcome { try ArchiveReader.open(source: DataByteSource(bytes), sourceURL: hint, options: on) }
                XCTAssertEqual(old, new, "seed=\(seedIndex) mutation=\(mutation)")
                if seed.0 == "tar.gz" { try compareGzip(bytes, limits: limits) }
                if let reader = try? ArchiveReader.open(source: DataByteSource(bytes), sourceURL: hint, options: on),
                   let snapshot = reader.tarEditingSnapshot(), snapshot.chunkMap != nil {
                    try TarEditTestSupport.verify(snapshot)
                }
            }
        }
        print("TAR-FUZZ mutations=\(seeds.count * 300) differences=0 seconds=\(Date().timeIntervalSince(start))")
        XCTAssertLessThan(Date().timeIntervalSince(start), 120)
    }
    func testRecordedGzipMatchesAllFrozenInputs() throws {
        for input in try TarGoldenCorpus.inputs() where input.suffix == "tar.gz" {
            try compareGzip(TarGoldenCorpus.decoded(input), limits: ReadLimits())
        }
    }
    private func compareGzip(_ bytes: Data, limits: ReadLimits) throws {
        let source = DataByteSource(bytes)
        let plain = try GzipDecompressor(source: source)
        let recorder = CompressedTarMapRecorder(format: .gzip)
        let recorded = try GzipDecompressor(source: source, recorder: recorder)
        let a = TarEditTestSupport.decodeOutcome(plain, limit: limits.maxEntrySize)
        let b = TarEditTestSupport.decodeOutcome(recorded, limit: limits.maxEntrySize)
        XCTAssertEqual(a.error, b.error)
        if a.error == nil { XCTAssertEqual(a.bytes, b.bytes) }
        else { XCTAssertTrue(a.bytes.starts(with: b.bytes) || b.bytes.starts(with: a.bytes)) }
    }
    private enum Outcome: Equatable {
        case failure(String)
        case success(ArchiveFormat, UInt?, [ArchiveEntry], Data)
    }
    private func serialBzip2Reference(_ bytes: Data, hint: URL, options: ReaderOptions) -> Outcome {
        do {
            let single = try SingleFileReader(source: DataByteSource(bytes), format: .bzip2, options: options, fallbackFileName: hint.lastPathComponent)
            let image = try SingleFileMaterializer.materialize(single.stream(for: single.entries[0], limits: options.limits), limits: options.limits)
            let reader = try TarReader(source: image, options: options)
            var total: UInt64 = 0
            for entry in reader.entries {
                let next = total.addingReportingOverflow(entry.uncompressedSize ?? 0)
                guard !next.overflow, next.partialValue <= options.limits.maxTotalUncompressedSize else {
                    throw KaitoError.limitExceeded("total uncompressed size")
                }
                total = next.partialValue
            }
            let contents = reader.entries.map { entry in
                TarGoldenCorpus.outcome { try reader.stream(for: entry, limits: options.limits).readAll() }
            }
            return .success(.tar, reader.nameEncoding?.rawValue, reader.entries, try TarGoldenCorpus.json(contents))
        } catch { return .failure(String(describing: error)) }
    }
    private func outcome(_ open: () throws -> ArchiveReader) -> Outcome {
        do {
            let reader = try open()
            let contents = reader.entries.map { entry in TarGoldenCorpus.outcome { try reader.read(entry) } }
            return .success(reader.format, reader.nameEncoding?.rawValue, reader.entries, try TarGoldenCorpus.json(contents))
        } catch { return .failure(String(describing: error)) }
    }
}
