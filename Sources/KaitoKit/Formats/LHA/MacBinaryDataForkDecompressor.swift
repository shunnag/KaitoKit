import Foundation

// Clean-room format inputs:
// - the public MacBinary and MacBinary II standard proposals for the 128-byte
//   header, fork lengths, padding, compatible trailing extensions, header CRC,
//   and legacy-header recognition;
// - supplied MacLHA vectors and installed `lha` output used only as a
//   black-box oracle.
// No archive-decoder implementation source was used.

/// Streaming MacBinary data-fork view used for members written by MacLHA.
///
/// MacLHA stores a complete MacBinary envelope as the LHA member body.  The
/// classic command-line behavior is to expose only its data fork while still
/// authenticating the complete LHA output (header, padding, and resource fork).
/// A Macintosh OS marker alone is not enough: MacLHA can also store an
/// unwrapped file, so the 128-byte prefix is validated heuristically first.
///
/// This filter lives with the LHA reader rather than in `Codecs/` or beside
/// the other Mac envelopes: it implements no compression algorithm, and its
/// contract is LHA's. It drains the complete envelope under the member's
/// CRC16, and `LHAReader.stream` wraps it in `RecoveryDecompressor` for
/// recovered members. Field offsets and the header CRC come from
/// `MacBinaryHeader`; the acceptance rules below are MacLHA-specific.
final class MacBinaryDataForkDecompressor: Decompressor {
    private static let drainChunkSize = 64 * 1_024
    /// Reserved in MacBinary I and zero there; checked only when the header
    /// CRC field is zero (see `macBinaryLayout`).
    private static let macBinaryIReservedRange = 101..<126

    private let input: any Decompressor
    private let inputSize: UInt64
    private let expectedCRC16: UInt16?
    private let entryIndex: Int
    private let allowIncomplete: Bool
    private let unwrapsMacBinary: Bool
    private let dataOffset: UInt64

    /// Number of bytes visible through this filtered stream.
    let outputSize: UInt64

    private var prefix: [UInt8]
    private var prefixOffset = 0
    private var inputBytesRead: UInt64
    private var outputBytesDelivered: UInt64 = 0
    private var checksum: CRC16
    private var completionVerified = false

    init(
        input: any Decompressor,
        inputSize: UInt64,
        expectedCRC16: UInt16?,
        entryIndex: Int,
        allowIncomplete: Bool = false
    ) throws {
        self.allowIncomplete = allowIncomplete
        self.input = input
        self.inputSize = inputSize
        self.expectedCRC16 = expectedCRC16
        self.entryIndex = entryIndex

        let prefixSize = try Checked.toInt(min(
            inputSize,
            UInt64(MacBinaryHeader.size)
        ))
        var bytes = [UInt8](repeating: 0, count: prefixSize)
        var bytesRead = 0
        var sourceChecksum = CRC16()
        while bytesRead < prefixSize {
            let count = try bytes.withUnsafeMutableBytes { storage in
                let destination = UnsafeMutableRawBufferPointer(
                    rebasing: storage[bytesRead..<prefixSize]
                )
                return try input.read(into: destination)
            }
            guard count >= 0, count <= prefixSize - bytesRead else {
                throw KaitoError.malformed(
                    "MacBinary input returned an invalid byte count"
                )
            }
            guard count > 0 else {
                if allowIncomplete { break }
                throw KaitoError.truncated
            }
            bytes.withUnsafeBytes { storage in
                sourceChecksum.update(UnsafeRawBufferPointer(
                    rebasing: storage[bytesRead..<(bytesRead + count)]
                ))
            }
            bytesRead += count
        }

        if bytesRead < bytes.count { bytes.removeLast(bytes.count - bytesRead) }
        if let layout = Self.macBinaryLayout(
            header: bytes,
            inputSize: inputSize
        ) {
            unwrapsMacBinary = true
            dataOffset = layout.dataOffset
            outputSize = layout.dataSize
            prefix = []
        } else {
            unwrapsMacBinary = false
            dataOffset = 0
            outputSize = inputSize
            prefix = bytes
        }
        inputBytesRead = UInt64(bytesRead)
        checksum = sourceChecksum
    }

