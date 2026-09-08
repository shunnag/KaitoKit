import Foundation

// Provenance / behavioral references:
// - RARLab, "RAR 5.0 archive format" technote, together with the KaitoKit M3
//   requirements supplied for the fixed RAR5 Delta, E8, E8E9, and ARM filters.
// - libarchive archive_read_support_format_rar.c (BSD-2-Clause), consulted only
//   for RAR3 standard-filter behavior and program fingerprints.
// - bitplane/rar-research's unofficial clean-room RAR 1.5-4.x format notes.
// - The existing KaitoKit BCJ/Delta filters and XZ Utils' 0BSD IA-64 BCJ
//   description for the architecture-level branch encodings.
// RAR5 decoder sources, 7-Zip Rar29, unrar, XADMaster, and The Unarchiver were
// not used for this implementation.

enum RARStandardFilterKind: UInt8, Sendable, Equatable {
    case delta = 0
    case e8 = 1
    case e8e9 = 2
    case arm = 3
    case audio = 4
    case rgb = 5
    case itanium = 6
}

enum RARFilterAddressMode: Sendable {
    case rar3
    case rar5
}

/// Native, size-preserving implementations of the standard RAR filters.
/// Parameter and buffer bounds are checked once before each transform loop.
enum RARStandardFilters {
    static let rar3VirtualMemorySize = 0x40_000
    static let rar3WorkAreaSize = 0x3C_000
    static let rar5MaximumBlockSize = 4 * 1_024 * 1_024

    private struct ProgramID: Hashable {
        let byteCount: Int
        let crc32: UInt32
    }

    private static let stockRAR3Programs: [ProgramID: RARStandardFilterKind] = [
        ProgramID(byteCount: 53, crc32: 0xAD57_6887): .e8,
        ProgramID(byteCount: 57, crc32: 0x3CD7_E57E): .e8e9,
        ProgramID(byteCount: 120, crc32: 0x3769_893F): .itanium,
        ProgramID(byteCount: 29, crc32: 0x0E06_077D): .delta,
        ProgramID(byteCount: 149, crc32: 0x1C2C_5DC8): .rgb,
        ProgramID(byteCount: 216, crc32: 0xBC85_E701): .audio,
    ]

    static func recognizeRAR3Program(_ bytes: [UInt8]) -> RARStandardFilterKind? {
        recognizeRAR3Program(
            byteCount: bytes.count,
            crc32: CRC32.checksum(bytes)
        )
    }

    /// Testable fingerprint lookup kept separate from CRC calculation so every
    /// published stock-program (length, CRC32) pair has a direct regression.
    static func recognizeRAR3Program(
        byteCount: Int,
        crc32: UInt32
    ) -> RARStandardFilterKind? {
        stockRAR3Programs[ProgramID(byteCount: byteCount, crc32: crc32)]
    }

    static func requireRAR3Program(_ bytes: [UInt8]) throws -> RARStandardFilterKind {
        guard let result = recognizeRAR3Program(bytes) else {
            throw KaitoError.unsupportedMethod("RAR3 custom VM filter")
        }
        return result
    }

    static func apply(
        _ filter: RARStandardFilterKind,
        to bytes: inout [UInt8],
        fileOffset: UInt64 = 0,
        channels: Int = 1,
        width: Int = 0,
        positionR: Int = 0,
        addressMode: RARFilterAddressMode = .rar5
    ) throws {
        switch filter {
        case .delta:
            try delta(&bytes, channels: channels)
        case .e8, .e8e9:
            try e8(
                &bytes,
                fileOffset: fileOffset,
                includeE9: filter == .e8e9,
                addressMode: addressMode
            )
        case .arm:
            try arm(&bytes, fileOffset: fileOffset)
        case .itanium:
            try itanium(&bytes, fileOffset: fileOffset)
        case .rgb:
            try rgb(&bytes, width: width, positionR: positionR)
        case .audio:
            try audio(&bytes, channels: channels)
        }
    }

