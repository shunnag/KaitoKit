// 検証済みの圧縮範囲を固定長バッファで読み、未消費の入力窓を codec に渡す。
struct ChunkedSourceInput {
    let source: any ByteSource
    let endOffset: UInt64
    private let chunkSize: Int
    private var sourceOffset: UInt64
    private var input: [UInt8]
    private var inputOffset = 0
    private var inputCount = 0

    init(source: any ByteSource, offset: UInt64, endOffset: UInt64, chunkSize: Int) {
        self.source = source
        self.endOffset = endOffset
        self.chunkSize = chunkSize
        self.sourceOffset = offset
        self.input = [UInt8](repeating: 0, count: chunkSize)
    }

    var availableCount: Int { inputCount - inputOffset }

    var isSourceExhausted: Bool { sourceOffset == endOffset }

    var consumedSourceOffset: UInt64 {
        get throws {
            try Checked.sub(sourceOffset, UInt64(availableCount))
        }
    }

    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try input.withUnsafeBytes { bytes in
            try body(UnsafeRawBufferPointer(rebasing: bytes[inputOffset..<inputCount]))
        }
    }

    // codec が報告した消費量は呼び出し側で入力窓の範囲内と検証する。
    mutating func consume(_ count: Int) {
        inputOffset += count
    }

    mutating func reset(to offset: UInt64) {
        sourceOffset = offset
        inputOffset = 0
        inputCount = 0
    }

    mutating func refill() throws {
        guard sourceOffset < endOffset else {
            inputOffset = 0
            inputCount = 0
            return
        }

        let remaining = try Checked.sub(endOffset, sourceOffset)
        let requested = try Checked.toInt(min(UInt64(chunkSize), remaining))
        let source = self.source
        let offset = sourceOffset
        let count = try input.withUnsafeMutableBytes { bytes -> Int in
            // requested <= input.count なので、ByteSource が書き込める範囲だけを公開する。
            let destination = UnsafeMutableRawBufferPointer(rebasing: bytes[..<requested])
            return try source.read(into: destination, at: offset)
        }
        guard count > 0, count <= requested else {
            throw KaitoError.truncated
        }

        sourceOffset = try Checked.add(sourceOffset, UInt64(count))
        inputOffset = 0
        inputCount = count
    }
}
