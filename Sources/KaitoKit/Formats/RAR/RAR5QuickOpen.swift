import Foundation
import Synchronization

// 形式参照: RARLab「RAR 5.0 archive format」
// https://www.rarlab.com/technote.htm （2026-10-22 参照）。
// 公開された形式記述から独立に実装した。
// RARLab/UnRAR、7-Zip、XADMaster、The Unarchiver のソースは使用していない。

struct RAR5QuickOpen {
    struct Record {
        let target: UInt64
        let bytes: [UInt8]
    }
    let offset: UInt64
    let records: [Record]

    static func locator(in main: RAR5Block, sourceLength: UInt64) -> UInt64? {
        do {
            var extra = main.extra
            var result: UInt64?
            var seen = false
            while !extra.isAtEnd {
                let size = try extra.readVInt()
                var record = try extra.readSubcursor(Checked.toInt(size))
                guard try record.readVInt() == 1 else { continue }
                guard !seen else { return nil }
                seen = true
                let flags = try record.readVInt()
                guard flags & 1 != 0 else { continue }
                let distance = try record.readVInt()
                if flags & 2 != 0 { _ = try record.readVInt() }
                let start = try Checked.add(main.offset, distance)
                guard distance > 0, start >= main.nextOffset, start < sourceLength else { return nil }
                result = start
            }
            return result
        } catch { return nil }
    }

    static func load(source: any ByteSource, window: HeaderWindowByteSource,
                     main: RAR5Block, offset: UInt64, tailEnd: UInt64,
                     limits: ReadLimits) throws -> Self {
        var reader = try ByteReader(source: window, bufferCapacity: Int(min(16 << 10, limits.maxMetadataSize)))
        var verified = false
        let block = try RAR5VolumeParser.readBlock(source: window, reader: &reader, offset: offset,
            limits: limits, recoverDamagedArchives: false, headerBodyWasVerified: &verified)
        guard block.typeValue == 3, block.flags.contains(.dataArea),
              block.dataSize <= min(8 << 20, limits.maxMetadataSize) else {
            throw KaitoError.malformed("invalid RAR5 quick-open service block")
        }
        var cursor = block.specific
        let flags = RAR5FileFlags(rawValue: try cursor.readVInt())
        let unpacked = try cursor.readVInt()
        _ = try cursor.readVInt()
        if flags.contains(.unixTime) { _ = try cursor.readUInt32LE() }
        if flags.contains(.crc32) { _ = try cursor.readUInt32LE() }
        let compression = try RAR5CompressionInfo(rawValue: cursor.readVInt())
        _ = try cursor.readVInt()
        let nameLength = try cursor.readVInt()
        let name = try cursor.readBytes(Checked.toInt(nameLength))
        guard !flags.contains(.directory), !flags.contains(.unpackedSizeUnknown),
              unpacked == block.dataSize, compression.method == 0, compression.version == 0,
              !compression.isSolid, name == [0x51, 0x4f], cursor.isAtEnd else {
            throw KaitoError.malformed("invalid RAR5 quick-open service fields")
        }
        var extra = block.extra
        while !extra.isAtEnd {
            var record = try extra.readSubcursor(Checked.toInt(extra.readVInt()))
            guard try record.readVInt() != RAR5ExtraRecordType.encryption else {
                throw KaitoError.malformed("encrypted RAR5 quick-open service")
            }
        }
        if block.nextOffset > tailEnd {
            let end = block.nextOffset + min(source.length - block.nextOffset, 16 << 10)
            let bytes = try readByteRange(source: source, offset: tailEnd, count: Checked.toInt(end - tailEnd))
            window.seed(offset: tailEnd, bytes: bytes)
        }
        var data = RAR5ByteCursor(try readByteRange(source: window, offset: block.dataOffset,
            count: Checked.toInt(block.dataSize)))
        var records: [Record] = []
        let maximumRecords = try Checked.add(UInt64(max(0, limits.maxEntryCount)), UInt64(max(0, limits.maxMetadataRecordCount)))
        while !data.isAtEnd {
            try Task.checkCancellation()
            guard UInt64(records.count) < maximumRecords else { throw KaitoError.limitExceeded("RAR5 quick-open record count") }
            let crc = try data.readUInt32LE()
            // CRC は size vint 自身から record 末尾までを覆う。
            var covered = data
            let sizeStart = data.offset
            let size = try data.readVInt()
            let width = data.offset - sizeStart
            guard width <= 4, size <= UInt64(data.remaining) else { throw KaitoError.truncated }
            let bytes = try covered.readBytes(Checked.toInt(size) + width)
            guard CRC32.checksum(bytes) == crc else { throw KaitoError.malformed("RAR5 quick-open record CRC mismatch") }
            var record = try data.readSubcursor(Checked.toInt(size))
            guard try record.readVInt() == 0 else { throw KaitoError.malformed("RAR5 quick-open record flags") }
            let distance = try record.readVInt()
            guard distance > 0, distance <= offset - main.nextOffset else { throw KaitoError.malformed("RAR5 quick-open record distance") }
            let target = offset - distance
            guard records.last.map({ $0.target < target }) ?? true else { throw KaitoError.malformed("RAR5 quick-open record order") }
            let length = try record.readVInt()
            guard length == UInt64(record.remaining) else { throw KaitoError.malformed("RAR5 quick-open copy length") }
            let copy = try record.readBytes(Checked.toInt(length))
            let cached = try blockFromCachedHeader(copy, target: target, sourceLength: source.length, limits: limits)
            guard cached.typeValue == 2 || cached.typeValue == 3, cached.nextOffset <= offset else {
                throw KaitoError.malformed("RAR5 quick-open copy range or type")
            }
            records.append(Record(target: target, bytes: copy))
        }
        return Self(offset: offset, records: records)
    }

