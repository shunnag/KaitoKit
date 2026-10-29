private import CBzip2
import Foundation

/// XZ の block check が使う CRC-64（ECMA-182 の多項式を反転した形、初期値と最終 XOR は全 bit 1）。
/// 参照仕様: xz-file-format.txt §3.4 と ECMA-182。PMULL folding と portable slice-by-8。
struct CRC64: Sendable {
    private static let polynomial: UInt64 = 0xC96C_5795_D787_0F42

    /// 表は 8 枚 × 256 項を一つの配列に並べる（table[slice * 256 + byte]）。
    private static let tables: [UInt64] = {
        var tables = [UInt64](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var crc = UInt64(index)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1
            }
            tables[index] = crc
        }
        for slice in 1..<8 {
            for index in 0..<256 {
                let previous = tables[(slice - 1) * 256 + index]
                tables[slice * 256 + index] = (previous >> 8) ^ tables[Int(previous & 0xff)]
            }
        }
        return tables
    }()

    static let foldingAvailable = kk_crc64_has_folding() != 0

    private var state: UInt64 = ~0

    init() {}

    /// ここまでの入力の CRC-64。
    var value: UInt64 { ~state }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var crc = CRC64()
        crc.update(bytes)
        return crc.value
    }

    static func checksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { checksum($0) }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        state = Self.update(bytes, initial: state, folding: Self.foldingAvailable)
    }

    // Raw (uncomplemented) state entry point also exercises arbitrary seeds
    // and the original slice-by-eight fallback without global dispatch changes.
    static func update(_ bytes: UnsafeRawBufferPointer, initial: UInt64,
                       folding: Bool) -> UInt64 {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return initial }
        var crc = initial
        Self.tables.withUnsafeBufferPointer { tablesBuffer in
            let table = tablesBuffer.baseAddress!
            var position = 0
            let count = bytes.count
            if count >= 64 && folding && Self.foldingAvailable {
                position = count & ~15
                crc = kk_crc64_fold_blocks(base.assumingMemoryBound(to: UInt8.self), position, crc, table)
            }
            // 8 byte 境界まで 1 byte ずつ進めると load が整列し、残りは末尾で処理する。
            while position < count, (Int(bitPattern: base) &+ position) & 7 != 0 {
                let byte = base.load(fromByteOffset: position, as: UInt8.self)
                crc = (crc >> 8) ^ table[Int((crc ^ UInt64(byte)) & 0xff)]
                position &+= 1
            }
            while position &+ 8 <= count {
                let word = base.load(fromByteOffset: position, as: UInt64.self)
                let value = crc ^ UInt64(littleEndian: word)
                // slice-by-8: 下位 byte から順に高位の表を引く。
                crc = table[7 * 256 + Int(value & 0xff)]
                    ^ table[6 * 256 + Int((value >> 8) & 0xff)]
                    ^ table[5 * 256 + Int((value >> 16) & 0xff)]
                    ^ table[4 * 256 + Int((value >> 24) & 0xff)]
                    ^ table[3 * 256 + Int((value >> 32) & 0xff)]
                    ^ table[2 * 256 + Int((value >> 40) & 0xff)]
                    ^ table[1 * 256 + Int((value >> 48) & 0xff)]
                    ^ table[Int(value >> 56)]
                position &+= 8
            }
            while position < count {
                let byte = base.load(fromByteOffset: position, as: UInt8.self)
                crc = (crc >> 8) ^ table[Int((crc ^ UInt64(byte)) & 0xff)]
                position &+= 1
            }
        }
        return crc
    }
}
