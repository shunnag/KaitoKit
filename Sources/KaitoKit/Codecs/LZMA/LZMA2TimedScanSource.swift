import Foundation

// 一つの同期走査だけが所有する。復号 worker には渡さず、走査中の pread だけを計時する。
final class LZMA2TimedScanSource: ByteSource, @unchecked Sendable {
    struct TooSlow: Error {}

    private let source: any ByteSource
    private let clock: @Sendable () -> UInt64
    private var samples = [UInt64](repeating: 0, count: 256)
    private var count = 0
    private var total: UInt64 = 0
    var length: UInt64 { source.length }

    init(source: any ByteSource, clock: @escaping @Sendable () -> UInt64) {
        self.source = source
        self.clock = clock
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let start = clock()
        let actual = try source.read(into: buffer, at: offset)
        // 極端な遅延も合計の桁あふれを起こさず、必ず予算超過と判定する。
        let elapsed = min(clock() &- start, 256 * 500_000 + 1)
        let slot = count % samples.count
        total -= samples[slot]
        samples[slot] = elapsed
        total += elapsed
        count += 1
        if (count == 16 && total > 16 * 500_000)
            || total > 256 * 500_000 {
            throw TooSlow()
        }
        return actual
    }
}
