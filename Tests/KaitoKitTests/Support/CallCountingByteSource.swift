import Foundation
@testable import KaitoKit

final class CallCountingByteSource: ByteSource, VolumeLocalityHinting, @unchecked Sendable {
    private let base: any ByteSource
    private let lock = NSLock()
    let isOnNonLocalVolume: Bool
    private var calls = 0
    private var bytes = 0
    private var ranges: [Range<UInt64>] = []
    var length: UInt64 { base.length }
    var readCount: Int { lock.withLock { calls } }
    var readBytes: Int { lock.withLock { bytes } }
    var readRanges: [Range<UInt64>] { lock.withLock { ranges } }
    init(_ base: any ByteSource, reportsNonLocalVolume: Bool = false) {
        self.base = base
        self.isOnNonLocalVolume = reportsNonLocalVolume
    }
    func reset() { lock.withLock { calls = 0; bytes = 0; ranges = [] } }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        lock.withLock { calls += 1 }
        let count = try base.read(into: buffer, at: offset)
        lock.withLock { bytes += count; ranges.append(offset..<offset + UInt64(count)) }
        return count
    }
}
