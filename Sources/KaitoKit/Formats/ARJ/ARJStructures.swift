import Foundation

// ARJ の on-disk header。出典は ARJReader.swift の先頭。

/// 主 header と local file header に共通の basic header（technote の "basic header"）。
struct ARJHeader {
    static let identifier: [UInt8] = [0x60, 0xEA]
    static let maximumBasicSize = 2600
    static let flagGarbled: UInt8 = 0x01
    static let flagVolume: UInt8 = 0x04
    static let flagExtendedFilePosition: UInt8 = 0x08
    static let flagPathSymbol: UInt8 = 0x10

    let firstHeaderSize: Int
    let archiverVersion: UInt8
    let minimumVersion: UInt8
    let hostOS: UInt8
    let flags: UInt8
    let method: UInt8            // main header では security version
    let fileType: UInt8
    let dateTime: UInt32         // main header では作成日時
    let compressedSize: UInt32   // main header では更新日時
    let originalSize: UInt32     // main header では archive size
    let crc32: UInt32            // main header では security envelope position
    let filespecPosition: UInt16
    let accessMode: UInt16
    let extraData: [UInt8]
    let rawName: [UInt8]
    let rawComment: [UInt8]
    /// header id から extended header の終わりまでの byte 数。
    let totalSize: Int

    /// `bytes` の offset 0 に header id がある前提で読む。CRC が合わなければ malformed、id が無ければ nil。
    static func parse(_ b: [UInt8]) throws -> ARJHeader? {
        guard b.count >= 4, b[0] == identifier[0], b[1] == identifier[1] else { return nil }
        let basicSize = Int(LittleEndian.uint16(b, at: 2))
        guard basicSize <= maximumBasicSize else { throw KaitoError.malformed("arj basic header size \(basicSize)") }
        guard basicSize > 0 else {
            return ARJHeader(firstHeaderSize: 0, archiverVersion: 0, minimumVersion: 0, hostOS: 0, flags: 0, method: 0, fileType: 0,
                             dateTime: 0, compressedSize: 0, originalSize: 0, crc32: 0, filespecPosition: 0, accessMode: 0,
                             extraData: [], rawName: [], rawComment: [], totalSize: 4)
        }
        guard b.count >= 4 + basicSize + 4 else { throw KaitoError.truncated }
        let basic = Array(b[4..<(4 + basicSize)])
        var crc = CRC32()
        crc.update(basic)
        guard crc.value == LittleEndian.uint32(b, at: 4 + basicSize) else { throw KaitoError.malformed("arj header crc") }
        let firstSize = Int(basic[0])
        guard firstSize >= 30, firstSize <= basicSize else { throw KaitoError.malformed("arj first header size \(firstSize)") }
        var index = firstSize
        func cString() throws -> [UInt8] {
            guard let end = basic[index...].firstIndex(of: 0) else { throw KaitoError.malformed("arj header string") }
            defer { index = end + 1 }
            return Array(basic[index..<end])
        }
        let name = try cString()
        let comment = try cString()
        // extended header の列: 2 byte の size（0 で終わり）、本文、4 byte の CRC。
        var cursor = 4 + basicSize + 4
        var extendedCount = 0
        while true {
            guard b.count >= cursor + 2 else { throw KaitoError.truncated }
            let size = Int(LittleEndian.uint16(b, at: cursor))
            cursor += 2
            if size == 0 { break }
            guard extendedCount < 16, b.count >= cursor + size + 4 else { throw KaitoError.truncated }
            cursor += size + 4
            extendedCount += 1
        }
        return ARJHeader(firstHeaderSize: firstSize, archiverVersion: basic[1], minimumVersion: basic[2], hostOS: basic[3],
                         flags: basic[4], method: basic[5], fileType: basic[6], dateTime: LittleEndian.uint32(basic, at: 8),
                         compressedSize: LittleEndian.uint32(basic, at: 12), originalSize: LittleEndian.uint32(basic, at: 16), crc32: LittleEndian.uint32(basic, at: 20),
                         filespecPosition: LittleEndian.uint16(basic, at: 24), accessMode: LittleEndian.uint16(basic, at: 26),
                         extraData: Array(basic[30..<firstSize]), rawName: name, rawComment: comment, totalSize: cursor)
    }

    var isEndMarker: Bool { totalSize == 4 }

    static func hostOSName(_ value: UInt8) -> String {
        switch value {
        case 0: "MS-DOS"
        case 1: "PRIMOS"
        case 2: "UNIX"
        case 3: "AMIGA"
        case 4: "MAC-OS"
        case 5: "OS/2"
        case 6: "APPLE GS"
        case 7: "ATARI ST"
        case 8: "NeXT"
        case 9: "VAX VMS"
        case 10: "WIN95"
        case 11: "WIN32"
        default: "host \(value)"
        }
    }
}
