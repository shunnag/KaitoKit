import Foundation

// Implementation input: the public UNIX compress file description and the
// original LZW paper's dictionary rules. Codes are stored least-significant
// bit first in width-sized groups of at most eight codes.

/// A streaming decoder for UNIX compress (`.Z`) data.
final class LZWDecoder: Decompressor {
    private static let clearCode = 256

    private struct CodeReader {
        let source: any ByteSource
        let endOffset: UInt64
        var sourceOffset: UInt64
        var width: Int = 9
        var block: [UInt8] = []
        var bitOffset = 0

        mutating func setWidth(_ newWidth: Int) throws {
            guard (9...16).contains(newWidth) else {
                throw KaitoError.malformed("invalid UNIX compress code width")
            }
            width = newWidth
            block.removeAll(keepingCapacity: true)
            bitOffset = 0
        }

        mutating func nextCode() throws -> Int? {
            if bitOffset + width > block.count * 8 {
                guard sourceOffset < endOffset else { return nil }
                let remaining = try Checked.sub(endOffset, sourceOffset)
                let count = min(width, try Checked.toInt(remaining))
                block = try readByteRange(source: source, offset: sourceOffset, count: count)
                sourceOffset = try Checked.add(sourceOffset, UInt64(count))
                bitOffset = 0
                guard block.count * 8 >= width else { return nil }
            }

            var code = 0
            for bit in 0..<width {
                let absoluteBit = bitOffset + bit
                let byte = block[absoluteBit >> 3]
                let value = (byte >> (absoluteBit & 7)) & 1
                code |= Int(value) << bit
            }
            bitOffset += width
            return code
        }
    }

    private let maximumBits: Int
    private let maximumCodeCount: Int
    private let blockMode: Bool
    private let firstDictionaryCode: Int
    private var codeReader: CodeReader
    private var prefixes: [Int32]
    private var suffixes: [UInt8]
    private var nextDictionaryCode: Int
    private var codeWidth = 9
    private var maximumCodeForWidth = (1 << 9) - 1
    private var previousCode = 0
    private var firstCharacter: UInt8 = 0
    private var hasPreviousCode = false
    // Expansion bytes are stored in reverse order so popLast() yields output.
    private var expansionStack: [UInt8] = []
    private var finished = false

    init(source: any ByteSource, offset: UInt64 = 0, compressedSize: UInt64? = nil) throws {
        let size: UInt64
        if let compressedSize {
            size = compressedSize
        } else {
            size = try Checked.sub(source.length, offset)
        }
        let end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        guard size >= 3 else { throw KaitoError.truncated }
        let header = try readByteRange(source: source, offset: offset, count: 3)
        guard header[0] == 0x1f, header[1] == 0x9d else {
            throw KaitoError.unsupportedFormat
        }
        let flags = header[2]
        guard flags & 0x60 == 0 else {
            throw KaitoError.malformed("UNIX compress header uses reserved flags")
        }

        // Validate maxbits before using it in a shift or allocation.
        let maximumBits = Int(flags & 0x1f)
        guard (9...16).contains(maximumBits) else {
            throw KaitoError.malformed("UNIX compress maxbits is outside 9...16")
        }
        let maximumCodeCount = 1 << maximumBits
        let blockMode = flags & 0x80 != 0
        let firstDictionaryCode = blockMode ? Self.clearCode + 1 : Self.clearCode

        self.maximumBits = maximumBits
        self.maximumCodeCount = maximumCodeCount
        self.blockMode = blockMode
        self.firstDictionaryCode = firstDictionaryCode
        self.codeReader = CodeReader(
            source: source,
            endOffset: end,
            sourceOffset: try Checked.add(offset, 3)
        )
        self.prefixes = [Int32](repeating: -1, count: maximumCodeCount)
        self.suffixes = [UInt8](repeating: 0, count: maximumCodeCount)
        self.nextDictionaryCode = firstDictionaryCode
        if maximumBits == 9 {
            self.maximumCodeForWidth = maximumCodeCount
        }
        self.expansionStack.reserveCapacity(min(maximumCodeCount, 64 * 1_024))
    }

    var isFinished: Bool { finished }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty, !finished else { return 0 }
        guard let destination = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }

        var produced = 0
        while produced < buffer.count {
            if let byte = expansionStack.popLast() {
                destination[produced] = byte
                produced += 1
                continue
            }
            guard try prepareExpansion() else {
                finished = true
                break
            }
        }
        return produced
    }

    private func prepareExpansion() throws -> Bool {
        while true {
            try growCodeWidthIfNeeded()
            guard let code = try codeReader.nextCode() else { return false }

            if blockMode, code == Self.clearCode {
                try resetDictionary()
                continue
            }

            if !hasPreviousCode {
                guard code >= 0, code < 256 else {
                    throw KaitoError.malformed("UNIX compress stream does not start with a literal")
                }
                let literal = UInt8(code)
                previousCode = code
                firstCharacter = literal
                hasPreviousCode = true
                expansionStack.append(literal)
                return true
            }

            let inputCode = code
            expansionStack.removeAll(keepingCapacity: true)
            var cursor = code
            if cursor == nextDictionaryCode {
                guard nextDictionaryCode < maximumCodeCount else {
                    throw KaitoError.malformed("UNIX compress dictionary code is out of range")
                }
                expansionStack.append(firstCharacter)
                cursor = previousCode
            } else if cursor > nextDictionaryCode {
                throw KaitoError.malformed("UNIX compress dictionary code is not defined")
            }

            var depth = 0
            while cursor >= 256 {
                guard cursor >= firstDictionaryCode,
                      cursor < nextDictionaryCode,
                      cursor < maximumCodeCount else {
                    throw KaitoError.malformed("UNIX compress dictionary chain is invalid")
                }
                expansionStack.append(suffixes[cursor])
                cursor = Int(prefixes[cursor])
                depth += 1
                guard depth < maximumCodeCount else {
                    throw KaitoError.malformed("UNIX compress dictionary chain does not terminate")
                }
            }
            guard cursor >= 0, cursor < 256 else {
                throw KaitoError.malformed("UNIX compress literal is out of range")
            }
            firstCharacter = UInt8(cursor)
            expansionStack.append(firstCharacter)

            if nextDictionaryCode < maximumCodeCount {
                prefixes[nextDictionaryCode] = Int32(previousCode)
                suffixes[nextDictionaryCode] = firstCharacter
                nextDictionaryCode += 1
            }
            previousCode = inputCode
            return true
        }
    }

    private func growCodeWidthIfNeeded() throws {
        guard nextDictionaryCode > maximumCodeForWidth else { return }
        if codeWidth < maximumBits {
            codeWidth += 1
            maximumCodeForWidth = codeWidth == maximumBits
                ? maximumCodeCount
                : (1 << codeWidth) - 1
            try codeReader.setWidth(codeWidth)
            return
        }
    }

    private func resetDictionary() throws {
        codeWidth = 9
        maximumCodeForWidth = maximumBits == 9
            ? maximumCodeCount
            : (1 << 9) - 1
        nextDictionaryCode = firstDictionaryCode
        hasPreviousCode = false
        expansionStack.removeAll(keepingCapacity: true)
        try codeReader.setWidth(codeWidth)
    }
}
