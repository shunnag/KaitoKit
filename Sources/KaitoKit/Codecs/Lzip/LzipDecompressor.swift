import Foundation

// 参照仕様: draft-diaz-lzip-14 §2 "File Format"（散文節のみ。§3 の参照実装と付録 A は取り込まない）。
// member は `LZIP` + version 1 + 辞書サイズ 1 byte + LZMA-302eos stream（lc=3, lp=0, pb=2、
// end marker 終端）+ CRC32 (4) + data size (8) + member size (8)。複数 member は連結し、
// 末尾の member size を辿ると後ろから索引を作れる。CRC32 の多項式は仕様の散文に無いが、
// lzip 1.x / bsdtar --lzip の出力で RFC 1952 と同じ CRC-32 であることを黒箱で確認した。
struct LzipMember: Equatable {
    static let headerSize: UInt64 = 6
    static let trailerSize: UInt64 = 20
    static let magic: [UInt8] = [0x4C, 0x5A, 0x49, 0x50]

    /// member 先頭（`LZIP`）の絶対 offset。
    let offset: UInt64
    /// header と trailer を含む member 全体の長さ。
    let size: UInt64
    /// header の DS byte から復元した辞書サイズ。
    let dictionarySize: UInt64
    /// trailer が宣言する展開後サイズ。
    let dataSize: UInt64
    /// trailer が宣言する展開後 data の CRC-32。
    let crc32: UInt32

    var streamOffset: UInt64 { offset + Self.headerSize }
    var streamSize: UInt64 { size - Self.headerSize - Self.trailerSize }

    /// DS byte → 辞書サイズ。bits 4-0 が 2 の冪の指数（12〜29）、bits 7-5 がその 1/16 を単位に
    /// 引く分子（0〜7）。結果は 4 KiB〜512 MiB。
    static func dictionarySize(coded: UInt8) throws -> UInt64 {
        let exponent = Int(coded & 0x1F)
        let numerator = UInt64(coded >> 5)
        guard (12...29).contains(exponent) else {
            throw KaitoError.malformed("lzip dictionary size exponent is out of range")
        }
        let base = UInt64(1) << exponent
        let size = base - numerator * (base / 16)
        guard size >= 4_096, size <= 512 * 1_024 * 1_024 else {
            throw KaitoError.malformed("lzip dictionary size is out of range")
        }
        return size
    }

    /// LZMADecoder へ渡す 5 byte の LZMA1 properties。lc=3, lp=0, pb=2 は固定（0x5D）。
    var lzmaProperties: [UInt8] {
        [0x5D,
         UInt8(truncatingIfNeeded: dictionarySize),
         UInt8(truncatingIfNeeded: dictionarySize >> 8),
         UInt8(truncatingIfNeeded: dictionarySize >> 16),
         UInt8(truncatingIfNeeded: dictionarySize >> 24)]
    }
}

/// lzip file の member 索引。末尾の member size を後ろへ辿って組み立てる。
struct LzipMemberIndex {
    let members: [LzipMember]
    /// 全 member の data size の合計。
    let totalDataSize: UInt64

