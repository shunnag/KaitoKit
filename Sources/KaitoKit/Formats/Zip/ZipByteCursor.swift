// 読込み済みの [UInt8] の上を前へ進む little-endian cursor。範囲を超える読取は truncated を投げる。
// ZIP の固定 header・extra field・ZIP64 record の解析が使う。
struct ZipByteCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int {
        bytes.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw KaitoError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let low = UInt16(try readUInt8())
        return low | UInt16(try readUInt8()) << 8
    }

    mutating func readUInt32LE() throws -> UInt32 {
        var result: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            result |= UInt32(try readUInt8()) << shift
        }
        return result
    }

    mutating func readUInt64LE() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            result |= UInt64(try readUInt8()) << shift
        }
        return result
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let end = offset + count
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        offset += count
    }
}
