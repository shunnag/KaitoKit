import Foundation

/// 連続しない byte 範囲の並びを順に返す（CFB の sector 列、HFS+ の extent 列）。
final class ByteRunDecompressor: Decompressor {
    private let source: any ByteSource
    private let runs: [(offset: UInt64, length: UInt64)]
    private var index = 0
    private var current: CopyDecompressor?

    init(source: any ByteSource, runs: [(offset: UInt64, length: UInt64)]) {
        self.source = source
        self.runs = runs
    }

    var isFinished: Bool { index == runs.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !isFinished else { return 0 }
        if current == nil {
            current = try CopyDecompressor(source: source, offset: runs[index].offset, compressedSize: runs[index].length)
        }
        let count = try current!.read(into: buffer)
        if current!.isFinished { current = nil; index += 1 }
        return count
    }
}
