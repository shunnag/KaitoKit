import Foundation

// 参照仕様: LZMA SDK の公開ドメイン BCJ2 format description。
// main stream の opcode と 3 本の side stream を逐次的に結合する。

/// A bounded streaming decoder for the four-input 7z BCJ2 filter.
final class BCJ2Decompressor: Decompressor {
    private static let outputChunkSize = 256 * 1_024
    private static let probabilityTotal: UInt32 = 1 << 11
    private static let probabilityMoveBits: UInt32 = 5
    private static let rangeTop: UInt32 = 1 << 24

    private let mainInput: FilterByteInput
    private let callInput: FilterByteInput
    private let jumpInput: FilterByteInput
    private let rangeInput: FilterByteInput
    private let expectedSize: UInt64
    private let startOffset: UInt32

    private var probabilities = [UInt16](repeating: 1 << 10, count: 258)
    private var range: UInt32 = UInt32.max
    private var code: UInt32 = 0
    private var rangeInitialized = false
    private var previousByte: UInt8 = 0
    private var decodedSize: UInt64 = 0
    private var deliveredSize: UInt64 = 0
    private var ready = [UInt8]()
    private var readyOffset = 0
    private var completionVerified = false

    /// Creates a BCJ2 decoder over four independently bounded coder streams.
    init(
        main: any Decompressor,
        call: any Decompressor,
        jump: any Decompressor,
        range: any Decompressor,
        expectedSize: UInt64,
        startOffset: UInt64 = 0
    ) throws {
        guard startOffset <= UInt64(UInt32.max) else {
            throw KaitoError.malformed("BCJ2 start offset exceeds 32 bits")
        }
        self.mainInput = FilterByteInput(main, label: "main")
        self.callInput = FilterByteInput(call, label: "call")
        self.jumpInput = FilterByteInput(jump, label: "jump")
        self.rangeInput = FilterByteInput(range, label: "range")
        self.expectedSize = expectedSize
        self.startOffset = UInt32(startOffset)
        ready.reserveCapacity(Self.outputChunkSize + 5)
    }

    var isFinished: Bool {
        deliveredSize == expectedSize && completionVerified
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        if deliveredSize == expectedSize {
            try verifyInputCompletion()
            return 0
        }

        if readyOffset == ready.count {
            ready.removeAll(keepingCapacity: true)
            readyOffset = 0
        }
        let capacity = min(buffer.count, Self.outputChunkSize)
        while ready.count - readyOffset < capacity, decodedSize < expectedSize {
            try decodeUnit()
        }

        let remaining = try Checked.sub(expectedSize, deliveredSize)
        let count = min(
            ready.count - readyOffset,
            capacity,
            try Checked.toInt(remaining)
        )
        guard count > 0 else { throw KaitoError.truncated }
        buffer.copyBytes(from: ready[readyOffset..<(readyOffset + count)])
        readyOffset += count
        deliveredSize = try Checked.add(deliveredSize, UInt64(count))

        if readyOffset == ready.count {
            ready.removeAll(keepingCapacity: true)
            readyOffset = 0
        }
        if deliveredSize == expectedSize {
            try verifyInputCompletion()
        }
        return count
    }

    private func verifyInputCompletion() throws {
        guard !completionVerified else { return }
        guard decodedSize == expectedSize,
              readyOffset == ready.count else {
            throw KaitoError.malformed("BCJ2 ended with buffered output")
        }
        if !rangeInitialized {
            try initializeRangeDecoder()
        }
        try mainInput.verifyFinished()
        try callInput.verifyFinished()
        try jumpInput.verifyFinished()
        try rangeInput.verifyFinished()
        completionVerified = true
    }