    /// Decodes channel-major deltas to interleaved samples.
    static func delta(_ bytes: inout [UInt8], channels: Int) throws {
        var decoded = [UInt8](repeating: 0, count: bytes.count)
        try bytes.withUnsafeBytes { source in
            try decoded.withUnsafeMutableBytes { destination in
                try decodeDelta(input: source, output: destination, channels: channels)
            }
        }
        bytes = decoded
    }

    static func decodeDelta(
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        channels: Int
    ) throws {
        guard input.count == output.count else {
            throw KaitoError.malformed("RAR Delta input/output sizes differ")
        }
        guard (1...128).contains(channels) else {
            throw KaitoError.malformed("RAR Delta channel count is outside 1...128")
        }
        guard input.isEmpty || (input.baseAddress != nil && output.baseAddress != nil) else {
            throw KaitoError.malformed("RAR Delta buffer is invalid")
        }
        guard !input.isEmpty else { return }

        let encoded = input.bindMemory(to: UInt8.self)
        let decoded = output.bindMemory(to: UInt8.self)
        var encodedIndex = 0
        for channel in 0..<min(channels, input.count) {
            var sample: UInt8 = 0
            var decodedIndex = channel
            while decodedIndex < input.count {
                sample &-= encoded[encodedIndex]
                decoded[decodedIndex] = sample
                encodedIndex += 1
                decodedIndex += channels
            }
        }
        precondition(encodedIndex == input.count)
    }

    static func e8(
        _ bytes: inout [UInt8],
        fileOffset: UInt64,
        includeE9: Bool,
        addressMode: RARFilterAddressMode = .rar5
    ) throws {
        try bytes.withUnsafeMutableBytes {
            try e8($0, fileOffset: fileOffset, includeE9: includeE9, addressMode: addressMode)
        }
    }

    static func e8(
        _ storage: UnsafeMutableRawBufferPointer,
        fileOffset: UInt64,
        includeE9: Bool,
        addressMode: RARFilterAddressMode = .rar5
    ) throws {
        guard storage.isEmpty || storage.baseAddress != nil else {
            throw KaitoError.malformed("RAR x86 filter buffer is invalid")
        }
        guard storage.count >= 5 else { return }

        let bytes = storage.bindMemory(to: UInt8.self)
        let translationRange: UInt32 = 1 << 24
        var cursor = 0
        while cursor + 4 < storage.count {
            let opcode = bytes[cursor]
            if opcode != 0xE8 && !(includeE9 && opcode == 0xE9) {
                cursor += 1
                continue
            }

            let operand = cursor + 1
            let encodedAddress = loadUInt32LE(bytes, operand)
            let unboundedPosition = UInt32(truncatingIfNeeded: fileOffset)
                &+ UInt32(operand)

            var replacement: UInt32?
            switch addressMode {
            case .rar3:
                let position = unboundedPosition
                if encodedAddress < translationRange {
                    replacement = encodedAddress &- position
                } else if encodedAddress & 0x8000_0000 != 0 {
                    let absoluteMagnitude = (~encodedAddress) &+ 1
                    if absoluteMagnitude <= position {
                        replacement = encodedAddress &+ translationRange
                    }
                }
            case .rar5:
                // RAR5 x86 addresses are relative to a 24-bit position. This
                // reduction applies both to the signed-range test and to the
                // subtraction, including when a filter block crosses 16 MiB.
                let position = unboundedPosition & 0x00FF_FFFF
                if encodedAddress & 0x8000_0000 != 0 {
                    if (encodedAddress &+ position) & 0x8000_0000 == 0 {
                        replacement = encodedAddress &+ translationRange
                    }
                } else if (encodedAddress &- translationRange) & 0x8000_0000 != 0 {
                    replacement = encodedAddress &- position
                }
            }
            if let replacement {
                storeUInt32LE(replacement, bytes, operand)
            }
            cursor += 5
        }
    }

    /// RAR5 stores the ARM branch displacement in instruction words.
    static func arm(_ bytes: inout [UInt8], fileOffset: UInt64) throws {
        try bytes.withUnsafeMutableBytes { try arm($0, fileOffset: fileOffset) }
    }