    static func blockFromCachedHeader(_ bytes: [UInt8], target: UInt64,
                                      sourceLength: UInt64, limits: ReadLimits) throws -> RAR5Block {
        guard bytes.count >= 6 else { throw KaitoError.truncated }
        var cursor = RAR5ByteCursor(bytes)
        let crc = try cursor.readUInt32LE()
        let size = try cursor.readVInt()
        guard cursor.offset - 4 <= 3, size >= 2, size <= limits.maxMetadataSize,
              size == UInt64(cursor.remaining), CRC32.checksum(Array(bytes[4...])) == crc else {
            throw KaitoError.malformed("invalid RAR5 quick-open cached header")
        }
        return try RAR5VolumeParser.makeBlock(offset: target, body: cursor.readBytes(Checked.toInt(size)),
            dataOffset: Checked.add(target, UInt64(bytes.count)), sourceLength: sourceLength,
            recoverDamagedArchives: false)
    }
}

struct RAR5HeaderGuard: Sendable {
    let volumeSource: any ByteSource
    let headerOffset: UInt64
    let expected: [UInt8]
    let slot: Int
    let verification: RAR5QuickOpenVerification
}

final class RAR5QuickOpenVerification: Sendable {
    private struct State {
        var slots = 0
        var verified: [UInt64] = []
        var poison: KaitoError?
    }
    private let state = Mutex(State())

    func allocateSlot() -> Int {
        state.withLock { state in
            let slot = state.slots
            state.slots += 1
            if slot / 64 >= state.verified.count { state.verified.append(0) }
            return slot
        }
    }

    var hasAllocatedSlots: Bool { state.withLock { $0.slots > 0 } }

    func checkPoison() throws {
        try state.withLock { state in if let poison = state.poison { throw poison } }
    }

    func verify(_ guardValue: RAR5HeaderGuard, segment: SourceSegment?, span: PrefetchedPackedSpan?) throws -> (any ByteSource)? {
        let word = guardValue.slot / 64
        let mask = UInt64(1) << (guardValue.slot % 64)
        let needsVerification = try state.withLock { state in
            if let poison = state.poison { throw poison }
            return state.verified[word] & mask == 0
        }
        guard needsVerification else { return nil }

        // 読み取りはロック外で行い、並行する照合や poison の確認を妨げない。
        let headerEnd = try Checked.add(guardValue.headerOffset, UInt64(guardValue.expected.count))
        var end = headerEnd
        if let segment { end = try Checked.add(segment.offset, min(segment.length, 1 << 20)) }
        let source: any ByteSource
        if let span, span.covers(guardValue.headerOffset, length: end - guardValue.headerOffset) { source = span }
        else { source = guardValue.volumeSource }
        let bytes = try readByteRange(source: source, offset: guardValue.headerOffset,
            count: Checked.toInt(end - guardValue.headerOffset))

        try state.withLock { state in
            // 読み取り中に別の照合が poison した場合も、最初のエラーを共有する。
            if let poison = state.poison { throw poison }
            guard bytes.starts(with: guardValue.expected) else {
                let error = KaitoError.malformed("RAR5 quick-open header does not match the archive header at offset \(guardValue.headerOffset)")
                state.poison = error
                throw error
            }
            state.verified[word] |= mask
        }
        guard segment != nil else { return nil }
        return RAR5PrimedByteSource(base: guardValue.volumeSource, offset: guardValue.headerOffset, bytes: bytes)
    }
}

// 照合時の先読みは stream が保持する局所 record のみに渡す。
final class RAR5PrimedByteSource: ByteSource {
    let base: any ByteSource
    let offset: UInt64
    let bytes: [UInt8]
    var length: UInt64 { base.length }
    init(base: any ByteSource, offset: UInt64, bytes: [UInt8]) {
        self.base = base; self.offset = offset; self.bytes = bytes
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at position: UInt64) throws -> Int {
        if position >= offset, position - offset < UInt64(bytes.count) {
            let start = Int(position - offset)
            let count = min(buffer.count, bytes.count - start)
            bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[start..<start + count])) }
            return count
        }
        return try base.read(into: buffer, at: position)
    }
}

extension RAR5EntryRecord {
    // packedSegments の消費は stream、solid factory、prefetch の各入口で照合した局所値のみ。
    // preparePayload と validatePackedParts はこの後に呼び、reopen は未変更の guard と状態を共有する。
    func verifyingHeaders(span: PrefetchedPackedSpan? = nil, prime: Bool = true) throws -> Self {
        var result = self
        for (index, headerGuard) in headerGuards.enumerated() {
            guard let headerGuard else { continue }
            let segment = prime && packedSegments.count == 1 && index == 0 ? packedSegments[0] : nil
            if let primed = try headerGuard.verification.verify(headerGuard, segment: segment, span: span), let segment {
                result.packedSegments[0] = SourceSegment(source: primed, offset: segment.offset, length: segment.length)
            }
        }
        return result
    }
}
