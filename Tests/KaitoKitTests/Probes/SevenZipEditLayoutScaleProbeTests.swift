import Darwin
import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit
import XCTest

/// 凍結した 10 万 entry 以上の 7z（KAITOKIT_7Z_SCALE_DIR の g_k100.7z / z_k100.7z）を、SevenZipEditLayout の記録あり・なしを
/// 交互に 5 回ずつ毎回別 process で開かせ、open 時間の中央値の比（1.10 以下）と RSS の増分（1 entry 128 byte 以下）を `7Z-LAYOUT` 行で出す。
/// release でだけ測る（debug build では skip）。
final class SevenZipEditLayoutScaleProbeTests: XCTestCase {
    private struct Sample: Codable {
        let milliseconds: Double
        let residentBytes: UInt64
        let peakBytes: UInt64
        let entries: Int
    }

    func testOpenTimeAndResidentMemory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["KAITOKIT_7Z_SCALE_DIR"] else {
            throw XCTSkip("set KAITOKIT_7Z_SCALE_DIR to the frozen scale corpus; run in release")
        }
        #if DEBUG
        throw XCTSkip("run SevenZipEditLayoutScaleProbeTests with -c release")
        #else
        if let name = environment["KAITOKIT_7Z_SCALE_CHILD"] {
            var options = ReaderOptions()
            options.recordsSevenZipEditLayout = environment["KAITOKIT_7Z_SCALE_RECORDING"] == "1"
            let start = DispatchTime.now().uptimeNanoseconds
            let reader = try ArchiveReader.open(url: URL(fileURLWithPath: directory).appendingPathComponent(name), options: options)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let resident = try residentBytes()
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            let sample = Sample(milliseconds: milliseconds, residentBytes: resident,
                                peakBytes: UInt64(usage.ru_maxrss), entries: reader.entries.count)
            print("7Z-LAYOUT-SAMPLE " + String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
            withExtendedLifetime(reader) {}
            return
        }
        for name in ["g_k100.7z", "z_k100.7z"] {
            var off: [Sample] = [], on: [Sample] = []
            for repetition in 0..<5 {
                // 各回を新しい process で測り、allocator の残存や過去の RSS peak を混ぜない。
                for recording in repetition.isMultiple(of: 2) ? [false, true] : [true, false] {
                    let sample = try child(name: name, recording: recording)
                    if recording { on.append(sample) } else { off.append(sample) }
                }
            }
            let offMS = off.map(\.milliseconds).sorted()[2], onMS = on.map(\.milliseconds).sorted()[2]
            let offRSS = off.map(\.residentBytes).sorted()[2], onRSS = on.map(\.residentBytes).sorted()[2]
            let increment = Int64(onRSS) - Int64(offRSS)
            let count = try XCTUnwrap(on.first?.entries)
            XCTAssertGreaterThanOrEqual(count, 100_000)
            XCTAssertEqual(Set((on + off).map(\.entries)), [count])
            print("7Z-LAYOUT \(name) runs=5 entries=\(count) off_ms=\(offMS) on_ms=\(onMS) ratio=\(onMS / offMS) off_rss=\(offRSS) on_rss=\(onRSS) delta=\(increment) bytes_per_entry=\(Double(increment) / Double(count))")
            for (mode, values) in [("off", off), ("on", on)] {
                print("7Z-LAYOUT \(name) \(mode) samples=" + String(decoding: try JSONEncoder().encode(values), as: UTF8.self))
            }
            XCTAssertLessThanOrEqual(onMS / offMS, 1.10, name)
            XCTAssertLessThanOrEqual(increment, Int64(count * 128), name)
        }
        #endif
    }

    private func child(name: String, recording: Bool) throws -> Sample {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest",
            "KaitoKitTests.SevenZipEditLayoutScaleProbeTests/testOpenTimeAndResidentMemory",
            Bundle(for: SevenZipEditLayoutScaleProbeTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KAITOKIT_7Z_SCALE_CHILD"] = name
        environment["KAITOKIT_7Z_SCALE_RECORDING"] = recording ? "1" : "0"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        let prefix = "7Z-LAYOUT-SAMPLE "
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix(prefix) }, text)
        return try JSONDecoder().decode(Sample.self, from: Data(line.dropFirst(prefix.count).utf8))
    }

    private func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return UInt64(info.resident_size)
    }
}
