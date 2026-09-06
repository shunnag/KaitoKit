import Foundation

// 参照仕様: LZMA SDK の Methods.txt と各 ISA の公開命令形式。
// x86 は呼出し境界をまたぐ候補を 5-byte lookback state で追跡する。

/// 7z の単一入力 branch-conversion filter。
enum SevenZipBranchFilter: Sendable, Equatable {
    case x86
    case arm
    case armThumb
    case arm64
    case powerPC
}

/// 7z branch filter を固定長の出力ストリームとして逆変換する。
final class BCJFilterDecompressor: Decompressor {
    private static let inputChunkSize = 256 * 1_024

    private let input: any Decompressor
    private let filter: SevenZipBranchFilter
    private let startOffset: UInt32
    private let expectedSize: UInt64

    private var receivedSize: UInt64 = 0
    private var transformedSize: UInt64 = 0
    private var deliveredSize: UInt64 = 0
    private var pending = [UInt8]()
    private var ready = [UInt8]()
    private var readyOffset = 0
    private var x86State: UInt32 = 0
    private var completionVerified = false

    /// Creates a bounded branch-filter decoder.
    init(
        input: any Decompressor,
        filter: SevenZipBranchFilter,
        startOffset: UInt64 = 0,
        expectedSize: UInt64
    ) throws {
        guard startOffset <= UInt64(UInt32.max) else {
            throw KaitoError.malformed("BCJ start offset exceeds 32 bits")
        }
        switch filter {
        case .arm, .arm64, .powerPC:
            guard startOffset.isMultiple(of: 4) else {
                throw KaitoError.malformed("BCJ start offset is not 4-byte aligned")
            }
        case .armThumb:
            guard startOffset.isMultiple(of: 2) else {
                throw KaitoError.malformed("ARMT start offset is not 2-byte aligned")
            }
        case .x86:
            break
        }

        self.input = input
        self.filter = filter
        self.startOffset = UInt32(startOffset)
        self.expectedSize = expectedSize
        pending.reserveCapacity(Self.inputChunkSize + 8)
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

        while readyOffset == ready.count {
            ready.removeAll(keepingCapacity: true)
            readyOffset = 0
            try prepareOutput()
            if ready.isEmpty, !isFinished {
                // prepareOutput は入力を読むか byte を出すため、ここへ繰り返し到達しても
                // receivedSize が必ず増え、有限の lookahead の後に出力される。
                continue
            }
        }

        let available = ready.count - readyOffset
        let count = min(buffer.count, available)
        buffer.copyBytes(from: ready[readyOffset..<(readyOffset + count)])
        readyOffset += count
        deliveredSize = try Checked.add(deliveredSize, UInt64(count))
        if deliveredSize == expectedSize {
            try verifyInputCompletion()
        }
        return count
    }

    private func verifyInputCompletion() throws {
        guard !completionVerified else { return }
        guard receivedSize == expectedSize,
              transformedSize == expectedSize,
              pending.isEmpty,
              readyOffset == ready.count else {
            throw KaitoError.malformed("BCJ filter ended with buffered input")
        }
        if !input.isFinished {
            var extra: UInt8 = 0
            let count = try withUnsafeMutableBytes(of: &extra) { storage in
                try input.read(into: storage)
            }
            guard count == 0, input.isFinished else {
                throw KaitoError.malformed("BCJ input exceeds its declared size")
            }
        }
        completionVerified = true
    }

