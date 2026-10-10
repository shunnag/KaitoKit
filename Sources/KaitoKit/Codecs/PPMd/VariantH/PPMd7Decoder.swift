import Foundation

// 参照仕様: 公開ドメインの LZMA SDK `C/Ppmd7.c`、`C/Ppmd7.h`、
// `C/Ppmd7Dec.c` と Dmitry Shkarin の PPMd var.H model description。
// 7z 固有の carryless range coder と 5-byte properties を境界検査付きで再実装する
// （range coder は SevenZipPPMdRangeDecoder.swift）。

// 7z が使用する PPMd7（variant H）のストリーミング decoder。
// 失敗は latch しない。throw した時点で model と range coder は途中まで進んでいるので、instance を破棄する。
final class PPMd7Decoder: Decompressor {
    private static let outputChunkSize = 256 * 1_024

    private let expectedSize: UInt64
    private let rangeDecoder: SevenZipPPMdRangeDecoder
    private let model: PPMd7Model
    private var producedSize: UInt64 = 0

    // 検証済みの圧縮範囲から PPMd7 decoder を生成する。
    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        properties: [UInt8],
        expectedSize: UInt64,
        memorySizeLimit: UInt64
    ) throws {
        guard properties.count == 5 else {
            throw KaitoError.malformed("PPMd7 properties must contain five bytes")
        }
        let order = Int(properties[0])
        guard (2...64).contains(order) else {
            throw KaitoError.malformed("PPMd7 order must be in 2...64")
        }
        let memorySize = UInt64(properties[1])
            | (UInt64(properties[2]) << 8)
            | (UInt64(properties[3]) << 16)
            | (UInt64(properties[4]) << 24)
        guard memorySize >= 1 << 11,
              memorySize <= UInt64(UInt32.max) - 36 else {
            throw KaitoError.malformed("PPMd7 memory size is outside the supported format range")
        }
        try Checked.size(memorySize, limit: memorySizeLimit)
        let endOffset = try Checked.add(offset, compressedSize)
        guard endOffset <= source.length else { throw KaitoError.truncated }

        self.expectedSize = expectedSize
        self.rangeDecoder = try SevenZipPPMdRangeDecoder(
            source: source,
            offset: offset,
            endOffset: endOffset
        )
        self.model = try PPMd7Model(
            maximumOrder: order,
            memorySize: memorySize
        )
    }

    var isFinished: Bool {
        producedSize == expectedSize
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }

        let remaining = try Checked.sub(expectedSize, producedSize)
        let count = try Checked.toInt(min(
            UInt64(buffer.count),
            UInt64(Self.outputChunkSize),
            remaining
        ))
        try model.decode(into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]), using: rangeDecoder)
        producedSize = try Checked.add(producedSize, UInt64(count))
        return count
    }
}