    private func decodeUnit() throws {
        if !rangeInitialized {
            try initializeRangeDecoder()
        }

        let opcodePosition = decodedSize
        let byte = try mainInput.readByte()
        ready.append(byte)
        decodedSize = try Checked.add(decodedSize, 1)

        let probabilityIndex: Int?
        let sideInput: FilterByteInput?
        if byte == 0xE8 {
            probabilityIndex = 2 + Int(previousByte)
            sideInput = callInput
        } else if byte == 0xE9 {
            probabilityIndex = 1
            sideInput = jumpInput
        } else if previousByte == 0x0F, (byte & 0xF0) == 0x80 {
            probabilityIndex = 0
            sideInput = jumpInput
        } else {
            probabilityIndex = nil
            sideInput = nil
        }

        guard let probabilityIndex, let sideInput else {
            previousByte = byte
            return
        }

        let converted = try decodeDecision(probabilityIndex)
        guard converted else {
            previousByte = byte
            return
        }

        let afterOpcode = try Checked.sub(expectedSize, decodedSize)
        guard afterOpcode >= 4 else {
            throw KaitoError.malformed("BCJ2 branch exceeds declared output size")
        }
        let absolute = try sideInput.readUInt32BE()
        let nextInstruction = startOffset
            &+ UInt32(truncatingIfNeeded: opcodePosition)
            &+ 5
        let relative = absolute &- nextInstruction
        ready.append(UInt8(truncatingIfNeeded: relative))
        ready.append(UInt8(truncatingIfNeeded: relative >> 8))
        ready.append(UInt8(truncatingIfNeeded: relative >> 16))
        ready.append(UInt8(truncatingIfNeeded: relative >> 24))
        previousByte = UInt8(truncatingIfNeeded: relative >> 24)
        decodedSize = try Checked.add(decodedSize, 4)
    }

    private func initializeRangeDecoder() throws {
        let marker = try rangeInput.readByte()
        guard marker == 0 else {
            throw KaitoError.malformed("invalid BCJ2 range-coder marker")
        }
        var initialCode: UInt32 = 0
        for _ in 0..<4 {
            initialCode = (initialCode << 8) | UInt32(try rangeInput.readByte())
        }
        guard initialCode != UInt32.max else {
            throw KaitoError.malformed("invalid BCJ2 range-coder initialization")
        }
        code = initialCode
        range = UInt32.max
        rangeInitialized = true
    }

    private func decodeDecision(_ probabilityIndex: Int) throws -> Bool {
        guard probabilities.indices.contains(probabilityIndex) else {
            throw KaitoError.malformed("BCJ2 probability index is out of range")
        }
        while range < Self.rangeTop {
            range <<= 8
            code = (code << 8) | UInt32(try rangeInput.readByte())
        }

        let probability = UInt32(probabilities[probabilityIndex])
        let bound = (range >> 11) * probability
        if code < bound {
            range = bound
            let updated = probability
                + ((Self.probabilityTotal - probability) >> Self.probabilityMoveBits)
            probabilities[probabilityIndex] = UInt16(updated)
            return false
        }

        range &-= bound
        code &-= bound
        let updated = probability - (probability >> Self.probabilityMoveBits)
        probabilities[probabilityIndex] = UInt16(updated)
        return true
    }
}

// Decompressor の短い read を吸収し、range/side stream の読み越しをしない。
private final class FilterByteInput {
    private static let bufferSize = 64 * 1_024

    private let input: any Decompressor
    private let label: String
    private var buffer = [UInt8](repeating: 0, count: bufferSize)
    private var offset = 0
    private var count = 0

    init(_ input: any Decompressor, label: String) {
        self.input = input
        self.label = label
    }

    func readByte() throws -> UInt8 {
        if offset == count {
            offset = 0
            count = try buffer.withUnsafeMutableBytes { storage in
                // buffer は固定長で、下位 decoder はこの領域内だけへ書き込む。
                try input.read(into: storage)
            }
            guard count > 0 else {
                throw KaitoError.malformed("BCJ2 \(label) stream is truncated")
            }
            guard count <= buffer.count else {
                throw KaitoError.malformed("BCJ2 input returned too many bytes")
            }
        }
        let byte = buffer[offset]
        offset += 1
        return byte
    }

    func readUInt32BE() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(try readByte())
        }
        return value
    }

    func verifyFinished() throws {
        guard offset == count else {
            throw KaitoError.malformed("BCJ2 \(label) stream has unused bytes")
        }
        if input.isFinished { return }
        var extra: UInt8 = 0
        let actual = try withUnsafeMutableBytes(of: &extra) { storage in
            try input.read(into: storage)
        }
        guard actual == 0, input.isFinished else {
            throw KaitoError.malformed("BCJ2 \(label) stream exceeds its declared size")
        }
    }
}
