import Foundation

// Provenance:
// - RAR 1.5-4.x unofficial format notes, especially sections 18-20:
//   https://github.com/bitplane/rar-research/blob/master/doc/RAR15_40_FORMAT_SPECIFICATION.md
// - libarchive's BSD-2-licensed archive_read_support_format_rar.c was consulted
//   for behaviour (filter descriptors and validation), not for code or structure:
//   https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_rar.c
// No 7-Zip Rar29, unrar source, XADMaster, or The Unarchiver source was used.

/// One RARVM filter descriptor, decoded from the payload of an LZ symbol 257
/// or a PPMd escape 3 and resolved against the solid filter-program table.
///
/// Whether a payload carries bytecode depends on the program table, so parsing
/// reads it through `Context`, but never changes it. The table effects are
/// returned (`resetsPrograms`, `programIndex`, `isNewProgram`) and
/// `RAR29Decoder` applies them only after every check here has passed. Checks
/// run in payload order, so the first failing field decides the error.
struct RAR3FilterToken {
    /// Decoder state the payload grammar and its checks depend on.
    struct Context {
        let outputPosition: UInt64
        let expectedSize: UInt64
        let windowSize: Int
        let programs: [RAR29Decoder.StoredFilterProgram]
        let lastProgram: Int
        let maximumProgramCount: Int
        /// A program-table reset must not interrupt a filter that is being
        /// captured or emitted.
        let canResetPrograms: Bool
    }

    /// Added to the stored start when flag 0x40 is set.
    private static let startBias: UInt64 = 258
    private static let maximumBytecodeLength = 65_536
    private static let maximumGlobalDataLength = 0x1FC0

    /// The payload's program number 0 clears the program table first.
    let resetsPrograms: Bool
    let programIndex: Int
    /// The payload defines the program at `programIndex` (index == table count).
    let isNewProgram: Bool
    let start: UInt64
    let blockLength: Int
    let usageCount: UInt32
    let registers: [UInt32]
    let kind: RARStandardFilterKind