    init(source: any ByteSource, limits: ReadLimits) throws {
        let length = source.length
        guard length >= LzipMember.headerSize else { throw KaitoError.truncated }
        // 先頭 member の magic と version を最初に見る。version 0（2008 年以前）は trailer の
        // 形が違うので、後ろから辿る前に unsupportedMethod として報告する。
        let first = try readByteRange(source: source, offset: 0, count: Int(LzipMember.headerSize))
        guard Array(first[..<4]) == LzipMember.magic else {
            throw KaitoError.malformed("lzip member magic is missing")
        }
        guard first[4] == 1 else {
            throw KaitoError.unsupportedMethod("lzip version \(first[4])")
        }
        guard length >= LzipMember.headerSize + LzipMember.trailerSize else {
            throw KaitoError.truncated
        }
        var reversed = [LzipMember]()
        var end = length
        var total: UInt64 = 0
        while end > 0 {
            guard reversed.count < limits.maxMetadataRecordCount else {
                throw KaitoError.limitExceeded("lzip member count")
            }
            guard end >= LzipMember.headerSize + LzipMember.trailerSize else {
                throw KaitoError.malformed("lzip trailing bytes do not form a member")
            }
            let trailer = try readByteRange(
                source: source, offset: end - LzipMember.trailerSize, count: Int(LzipMember.trailerSize)
            )
            let crc = Self.littleEndian(trailer, at: 0, count: 4)
            let dataSize = Self.littleEndian(trailer, at: 4, count: 8)
            let memberSize = Self.littleEndian(trailer, at: 12, count: 8)
            // stream は range coder の初期 5 byte を必ず含む。file 末尾で成立しなければ、
            // 最後の member の後ろに lzip でない byte が付いている。
            guard memberSize >= LzipMember.headerSize + LzipMember.trailerSize + 5,
                  memberSize <= end else {
                throw KaitoError.malformed(end == length
                    ? "lzip file does not end with a member trailer (trailing bytes)"
                    : "lzip member size does not fit the file")
            }
            let offset = end - memberSize
            let header = try readByteRange(source: source, offset: offset, count: Int(LzipMember.headerSize))
            guard Array(header[..<4]) == LzipMember.magic else {
                throw KaitoError.malformed("lzip member magic is missing")
            }
            guard header[4] == 1 else {
                throw KaitoError.unsupportedMethod("lzip version \(header[4])")
            }
            let dictionarySize = try LzipMember.dictionarySize(coded: header[5])
            try Checked.size(dictionarySize, limit: limits.maxDictionarySize)
            try Checked.size(dataSize, limit: limits.maxEntrySize)
            total = try Checked.add(total, dataSize)
            try Checked.size(total, limit: limits.maxEntrySize)
            try Checked.size(total, limit: limits.maxTotalUncompressedSize)
            reversed.append(LzipMember(
                offset: offset, size: memberSize, dictionarySize: dictionarySize,
                dataSize: dataSize, crc32: UInt32(truncatingIfNeeded: crc)
            ))
            end = offset
        }
        let members = Array(reversed.reversed())
        // 空 member は単独 file のときだけ許される（§2）。
        if members.count > 1, members.contains(where: { $0.dataSize == 0 }) {
            throw KaitoError.malformed("lzip multimember file contains an empty member")
        }
        self.members = members
        self.totalDataSize = total
    }

    private static func littleEndian(_ bytes: [UInt8], at index: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(bytes[index + i]) << (8 * i)
        }
        return value
    }
}

/// lzip の member 列を一つの出力として復号し、member ごとに end marker・消費 byte 数・
/// data size・CRC-32 を検証する。
final class LzipDecompressor: Decompressor {
    private let source: any ByteSource
    private let limits: ReadLimits
    private let members: [LzipMember]
    private var memberIndex = 0
    private var decoder: LZMADecoder?
    private var produced: UInt64 = 0
    private var checksum = CRC32()
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init(source: any ByteSource, limits: ReadLimits) throws {
        self.source = source
        self.limits = limits
        self.members = try LzipMemberIndex(source: source, limits: limits).members
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while true {
                if decoder == nil {
                    guard memberIndex < members.count else {
                        isFinished = true
                        return 0
                    }
                    let member = members[memberIndex]
                    decoder = try LZMADecoder(
                        source: source,
                        offset: member.streamOffset,
                        compressedSize: member.streamSize,
                        properties: member.lzmaProperties,
                        expectedSize: nil,
                        dictionarySizeLimit: limits.maxDictionarySize,
                        outputSizeHint: member.dataSize
                    )
                    produced = 0
                    checksum = CRC32()
                }
                guard let current = decoder else { continue }
                let count = try current.read(into: buffer)
                if count > 0 {
                    produced = try Checked.add(produced, UInt64(count))
                    let member = members[memberIndex]
                    guard produced <= member.dataSize else {
                        throw KaitoError.malformed("lzip member output exceeds its declared data size")
                    }
                    checksum.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
                    if current.isFinished { try finishMember(current) }
                    return count
                }
                guard current.isFinished else {
                    throw KaitoError.malformed("lzip member made no progress")
                }
                try finishMember(current)
            }
        } catch {
            terminalError = error
            throw error
        }
    }

    private func finishMember(_ current: LZMADecoder) throws {
        let member = members[memberIndex]
        guard produced == member.dataSize else {
            throw KaitoError.malformed("lzip member data size mismatch")
        }
        guard current.consumedEntireInput else {
            throw KaitoError.malformed("lzip member size does not match its LZMA stream")
        }
        guard checksum.value == member.crc32 else {
            throw KaitoError.checksumMismatch(entry: 0)
        }
        decoder = nil
        memberIndex += 1
    }
}
