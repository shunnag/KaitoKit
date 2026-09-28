import Foundation

// 参照仕様: LZMA SDK DOC/7zFormat.txt (18.06)。header の wire 構造体、上限、metadata 予算、byte cursor を置く。

enum SevenZipFormatLimits {
    // 7zz が生成する BCJ2 + AES の複合 folder を受理しつつ、
    // graph 走査の再帰深度と decoder 構築コストを一定に抑える。
    static let maxFolderCodersAndStreams = 64
}

enum SevenZipNID: UInt8 {
    case end = 0x00
    case header = 0x01
    case archiveProperties = 0x02
    case additionalStreamsInfo = 0x03
    case mainStreamsInfo = 0x04
    case filesInfo = 0x05
    case packInfo = 0x06
    case unpackInfo = 0x07
    case subStreamsInfo = 0x08
    case size = 0x09
    case crc = 0x0A
    case folder = 0x0B
    case codersUnpackSize = 0x0C
    case numUnpackStream = 0x0D
    case emptyStream = 0x0E
    case emptyFile = 0x0F
    case anti = 0x10
    case name = 0x11
    case creationTime = 0x12
    case accessTime = 0x13
    case modificationTime = 0x14
    case windowsAttributes = 0x15
    case comment = 0x16
    case encodedHeader = 0x17
    case startPosition = 0x18
    case dummy = 0x19
}

struct SevenZipDigest: Sendable, Equatable {
    let value: UInt32?
}

struct SevenZipCoder: Sendable, Equatable {
    let methodID: [UInt8]
    let inputCount: Int
    let outputCount: Int
    let properties: [UInt8]
    let firstInput: Int
    let firstOutput: Int
    /// coder record 先頭 byte の生値。bit の意味は `SevenZipCoderFlag`。
    var flags: UInt8 = 0
}

/// coder record 先頭 byte の bit 配置（7zFormat.txt の Coder flags）。
enum SevenZipCoderFlag {
    /// bit 6 は予約、bit 7 は廃止された alternative methods。どちらも 0 でなければならない。
    static let reservedMask: UInt8 = 0xC0
    /// method ID の byte 数（1…8）。
    static let idSizeMask: UInt8 = 0x0F
    /// 入力数・出力数を明示する複合 coder。立っていなければ 1 入力 1 出力。
    static let complex: UInt8 = 0x10
    /// properties の長さと本体が続く。
    static let hasProperties: UInt8 = 0x20
}

struct SevenZipBindPair: Sendable, Equatable {
    let input: Int
    let output: Int
}

struct SevenZipFolder: Sendable, Equatable {
    var coders: [SevenZipCoder]
    let bindPairs: [SevenZipBindPair]
    let packedIndices: [Int]
    let inputCount: Int
    let outputCount: Int
    let finalOutputIndex: Int
    var unpackSizes: [UInt64]
    var digest: SevenZipDigest

    func coderIndex(containingOutput output: Int) -> Int? {
        coders.firstIndex {
            output >= $0.firstOutput && output < $0.firstOutput + $0.outputCount
        }
    }

    func boundOutput(forInput input: Int) -> Int? {
        bindPairs.first(where: { $0.input == input })?.output
    }
}

struct SevenZipPackInfo: Sendable, Equatable {
    let position: UInt64
    let sizes: [UInt64]
    let digests: [SevenZipDigest]
}

struct SevenZipSubstream: Sendable, Equatable {
    let folderIndex: Int
    let offset: UInt64
    let size: UInt64
    let digest: SevenZipDigest
}

struct SevenZipStreamsInfo: Sendable, Equatable {
    let packInfo: SevenZipPackInfo
    let folders: [SevenZipFolder]
    let substreams: [SevenZipSubstream]
}

// 7z header の各 parser が個別に上限を使い切らないよう、open 全体で
// 単調増加する論理 metadata 予算を共有する。
final class SevenZipMetadataBudget {
    private let limit: UInt64
    private(set) var used: UInt64 = 0

    init(limit: UInt64) {
        self.limit = limit
    }

    func reserve(_ bytes: UInt64, description: String) throws {
        let next = try Checked.add(used, bytes)
        guard next <= limit else {
            throw KaitoError.limitExceeded(
                "\(description) exceeds aggregate 7z metadata limit"
            )
        }
        used = next
    }

    func reserve(
        count: Int,
        bytesPerRecord: UInt64,
        description: String
    ) throws {
        guard count >= 0 else {
            throw KaitoError.malformed("negative 7z metadata record count")
        }
        try reserve(
            try Checked.mul(UInt64(count), bytesPerRecord),
            description: description
        )
    }
}

struct SevenZipHeaderCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int
    private let upperBound: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.upperBound = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, upperBound: Int) {
        self.bytes = bytes
        self.offset = offset
        self.upperBound = upperBound
    }

    var remaining: Int { upperBound - offset }
    var isAtEnd: Bool { offset == upperBound }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw KaitoError.truncated }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readUInt32LE() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try readUInt8()) << shift
        }
        return value
    }

    mutating func readUInt64LE() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(try readUInt8()) << shift
        }
        return value
    }

    // 先頭 byte の連続 1 の数が後続 byte 数になる 7z UINT64。
    mutating func readNumber() throws -> UInt64 {
        let first = try readUInt8()
        var mask: UInt8 = 0x80
        var value: UInt64 = 0

        for byteIndex in 0..<8 {
            if first & mask == 0 {
                let prefix = UInt64(first & (mask &- 1))
                let shift = UInt64(byteIndex * 8)
                return try Checked.add(value, try Checked.shiftLeft(prefix, by: shift))
            }
            let byte = UInt64(try readUInt8())
            value |= byte << UInt64(byteIndex * 8)
            mask >>= 1
        }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let end = offset + count
        let result = Array(bytes[offset..<end])
        offset = end
        return result
    }

    mutating func readSubcursor(_ count: Int) throws -> SevenZipHeaderCursor {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let start = offset
        offset += count
        return SevenZipHeaderCursor(bytes: bytes, offset: start, upperBound: start + count)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        offset += count
    }

    mutating func readBitVector(count: Int) throws -> [Bool] {
        guard count >= 0 else { throw KaitoError.malformed("negative 7z bit-vector size") }
        let byteCount = (count + 7) / 8
        guard byteCount <= remaining else { throw KaitoError.truncated }
        var result = [Bool](repeating: false, count: count)
        var mask: UInt8 = 0
        var byte: UInt8 = 0
        for index in 0..<count {
            try checkCancellation(every: index)
            if mask == 0 {
                byte = try readUInt8()
                mask = 0x80
            }
            result[index] = byte & mask != 0
            mask >>= 1
        }
        return result
    }

    mutating func readDefinedVector(count: Int) throws -> [Bool] {
        let allDefined = try readUInt8()
        switch allDefined {
        case 0:
            return try readBitVector(count: count)
        case 1:
            return [Bool](repeating: true, count: count)
        default:
            throw KaitoError.malformed("invalid 7z all-defined flag")
        }
    }
}
