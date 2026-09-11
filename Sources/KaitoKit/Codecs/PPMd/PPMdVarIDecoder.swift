import Foundation

// ZIP method 98 の二バイトパラメータと既知の展開サイズを受け取る。
final class PPMdVarIDecoder: Decompressor {
    private let expectedSize: UInt64
    private let rangeDecoder: PPMdVarIRangeDecoder?
    internal let model: PPMdVarIModel
    private var producedSize: UInt64 = 0

    init(
        source: any ByteSource,
        offset: UInt64,
        compressedSize: UInt64,
        parameterWord: UInt16,
        expectedSize: UInt64,
        memorySizeLimit: UInt64
    ) throws {
        let order = Int(parameterWord & 0x0F) + 1
        let memorySize = UInt64(((parameterWord >> 4) & 0xFF) + 1) << 20
        let restoreMethod = Int((parameterWord >> 12) & 3)
        guard (2...16).contains(order), restoreMethod <= 2 else {
            throw KaitoError.malformed("invalid ZIP PPMd parameters")
        }
        try Checked.size(memorySize, limit: memorySizeLimit)
        let end = try Checked.add(offset, compressedSize)
        guard end <= source.length else { throw KaitoError.truncated }
        self.expectedSize = expectedSize
        // 空の entry では range coder の初期化も EOF escape の消費も不要。
        rangeDecoder = expectedSize == 0 ? nil : try PPMdVarIRangeDecoder(
            source: source, offset: offset, endOffset: end
        )
        model = try PPMdVarIModel(maximumOrder: order, memorySize: memorySize, restoreMethod: restoreMethod)
        if expectedSize == 0 { model.releaseArena() }
    }

    var isFinished: Bool { producedSize == expectedSize }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        guard let rangeDecoder else { throw KaitoError.truncated }
        let count = Int(min(UInt64(min(buffer.count, 256 * 1024)), expectedSize - producedSize))
        for i in 0..<count {
            buffer[i] = try model.decodeByte(using: rangeDecoder)
            producedSize += 1
        }
        if isFinished { model.releaseArena() }
        return count
    }
}
