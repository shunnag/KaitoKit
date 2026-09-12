// Clean-room format inputs: 指定レポート Ch.04 の method 1 に基づく。
// XADMaster / The Unarchiver / stuffit-go 等の実装ソースは参照していない。
import Foundation

final class StuffItRLE90: Decompressor {
    private let input: StuffItPackedInput
    private var remaining: UInt64
    private var remembered: UInt8 = 0
    private var pending = 0
    var isFinished: Bool { remaining == 0 }
    init(input: StuffItPackedInput, size: UInt64) { self.input = input; remaining = size }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining))
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        var written = 0
        while written < count {
            if pending == 0 {
                let byte = try input.byte()
                if byte == 0x90 {
                    let run = try input.byte()
                    guard run != 1 else { throw KaitoError.malformed("StuffIt RLE90 count 1") }
                    if run == 0 { remembered = 0x90; pending = 1 } else { pending = Int(run) - 1 }
                } else { remembered = byte; pending = 1 }
                guard UInt64(pending) <= remaining else { throw KaitoError.malformed("StuffIt RLE90 output length") }
            }
            let n = min(pending, count - written)
            destination.advanced(by: written).update(repeating: remembered, count: n)
            written += n; remaining -= UInt64(n); pending -= n
        }
        return written
    }
}
