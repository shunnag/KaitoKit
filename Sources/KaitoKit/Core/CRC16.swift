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

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let baseAddress = buffer.baseAddress else { return }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var crc = state
        for index in 0..<buffer.count {
            crc ^= UInt16(bytes[index])
            for _ in 0..<8 {
                let mask = UInt16(bitPattern: -Int16(crc & 1))
                crc = (crc >> 1) ^ (0xA001 & mask)
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
