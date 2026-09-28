import Foundation
@_spi(ZipRawLayout) @testable import KaitoKit
import XCTest

final class ZipRawLayoutDifferentialFuzzTests: XCTestCase {
    func testFiveSeedsWithThreeHundredMutationsEach() throws {
        let inputs = try ZipGoldenCorpus.inputs()
        let names = ["descriptor-true-3", "sfx-true", "aes128-ae2", "shuffled"]
        let small = try ZipTestSupport.makeArchive(entries: (0..<12).map {
            HandZipEntry(name: "d/f\($0)", uncompressedData: Data([0x78]))
        })
        let seeds = try [small] + names.map { name in
            try ZipGoldenCorpus.decoded(XCTUnwrap(inputs.first { $0.id == name }).files[0])
        }
        let start = ContinuousClock.now
        for (seedIndex, seed) in seeds.enumerated() {
            var random = ZipDeterministicRandom(state: 0x50314b_f022 &+ UInt64(seedIndex))
            for iteration in 0..<300 {
                let bytes = random.mutate(seed, operation: iteration % 4)
                for reverse in [false, true] {
                    let left = ZipDifferentialSnapshot(bytes, reverse: reverse, spiFirst: false)
                    let right = ZipDifferentialSnapshot(bytes, reverse: reverse, spiFirst: true)
                    XCTAssertEqual(left, right, "seed=\(seedIndex) iteration=\(iteration) reverse=\(reverse)")
                }
            }
        }
        let duration = start.duration(to: .now)
        XCTAssertLessThan(duration, .seconds(60))
        print("ZIP-DIFFERENTIAL seeds=0x50314bf022...0x50314bf026 mutations=1500 seconds=\(duration)")
    }
}

enum ZipTestOutcome<Value: Equatable>: Equatable {
    case success(Value)
    case failure(String)
    init(_ body: () throws -> Value) {
        do { self = .success(try body()) } catch { self = .failure(String(describing: error)) }
    }
}

struct ZipRawSnapshot: Equatable {
    let record: Range<UInt64>
    let payload: Range<UInt64>
    let specific: [String: String]
    init(_ raw: RawEntryRecord) { record = raw.recordRange; payload = raw.payloadRange; specific = raw.formatSpecific }
}

struct ZipDifferentialSnapshot: Equatable {
    var openError: String?
    var entries: [ArchiveEntry] = []
    var encoding: String.Encoding?
    var raw: [ZipTestOutcome<ZipRawSnapshot?>] = []
    var spi: [ZipTestOutcome<ZipRawRecordLayout?>] = []
    var stream: [ZipTestOutcome<Data>] = []
    init(_ bytes: Data, reverse: Bool, spiFirst: Bool) {
        let limits = ReadLimits(maxEntrySize: 1 << 20, maxInMemorySize: 1 << 20,
                                maxEntryCount: 4096, maxTotalMetadataSize: 4 << 20, maxDictionarySize: 1 << 20)
        let options = ReaderOptions(limits: limits, password: "raw-password", scanForSFXInData: true, appleDoublePolicy: .expose)
        self.init(source: DataByteSource(bytes), options: options,
                  policy: spiFirst ? .standard : .disabled, reverse: reverse, spiFirst: spiFirst)
    }
    init(source: any ByteSource, options: ReaderOptions, policy: ZipLocalReadAheadPolicy,
         diskLayout: ZipDiskLayout? = nil, reverse: Bool = false, spiFirst: Bool = false) {
        let limits = options.limits
        do {
            let reader = try AppleDoubleReader.wrap(ZipReader(source: source, options: options,
                                       diskLayout: diskLayout, readAhead: policy), options: options)
            entries = reader.entries
            encoding = reader.nameEncoding
            let indices = reverse ? Array(entries.indices.reversed()) : Array(entries.indices)
            for index in indices {
                if spiFirst { spi.append(ZipTestOutcome { try reader.zipRawRecordLayout(at: index, limits: limits) }) }
                raw.append(ZipTestOutcome { try reader.rawRecord(for: entries[index], limits: limits).map(ZipRawSnapshot.init) })
                if !spiFirst { spi.append(ZipTestOutcome { try reader.zipRawRecordLayout(at: index, limits: limits) }) }
                stream.append(ZipTestOutcome { try reader.stream(for: entries[index], limits: limits).readAll() })
            }
        } catch { openError = String(describing: error) }
    }
}
