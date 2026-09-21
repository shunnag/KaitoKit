import Foundation

// 参照資料: Apple の flat package（pkgbuild --compression latest）と OTA が使う pbzx container を、
// macOS 27.2 の `pkgbuild` / `xar` の出力から黒箱で計測したもの（2026-09-20、
// Documentation/verification/2026-09-20-pbzx.md）。Apple の文書も第三者実装の source も参照していない。
//
//   0      4  "pbzx"
//   4      8  BE64: chunk の展開後サイズの上限（pkgbuild は 0x01000000 = 16 MiB）
//   12     -  chunk の列。各 chunk は
//              BE64 展開後サイズ U、BE64 格納長 L、L byte の本文。
//              本文が XZ 署名で始まれば XZ stream（展開後 U byte）、そうでなければ L == U の生 byte。
//   最後の chunk は U が上限より小さくてよい。chunk の間や末尾に padding は無い。
struct PbzxHeader: Equatable {
    static let magic: [UInt8] = [0x70, 0x62, 0x7A, 0x78]
    static let size = 12
    /// 各 chunk の展開後サイズの上限。
    let chunkSize: UInt64

    init(prefix: [UInt8], limits: ReadLimits) throws {
        guard prefix.count >= Self.size else { throw KaitoError.truncated }
        guard Array(prefix[..<4]) == Self.magic else { throw KaitoError.unsupportedFormat }
        let chunkSize = PbzxDecompressor.bigEndian(prefix, at: 4)
        guard chunkSize > 0 else { throw KaitoError.malformed("pbzx chunk size is zero") }
        // chunk 全体を memory で扱うわけではないが、XZ の辞書と同じ上限で法外な宣言を拒否する。
        try Checked.size(chunkSize, limit: max(limits.maxDictionarySize, 16 * 1_024 * 1_024))
        self.chunkSize = chunkSize
    }
}

/// pbzx の chunk 列を一つの出力として復号する。chunk ごとに宣言サイズを検証する。
final class PbzxDecompressor: Decompressor {
    private let source: any ByteSource
    private let limits: ReadLimits
    private let header: PbzxHeader
    private var cursor: UInt64 = UInt64(PbzxHeader.size)
    private var current: (any Decompressor)?
    private var currentExpected: UInt64 = 0
    private var currentProduced: UInt64 = 0
    private var chunkCount: UInt64 = 0
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init(source: any ByteSource, limits: ReadLimits) throws {
        self.source = source
        self.limits = limits
        let count = try Checked.toInt(min(UInt64(PbzxHeader.size), source.length))
        header = try PbzxHeader(prefix: readByteRange(source: source, offset: 0, count: count), limits: limits)
    }

    /// chunk 表を歩いて展開後サイズの合計を求める（open 時の宣言サイズ）。
    static func contentSize(source: any ByteSource, limits: ReadLimits) throws -> UInt64 {
        let decoder = try PbzxDecompressor(source: source, limits: limits)
        var total: UInt64 = 0
        var cursor = UInt64(PbzxHeader.size)
        var chunks: UInt64 = 0
        while cursor < source.length {
            let (unpacked, stored) = try decoder.chunkHeader(at: cursor)
            total = try Checked.add(total, unpacked)
            try Checked.size(total, limit: limits.maxEntrySize)
            cursor = try Checked.add(Checked.add(cursor, 16), stored)
            chunks += 1
            guard chunks <= UInt64(limits.maxMetadataRecordCount) else {
                throw KaitoError.limitExceeded("pbzx chunk count")
            }
        }
        return total
    }

    private func chunkHeader(at offset: UInt64) throws -> (unpacked: UInt64, stored: UInt64) {
        guard try Checked.add(offset, 16) <= source.length else { throw KaitoError.truncated }
        let bytes = try readByteRange(source: source, offset: offset, count: 16)
        let unpacked = Self.bigEndian(bytes, at: 0)
        let stored = Self.bigEndian(bytes, at: 8)
        guard unpacked <= header.chunkSize else {
            throw KaitoError.malformed("pbzx chunk exceeds the declared chunk size")
        }
        guard try Checked.add(Checked.add(offset, 16), stored) <= source.length else {
            throw KaitoError.truncated
        }
        return (unpacked, stored)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while true {
                if let decoder = current {
                    let count = try decoder.read(into: buffer)
                    if count > 0 {
                        currentProduced += UInt64(count)
                        guard currentProduced <= currentExpected else {
                            throw KaitoError.malformed("pbzx chunk is longer than declared")
                        }
                        return count
                    }
                    guard decoder.isFinished, currentProduced == currentExpected else {
                        throw KaitoError.malformed("pbzx chunk is shorter than declared")
                    }
                    current = nil
                    continue
                }
                guard cursor < source.length else {
                    isFinished = true
                    return 0
                }
                chunkCount += 1
                guard chunkCount <= UInt64(limits.maxMetadataRecordCount) else {
                    throw KaitoError.limitExceeded("pbzx chunk count")
                }
                let (unpacked, stored) = try chunkHeader(at: cursor)
                let body = try Checked.add(cursor, 16)
                cursor = try Checked.add(body, stored)
                currentExpected = unpacked
                currentProduced = 0
                if unpacked == 0 {
                    guard stored == 0 else { throw KaitoError.malformed("pbzx empty chunk has a body") }
                    continue
                }
                let probe = try readByteRange(source: source, offset: body, count: Int(min(6, stored)))
                if probe == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] {
                    current = try XZDecompressor(source: source, offset: body, compressedSize: stored, limits: limits)
                } else {
                    guard stored == unpacked else {
                        throw KaitoError.malformed("pbzx raw chunk sizes differ")
                    }
                    current = try CopyDecompressor(source: source, offset: body, compressedSize: stored)
                }
            }
        } catch {
            terminalError = error
            throw error
        }
    }

    static func bigEndian(_ bytes: [UInt8], at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[index + i]) }
        return value
    }
}
