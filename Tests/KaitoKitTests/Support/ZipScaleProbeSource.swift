import Foundation
import KaitoKit
import Synchronization
import XCTest

/// 大きな ZIP の計測用に、読み出しの回数と範囲を数える ByteSource。
final class ZipScaleProbeSource: ByteSource {
    struct Counts { var calls = 0; var bytes: UInt64 = 0; var localCalls = 0; var localBytes: UInt64 = 0 }
    private let source: FileByteSource
    private let state = Mutex(Counts())
    let localRange: Range<UInt64>
    var length: UInt64 { source.length }
    var counts: Counts { state.withLock { $0 } }
    init(_ url: URL) throws {
        let source = try FileByteSource(url: url)
        self.source = source
        // corpus の EOCD / ZIP64 EOCD だけから CD の開始位置を得る。
        let tailStart = source.length - min(source.length, 65557)
        var tail = [UInt8](repeating: 0, count: Int(source.length - tailStart))
        let count = try tail.withUnsafeMutableBytes { try source.read(into: $0, at: tailStart) }
        guard count == tail.count else { throw KaitoError.truncated }
        func little(_ bytes: [UInt8], _ offset: Int, _ size: Int) -> UInt64 {
            (0..<size).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        let end = try XCTUnwrap((0...(tail.count - 22)).reversed().first { little(tail, $0, 4) == 0x06054b50 })
        var cd = little(tail, end + 16, 4)
        if end >= 20, little(tail, end - 20, 4) == 0x07064b50 {
            let offset = little(tail, end - 12, 8)
            var wide = [UInt8](repeating: 0, count: 56)
            _ = try wide.withUnsafeMutableBytes { try source.read(into: $0, at: offset) }
            cd = little(wide, 48, 8)
        }
        localRange = 0..<cd
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try source.read(into: buffer, at: offset)
        state.withLock {
            $0.calls += 1; $0.bytes += UInt64(count)
            if offset >= localRange.lowerBound, offset + UInt64(count) <= localRange.upperBound {
                $0.localCalls += 1; $0.localBytes += UInt64(count)
            }
        }
        return count
    }
    func reset() { state.withLock { $0 = Counts() } }
    static func corpus() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KAITOKIT_ZIP_SCALE_PROBE"] else { throw XCTSkip("set KAITOKIT_ZIP_SCALE_PROBE to a 500k ZIP") }
        return URL(fileURLWithPath: path)
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func report(_ metric: String, times: [Double], counts: [Counts]) {
        print("KAITOKIT-PROBE\t\(metric)_ms\t\(times.sorted()[times.count / 2])")
        let count = counts[counts.count / 2]
        print("KAITOKIT-PROBE\t\(metric)_reads\t\(count.calls)")
        print("KAITOKIT-PROBE\t\(metric)_bytes\t\(count.bytes)")
        print("KAITOKIT-PROBE\t\(metric)_local_reads\t\(count.localCalls)")
        print("KAITOKIT-PROBE\t\(metric)_local_bytes\t\(count.localBytes)")
        print("KAITOKIT-PROBE\t\(metric)_samples_ms\t\(times.map(String.init(describing:)).joined(separator: ","))")
    }
}