    static func parse(
        _ payload: [UInt8],
        flags: UInt8,
        context: Context
    ) throws -> RAR3FilterToken {
        var cursor = RAR3MemoryBitCursor(bytes: payload)
        var programCount = context.programs.count
        var resetsPrograms = false
        var programIndex = context.lastProgram
        if flags & 0x80 != 0 {
            let storedNumber = try cursor.readRARVMNumber()
            if storedNumber == 0 {
                guard context.canResetPrograms else {
                    throw KaitoError.malformed(
                        "RAR3 filter program reset interrupts an active filter"
                    )
                }
                resetsPrograms = true
                programCount = 0
                programIndex = 0
            } else {
                guard let exactIndex = Int(exactly: storedNumber - 1) else {
                    throw KaitoError.malformed("RAR3 filter program number is too large")
                }
                programIndex = exactIndex
            }
            guard programIndex <= programCount else {
                throw KaitoError.malformed("RAR3 filter program number is invalid")
            }
        } else {
            guard programIndex <= programCount else {
                throw KaitoError.malformed("RAR3 previous filter program is unavailable")
            }
        }

        let storedStart = try cursor.readRARVMNumber()
        guard storedStart & 0x8000_0000 == 0 else {
            throw KaitoError.malformed("RAR3 filter start is negative")
        }
        var relativeStart = UInt64(storedStart)
        if flags & 0x40 != 0 {
            relativeStart = try Checked.add(relativeStart, startBias)
        }
        let start = try Checked.add(context.outputPosition, relativeStart)

        let isNewProgram = programIndex == programCount
        let blockLength: Int
        if flags & 0x20 != 0 {
            let storedLength = try cursor.readRARVMNumber()
            guard let exactLength = Int(exactly: storedLength) else {
                throw KaitoError.malformed("RAR3 filter length is too large")
            }
            blockLength = exactLength
        } else {
            guard !isNewProgram else {
                throw KaitoError.malformed("new RAR3 filter omits its block length")
            }
            blockLength = context.programs[programIndex].previousLength
        }
        guard blockLength > 0,
              blockLength <= context.windowSize,
              blockLength <= RARStandardFilters.rar3WorkAreaSize else {
            throw KaitoError.malformed("RAR3 filter length is outside its work area")
        }

        let usageCount: UInt32
        if isNewProgram {
            usageCount = 0
        } else {
            let (incremented, overflow) = context.programs[programIndex]
                .usageCount.addingReportingOverflow(1)
            guard !overflow else {
                throw KaitoError.limitExceeded("RAR3 filter usage count")
            }
            usageCount = incremented
        }
        var registers = [UInt32](repeating: 0, count: 8)
        registers[3] = UInt32(RARStandardFilters.rar3WorkAreaSize)
        registers[4] = UInt32(blockLength)
        registers[5] = usageCount
        registers[7] = UInt32(RARStandardFilters.rar3VirtualMemorySize)

        if flags & 0x10 != 0 {
            let mask = try cursor.read(7)
            for register in 0..<7 where mask & UInt32(1 << register) != 0 {
                registers[register] = try cursor.readRARVMNumber()
            }
        }

        let kind: RARStandardFilterKind
        if isNewProgram {
            let storedBytecodeLength = try cursor.readRARVMNumber()
            guard let bytecodeLength = Int(exactly: storedBytecodeLength),
                  (1...maximumBytecodeLength).contains(bytecodeLength),
                  bytecodeLength <= cursor.remainingByteCapacity else {
                throw KaitoError.malformed("RAR3 VM bytecode length is invalid")
            }
            var bytecode = [UInt8]()
            bytecode.reserveCapacity(bytecodeLength)
            for _ in 0..<bytecodeLength {
                bytecode.append(UInt8(truncatingIfNeeded: try cursor.read(8)))
            }
            guard let checksum = bytecode.first,
                  bytecode.dropFirst().reduce(UInt8(0), ^) == checksum else {
                throw KaitoError.malformed("RAR3 VM bytecode checksum mismatch")
            }
            kind = try RARStandardFilters.requireRAR3Program(bytecode)
            guard programCount < context.maximumProgramCount else {
                throw KaitoError.limitExceeded("RAR3 filter program count")
            }
        } else {
            kind = context.programs[programIndex].kind
        }

        if flags & 0x08 != 0 {
            let storedGlobalLength = try cursor.readRARVMNumber()
            guard let globalLength = Int(exactly: storedGlobalLength),
                  globalLength <= maximumGlobalDataLength,
                  globalLength <= cursor.remainingByteCapacity else {
                throw KaitoError.malformed("RAR3 filter global data is invalid")
            }
            for _ in 0..<globalLength {
                _ = try cursor.read(8)
            }
        }

        // Native standard filters are size preserving. R3/R4/R5/R6 are VM
        // execution state supplied by the decoder; accepting altered values
        // would silently change a recognized program's semantics.
        guard registers[3] == UInt32(RARStandardFilters.rar3WorkAreaSize),
              registers[4] == UInt32(blockLength),
              registers[5] == usageCount,
              registers[6] == 0 else {
            throw KaitoError.unsupportedMethod("RAR3 custom VM filter registers")
        }

        switch kind {
        case .delta, .rgb, .audio:
            guard blockLength <= RARStandardFilters.rar3WorkAreaSize / 2 else {
                throw KaitoError.malformed("RAR3 filter output exceeds its work area")
            }
        case .e8, .e8e9:
            guard blockLength > 4 else {
                throw KaitoError.malformed("RAR3 x86 filter block is too short")
            }
        case .itanium:
            break
        case .arm:
            throw KaitoError.unsupportedMethod("RAR3 ARM filter")
        }

        let end = try Checked.add(start, UInt64(blockLength))
        guard end <= context.expectedSize else {
            throw KaitoError.malformed("RAR3 filter range exceeds output")
        }
        return RAR3FilterToken(
            resetsPrograms: resetsPrograms,
            programIndex: programIndex,
            isNewProgram: isNewProgram,
            start: start,
            blockLength: blockLength,
            usageCount: usageCount,
            registers: registers,
            kind: kind
        )
    }
}

/// MSB-first bit cursor for the byte-bounded payload embedded in a RAR3
/// filter token. Unlike the sentinel-backed LZ cursor, every read is checked
/// against the descriptor's declared byte length.
private struct RAR3MemoryBitCursor {
    let bytes: [UInt8]
    private(set) var bitOffset = 0

    var remainingByteCapacity: Int {
        max(0, (bytes.count * 8 - bitOffset) / 8)
    }

    mutating func read(_ count: Int) throws -> UInt32 {
        guard (0...32).contains(count),
              bitOffset <= bytes.count * 8,
              count <= bytes.count * 8 - bitOffset else {
            throw KaitoError.malformed("RAR3 filter payload is truncated")
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset >> 3]
            let shift = 7 - (bitOffset & 7)
            value = value << 1 | UInt32(byte >> shift & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func readRARVMNumber() throws -> UInt32 {
        switch try read(2) {
        case 0:
            return try read(4)
        case 1:
            let value = try read(8)
            if value >= 16 { return value }
            return 0xFFFF_FF00 | value << 4 | (try read(4))
        case 2:
            return try read(16)
        default:
            return try read(32)
        }
    }
}
