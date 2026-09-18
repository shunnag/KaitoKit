import CryptoKit
import Foundation

/// Checks every dictionary before Apple Compression can allocate it. The
/// framework has no memory-limit option. Walking LZMA2 chunk envelopes (not
/// decompressing payloads) also covers later blocks and concatenated streams;
/// trusting only the first block or a claimed Index offset would miss them.
/// Format input: https://tukaani.org/xz/xz-file-format.txt and LZMA2's public
/// control-byte layout. Apple Compression still verifies the decoded data.
enum XZResourceValidator {
    static func validate(source: any ByteSource, dictionaryLimit: UInt64) throws {
        guard source.length >= 24, source.length % 4 == 0 else { throw KaitoError.truncated }
        var reader = try ByteReader(source: source, bufferCapacity: 1_024)
        repeat {
            let header = try reader.readBytes(12)
            guard header.prefix(6) == Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]),
                  header[6] == 0, header[7] & 0xf0 == 0,
                  CRC32.checksum(Data(header[6..<8])) == littleEndian(header, at: 8) else {
                throw KaitoError.malformed("invalid XZ stream header")
            }
            let check = header[7] & 0x0f
            let checkSize: UInt64 = check == 0 ? 0 : UInt64(1) << ((Int(check) - 1) / 3 + 2)
            var blocks: UInt64 = 0
            var actualIndex = SHA256()
            var indexStart: UInt64
            while true {
                let blockStart = reader.offset
                let encodedSize = try reader.readUInt8()
                if encodedSize == 0 { indexStart = blockStart; break }
                let headerSize = (Int(encodedSize) + 1) * 4
                var block = Data([encodedSize])
                block.append(try reader.readBytes(headerSize - 1))
                let declared = try validateBlockHeader(block, dictionaryLimit: dictionaryLimit)
                let payloadStart = reader.offset
                let outputSize = try skipLZMA2Payload(&reader)
                let compressedSize = reader.offset - payloadStart
                if let size = declared.compressed, size != compressedSize {
                    throw KaitoError.malformed("XZ compressed block size mismatch")
                }
                if let size = declared.uncompressed, size != outputSize {
                    throw KaitoError.malformed("XZ uncompressed block size mismatch")
                }
                try zeros(&reader, count: (4 - compressedSize % 4) % 4)
                try reader.seek(to: Checked.add(reader.offset, checkSize))
                hashRecord(&actualIndex, UInt64(headerSize) + compressedSize + checkSize, outputSize)
                blocks = try Checked.add(blocks, 1)
            }
            let records = try variableInteger(&reader)
            guard records == blocks else { throw KaitoError.malformed("XZ Index block count mismatch") }
            var storedIndex = SHA256()
            for _ in 0..<records {
                let unpadded = try variableInteger(&reader)
                let unpacked = try variableInteger(&reader)
                hashRecord(&storedIndex, unpadded, unpacked)
            }
            guard actualIndex.finalize() == storedIndex.finalize() else {
                throw KaitoError.malformed("XZ Index block sizes mismatch")
            }
            try zeros(&reader, count: (4 - (reader.offset - indexStart) % 4) % 4)
            // The native decoder validates Index CRC and payload checksums.
            _ = try reader.readUInt32LE()
            let indexSize = reader.offset - indexStart
            let footer = try reader.readBytes(12)
            guard footer.suffix(2) == Data([0x59, 0x5a]),
                  footer[8] == header[6], footer[9] == header[7],
                  (UInt64(littleEndian(footer, at: 4)) + 1) * 4 == indexSize,
                  CRC32.checksum(Data(footer[4..<10])) == littleEndian(footer, at: 0) else {
                throw KaitoError.malformed("invalid XZ stream footer")
            }
            while reader.remaining > 0 {
                let offset = reader.offset
                if try reader.readUInt32LE() != 0 {
                    try reader.seek(to: offset)
                    break
                }
            }
        } while reader.remaining > 0
    }

    private static func validateBlockHeader(_ header: Data, dictionaryLimit: UInt64) throws
        -> (compressed: UInt64?, uncompressed: UInt64?) {
        let size = header.count
        guard CRC32.checksum(Data(header.prefix(size - 4))) == littleEndian(header, at: size - 4) else {
            throw KaitoError.malformed("XZ block header checksum mismatch")
        }
        var reader = try ByteReader(source: DataByteSource(data: Data(header.prefix(size - 4))),
                                    offset: 1, bufferCapacity: 1_024)
        let flags = try reader.readUInt8()
        guard flags & 0x3c == 0 else { throw KaitoError.malformed("invalid XZ block flags") }
        let compressed = flags & 0x40 == 0 ? nil : try variableInteger(&reader)
        let uncompressed = flags & 0x80 == 0 ? nil : try variableInteger(&reader)
        let count = Int(flags & 3) + 1
        for index in 0..<count {
            let id = try variableInteger(&reader)
            let propertiesSize = try variableInteger(&reader)
            guard propertiesSize <= reader.remaining else { throw KaitoError.truncated }
            if index == count - 1 {
                guard id == 0x21, propertiesSize == 1 else {
                    throw KaitoError.unsupportedMethod("XZ final filter \(id)")
                }
                let dictionary = try LZMA2Decoder.dictionarySize(for: reader.readUInt8())
                try Checked.size(dictionary, limit: dictionaryLimit)
            } else {
                // Every preceding standardized XZ filter is size-preserving.
                // Unknown filters are left to the native decoder to reject.
                guard id != 0x21, id < (UInt64(1) << 62) else {
                    throw KaitoError.malformed("invalid XZ filter chain")
                }
                try reader.seek(to: Checked.add(reader.offset, propertiesSize))
            }
        }
        try zeros(&reader, count: reader.remaining)
        return (compressed, uncompressed)
    }

    /// Reads only chunk controls and sizes. No archive-sized allocation is made.
    private static func skipLZMA2Payload(_ reader: inout ByteReader) throws -> UInt64 {
        var output: UInt64 = 0
        while true {
            let control = try reader.readUInt8()
            if control == 0 { return output }
            let packed: UInt64
            let unpacked: UInt64
            if control < 0x80 {
                guard control == 1 || control == 2 else { throw KaitoError.malformed("invalid LZMA2 chunk") }
                packed = UInt64(try reader.readUInt16BE()) + 1
                unpacked = packed
            } else {
                unpacked = (UInt64(control & 0x1f) << 16) + UInt64(try reader.readUInt16BE()) + 1
                packed = UInt64(try reader.readUInt16BE()) + 1
                if control >= 0xc0 { _ = try reader.readUInt8() }
            }
            output = try Checked.add(output, unpacked)
            try reader.seek(to: Checked.add(reader.offset, packed))
        }
    }

    private static func variableInteger(_ reader: inout ByteReader) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<9 {
            let byte = try reader.readUInt8()
            guard index == 0 || byte != 0 else { throw KaitoError.malformed("noncanonical XZ integer") }
            value |= UInt64(byte & 0x7f) << (7 * index)
            if byte & 0x80 == 0 { return value }
        }
        throw KaitoError.malformed("XZ integer exceeds 63 bits")
    }

    private static func zeros(_ reader: inout ByteReader, count: UInt64) throws {
        for _ in 0..<count {
            guard try reader.readUInt8() == 0 else { throw KaitoError.malformed("invalid XZ padding") }
        }
    }

    private static func littleEndian(_ data: Data, at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(data[index + $1]) << ($1 * 8)) }
    }

    private static func hashRecord(_ hash: inout SHA256, _ packed: UInt64, _ unpacked: UInt64) {
        var bytes = Data()
        for value in [packed, unpacked] {
            bytes.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        hash.update(data: bytes)
    }
}
