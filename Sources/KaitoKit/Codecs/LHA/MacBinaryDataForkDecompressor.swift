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
final class MacBinaryDataForkDecompressor: Decompressor {
    private static let headerSize = 128
    private static let drainChunkSize = 64 * 1_024

    private let input: any Decompressor
    private let inputSize: UInt64
    private let expectedCRC16: UInt16
    private let entryIndex: Int
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
        expectedCRC16: UInt16,
        entryIndex: Int
    ) throws {
        self.input = input
        self.inputSize = inputSize
        self.expectedCRC16 = expectedCRC16
        self.entryIndex = entryIndex

        let prefixSize = try Checked.toInt(min(
            inputSize,
            UInt64(Self.headerSize)
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
            guard count > 0 else { throw KaitoError.truncated }
            bytes.withUnsafeBytes { storage in
                sourceChecksum.update(UnsafeRawBufferPointer(
                    rebasing: storage[bytesRead..<(bytesRead + count)]
                ))
            }
            bytesRead += count
        }

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
        try discardInput(until: inputSize)

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
        guard checksum.value == expectedCRC16 else {
            throw KaitoError.checksumMismatch(entry: entryIndex)
        }
        completionVerified = true
    }

    private static func macBinaryLayout(
        header: [UInt8],
        inputSize: UInt64
    ) -> (dataOffset: UInt64, dataSize: UInt64)? {
        guard header.count == headerSize,
              header[0] == 0,
              (1...63).contains(Int(header[1])),
              header[74] == 0,
              header[82] == 0 else {
            return nil
        }

        let filenameLength = Int(header[1])
        guard !header[2..<(2 + filenameLength)].contains(0) else {
            return nil
        }

        // MacBinary II/III authenticates bytes 0...123 with CRC-CCITT.  A
        // zero field denotes the older MacBinary I header emitted by MacLHA.
        let storedHeaderCRC = bigUInt16(header, at: 124)
        let computedHeaderCRC = macBinaryHeaderCRC(header[..<124])
        if storedHeaderCRC == computedHeaderCRC {
            // A conforming CRC-CCITT can itself be zero. Compare before using
            // a zero stored field as the legacy MacBinary I discriminator.
        } else if storedHeaderCRC == 0 {
            // The MacBinary II proposal recommends these stronger checks when
            // distinguishing a CRC-less MacBinary I header from arbitrary
            // binary data. Bytes 101...125 were reserved/zero in version I;
            // a shorter significant name is followed by its zero-filled tail.
            let hasNameTerminator = filenameLength == 63
                || header[2 + filenameLength] == 0
            guard hasNameTerminator,
                  header[101..<126].allSatisfy({ $0 == 0 }) else {
                return nil
            }
        } else {
            return nil
        }

        let secondaryHeaderSize = UInt64(bigUInt16(header, at: 120))
        let dataSize = UInt64(bigUInt32(header, at: 83))
        let resourceSize = UInt64(bigUInt32(header, at: 87))
        let commentSize = UInt64(bigUInt16(header, at: 99))

        guard let paddedSecondary = paddedBlockSize(secondaryHeaderSize),
              let paddedData = paddedBlockSize(dataSize),
              let paddedResource = paddedBlockSize(resourceSize),
              let paddedComment = paddedBlockSize(commentSize) else {
            return nil
        }
        let dataOffset = UInt64(headerSize).addingReportingOverflow(
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

    private static func paddedBlockSize(_ size: UInt64) -> UInt64? {
        let addition = size.addingReportingOverflow(127)
        guard !addition.overflow else { return nil }
        return addition.partialValue & ~UInt64(127)
    }

    private static func bigUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func bigUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func macBinaryHeaderCRC(
        _ bytes: ArraySlice<UInt8>
    ) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }
}
