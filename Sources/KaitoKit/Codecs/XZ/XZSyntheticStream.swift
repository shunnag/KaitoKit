public import Foundation

/// 連続する block をコピーせず、一つの独立した XZ stream として提示する。
enum XZSyntheticStream {
    static func make(source: any ByteSource, stream: XZStreamLayout.Stream,
                     blocks: ArraySlice<XZStreamLayout.Block>) throws -> any ByteSource {
        guard let first = blocks.first, let last = blocks.last else {
            throw KaitoError.malformed("synthetic XZ stream has no blocks")
        }
        let header = try BoundedByteSource(source: source, baseOffset: stream.headerRange.lowerBound,
                                          length: Checked.sub(stream.headerRange.upperBound, stream.headerRange.lowerBound))
        let body = try BoundedByteSource(source: source, baseOffset: first.compressedRange.lowerBound,
                                        length: Checked.sub(last.compressedRange.upperBound, first.compressedRange.lowerBound))
        let tail = try DataByteSource(xzIndexFooter(blocks: blocks.map { ($0.unpaddedSize, $0.outputSize) }, flags: stream.flags))
        return try ConcatenatedByteSource(segments: [
            .init(source: header, offset: 0, length: header.length),
            .init(source: body, offset: 0, length: body.length),
            .init(source: tail, offset: 0, length: tail.length)
        ], maximumLength: .max, label: "synthetic XZ stream")
    }

    static func xzIndexFooter(blocks: [(unpaddedSize: UInt64, outputSize: UInt64)], flags: UInt16) throws -> Data {
        func integer(_ number: UInt64, into bytes: inout [UInt8]) {
            var number = number
            repeat { bytes.append(UInt8(number & 127) | (number >= 128 ? 128 : 0)); number >>= 7 } while number > 0
        }
        func little(_ number: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: number >> (8 * $0)) }
        }
        var index: [UInt8] = [0]
        integer(UInt64(blocks.count), into: &index)
        for block in blocks {
            integer(block.unpaddedSize, into: &index)
            integer(block.outputSize, into: &index)
        }
        while index.count % 4 != 0 { index.append(0) }
        index.append(contentsOf: little(CRC32.checksum(index)))
        let backwardSize = UInt64(index.count / 4 - 1)
        try Checked.size(backwardSize, limit: UInt64(UInt32.max))
        var footer = little(UInt32(backwardSize))
        footer.append(contentsOf: [UInt8(truncatingIfNeeded: flags), UInt8(truncatingIfNeeded: flags >> 8)])
        index.append(contentsOf: little(CRC32.checksum(footer)))
        index.append(contentsOf: footer)
        index.append(contentsOf: [0x59, 0x5a])
        return Data(index)
    }
}
