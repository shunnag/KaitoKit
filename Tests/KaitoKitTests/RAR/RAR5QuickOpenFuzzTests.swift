import Foundation
import XCTest
@testable import KaitoKit

final class RAR5QuickOpenFuzzTests: XCTestCase {
    typealias Q = RAR5QuickOpenTestSupport
    func testDeterministicQuickOpenMutantsNeverCrashHangOrServeUnverifiedBytes() throws {
        try RAR5TestSupport.requireRAR()
        let start = Date()
        var random: UInt64 = 0x514f_2026_1022
        func next(_ upper: Int) -> Int {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            return Int(random % UInt64(upper))
        }
        for solid in [false, true] {
            let directory = try TarTestSupport.temporaryDirectory()
            let names = (0..<40).map { String(format: "file-%03d", $0) }
            for (index, name) in names.enumerated() {
                let payload = Data(repeating: UInt8(index + 65), count: 2048)
                try payload.write(to: directory.appendingPathComponent(name))
            }
            let url = directory.appendingPathComponent("archive.rar")
            try RAR5TestSupport.makeGeneratedArchive(sourceDirectory: directory, paths: names, archiveURL: url,
                options: ["-qo+", "-m3", "-md128k", solid ? "-s" : "-s-"])
            let original = try Q.decode(Data(contentsOf: url))
            for seed in 0..<512 {
                let caseStart = Date()
                var f = original
                let index = next(f.records.count)
                switch seed % 8 {
                case 0:
                    var locator = [UInt8(1)] + RAR5TestSupport.vint(f.qoOffset - 8)
                    locator[next(locator.count)] ^= UInt8(1 << next(8))
                    f.locatorBytes = locator
                case 1, 2, 3:
                    var bytes = f.records.flatMap { $0.encode() }
                    let at = next(bytes.count)
                    if seed % 8 == 1 { bytes[at] ^= UInt8(1 << next(8)) }
                    if seed % 8 == 2 { bytes.insert(UInt8(next(256)), at: at) }
                    if seed % 8 == 3 { bytes.remove(at: at) }
                    f.dataOverride = bytes
                case 4:
                    let at = next(f.records[index].header.count)
                    f.records[index].header[at] ^= UInt8(1 << next(8))
                    // 半数で内側 CRC を修復し、他の半数は record CRC だけを修復する。
                    if seed & 8 == 0 { Q.repairCRC(&f.records[index].header) }
                case 5:
                    let at = next(f.records[index].header.count)
                    if seed & 8 == 0 { f.records[index].header.insert(UInt8(next(256)), at: at) }
                    else { f.records[index].header.remove(at: at) }
                    if seed & 16 == 0 { Q.repairCRC(&f.records[index].header) }
                case 6:
                    let fields = try Q.fields(f.records[index].header)
                    let at = seed & 8 == 0 ? fields.name.lowerBound : try XCTUnwrap(fields.crc)
                    f.records[index].header[at] ^= 1
                    Q.repairCRC(&f.records[index].header)
                default:
                    f.records[index].distance = UInt64(next(Int(f.qoOffset + 10)))
                    if seed & 8 == 0 { f.records[index].corruptCRC = true }
                }
                let data = f.data()
                let full = try? Q.reader(data, policy: .never)
                let quick: RAR5Reader
                do { quick = try Q.reader(data) }
                catch {
                    if full != nil { XCTFail("plain walk succeeds but Quick Open throws: \(error), seed \(seed)") }
                    continue
                }
                var reference: [UInt64: Data] = [:]
                if let full {
                    for entry in full.entries {
                        reference[full.headerOffsetForTesting(entry: entry)] = try full.stream(for: entry, limits: ReadLimits()).readAll()
                    }
                }
                var threw = false
                var allMatched = true
                for entry in quick.entries {
                    do {
                        let guards = quick.recordsForTesting[entry.index].headerGuards.compactMap { $0 }
                        let lies = try guards.contains { guardValue in
                            try readByteRange(source: guardValue.volumeSource, offset: guardValue.headerOffset,
                                count: guardValue.expected.count) != guardValue.expected
                        }
                        let stream = try quick.stream(for: entry, limits: ReadLimits())
                        XCTAssertFalse(lies, "未照合の stream を公開: solid \(solid), seed \(seed)")
                        let bytes = try stream.readAll()
                        let expected = reference[quick.headerOffsetForTesting(entry: entry)]
                        XCTAssertEqual(bytes, expected, "solid \(solid), seed \(seed), entry \(entry.index)")
                        allMatched = allMatched && bytes == expected
                    } catch {
                        threw = true
                        if case KaitoError.malformed(let message) = error, message.contains("quick-open header") {
                            XCTAssertTrue(message.hasPrefix(Q.mismatchPrefix), message)
                        }
                    }
                }
                if full?.entries != quick.entries { XCTAssertTrue(threw || allMatched, "seed \(seed)") }
                XCTAssertLessThan(Date().timeIntervalSince(caseStart), 3, "hang guard, seed \(seed)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }
}
