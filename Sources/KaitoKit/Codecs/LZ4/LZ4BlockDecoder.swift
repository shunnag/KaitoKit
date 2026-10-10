import Foundation

// Public LZ4 Block Format Description, revised 2022-07-31.
// The enclosing frame supplies the maximum decoded size and up to 64 KiB of
// preceding decoded bytes. External dictionaries are not accepted by the frame.
enum LZ4BlockDecoder {
    static func decode(_ input: [UInt8], history: [UInt8], maximumSize: Int) throws -> [UInt8] {
        guard maximumSize >= 0, history.count <= 65_536 else {
            throw KaitoError.malformed("LZ4 block bounds")
        }
        let buffer = LZ4BlockBuffer()
        buffer.setHistory(history)
        try input.withUnsafeBytes { try decode($0, into: buffer, maximumSize: maximumSize) }
        return buffer.withOutputBytes { Array($0) }
    }

    static func decode(_ input: UnsafeRawBufferPointer, into buffer: LZ4BlockBuffer,
                       maximumSize: Int) throws {
        guard maximumSize >= 0, buffer.historyCount <= 65_536 else {
            throw KaitoError.malformed("LZ4 block bounds")
        }
        var cursor = 0
        buffer.outputCount = 0
        var lastMatchStart: Int?

        func length(_ nibble: Int, minimum: Int = 0) throws -> Int {
            var result = nibble + minimum
            if nibble == 15 {
                while true {
                    guard cursor < input.count else { throw KaitoError.truncated }
                    let extra = Int(input[cursor])
                    cursor += 1
                    guard result <= maximumSize, extra <= maximumSize - result else {
                        throw KaitoError.limitExceeded("LZ4 block output")
                    }
                    result += extra
                    if extra != 255 { break }
                }
            }
            return result
        }

        while cursor < input.count {
            let token = input[cursor]
            cursor += 1
            let literals = try length(Int(token >> 4))
            guard literals <= input.count - cursor else { throw KaitoError.truncated }
            guard literals <= maximumSize - buffer.outputCount else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            if literals > 0 {
                buffer.reserveOutput(buffer.outputCount + literals)
                let target = buffer.outputAddress.advanced(by: buffer.outputCount)
                // Unlike Zstd's padded literal storage, encoded LZ4 has no input
                // slack. Use its copy16 pattern only for complete chunks.
                let source = input.baseAddress!.advanced(by: cursor)
                var position = 0
                while literals - position >= 16 {
                    copy16(from: source.advanced(by: position), to: target.advanced(by: position))
                    position += 16
                }
                target.advanced(by: position).copyMemory(from: source.advanced(by: position),
                                                       byteCount: literals - position)
            }
            buffer.outputCount += literals
            cursor += literals
            if cursor == input.count {
                if let lastMatchStart {
                    guard literals >= 5, buffer.outputCount - lastMatchStart >= 12 else {
                        throw KaitoError.malformed("LZ4 block end conditions")
                    }
                }
                return
            }
            guard input.count - cursor >= 2 else { throw KaitoError.truncated }
            let distance = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard distance > 0, distance <= buffer.historyCount + buffer.outputCount else {
                throw KaitoError.malformed("LZ4 match distance")
            }
            let count = try length(Int(token & 15), minimum: 4)
            guard count <= maximumSize - buffer.outputCount else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            lastMatchStart = buffer.outputCount
            buffer.reserveOutput(buffer.outputCount + count)
            copyMatch(output: buffer.outputAddress.advanced(by: buffer.outputCount),
                      length: count, offset: distance)
            buffer.outputCount += count
        }
        throw KaitoError.malformed("LZ4 block has no final literal sequence")
    }

    // Same wide-copy and period-expansion technique as the private Zstd helpers.
    // All match reads precede the current write; overcopy stays in 32-byte slack.
    @inline(__always)
    private static func copy16(from source: UnsafeRawPointer, to target: UnsafeMutableRawPointer) {
        target.storeBytes(of: source.loadUnaligned(as: UInt64.self), as: UInt64.self)
        target.storeBytes(of: source.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                          toByteOffset: 8, as: UInt64.self)
    }

    @inline(__always)
    private static func copyMatch(output: UnsafeMutableRawPointer, length: Int, offset: Int) {
        var position = 0
        if offset >= 16 {
            repeat {
                copy16(from: output.advanced(by: position - offset), to: output.advanced(by: position))
                position += 16
            } while position < length
            return
        }
        var distance = offset
        if offset < 8 {
            let prefix = min(8, length)
            while position < prefix {
                output.storeBytes(of: output.load(fromByteOffset: position - offset, as: UInt8.self),
                                  toByteOffset: position, as: UInt8.self)
                position += 1
            }
            distance = offset * ((8 + offset - 1) / offset)
        }
        while position < length {
            output.storeBytes(of: output.loadUnaligned(fromByteOffset: position - distance, as: UInt64.self),
                              toByteOffset: position, as: UInt64.self)
            position += 8
        }
    }
}

// Reused across blocks: [retained history | decoded output | 32-byte slack].
// Grow only after validation, so tiny malformed blocks cannot allocate block max.
final class LZ4BlockBuffer {
    private var storage: UnsafeMutableRawPointer?
    private var capacity = 0
    private(set) var historyCount = 0
    var outputCount = 0

    deinit { storage?.deallocate() }

    var outputAddress: UnsafeMutableRawPointer { storage!.advanced(by: historyCount) }

    func reserveOutput(_ count: Int) {
        let needed = historyCount + count + 32
        guard needed > capacity else { return }
        let nextCapacity = max(needed, capacity <= Int.max / 2 ? capacity * 2 : needed)
        let next = UnsafeMutableRawPointer.allocate(byteCount: nextCapacity, alignment: 16)
        if let storage {
            next.copyMemory(from: storage, byteCount: historyCount + outputCount)
            storage.deallocate()
        }
        storage = next
        capacity = nextCapacity
    }

    func setHistory(_ history: [UInt8]) {
        historyCount = 0
        outputCount = 0
        reserveOutput(history.count)
        history.withUnsafeBytes { bytes in
            if !bytes.isEmpty { storage!.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        }
        historyCount = history.count
    }

    func finishBlock(keepHistory: Bool) {
        let retained = keepHistory ? min(65_536, historyCount + outputCount) : 0
        if retained > 0 {
            memmove(storage!, storage!.advanced(by: historyCount + outputCount - retained), retained)
        }
        historyCount = retained
        outputCount = 0
    }

    func reset() { historyCount = 0; outputCount = 0 }

    func store(_ input: UnsafeRawBufferPointer) {
        reserveOutput(input.count)
        if !input.isEmpty { outputAddress.copyMemory(from: input.baseAddress!, byteCount: input.count) }
        outputCount = input.count
    }

    func withOutputBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawBufferPointer(start: storage.map { $0.advanced(by: historyCount) }, count: outputCount))
    }
}