    private func prepareOutput() throws {
        if receivedSize < expectedSize {
            let remaining = try Checked.sub(expectedSize, receivedSize)
            let requested = try Checked.toInt(min(
                UInt64(Self.inputChunkSize),
                remaining
            ))
            var bytes = [UInt8](repeating: 0, count: requested)
            let count = try bytes.withUnsafeMutableBytes { storage in
                // storage は requested バイトの固定領域で、下位 decoder へ全域を公開する。
                try input.read(into: storage)
            }
            guard count > 0 else { throw KaitoError.truncated }
            guard count <= requested else {
                throw KaitoError.malformed("BCJ input returned too many bytes")
            }
            pending.append(contentsOf: bytes[..<count])
            receivedSize = try Checked.add(receivedSize, UInt64(count))
        }

        let isFinal = receivedSize == expectedSize
        let virtualOffset = startOffset &+ UInt32(truncatingIfNeeded: transformedSize)
        let consumed: Int

        switch filter {
        case .x86:
            consumed = Self.decodeX86(
                &pending,
                instructionPointer: virtualOffset,
                state: &x86State
            )
        case .arm:
            consumed = Self.decodeARM(&pending, instructionPointer: virtualOffset)
        case .armThumb:
            consumed = Self.decodeARMThumb(&pending, instructionPointer: virtualOffset)
        case .arm64:
            consumed = Self.decodeARM64(&pending, instructionPointer: virtualOffset)
        case .powerPC:
            consumed = Self.decodePowerPC(&pending, instructionPointer: virtualOffset)
        }

        guard consumed >= 0, consumed <= pending.count else {
            throw KaitoError.malformed("BCJ filter produced an invalid boundary")
        }

        if consumed > 0 {
            ready.append(contentsOf: pending[..<consumed])
            pending.removeFirst(consumed)
            transformedSize = try Checked.add(transformedSize, UInt64(consumed))
        }

        if isFinal, !pending.isEmpty {
            // 各 converter が残す末尾は完全な候補命令より短く、変換せず出力する。
            ready.append(contentsOf: pending)
            transformedSize = try Checked.add(transformedSize, UInt64(pending.count))
            pending.removeAll(keepingCapacity: true)
        }

        guard transformedSize <= expectedSize else {
            throw KaitoError.malformed("BCJ output exceeds its declared size")
        }
        if isFinal, transformedSize != expectedSize {
            throw KaitoError.truncated
        }
    }

    // x86 converter の state は直前 4 byte にある E8/E9 候補の mask。
    // 配列添字は limit=count-4 と各 mask table によって事前に限定される。
    private static func decodeX86(
        _ bytes: inout [UInt8],
        instructionPointer: UInt32,
        state: inout UInt32
    ) -> Int {
        guard bytes.count >= 5 else { return 0 }

        let allowed = [true, true, true, false, true, false, false, false]
        let bitNumbers = [0, 1, 2, 2, 3, 3, 3, 3]
        let limit = bytes.count - 4
        let base = instructionPointer &+ 5
        var position = 0
        var previousPosition = -1
        var previousMask = Int(state & 7)

        while true {
            while position < limit, (bytes[position] & 0xFE) != 0xE8 {
                position += 1
            }
            guard position < limit else { break }

            let distance = position - previousPosition
            if distance > 3 {
                previousMask = 0
            } else {
                previousMask = (previousMask << (distance - 1)) & 7
                if previousMask != 0 {
                    let testIndex = position + 4 - bitNumbers[previousMask]
                    if !allowed[previousMask] || isX86SignByte(bytes[testIndex]) {
                        previousPosition = position
                        previousMask = ((previousMask << 1) | 1) & 7
                        position += 1
                        continue
                    }
                }
            }

            previousPosition = position
            if isX86SignByte(bytes[position + 4]) {
                var source = readUInt32LE(bytes, at: position + 1)
                var destination: UInt32
                while true {
                    destination = source &- (base &+ UInt32(position))
                    guard previousMask != 0 else { break }

                    let shift = bitNumbers[previousMask] * 8
                    let signByte = UInt8(truncatingIfNeeded: destination >> (24 - shift))
                    guard isX86SignByte(signByte) else { break }
                    // previousMask != 0 なので shift は 8, 16, 24 のいずれか。
                    source = destination ^ ((UInt32(1) << (32 - shift)) &- 1)
                }
                writeUInt32LE(destination, into: &bytes, at: position + 1)
                position += 5
            } else {
                previousMask = ((previousMask << 1) | 1) & 7
                position += 1
            }
        }

        let trailingDistance = position - previousPosition
        state = trailingDistance > 3
            ? 0
            : UInt32((previousMask << (trailingDistance - 1)) & 7)
        return position
    }

