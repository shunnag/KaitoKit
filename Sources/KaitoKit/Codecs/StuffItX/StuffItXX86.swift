// 指定資料 Ch.10 / Ch.38。候補には六バイトを要求し、未処理の末尾はそのまま出力する。
import Foundation

final class StuffItXX86: Decompressor {
    private let input: StuffItXDecodedInput
    private var remaining: UInt64
    private var position: UInt64 = 0
    private var lastCandidate: UInt64?
    private var mask: UInt32 = 0
    private var operand: UInt32 = 0
    private var operandBytes = 0
    private var correctionWork: UInt64 = 0
    private let correctionLimit: UInt64
    private(set) var isFinished = false

    init(decoder: any Decompressor, size: UInt64) {
        input = StuffItXDecodedInput(decoder); remaining = size
        // Ch.38 の実装 profile と同じ作業上限。上限の計算自体も飽和させる。
        correctionLimit = size > (UInt64.max - 16) / 2 ? UInt64.max : size * 2 + 16
    }
    private func restore(_ address: UInt32) throws -> UInt32 {
        let delta = lastCandidate.map { position - $0 } ?? 6
        lastCandidate = position
        if delta > 5 { mask = 0 }
        else { for _ in 0..<delta { mask = (mask & 0x77) << 1 } }
        let high = address >> 24
        if high != 0 && high != 255 { mask |= 1; return address }
        let t = mask >> 1
        guard t <= 15, (0x17 >> (t & 7)) & 1 != 0 else { mask |= 0x11; return address }
        // 正距離の更新と accept 表から到達できる非ゼロ mask は 2 / 4 / 8 だけ。
        guard mask == 0 || mask == 2 || mask == 4 || mask == 8 else { throw KaitoError.malformed("StuffIt X x86 history") }
        let shift = mask == 2 ? 16 : (mask == 4 ? 8 : 0)
        var a = address, r: UInt32
        repeat {
            guard correctionWork < correctionLimit else { throw KaitoError.limitExceeded("StuffIt X x86 correction work") }
            correctionWork += 1
            r = a &- UInt32(truncatingIfNeeded: position) &- 6
            if mask == 0 { break }
            let byte = (r >> shift) & 255
            if byte != 0 && byte != 255 { break }
            a = r ^ ((UInt32(1) << (shift + 8)) - 1)
        } while true
        mask = 0; operandBytes = 4
        return (r & 0x00ff_ffff) | (r & 0x0100_0000 == 0 ? 0 : 0xff00_0000)
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        if remaining == 0 {
            guard operandBytes == 0, try input.byte() == nil else { throw KaitoError.malformed("StuffIt X x86 excess output") }
            isFinished = true; return 0
        }
        let n = Int(min(UInt64(buffer.count), remaining)), output = buffer.bindMemory(to: UInt8.self)
        for i in 0..<n {
            let byte: UInt8
            if operandBytes > 0 { byte = UInt8(truncatingIfNeeded: operand); operand >>= 8; operandBytes -= 1 }
            else {
                guard let opcode = try input.peek() else { throw KaitoError.truncated }
                if (opcode == 0xe8 || opcode == 0xe9), try input.peek(5) != nil {
                    var address: UInt32 = 0
                    for j in 0..<4 { address |= UInt32(try input.peek(j + 1)!) << (j * 8) }
                    operand = try restore(address)
                }
                _ = try input.byte(); byte = opcode
                if operandBytes > 0 { for _ in 0..<4 { _ = try input.byte() } }
            }
            output[i] = byte; position += 1; remaining -= 1
        }
        return n
    }
}
