import Foundation

// 一つの同期走査だけが所有する。復号 worker には渡さず、走査中の pread だけを計時する。
final class LZMA2TimedScanSource: ByteSource, @unchecked Sendable {
    struct TooSlow: Error {}

    private let source: any ByteSource
    private let clock: @Sendable () -> UInt64
    private var samples = [UInt64](repeating: 0, count: 16)
    private var stallSamples = [UInt64](repeating: 0, count: 256)
    private var rawSamples = [UInt64](repeating: 0, count: 256)
    private var count = 0
    private var total: UInt64 = 0
    private var stallTotal: UInt64 = 0
    private var rawTotal: UInt64 = 0
    var length: UInt64 { source.length }

    init(source: any ByteSource, clock: @escaping @Sendable () -> UInt64) {
        self.source = source
        self.clock = clock
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let start = clock()
        let actual = try source.read(into: buffer, at: offset)
        let elapsed = clock() &- start
        // 各窓の標本をそれぞれの予算 + 1 ns に抑え、極端な遅延でも合計の桁あふれを防ぐ。
        let shortBudget: UInt64 = 14 * 500_000
        let sample = min(elapsed, shortBudget + 1)
        let slot = count % samples.count
        total -= samples[slot]
        samples[slot] = sample
        total += sample
        var largest: UInt64 = 0, secondLargest: UInt64 = 0
        for sample in samples {
            if sample >= largest { secondLargest = largest; largest = sample }
            else if sample > secondLargest { secondLargest = sample }
        }

        // 256 回窓で 16 回ごとに 9 ms なら超過分 80 ms を許容し、
        // 30 回ごとに 17 ms なら超過分 104 ms で打ち切るため、予算を 96 ms にする。
        let stallBudget: UInt64 = 96_000_000
        let stall = min(elapsed > 4_000_000 ? elapsed - 4_000_000 : 0, stallBudget + 1)
        let stallSlot = count % stallSamples.count
        stallTotal -= stallSamples[stallSlot]
        stallSamples[stallSlot] = stall
        stallTotal += stall

        let rawBudget: UInt64 = 256 * 500_000
        let rawSample = min(elapsed, rawBudget + 1)
        let rawSlot = count % rawSamples.count
        rawTotal -= rawSamples[rawSlot]
        rawSamples[rawSlot] = rawSample
        rawTotal += rawSample
        count += 1
        // 最長の 2 回を除く 16 回窓は、孤立した停止を許容しつつ密な低速読み取りを拾う。
        // 4 ms 超過分の 256 回窓は、疎だが大きな停止を拾う。
        // 生時間の 256 回窓は、疎で中程度の遅延による平均超過を拾う。三つとも走査の最後まで動かす。
        if total - largest - secondLargest > shortBudget || stallTotal > stallBudget
            || rawTotal > rawBudget {
            throw TooSlow()
        }
        return actual
    }
}
