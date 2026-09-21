import Foundation

// 参照仕様: "Description of the zisofs Format"（Thomas Schmitt、libburnia、distribute freely）と
// RFC 1950。file 本文は 16 byte header + block pointer 配列 + zlib block 列で、Rock Ridge の
// "ZF" entry（version 1、algorithm "pz"）が header の値を複製する。

/// Rock Ridge ZF entry から得た zisofs のパラメータ。
struct ISOZisofsInfo: Equatable {
    static let magic: [UInt8] = [0x37, 0xE4, 0x53, 0x96, 0xC9, 0xDB, 0xD6, 0x07]
    static let headerSize = 16

    /// log2(block size)。仕様は 15〜17（32 KiB〜128 KiB）だけを許す。
    let blockSizeLog2: Int
    /// 展開後の長さ（4 GiB 未満）。
    let uncompressedSize: UInt64

    var blockSize: UInt64 { UInt64(1) << UInt64(blockSizeLog2) }
    var blockCount: UInt64 { (uncompressedSize + blockSize - 1) / blockSize }
    /// header + (blockCount + 1) 個の 4 byte pointer。
    var tableEnd: UInt64 { UInt64(Self.headerSize) + (blockCount + 1) * 4 }
}

/// zisofs の block 列を展開後の byte 列として順に返す。
final class ISOZisofsDecompressor: Decompressor {
    private let source: any ByteSource
    private let section: ISOSection
    private let info: ISOZisofsInfo
    private var pointers: [UInt32] = []
    private var blockIndex: UInt64 = 0
    private var produced: UInt64 = 0
    private var current: (any Decompressor)?
    private var currentExpected: UInt64 = 0
    private var currentProduced: UInt64 = 0
    private var zeroRemaining: UInt64 = 0
    private var terminalError: (any Error)?
    private(set) var isFinished = false

    init(source: any ByteSource, section: ISOSection, info: ISOZisofsInfo, limits: ReadLimits) throws {
        self.source = source
        self.section = section
        self.info = info
        guard section.length >= info.tableEnd else { throw KaitoError.truncated }
        let header = try readByteRange(source: source, offset: section.offset, count: ISOZisofsInfo.headerSize)
        guard Array(header[..<8]) == ISOZisofsInfo.magic else {
            throw KaitoError.malformed("zisofs magic")
        }
        let declared = UInt64(header[8]) | UInt64(header[9]) << 8 | UInt64(header[10]) << 16 | UInt64(header[11]) << 24
        guard declared == info.uncompressedSize else {
            throw KaitoError.malformed("zisofs header size differs from the ZF entry")
        }
        guard header[12] == 4, Int(header[13]) == info.blockSizeLog2, header[14] == 0, header[15] == 0 else {
            throw KaitoError.malformed("zisofs header fields differ from the ZF entry")
        }
        // pointer 配列は metadata として一度だけ確保する。4 GiB / 32 KiB でも 512 KiB。
        let tableBytes = try Checked.mul((info.blockCount + 1), 4)
        try Checked.size(tableBytes, limit: limits.maxMetadataSize)
        let table = try readByteRange(source: source, offset: Checked.add(section.offset, UInt64(ISOZisofsInfo.headerSize)),
                                      count: Int(tableBytes))
        var previous = UInt32(truncatingIfNeeded: info.tableEnd)
        pointers.reserveCapacity(Int(info.blockCount) + 1)
        for index in 0...Int(info.blockCount) {
            let value = UInt32(table[index * 4]) | UInt32(table[index * 4 + 1]) << 8
                | UInt32(table[index * 4 + 2]) << 16 | UInt32(table[index * 4 + 3]) << 24
            // pointer は単調非減少で、表の直後から extent の終端までに収まる。
            guard value >= previous, UInt64(value) <= section.length else {
                throw KaitoError.malformed("zisofs block pointer")
            }
            pointers.append(value)
            previous = value
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let terminalError { throw terminalError }
        guard !buffer.isEmpty, !isFinished else { return 0 }
        do {
            while true {
                if zeroRemaining > 0 {
                    let count = Int(min(UInt64(buffer.count), zeroRemaining))
                    buffer.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: count)
                    zeroRemaining -= UInt64(count)
                    produced += UInt64(count)
                    return count
                }
                if let decoder = current {
                    let count = try decoder.read(into: buffer)
                    if count > 0 {
                        currentProduced += UInt64(count)
                        guard currentProduced <= currentExpected else {
                            throw KaitoError.malformed("zisofs block is longer than the block size")
                        }
                        produced += UInt64(count)
                        return count
                    }
                    guard decoder.isFinished, currentProduced == currentExpected else {
                        throw KaitoError.malformed("zisofs block is shorter than the block size")
                    }
                    current = nil
                    continue
                }
                guard blockIndex < info.blockCount else {
                    guard produced == info.uncompressedSize else {
                        throw KaitoError.malformed("zisofs output size mismatch")
                    }
                    isFinished = true
                    return 0
                }
                let start = UInt64(pointers[Int(blockIndex)])
                let end = UInt64(pointers[Int(blockIndex) + 1])
                let expected = min(info.blockSize, info.uncompressedSize - blockIndex * info.blockSize)
                blockIndex += 1
                if end == start {
                    // 長さ 0 の block は block 分の 0 byte を表す。
                    zeroRemaining = expected
                    continue
                }
                current = try DeflateDecompressor(
                    source: source, offset: Checked.add(section.offset, start),
                    compressedSize: end - start, zlibWrapped: true
                )
                currentExpected = expected
                currentProduced = 0
            }
        } catch {
            terminalError = error
            throw error
        }
    }
}
