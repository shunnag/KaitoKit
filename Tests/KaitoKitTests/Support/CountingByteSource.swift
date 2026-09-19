import Foundation
import KaitoKit
import Synchronization

final class CountingByteSource: ByteSource {
    private let source: any ByteSource
    private let count = Mutex<UInt64>(0)

    init(_ source: any ByteSource) { self.source = source }
    var length: UInt64 { source.length }
    var bytesRead: UInt64 { count.withLock { $0 } }
    func reset() { count.withLock { $0 = 0 } }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let actual = try source.read(into: buffer, at: offset)
        count.withLock { $0 += UInt64(actual) }
        return actual
    }
}
