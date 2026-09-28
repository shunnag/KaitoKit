// StuffIt X JPEG 復元の共通部品: エラーの生成、JPEG marker の定数、寿命を所有する固定長領域 JPEGStorage、
// 復元した JPEG を行・scan ごとに渡す出力 buffer JPEGOutput。
// JPEG/ の移植元 stuffitx_jpeg*.py は利用者の独立 Python 実装（inbox/stuffit/tools/、repo 外）で、
// 関数と Swift の対応は Documentation/verification/2026-09-13-stuffit-slice7.md に記録する。
import Foundation

@inline(__always) func jpegMalformed(_ reason: String) -> KaitoError {
    .malformed("StuffIt X JPEG \(reason)")
}

@inline(__always) func jpegUnsupported(_ reason: String) -> KaitoError {
    .unsupportedMethod("StuffIt X JPEG \(reason)")
}

/// JPEG（ITU-T T.81 表 B.1）の marker。`prefix` 以外は 0xFF に続く第二 byte の値。
enum JPEGMarker {
    static let prefix = 0xFF
    /// 第二 byte としての 0xFF（fill byte）。
    static let fill = 0xFF
    /// FF 00 は entropy 符号内の 0xFF の escape で、marker ではない。
    static let stuffedZero = 0x00
    static let tem = 0x01
    static let sof0 = 0xC0  // baseline DCT
    static let sof2 = 0xC2  // progressive DCT
    static let dht = 0xC4
    static let jpg = 0xC8
    static let dac = 0xCC
    /// SOF0–SOF15 の範囲。DHT・JPG・DAC もこの範囲に含まれるので、SOF の判定では除く。
    static let sofRange = 0xC0...0xCF
    static let rst = 0xD0...0xD7
    static let soi = 0xD8
    static let eoi = 0xD9
    static let sos = 0xDA
    static let dqt = 0xDB
    static let dri = 0xDD
}

// 固定長領域の寿命を所有する。ホットループでは p を直接参照する。
final class JPEGStorage<T> {
    let p: UnsafeMutablePointer<T>
    let count: Int
    init(_ count: Int, _ value: T) {
        self.count = count; p = .allocate(capacity: max(1, count))
        p.initialize(repeating: value, count: count)
    }
    deinit { p.deinitialize(count: count); p.deallocate() }
}

// read(into:) が消費した行／scan は直ちに再利用する。全画像バイト列は保持しない。
final class JPEGOutput {
    private var storage: UnsafeMutablePointer<UInt8>
    private var capacity = 4096
    var count = 0
    var cursor = 0
    var produced: UInt64 = 0
    let limit: UInt64
    init(limit: UInt64) { self.limit = limit; storage = .allocate(capacity: capacity) }
    deinit { storage.deallocate() }
    @inline(__always) func append(_ byte: Int) throws {
        guard produced < limit else { throw KaitoError.limitExceeded("StuffIt X JPEG output") }
        if count == capacity { grow() }
        storage[count] = UInt8(truncatingIfNeeded: byte); count += 1; produced += 1
    }
    private func grow() {
        let next = capacity * 2, replacement = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        replacement.initialize(from: storage, count: count); storage.deallocate(); storage = replacement; capacity = next
    }
    func append(_ bytes: [UInt8]) throws { for byte in bytes { try append(Int(byte)) } }
    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        let n = min(buffer.count, count - cursor)
        if n > 0 { buffer.baseAddress!.copyMemory(from: storage.advanced(by: cursor), byteCount: n); cursor += n }
        if cursor == count { count = 0; cursor = 0 }
        return n
    }
    /// テスト専用: 最後に全量を読み出した後に蓄積した出力の複製。本番経路では呼ばれない。
    /// private な storage を読むので、テスト target の extension へは移せない。
    var bytes: [UInt8] { Array(UnsafeBufferPointer(start: storage, count: count)) }
}