    private static func decodeARM(
        _ bytes: inout [UInt8],
        instructionPointer: UInt32
    ) -> Int {
        let count = bytes.count - (bytes.count % 4)
        var index = 0
        while index < count {
            if bytes[index + 3] == 0xEB {
                let instruction = readUInt32LE(bytes, at: index)
                let encoded = (instruction & 0x00FF_FFFF) << 2
                let decoded = encoded &- (instructionPointer &+ UInt32(index) &+ 8)
                let immediate = (decoded >> 2) & 0x00FF_FFFF
                writeUInt32LE(0xEB00_0000 | immediate, into: &bytes, at: index)
            }
            index += 4
        }
        return count
    }

    private static func decodeARMThumb(
        _ bytes: inout [UInt8],
        instructionPointer: UInt32
    ) -> Int {
        var index = 0
        while index + 4 <= bytes.count {
            if (bytes[index + 1] & 0xF8) == 0xF0,
               (bytes[index + 3] & 0xF8) == 0xF8 {
                var encoded = UInt32(bytes[index + 1] & 7) << 19
                encoded |= UInt32(bytes[index]) << 11
                encoded |= UInt32(bytes[index + 3] & 7) << 8
                encoded |= UInt32(bytes[index + 2])
                encoded <<= 1

                let decoded = encoded &- (instructionPointer &+ UInt32(index) &+ 4)
                let immediate = decoded >> 1
                bytes[index] = UInt8(truncatingIfNeeded: immediate >> 11)
                bytes[index + 1] = 0xF0 | UInt8(truncatingIfNeeded: immediate >> 19) & 7
                bytes[index + 2] = UInt8(truncatingIfNeeded: immediate)
                bytes[index + 3] = 0xF8 | UInt8(truncatingIfNeeded: immediate >> 8) & 7
                index += 4
            } else {
                index += 2
            }
        }
        return index
    }

    private static func decodeARM64(
        _ bytes: inout [UInt8],
        instructionPointer: UInt32
    ) -> Int {
        let count = bytes.count - (bytes.count % 4)
        var index = 0
        while index < count {
            var instruction = readUInt32LE(bytes, at: index)
            let pc = instructionPointer &+ UInt32(index)

            if (instruction & 0xFC00_0000) == 0x9400_0000 {
                let encoded = instruction & 0x03FF_FFFF
                let decoded = encoded &- (pc >> 2)
                instruction = 0x9400_0000 | (decoded & 0x03FF_FFFF)
                writeUInt32LE(instruction, into: &bytes, at: index)
            } else if (instruction & 0x9F00_0000) == 0x9000_0000 {
                let encoded = ((instruction >> 29) & 3)
                    | (((instruction >> 5) & 0x7_FFFF) << 2)
                // 7z は ADRP の 21-bit page delta が ±2^17 pages の範囲だけを
                // 変換する。これを外すとデータ領域の偶然の opcode を破壊する。
                guard encoded < 0x2_0000 || encoded >= 0x1E_0000 else {
                    index += 4
                    continue
                }
                let decoded = encoded &- (pc >> 12)
                instruction &= ~UInt32(0x60FF_FFE0)
                instruction |= (decoded & 3) << 29
                instruction |= ((decoded >> 2) & 0x7_FFFF) << 5
                writeUInt32LE(instruction, into: &bytes, at: index)
            }
            index += 4
        }
        return count
    }

    private static func decodePowerPC(
        _ bytes: inout [UInt8],
        instructionPointer: UInt32
    ) -> Int {
        let count = bytes.count - (bytes.count % 4)
        var index = 0
        while index < count {
            let instruction = readUInt32BE(bytes, at: index)
            if (instruction & 0xFC00_0003) == 0x4800_0001 {
                let encoded = instruction & 0x03FF_FFFC
                let decoded = encoded &- (instructionPointer &+ UInt32(index))
                let replacement = 0x4800_0001 | (decoded & 0x03FF_FFFC)
                writeUInt32BE(replacement, into: &bytes, at: index)
            }
            index += 4
        }
        return count
    }

    private static func isX86SignByte(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 0xFF
    }

    private static func readUInt32LE(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func readUInt32BE(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    private static func writeUInt32LE(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at index: Int
    ) {
        bytes[index] = UInt8(truncatingIfNeeded: value)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func writeUInt32BE(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at index: Int
    ) {
        bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 3] = UInt8(truncatingIfNeeded: value)
    }
}
