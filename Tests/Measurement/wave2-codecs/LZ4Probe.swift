import Compression
import Foundation

// Project-owned legacy corpus and KaitoKit decoders; Apple buffer API only.
// Build/run commands and clean-room provenance are in the wave 2 verification record.

@main struct Probe {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        var cursor = 4
        var blocks = [Data]()
        while cursor < data.count {
            let size = word(cursor)
            cursor += 4
            blocks.append(data.subdata(in: cursor..<(cursor + size)))
            cursor += size
        }
        let buffer = LZ4BlockBuffer(), adapter = LZ4AppleBlockDecoder()
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW)), alignment: 16)
        defer { scratch.deallocate() }
        for mode in 0..<4 {
            var total = 0
            let start = ContinuousClock.now
            for _ in 0..<20 {
                for block in blocks {
                    buffer.reset()
                    try block.withUnsafeBytes { raw in
                        switch mode {
                        case 0: try LZ4BlockDecoder.decode(raw, into: buffer, maximumSize: 8 * 1024 * 1024)
                        case 1: total += try LZ4AppleBlockDecoder.validatedSize(raw, maximumSize: 8 * 1024 * 1024)
                        case 2:
                            buffer.reserveOutput(8 * 1024 * 1024 + 1)
                            total += compression_decode_buffer(buffer.outputAddress.assumingMemoryBound(to: UInt8.self), 8 * 1024 * 1024 + 1, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count, scratch, COMPRESSION_LZ4_RAW)
                        default: try adapter.decode(raw, into: buffer, blockMaximum: 8 * 1024 * 1024, maximumSize: 8 * 1024 * 1024)
                        }
                        total += buffer.outputCount
                    }
                }
            }
            print(mode, start.duration(to: .now), total)
        }
    }
}
