import Foundation

// IDs: 7-Zip DOC/Methods.txt, 02 03 02 / 02 03 04.
// Complete 2/4-byte units reverse byte order; a final partial unit is copied.
// The tail rule is independently checked against 7zz 26.03 fixtures.
final class SwapFilterDecompressor: Decompressor {
    private static let chunkSize = 256 * 1_024
    private let input: any Decompressor
    private let width: Int
    private let expectedSize: UInt64
    private var received: UInt64 = 0
    private var delivered: UInt64 = 0
    private var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
    private var pending: [UInt8] = []
    private var ready: [UInt8] = []
    private var readyOffset = 0
    private var completionVerified = false

    init(input: any Decompressor, width: Int, expectedSize: UInt64) throws {
        guard width == 2 || width == 4 else { throw KaitoError.malformed("invalid Swap unit size") }
        self.input = input
        self.width = width
        self.expectedSize = expectedSize
    }

    var isFinished: Bool { delivered == expectedSize && completionVerified }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if delivered == expectedSize {
            try verifyInputCompletion()
            return 0
        }
        while readyOffset == ready.count {
            let requested = try Checked.toInt(min(UInt64(Self.chunkSize), try Checked.sub(expectedSize, received)))
            guard requested > 0 else { throw KaitoError.truncated }
            let count = try inputBuffer.withUnsafeMutableBytes {
                try input.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<requested]))
            }
            guard count > 0 else { throw KaitoError.truncated }
            guard count <= requested else { throw KaitoError.malformed("Swap input returned too many bytes") }
            received = try Checked.add(received, UInt64(count))
            ready = pending + inputBuffer.prefix(count)
            readyOffset = 0
            let complete = ready.count / width * width
            for start in stride(from: 0, to: complete, by: width) {
                for index in 0..<(width / 2) { ready.swapAt(start + index, start + width - index - 1) }
            }
            if received == expectedSize {
                pending.removeAll(keepingCapacity: true)
            } else {
                pending = Array(ready[complete...])
                ready.removeLast(ready.count - complete)
            }
        }
        let count = min(buffer.count, ready.count - readyOffset)
        buffer.copyBytes(from: ready[readyOffset..<(readyOffset + count)])
        readyOffset += count
        delivered = try Checked.add(delivered, UInt64(count))
        if delivered == expectedSize { try verifyInputCompletion() }
        return count
    }

    private func verifyInputCompletion() throws {
        guard !completionVerified else { return }
        guard received == expectedSize, pending.isEmpty else { throw KaitoError.truncated }
        if !input.isFinished {
            var extra: UInt8 = 0
            let count = try withUnsafeMutableBytes(of: &extra) { try input.read(into: $0) }
            guard count == 0, input.isFinished else {
                throw KaitoError.malformed("Swap input exceeds its declared size")
            }
        }
        completionVerified = true
    }
}
