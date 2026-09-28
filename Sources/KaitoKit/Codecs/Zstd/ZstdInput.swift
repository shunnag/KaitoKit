import Foundation

// Zstd の byte 記憶の所有者: ByteSource の指定範囲を先読みする ZstdInput と、
// frame が所有する前後余白付きの byte 領域 ZstdScratchBuffer。

// ByteSource の指定範囲だけを読む。skip は圧縮データや metadata を確保しない。
final class ZstdInput {
    // 先読みの単位。これ以上の本文の残り要求は先読みせず source から直接読む。
    private static let readAhead = 4 * 1_024
    private let source: any ByteSource
    let end: UInt64
    private(set) var position: UInt64
    private var buffer: [UInt8] = []
    private var bufferOffset = 0

    init(source: any ByteSource, offset: UInt64, size: UInt64) throws {
        end = try Checked.add(offset, size)
        guard end <= source.length else { throw KaitoError.truncated }
        self.source = source
        position = offset
    }

    var remaining: UInt64 { end - position }

    func byte() throws -> UInt8 {
        if bufferOffset == buffer.count {
            guard position < end else { throw KaitoError.truncated }
            let count = Int(min(UInt64(Self.readAhead), remaining))
            buffer = try readByteRange(source: source, offset: position, count: count)
            bufferOffset = 0
        }
        let value = buffer[bufferOffset]
        bufferOffset += 1
        position += 1
        return value
    }

    func integer(_ count: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<count { result |= UInt64(try byte()) << (index * 8) }
        return result
    }

    func read(_ count: Int, into destination: UnsafeMutableRawPointer) throws {
        // 呼出側は count バイトを確保済み。入力範囲を検査してから source に触れる。
        guard count >= 0, UInt64(count) <= remaining else { throw KaitoError.truncated }
        var filled = 0
        while filled < count {
            if bufferOffset < buffer.count {
                let amount = min(count - filled, buffer.count - bufferOffset)
                buffer.withUnsafeBytes { bytes in
                    // 両範囲は残量で制限済みで、先読み配列と destination は独立している。
                    destination.advanced(by: filled).copyMemory(
                        from: bytes.baseAddress!.advanced(by: bufferOffset), byteCount: amount)
                }
                bufferOffset += amount
                position += UInt64(amount)
                filled += amount
            } else if count - filled >= Self.readAhead {
                // readByteRange と同じく short read を完了まで続け、不正な返却長は拒否する。
                while filled < count {
                    let remaining = count - filled
                    let actual = try source.read(
                        into: UnsafeMutableRawBufferPointer(start: destination.advanced(by: filled), count: remaining),
                        at: position)
                    guard actual > 0, actual <= remaining else { throw KaitoError.truncated }
                    filled += actual
                    position += UInt64(actual)
                }
            } else {
                let amount = Int(min(UInt64(Self.readAhead), remaining))
                buffer = try readByteRange(source: source, offset: position, count: amount)
                bufferOffset = 0
            }
        }
    }

    func skip(_ count: UInt64) throws {
        guard count <= remaining else { throw KaitoError.truncated }
        if count <= UInt64(buffer.count - bufferOffset) {
            bufferOffset += Int(count)
        } else {
            buffer.removeAll(keepingCapacity: true)
            bufferOffset = 0
        }
        position += count
    }
}

// D0/D1: フレーム所有の遅延 scratch。再確保時に有効データは引き継がず、次の fill で埋める。
final class ZstdScratchBuffer {
    static let frontPad = 8
    static let backPad = 32
    private var allocation: UnsafeMutableRawPointer?
    private(set) var capacity = 0
    var allocatedBytes: Int { allocation == nil ? 0 : Self.frontPad + capacity + Self.backPad }
    var base: UnsafeMutableRawPointer { allocation!.advanced(by: Self.frontPad) }

    func reserve(_ count: Int, maximum: Int) {
        precondition(count >= 0 && count <= maximum)
        if allocation != nil, count <= capacity { return }
        var nextCapacity = capacity == 0 ? min(maximum, max(4 * 1_024, count)) : capacity
        while nextCapacity < count { nextCapacity = min(maximum, nextCapacity * 2) }
        capacity = nextCapacity
        allocation?.deallocate()
        allocation = .allocate(byteCount: Self.frontPad + capacity + Self.backPad, alignment: 16)
        // 前余白だけ初期化する。有効領域と直後の後余白は呼出側が毎回埋める。
        allocation!.initializeMemory(as: UInt8.self, repeating: 0, count: Self.frontPad)
    }

    func pad(after count: Int, byte: UInt8 = 0) {
        // count <= capacity。読取り可能な後余白は有効データ直後の 32 バイトだけ。
        base.advanced(by: count).initializeMemory(as: UInt8.self, repeating: byte, count: Self.backPad)
    }

    deinit { allocation?.deallocate() }
}