    static func arm(
        _ storage: UnsafeMutableRawBufferPointer,
        fileOffset: UInt64
    ) throws {
        guard storage.isEmpty || storage.baseAddress != nil else {
            throw KaitoError.malformed("RAR ARM filter buffer is invalid")
        }
        let bytes = storage.bindMemory(to: UInt8.self)
        let limit = storage.count & ~3
        let firstInstruction = UInt32(truncatingIfNeeded: fileOffset >> 2)
        var cursor = 0
        while cursor < limit {
            if bytes[cursor + 3] == 0xEB {
                let instruction = loadUInt32LE(bytes, cursor)
                let encoded = instruction & 0x00FF_FFFF
                let position = firstInstruction &+ UInt32(cursor >> 2)
                let decoded = (encoded &- position) & 0x00FF_FFFF
                storeUInt32LE(0xEB00_0000 | decoded, bytes, cursor)
            }
            cursor += 4
        }
    }

    static func itanium(_ bytes: inout [UInt8], fileOffset: UInt64) throws {
        try bytes.withUnsafeMutableBytes { try itanium($0, fileOffset: fileOffset) }
    }

    static func itanium(
        _ storage: UnsafeMutableRawBufferPointer,
        fileOffset: UInt64
    ) throws {
        guard storage.isEmpty || storage.baseAddress != nil else {
            throw KaitoError.malformed("RAR Itanium filter buffer is invalid")
        }
        let bytes = storage.bindMemory(to: UInt8.self)
        let branchMask: [UInt8] = [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0,
        ]
        let limit = storage.count & ~15
        var bundleOffset = 0

        while bundleOffset < limit {
            let slots = branchMask[Int(bytes[bundleOffset] & 0x1F)]
            for slot in 0..<3 where slots & UInt8(1 << slot) != 0 {
                let bitOffset = 5 + slot * 41
                let byteOffset = bitOffset >> 3
                let intraByte = bitOffset & 7
                var sixBytes: UInt64 = 0
                for index in 0..<6 {
                    sixBytes |= UInt64(bytes[bundleOffset + byteOffset + index])
                        << UInt64(index * 8)
                }

                var instruction = sixBytes >> UInt64(intraByte)
                guard (instruction >> 37) & 0xF == 5,
                      (instruction >> 9) & 7 == 0 else { continue }

                var branch = UInt32((instruction >> 13) & 0xF_FFFF)
                branch |= UInt32((instruction >> 36) & 1) << 20
                branch <<= 4
                let bundlePosition = UInt32(truncatingIfNeeded: fileOffset)
                    &+ UInt32(bundleOffset)
                branch = (branch &- bundlePosition) >> 4

                instruction &= ~(UInt64(0x8F_FFFF) << 13)
                instruction |= UInt64(branch & 0xF_FFFF) << 13
                instruction |= UInt64(branch & 0x10_0000) << 16
                let preservedLowBits = sixBytes & ((UInt64(1) << UInt64(intraByte)) - 1)
                sixBytes = preservedLowBits | (instruction << UInt64(intraByte))

                for index in 0..<6 {
                    bytes[bundleOffset + byteOffset + index] = UInt8(
                        truncatingIfNeeded: sixBytes >> UInt64(index * 8)
                    )
                }
            }
            bundleOffset += 16
        }
    }

    static func rgb(_ bytes: inout [UInt8], width: Int, positionR: Int) throws {
        guard bytes.count >= 3,
              (1...bytes.count).contains(width),
              (0...2).contains(positionR) else {
            throw KaitoError.malformed("RAR RGB filter parameters are invalid")
        }

        let encoded = bytes
        var decoded = [UInt8](repeating: 0, count: encoded.count)
        var encodedIndex = 0
        for component in 0..<3 {
            var predictor: UInt8 = 0
            var upperIndex = component - width
            var outputIndex = component
            while outputIndex < decoded.count {
                if upperIndex >= 0, upperIndex + 3 < decoded.count {
                    let upper = decoded[upperIndex]
                    let upperRight = decoded[upperIndex + 3]
                    let verticalChange = abs(Int(upperRight) - Int(upper))
                    let leftChange = abs(Int(predictor) - Int(upper))
                    let diagonalChange = abs(
                        Int(upperRight) + Int(predictor) - 2 * Int(upper)
                    )
                    if verticalChange > leftChange || verticalChange > diagonalChange {
                        predictor = leftChange <= diagonalChange ? upperRight : upper
                    }
                }
                predictor &-= encoded[encodedIndex]
                decoded[outputIndex] = predictor
                encodedIndex += 1
                outputIndex += 3
                upperIndex += 3
            }
        }
        precondition(encodedIndex == encoded.count)

        var red = positionR
        while red + 2 < decoded.count {
            decoded[red] &+= decoded[red + 1]
            decoded[red + 2] &+= decoded[red + 1]
            red += 3
        }
        bytes = decoded
    }

