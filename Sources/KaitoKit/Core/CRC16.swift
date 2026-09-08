import Foundation

/// Incremental reflected CRC-16 used by LHA member payloads.
///
/// LHA uses the ANSI/IBM polynomial `0xA001`, an initial value of zero, and no
/// final XOR. Keeping the calculator independent of the format reader lets the
/// normal `EntryStream` completion path validate the final output chunk before
/// returning it to the caller.
struct CRC16: Sendable {
    private var state: UInt16 = 0

    var value: UInt16 { state }

    init() {}

    // Slice-by-eight tables for the reflected ARC recurrence. Swift initializes
    // this immutable storage once; the hot loop borrows its raw pointer once.
    private static let tables: [UInt16] = {
        var tables = [UInt16](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var crc = UInt16(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xA001)
            }
            tables[byte] = crc
        }
        for slice in 1..<8 {
            for byte in 0..<256 {
                let crc = tables[(slice - 1) * 256 + byte]
                tables[slice * 256 + byte] = (crc >> 8) ^ tables[Int(crc & 255)]
            }
        }
        return tables
    }()

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let baseAddress = buffer.baseAddress else { return }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var crc = state
        Self.tables.withUnsafeBufferPointer { storage in
            let table = storage.baseAddress!
            var index = 0
            // Each unaligned load is wholly inside the caller's buffer.
            while buffer.count - index >= 8 {
                let word = UInt64(littleEndian: UnsafeRawPointer(bytes + index)
                    .loadUnaligned(as: UInt64.self)) ^ UInt64(crc)
                crc = table[7 * 256 + Int(word & 255)]
                    ^ table[6 * 256 + Int((word >> 8) & 255)]
                    ^ table[5 * 256 + Int((word >> 16) & 255)]
                    ^ table[4 * 256 + Int((word >> 24) & 255)]
                    ^ table[3 * 256 + Int((word >> 32) & 255)]
                    ^ table[2 * 256 + Int((word >> 40) & 255)]
                    ^ table[256 + Int((word >> 48) & 255)]
                    ^ table[Int(word >> 56)]
                index += 8
            }
            while index < buffer.count {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt16(bytes[index])) & 255)]
                index += 1
            }
        }
        state = crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var checksum = CRC16()
        bytes.withUnsafeBytes { checksum.update($0) }
        return checksum.value
    }
}
