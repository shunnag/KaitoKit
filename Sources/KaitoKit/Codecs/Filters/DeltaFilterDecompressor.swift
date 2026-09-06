import Foundation

// 参照仕様: LZMA SDK の Methods.txt に記載された 7z Delta filter。

/// 7z の Delta filter を逐次的に逆変換する。
final class DeltaFilterDecompressor: Decompressor {
    private static let chunkSize = 256 * 1_024

    private let input: any Decompressor
    private let distance: Int
    private let expectedSize: UInt64
    private var producedSize: UInt64 = 0
    private var history = [UInt8](repeating: 0, count: 256)
    private var historyPosition = 0
    private var completionVerified = false

    /// Creates a bounded Delta-filter decoder.
    init(
        input: any Decompressor,
        distance: Int,
        expectedSize: UInt64
    ) throws {
        guard (1...256).contains(distance) else {
            throw KaitoError.malformed("7z Delta distance must be in 1...256")
        }
        self.input = input
        self.distance = distance
        self.expectedSize = expectedSize
    }

    var isFinished: Bool {
        producedSize == expectedSize && completionVerified
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if producedSize == expectedSize {
            try verifyInputCompletion()
            return 0
        }

        let remaining = try Checked.sub(expectedSize, producedSize)
        let requested = try Checked.toInt(min(
            UInt64(buffer.count),
            UInt64(Self.chunkSize),
            remaining
        ))
        var bytes = [UInt8](repeating: 0, count: requested)
        let count = try bytes.withUnsafeMutableBytes { storage in
            // storage は requested バイトの固定領域で、下位 decoder へ全域を公開する。
            try input.read(into: storage)
        }
        guard count > 0 else { throw KaitoError.truncated }
        guard count <= requested else {
            throw KaitoError.malformed("Delta input returned too many bytes")
        }

        for index in 0..<count {
            let value = bytes[index] &+ history[historyPosition]
            bytes[index] = value
            history[historyPosition] = value
            historyPosition += 1
            if historyPosition == distance {
                historyPosition = 0
            }
        }

        buffer.copyBytes(from: bytes[..<count])
        producedSize = try Checked.add(producedSize, UInt64(count))
        if producedSize == expectedSize {
            try verifyInputCompletion()
        }
        return count
    }

    private func verifyInputCompletion() throws {
        guard !completionVerified else { return }
        if !input.isFinished {
            var extra: UInt8 = 0
            let count = try withUnsafeMutableBytes(of: &extra) { storage in
                try input.read(into: storage)
            }
            guard count == 0, input.isFinished else {
                throw KaitoError.malformed("Delta input exceeds its declared size")
            }
        }
        completionVerified = true
    }
}
