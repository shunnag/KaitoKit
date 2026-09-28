// Microsoft [MS-CAB]、RFC 1951、zlib manual と利用者提供の実測 byte 表に基づくクリーンルーム実装。
// 他の archiver の実装 source は開かず、参照・引用していない。
import Foundation

struct CabHeader {
    let cabinetSize, filesOffset: UInt64
    let folderCount, fileCount: Int
    let flags, setID, cabinetIndex: UInt16

    init(_ bytes: [UInt8]) throws {
        guard bytes.starts(with: [0x4d, 0x53, 0x43, 0x46]), bytes[25] == 1 else {
            throw KaitoError.unsupportedFormat
        }
        cabinetSize = UInt64(LittleEndian.uint32(bytes, at: 8))
        filesOffset = UInt64(LittleEndian.uint32(bytes, at: 16))
        folderCount = Int(LittleEndian.uint16(bytes, at: 26))
        fileCount = Int(LittleEndian.uint16(bytes, at: 28))
        flags = LittleEndian.uint16(bytes, at: 30)
        setID = LittleEndian.uint16(bytes, at: 32)
        cabinetIndex = LittleEndian.uint16(bytes, at: 34)
    }
}

struct CabFolder {
    let dataOffset: UInt64
    let blockCount: Int
    let typeCompress: UInt16
    var method: UInt16 { typeCompress & 0x000f }
    var windowBits: Int { Int((typeCompress >> 8) & 0x1f) }
    var methodName: String {
        switch method {
        case 0: "stored"
        case 1: "MSZIP"
        case 2: "Quantum"
        case 3: "LZX"
        default: "method \(method)"
        }
    }

    init(_ bytes: [UInt8]) {
        dataOffset = UInt64(LittleEndian.uint32(bytes, at: 0))
        blockCount = Int(LittleEndian.uint16(bytes, at: 4))
        typeCompress = LittleEndian.uint16(bytes, at: 6)
    }
}

struct CabFile {
    let size, folderOffset: UInt64
    let folderIndex, date, time, attributes: UInt16
    let name: [UInt8]
    var continued: String? {
        switch folderIndex {
        case 0xfffd: "previous"
        case 0xfffe: "next"
        case 0xffff: "both"
        default: nil
        }
    }

    init(_ bytes: [UInt8], name: [UInt8]) {
        size = UInt64(LittleEndian.uint32(bytes, at: 0))
        folderOffset = UInt64(LittleEndian.uint32(bytes, at: 4))
        folderIndex = LittleEndian.uint16(bytes, at: 8)
        date = LittleEndian.uint16(bytes, at: 10)
        time = LittleEndian.uint16(bytes, at: 12)
        attributes = LittleEndian.uint16(bytes, at: 14)
        self.name = name
    }
}

struct CabDataBlock {
    let checksum: UInt32
    let compressedSize, uncompressedSize: UInt16
    let dataOffset: UInt64
    let folderOffset: UInt64

    init(_ bytes: [UInt8], dataOffset: UInt64, folderOffset: UInt64 = 0) throws {
        checksum = LittleEndian.uint32(bytes, at: 0)
        compressedSize = LittleEndian.uint16(bytes, at: 4)
        uncompressedSize = LittleEndian.uint16(bytes, at: 6)
        guard uncompressedSize <= 32768 else { throw KaitoError.malformed("cab block size") }
        self.dataOffset = dataOffset
        self.folderOffset = folderOffset
    }

    func computedChecksum(_ data: [UInt8]) -> UInt32 {
        var sum = UInt32(compressedSize) | (UInt32(uncompressedSize) << 16)
        var index = 0
        while data.count - index >= 4 {
            sum ^= LittleEndian.uint32(data, at: index)
            index += 4
        }
        // [MS-CAB] §3.1: 端数だけ逆順の byte word にする。通常のゼロ埋め LE とは異なる。
        var remainder: UInt32 = 0
        for byte in data[index...] { remainder = (remainder << 8) | UInt32(byte) }
        return sum ^ remainder
    }
}

struct CabCursor {
    let source: any ByteSource
    let end: UInt64
    var offset: UInt64

    mutating func skip(_ count: UInt64) throws {
        let next = try Checked.add(offset, count)
        guard next <= end else { throw KaitoError.truncated }
        offset = next
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        let start = offset
        try skip(UInt64(count))
        return try readByteRange(source: source, offset: start, count: count)
    }

    func validateRecords(count: Int, stride: UInt64) throws {
        guard try Checked.add(offset, Checked.mul(UInt64(count), stride)) <= end else {
            throw KaitoError.truncated
        }
    }

    mutating func name(limit: UInt64, label: String) throws -> [UInt8] {
        var result: [UInt8] = []
        while offset < end {
            let remaining = try Checked.sub(limit, UInt64(result.count))
            let count = try Checked.toInt(min(try Checked.sub(end, offset), Checked.add(min(4095, remaining), 1)))
            let bytes = try readByteRange(source: source, offset: offset, count: count)
            let used = bytes.firstIndex(of: 0) ?? bytes.count
            try Checked.size(Checked.add(UInt64(result.count), UInt64(used)), limit: limit)
            result.append(contentsOf: bytes.prefix(used))
            try skip(UInt64(used))
            if used < bytes.count { try skip(1); return result }
        }
        throw KaitoError.malformed(label)
    }
}
