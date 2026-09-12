// 指定資料 Ch.10。辞書 token と case 状態は要素全体で連続し、fork の境界を参照しない。
import Foundation

final class StuffItXDecodedInput {
    private let decoder: any Decompressor
    private let bytes: UnsafeMutablePointer<UInt8>
    private var cursor = 0
    private var available = 0
    private var ended = false
    init(_ decoder: any Decompressor) { self.decoder = decoder; bytes = .allocate(capacity: 16_384) }
    deinit { bytes.deallocate() }
    @inline(__always) func peek(_ lookahead: Int = 0) throws -> UInt8? {
        while available - cursor <= lookahead {
            if ended { return nil }
            let left = available - cursor
            if left > 0 { for i in 0..<left { bytes[i] = bytes[cursor + i] } }
            available = left; cursor = 0
            let n = try decoder.read(into: UnsafeMutableRawBufferPointer(start: bytes + left, count: 16_384 - left))
            guard n >= 0, n <= 16_384 - left else { throw KaitoError.malformed("StuffIt X preprocessor input count") }
            if n == 0 {
                guard decoder.isFinished else { throw KaitoError.truncated }
                ended = true
            }
            available += n
        }
        return bytes[cursor + lookahead]
    }
    @inline(__always) func byte() throws -> UInt8? {
        guard let b = try peek() else { return nil }; cursor += 1; return b
    }
}

final class StuffItXEnglish: Decompressor {
    private let input: StuffItXDecodedInput
    private let words: [Substring]
    private let markers: (UInt8, UInt8, UInt8, UInt8)
    private let pending: UnsafeMutablePointer<UInt8>
    private var pendingCount = 0
    private var pendingIndex = 0
    private var toggle = true
    private var remaining: UInt64
    private(set) var isFinished = false

    init(decoder: any Decompressor, size: UInt64) throws {
        input = StuffItXDecodedInput(decoder); remaining = size
        guard let a = try input.byte(), let b = try input.byte(), let c = try input.byte(), let d = try input.byte() else { throw KaitoError.truncated }
        markers = (a, b, c, d); words = try StuffItXEnglishDictionary.words.get()
        pending = .allocate(capacity: 26)
    }
    deinit { pending.deallocate() }
    @inline(__always) private func letter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
    @inline(__always) private func punctuation(_ b: UInt8) -> Bool { b == 46 || b == 63 || b == 33 }
    private func token(_ b: UInt8) throws {
        pendingIndex = 0; pendingCount = 0
        if b == markers.0 {
            guard let literal = try input.byte() else { throw KaitoError.truncated }
            pending[0] = literal; pendingCount = 1; toggle = false
        } else if b == markers.1 || b == markers.2 || b == markers.3 {
            var index = 0, terminator: UInt8?
            while let digit = try input.byte() {
                if !letter(digit) { terminator = digit; break }
                let value = digit >= 97 ? Int(digit - 96) : Int(digit - 38)
                // 直前の index が語数未満なので、乗算も Int の範囲内に収まる。
                index = index * 52 + value
                guard index < words.count else { throw KaitoError.malformed("StuffIt X English dictionary index") }
            }
            for byte in words[index].utf8 {
                var value = byte
                if b == markers.3 || (b == markers.2 && pendingCount == 0) { value -= 32 }
                if toggle && pendingCount == 0 { value ^= 32 }
                pending[pendingCount] = value; pendingCount += 1
            }
            if terminator == markers.0 {
                guard let escaped = try input.byte() else { throw KaitoError.truncated }; terminator = escaped
            }
            if let terminator { pending[pendingCount] = terminator; pendingCount += 1 }
            toggle = terminator.map(punctuation) ?? false
        } else {
            var value = b
            if toggle, letter(b) { value ^= 32; toggle = false }
            if punctuation(b) { toggle = true }
            else if b != 32 && b != 10 && b != 13 && b != 9 { toggle = false }
            pending[0] = value; pendingCount = 1
        }
        guard UInt64(pendingCount) <= remaining else { throw KaitoError.malformed("StuffIt X English excess output") }
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if isFinished || buffer.isEmpty { return 0 }
        let output = buffer.bindMemory(to: UInt8.self)
        var written = 0
        while written < output.count {
            if pendingIndex == pendingCount {
                guard let b = try input.byte() else {
                    guard remaining == 0 else { throw KaitoError.truncated }; isFinished = true; break
                }
                try token(b)
            }
            let n = min(output.count - written, pendingCount - pendingIndex)
            output.baseAddress!.advanced(by: written).update(from: pending + pendingIndex, count: n)
            pendingIndex += n; written += n; remaining -= UInt64(n)
        }
        return written
    }
}
