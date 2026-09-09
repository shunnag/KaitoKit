import Foundation

// cpio(5) / Heirloom: CRC ではなく data byte の unsigned 32-bit 単純加算。
final class CpioSumDecompressor: Decompressor {
    private let copy: CopyDecompressor
    private(set) var value: UInt32 = 0
    init(source: any ByteSource, offset: UInt64, length: UInt64) throws {
        copy = try CopyDecompressor(source: source, offset: offset, compressedSize: length)
    }
    var isFinished: Bool { copy.isFinished }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try copy.read(into: buffer)
        for byte in buffer[..<count] { value &+= UInt32(byte) }
        return count
    }
}
