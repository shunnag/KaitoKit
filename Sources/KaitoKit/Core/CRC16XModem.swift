import Foundation

/// CRC-16/XMODEM（CRC-ITU-T）: 多項式 0x1021、初期値 0、入出力の反転なし。ECMA-167 3/7.2.6 の例:
/// 70 6A 77 → 3299。UDF の descriptor tag と MacBinary / BinHex の header・fork CRC が使う。
/// `CRC16` は反転する 0xA001（LHA・ARC）で別物。短い header にだけ使うので表は持たず bit ごとに計算する。
enum CRC16XModem {
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