    static func audio(_ bytes: inout [UInt8], channels: Int) throws {
        guard (1...128).contains(channels) else {
            throw KaitoError.malformed("RAR Audio channel count is outside 1...128")
        }

        let encoded = bytes
        var decoded = [UInt8](repeating: 0, count: encoded.count)
        var encodedIndex = 0
        for channel in 0..<min(channels, encoded.count) {
            var coefficients = [Int](repeating: 0, count: 3)
            var differences = [Int](repeating: 0, count: 3)
            var previousDifference = 0
            var accumulatedErrors = [Int](repeating: 0, count: 7)
            var sampleCount = 0
            var previousSample: UInt8 = 0
            var outputIndex = channel

            while outputIndex < decoded.count {
                let residual = Int(Int8(bitPattern: encoded[encodedIndex]))
                encodedIndex += 1
                differences[2] = differences[1]
                differences[1] = previousDifference - differences[0]
                differences[0] = previousDifference

                let prediction = (
                    8 * Int(previousSample)
                        + coefficients[0] * differences[0]
                        + coefficients[1] * differences[1]
                        + coefficients[2] * differences[2]
                ) >> 3
                let sample = UInt8(truncatingIfNeeded: prediction - residual)
                let scaledResidual = residual * 8
                accumulatedErrors[0] += abs(scaledResidual)
                accumulatedErrors[1] += abs(scaledResidual - differences[0])
                accumulatedErrors[2] += abs(scaledResidual + differences[0])
                accumulatedErrors[3] += abs(scaledResidual - differences[1])
                accumulatedErrors[4] += abs(scaledResidual + differences[1])
                accumulatedErrors[5] += abs(scaledResidual - differences[2])
                accumulatedErrors[6] += abs(scaledResidual + differences[2])

                previousDifference = Int(Int8(
                    truncatingIfNeeded: Int(sample) - Int(previousSample)
                ))
                previousSample = sample
                decoded[outputIndex] = sample

                if sampleCount & 31 == 0 {
                    var best = 0
                    for candidate in 1..<accumulatedErrors.count
                    where accumulatedErrors[candidate] < accumulatedErrors[best] {
                        best = candidate
                    }
                    accumulatedErrors = [Int](repeating: 0, count: 7)
                    switch best {
                    case 1 where coefficients[0] >= -16: coefficients[0] -= 1
                    case 2 where coefficients[0] < 16: coefficients[0] += 1
                    case 3 where coefficients[1] >= -16: coefficients[1] -= 1
                    case 4 where coefficients[1] < 16: coefficients[1] += 1
                    case 5 where coefficients[2] >= -16: coefficients[2] -= 1
                    case 6 where coefficients[2] < 16: coefficients[2] += 1
                    default: break
                    }
                }
                sampleCount += 1
                outputIndex += channels
            }
        }
        precondition(encodedIndex == encoded.count)
        bytes = decoded
    }

    private static func loadUInt32LE(
        _ bytes: UnsafeMutableBufferPointer<UInt8>,
        _ index: Int
    ) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    private static func storeUInt32LE(
        _ value: UInt32,
        _ bytes: UnsafeMutableBufferPointer<UInt8>,
        _ index: Int
    ) {
        bytes[index] = UInt8(truncatingIfNeeded: value)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[index + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
