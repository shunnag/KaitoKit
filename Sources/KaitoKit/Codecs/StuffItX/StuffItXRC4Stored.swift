// 指定資料 Ch.07 §7。slice 2 の標準 RC4 を共有する。
import Foundation

final class StuffItXRC4Stored: Decompressor {
    private let input: StuffItXBitReader
    private let rc4: StuffItRC4
    private var remaining: UInt64
    init(input: StuffItXBitReader, size: UInt64) throws {
        self.input = input; remaining = size
        _ = try input.byte(); _ = try input.byte(); rc4 = try StuffItRC4(key: [input.byte()])
        guard input.source.length - input.offset == size else { throw KaitoError.malformed("StuffIt X RC4-stored length") }
    }
    var isFinished: Bool { remaining == 0 }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Int(min(UInt64(buffer.count), remaining)), bytes = buffer.bindMemory(to: UInt8.self)
        for i in 0..<count { bytes[i] = rc4.transform(try input.byte()) }
        remaining -= UInt64(count); return count
    }
}