    var isFinished: Bool {
        completionVerified
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !completionVerified else { return 0 }

        if unwrapsMacBinary {
            try discardInput(until: dataOffset)
            guard outputBytesDelivered < outputSize else {
                try verifyInputCompletion()
                return 0
            }

            let remaining = try Checked.sub(outputSize, outputBytesDelivered)
            let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))
            let destination = UnsafeMutableRawBufferPointer(
                rebasing: buffer[..<requested]
            )
            let count = try readInput(into: destination)
            guard count > 0 else { throw KaitoError.truncated }
            outputBytesDelivered = try Checked.add(
                outputBytesDelivered,
                UInt64(count)
            )
            if outputBytesDelivered == outputSize {
                try verifyInputCompletion()
            }
            return count
        }

        if prefixOffset < prefix.count {
            let count = min(buffer.count, prefix.count - prefixOffset)
            buffer.copyBytes(from: prefix[prefixOffset..<(prefixOffset + count)])
            prefixOffset += count
            outputBytesDelivered = try Checked.add(
                outputBytesDelivered,
                UInt64(count)
            )
            if outputBytesDelivered == outputSize {
                try verifyInputCompletion()
            }
            return count
        }

        guard outputBytesDelivered < outputSize else {
            try verifyInputCompletion()
            return 0
        }
        let remaining = try Checked.sub(outputSize, outputBytesDelivered)
        let requested = try Checked.toInt(min(UInt64(buffer.count), remaining))
        let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[..<requested])
        let count = try readInput(into: destination)
        guard count > 0 else { throw KaitoError.truncated }
        outputBytesDelivered = try Checked.add(outputBytesDelivered, UInt64(count))
        if outputBytesDelivered == outputSize {
            try verifyInputCompletion()
        }
        return count
    }

    private func readInput(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let remaining = try Checked.sub(inputSize, inputBytesRead)
        guard UInt64(buffer.count) <= remaining else {
            throw KaitoError.malformed("MacBinary filter read exceeds its input")
        }
        let count = try input.read(into: buffer)
        guard count >= 0, count <= buffer.count else {
            throw KaitoError.malformed(
                "MacBinary input returned an invalid byte count"
            )
        }
        if count > 0 {
            checksum.update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
            inputBytesRead = try Checked.add(inputBytesRead, UInt64(count))
        }
        return count
    }

    private func discardInput(until target: UInt64) throws {
        guard target <= inputSize else {
            throw KaitoError.malformed("MacBinary data fork lies outside its input")
        }
        var scratch = [UInt8](repeating: 0, count: Self.drainChunkSize)
        while inputBytesRead < target {
            let remaining = try Checked.sub(target, inputBytesRead)
            let requested = try Checked.toInt(min(
                UInt64(scratch.count),
                remaining
            ))
            let count = try scratch.withUnsafeMutableBytes { storage in
                try readInput(into: UnsafeMutableRawBufferPointer(
                    rebasing: storage[..<requested]
                ))
            }
            guard count > 0 else { throw KaitoError.truncated }
        }
    }

    private func verifyInputCompletion() throws {
        guard !completionVerified else { return }
        do {
            try discardInput(until: inputSize)
        } catch KaitoError.truncated where allowIncomplete {
            completionVerified = true
            return
        }

        if !input.isFinished {
            var extra: UInt8 = 0
            let count = try withUnsafeMutableBytes(of: &extra) { storage in
                try input.read(into: storage)
            }
            guard count == 0, input.isFinished else {
                throw KaitoError.malformed(
                    "MacBinary input exceeds the declared LHA output size"
                )
            }
        }
        if let expectedCRC16, checksum.value != expectedCRC16 {
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        completionVerified = true
    }

    private static func macBinaryLayout(
        header: [UInt8],
        inputSize: UInt64
    ) -> (dataOffset: UInt64, dataSize: UInt64)? {
        let filenameLengthRange = 1...MacBinaryHeader.maximumFilenameLength
        guard header.count == MacBinaryHeader.size,
              MacBinaryHeader.requiredZeroOffsets.allSatisfy({ header[$0] == 0 }),
              filenameLengthRange.contains(Int(header[MacBinaryHeader.filenameLengthOffset])) else {
            return nil
        }

        let filenameLength = Int(header[MacBinaryHeader.filenameLengthOffset])
        let filenameEnd = MacBinaryHeader.filenameOffset + filenameLength
        guard !header[MacBinaryHeader.filenameOffset..<filenameEnd].contains(0) else {
            return nil
        }

        // MacBinary II/III authenticates bytes 0...123 with CRC-CCITT.  A
        // zero field denotes the older MacBinary I header emitted by MacLHA.
        let storedHeaderCRC = MacBinaryHeader.storedCRC(header)
        let computedHeaderCRC = MacBinaryHeader.computedCRC(header)
        if storedHeaderCRC == computedHeaderCRC {
            // A conforming CRC-CCITT can itself be zero. Compare before using
            // a zero stored field as the legacy MacBinary I discriminator.
        } else if storedHeaderCRC == 0 {
            // The MacBinary II proposal recommends these stronger checks when
            // distinguishing a CRC-less MacBinary I header from arbitrary
            // binary data. Bytes 101...125 were reserved/zero in version I;
            // a shorter significant name is followed by its zero-filled tail.
            let hasNameTerminator = filenameLength == MacBinaryHeader.maximumFilenameLength
                || header[filenameEnd] == 0
            guard hasNameTerminator,
                  header[macBinaryIReservedRange].allSatisfy({ $0 == 0 }) else {
                return nil
            }
        } else {
            return nil
        }

        let secondaryHeaderSize = UInt64(BigEndian.uint16(header, at: MacBinaryHeader.secondaryHeaderSizeOffset))
        let dataSize = UInt64(BigEndian.uint32(header, at: MacBinaryHeader.dataForkSizeOffset))
        let resourceSize = UInt64(BigEndian.uint32(header, at: MacBinaryHeader.resourceForkSizeOffset))
        let commentSize = UInt64(BigEndian.uint16(header, at: MacBinaryHeader.commentSizeOffset))

        guard let paddedSecondary = paddedBlockSize(secondaryHeaderSize),
              let paddedData = paddedBlockSize(dataSize),
              let paddedResource = paddedBlockSize(resourceSize),
              let paddedComment = paddedBlockSize(commentSize) else {
            return nil
        }
        let dataOffset = UInt64(MacBinaryHeader.size).addingReportingOverflow(
            paddedSecondary
        )
        guard !dataOffset.overflow else { return nil }
        var envelopeSize = dataOffset.partialValue
        for size in [paddedData, paddedResource, paddedComment] {
            let addition = envelopeSize.addingReportingOverflow(size)
            guard !addition.overflow else { return nil }
            envelopeSize = addition.partialValue
        }
        // The original proposal permits compatible version-zero extensions
        // after the defined envelope. They remain hidden, but the streaming
        // filter drains and authenticates them as part of the LHA member.
        guard envelopeSize <= inputSize else { return nil }
        return (dataOffset.partialValue, dataSize)
    }

    /// `size` rounded up to a multiple of `MacBinaryHeader.blockSize`, or nil
    /// on overflow.
    private static func paddedBlockSize(_ size: UInt64) -> UInt64? {
        let mask = UInt64(MacBinaryHeader.blockSize - 1)
        let addition = size.addingReportingOverflow(mask)
        guard !addition.overflow else { return nil }
        return addition.partialValue & ~mask
    }
}
