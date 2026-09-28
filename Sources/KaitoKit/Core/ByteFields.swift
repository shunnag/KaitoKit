import Foundation

// 固定幅の整数 field を [UInt8] から読む。範囲の検査は呼出側が済ませ、ここでは添字だけを使う。
// 形式ごとの `*Bytes` enum は、この二つへ委譲するか、形式固有の field（日時・CRC・文字列）だけを持つ。

/// little-endian（下位 byte が先）。ZIP・7z・RAR・LHA・CAB・CFB・CHM・ARJ・UDF・WIM・GPT が使う。
enum LittleEndian {
    @inline(__always)
    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    @inline(__always)
    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    @inline(__always)
    static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(uint32(bytes, at: offset)) | UInt64(uint32(bytes, at: offset + 4)) << 32
    }
}

/// big-endian（上位 byte が先）。HFS+・UDIF・StuffIt・AppleDouble・rpm・pbzx が使う。
enum BigEndian {
    @inline(__always)
    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    @inline(__always)
    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    @inline(__always)
    static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(uint32(bytes, at: offset)) << 32 | UInt64(uint32(bytes, at: offset + 4))
    }
}
