import CryptoKit
import Foundation
@_spi(TarEditLayout) @testable import KaitoKit
import XCTest
import zlib

enum TarSpliceTestSupport {
    enum Codec: String, CaseIterable { case tgz, tbz, txz }
    struct Output {
        let name: String
        let bytes: Data
        let splice: CompressedTarSplice
        let image: Data
    }
    static func options(disk: Bool = false) -> ReaderOptions {
        var options = ReaderOptions(appleDoublePolicy: .expose)
        options.recordsTarEditLayout = true
        if disk { options.limits.inMemorySingleFileLimit = 0 }
        return options
    }
    static func hint(_ codec: Codec) -> URL { URL(fileURLWithPath: "/splice." + codec.rawValue) }
    static func full(_ data: Data, _ codec: Codec, options: ReaderOptions = options()) throws -> ArchiveReader {
        try ArchiveReader.open(source: DataByteSource(data), sourceURL: hint(codec), options: options)
    }
    static func open(_ result: Output, _ codec: Codec, base: TarEditingSnapshot,
                     options: ReaderOptions = options(), policy: TarSpliceStoragePolicy = .init()) throws -> ArchiveReader {
        try ArchiveReader.openSplicedCompressedTar(output: DataByteSource(result.bytes), sourceURL: hint(codec),
            base: base, splice: result.splice, options: options, storagePolicy: policy)
    }
    static func encode(_ image: Data, _ codec: Codec, chunkSize: Int = 16_384) throws -> CompressedTarFramingTestSupport.Encoded {
        switch codec {
        case .tgz: try CompressedTarFramingTestSupport.gzip(image, chunkSize: chunkSize)
        case .tbz: try CompressedTarFramingTestSupport.bzip2(image, chunkSize: chunkSize)
        case .txz: try CompressedTarFramingTestSupport.xz(image, chunkSize: chunkSize)
        }
    }
    static func corpus() throws -> Data {
        var state: UInt64 = 0xa03f89c5
        let sizes = [16_384, 16_384, 65_536, 16_384, 16_384]
        return try TarTestSupport.makeTar(entries: sizes.enumerated().map { i, size in
            let bytes = Data((0..<(size - 512)).map { j -> UInt8 in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return j % 3 == 0 ? UInt8(truncatingIfNeeded: state) : UInt8(65 + i)
            })
            return HandTarEntry(name: "file-\(i)", contents: bytes)
        })
    }
    static func member(_ name: String, _ contents: Data) throws -> Data {
        try TarTestSupport.makeTar(entries: [HandTarEntry(name: name, contents: contents)], terminated: false)
    }
    static func cases(_ base: TarEditingSnapshot, _ codec: Codec) throws -> [Output] {
        let image = try TarEditTestSupport.bytes(base.image), layout = try XCTUnwrap(base.layout)
        let members = try (0..<layout.memberCount).map { try layout.member(at: $0) }
        let eof = Int(layout.endOfArchiveOffset)
        let appended = try member("added", Data(repeating: 90, count: 1234)) + Data(count: 1024)
        var results = [try edit("append", base, codec, a: eof, b: image.count, replacement: appended)]
        for (name, i) in [("delete-mid", 1), ("delete-big", 2)] {
            let m = members[min(i, members.count - 1)]
            results.append(try edit(name, base, codec, a: Int(m.groupRange.lowerBound), b: Int(m.groupRange.upperBound), replacement: Data()))
        }
        let m = members[0]
        let header = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "renamed", contents: Data(count: Int(m.bodyRange.upperBound - m.bodyRange.lowerBound)))], terminated: false).prefix(512)
        results.append(try edit("rename-same", base, codec, a: Int(m.headerRange.lowerBound), b: Int(m.headerRange.upperBound), replacement: Data(header)))
        // GNU L の群を追加して header の長さを変える。
        let long = Data((String(repeating: "long-name-", count: 20) + "\0").utf8)
        let extended = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "././@LongLink", contents: long, type: 76)], terminated: false) + header
        results.append(try edit("rename-diff", base, codec, a: Int(m.headerRange.lowerBound), b: Int(m.headerRange.upperBound), replacement: extended))
        results.append(try prefix(base, codec, bytes: member("prefix", Data([1, 2, 3]))))
        let encoded = try encode(image, codec)
        let range = payload(encoded.data, codec)
        results.append(.init(name: "whole", bytes: encoded.data, splice: .init(segments: [.encoded(output: range)]), image: image))
        if codec != .tgz {
            results.append(try dropping(base, codec, indices: [1]))
        }
        return results
    }

    // 試作 splice.py の s1 / s2 と同じ。gzip は再利用の前に 32 KiB を再符号化する。
    static func edit(_ name: String, _ base: TarEditingSnapshot, _ codec: Codec, a: Int, b: Int, replacement: Data) throws -> Output {
        let image = try TarEditTestSupport.bytes(base.image), archive = try TarEditTestSupport.bytes(base.archive)
        let map = try XCTUnwrap(base.chunkMap), chunks = map.chunks
        let i = try XCTUnwrap(chunks.indices.last { chunks[$0].imageRange.lowerBound <= a })
        let j = chunks.indices.first { $0 > i && chunks[$0].imageRange.lowerBound >= b + (codec == .tgz ? 32_768 : 0) }
        let s1 = Int(chunks[i].imageRange.lowerBound), s2 = j.map { Int(chunks[$0].imageRange.lowerBound) } ?? image.count
        let bridge = joined(image[s1..<a], replacement, image[b..<s2])
        let changed = joined(image[..<a], replacement, image[b...])
        let packed: Data, records: [(UInt64, UInt64)]
        if codec == .tgz {
            packed = try rawGzip(Data(bridge), dictionary: Data(image[max(0, s1 - 32_768)..<s1]), final: j == nil)
            records = []
        } else {
            let encoded = try encode(Data(bridge), codec)
            let range = payload(encoded.data, codec)
            packed = Data(encoded.data[Int(range.lowerBound)..<Int(range.upperBound)])
            records = codec == .txz ? try xzRecords(encoded.data) : []
        }
        let payload = payload(archive, codec), c1 = chunks[i].compressedRange.lowerBound
        let c2 = j.map { chunks[$0].compressedRange.lowerBound } ?? payload.upperBound
        var output = Data(archive[..<Int(c1)]), segments: [CompressedTarSplice.Segment] = []
        if c1 > payload.lowerBound { segments.append(.reused(output: payload.lowerBound..<c1, base: payload.lowerBound..<c1)) }
        if !packed.isEmpty { output.append(packed); segments.append(.encoded(output: c1..<UInt64(output.count))) }
        if c2 < payload.upperBound {
            let start = UInt64(output.count); output.append(archive[Int(c2)..<Int(payload.upperBound)])
            segments.append(.reused(output: start..<UInt64(output.count), base: c2..<payload.upperBound))
        }
        var allRecords: [(UInt64, UInt64)] = []
        if case .xz(let xz) = map {
            allRecords = xz.blocks[..<i].map { ($0.unpaddedSize, $0.imageRange.upperBound - $0.imageRange.lowerBound) }
                + records + xz.blocks[(j ?? xz.blocks.count)...].map { ($0.unpaddedSize, $0.imageRange.upperBound - $0.imageRange.lowerBound) }
        }
        appendTail(&output, image: Data(changed), codec: codec, records: allRecords, flags: Data(archive[6..<8]))
        return .init(name: name, bytes: output, splice: .init(segments: segments), image: Data(changed))
    }
    static func prefix(_ base: TarEditingSnapshot, _ codec: Codec, bytes: Data) throws -> Output {
        let archive = try TarEditTestSupport.bytes(base.archive), image = try joined(bytes, TarEditTestSupport.bytes(base.image))
        let range = payload(archive, codec)
        let encoded = try encode(bytes, codec), packed: Data
        if codec == .tgz { packed = try rawGzip(bytes, dictionary: Data(), final: false) }
        else { let r = payload(encoded.data, codec); packed = Data(encoded.data[Int(r.lowerBound)..<Int(r.upperBound)]) }
        var output = joined(archive.prefix(Int(range.lowerBound)), packed)
        let end = UInt64(output.count)
        output.append(archive[Int(range.lowerBound)..<Int(range.upperBound)])
        let segments: [CompressedTarSplice.Segment] = [.encoded(output: range.lowerBound..<end), .reused(output: end..<UInt64(output.count), base: range)]
        let records = codec == .txz ? try xzRecords(encoded.data) + xzRecords(archive) : []
        appendTail(&output, image: image, codec: codec, records: records, flags: Data(archive[6..<8]))
        return .init(name: "prefix", bytes: output, splice: .init(segments: segments), image: image)
    }
    static func dropping(_ base: TarEditingSnapshot, _ codec: Codec, indices: Set<Int>) throws -> Output {
        let archive = try TarEditTestSupport.bytes(base.archive), image = try TarEditTestSupport.bytes(base.image)
        let chunks = try XCTUnwrap(base.chunkMap).chunks, range = payload(archive, codec)
        var output = Data(archive.prefix(Int(range.lowerBound))), changed = Data(), segments: [CompressedTarSplice.Segment] = []
        for (i, chunk) in chunks.enumerated() where !indices.contains(i) {
            let start = UInt64(output.count)
            output.append(archive[Int(chunk.compressedRange.lowerBound)..<Int(chunk.compressedRange.upperBound)])
            segments.append(.reused(output: start..<UInt64(output.count), base: chunk.compressedRange))
            changed.append(image[Int(chunk.imageRange.lowerBound)..<Int(chunk.imageRange.upperBound)])
        }
        let records = codec == .txz ? try xzRecords(archive).enumerated().filter { !indices.contains($0.offset) }.map(\.element) : []
        appendTail(&output, image: changed, codec: codec, records: records, flags: Data(archive[6..<8]))
        return .init(name: "drop-chunk", bytes: output, splice: .init(segments: segments), image: changed)
    }
    static func payload(_ bytes: Data, _ codec: Codec) -> Range<UInt64> {
        switch codec {
        case .tgz: return 10..<UInt64(bytes.count - 8)
        case .tbz: return 0..<UInt64(bytes.count)
        case .txz:
            let indexLength = Int(CompressedTarFramingTestSupport.uint32(bytes, bytes.count - 8) + 1) * 4
            return 12..<UInt64(bytes.count - 12 - indexLength)
        }
    }
    // macOS 26 の Foundation は、位置 0 でない空の slice（記憶域を共有）へ空の Data を
    // 汎用の append(contentsOf:)（`+` を含む）で足すと trap する（macOS 27 では起きない）。
    // 新しい Data へ append(_: Data) で積み、slice の連結に `+` を使わない。
    static func joined(_ parts: Data...) -> Data {
        var result = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for part in parts { result.append(part) }
        return result
    }
    static func xzRecords(_ bytes: Data) throws -> [(UInt64, UInt64)] {
        var offset = Int(payload(bytes, .txz).upperBound) + 1
        let count = try CompressedTarFramingTestSupport.readVLI(bytes, &offset)
        return try (0..<count).map { _ in (try CompressedTarFramingTestSupport.readVLI(bytes, &offset), try CompressedTarFramingTestSupport.readVLI(bytes, &offset)) }
    }
    static func appendTail(_ output: inout Data, image: Data, codec: Codec, records: [(UInt64, UInt64)], flags: Data) {
        if codec == .tgz {
            output.append(CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(image)))
            output.append(CompressedTarFramingTestSupport.le(UInt32(truncatingIfNeeded: image.count)))
        } else if codec == .txz {
            var index = Data([0]) + CompressedTarFramingTestSupport.vli(UInt64(records.count))
            for (packed, unpacked) in records { index.append(CompressedTarFramingTestSupport.vli(packed)); index.append(CompressedTarFramingTestSupport.vli(unpacked)) }
            while index.count % 4 != 0 { index.append(0) }
            index.append(CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(index)))
            output.append(index)
            let footer = CompressedTarFramingTestSupport.le(UInt32(index.count / 4 - 1)) + flags
            output.append(CompressedTarFramingTestSupport.le(CompressedTarFramingTestSupport.crc(footer)) + footer + Data([0x59, 0x5a]))
        }
    }
    static func rawGzip(_ bytes: Data, dictionary: Data, final: Bool, level: Int32 = 6, flush: Int32 = Z_SYNC_FLUSH) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw KaitoError.truncated }
        defer { deflateEnd(&stream) }
        if !dictionary.isEmpty {
            let code = dictionary.withUnsafeBytes { deflateSetDictionary(&stream, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard code == Z_OK else { throw KaitoError.truncated }
        }
        var encoded = Data(count: bytes.count + bytes.count / 100 + 128)
        let status = bytes.withUnsafeBytes { src in encoded.withUnsafeMutableBytes { dst in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(src.count)
            stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(dst.count)
            return deflate(&stream, final ? Z_FINISH : flush)
        } }
        guard status == (final ? Z_STREAM_END : Z_OK), stream.avail_in == 0, stream.avail_out > 0 else { throw KaitoError.truncated }
        encoded.removeLast(Int(stream.avail_out))
        return encoded
    }
    static func equal(_ actual: ArchiveReader, _ full: ArchiveReader, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.entries, full.entries, file: file, line: line)
        XCTAssertEqual(actual.nameEncoding, full.nameEncoding, file: file, line: line)
        XCTAssertEqual(actual.format, full.format, file: file, line: line)
        XCTAssertEqual(actual.password, full.password, file: file, line: line)
        for (a, b) in zip(actual.entries, full.entries) {
            XCTAssertEqual(try digest(actual.stream(a)), try digest(full.stream(b)), "entry \(a.index)", file: file, line: line)
        }
        let a = try XCTUnwrap(actual.tarEditingSnapshot(), file: file, line: line)
        let b = try XCTUnwrap(full.tarEditingSnapshot(), file: file, line: line)
        XCTAssertEqual(a.chunkMap, b.chunkMap, file: file, line: line)
        XCTAssertEqual(a.chunkMapUnavailableReason, b.chunkMapUnavailableReason, file: file, line: line)
        XCTAssertEqual(a.layoutUnavailableReason, b.layoutUnavailableReason, file: file, line: line)
        XCTAssertEqual(a.layout?.memberCount, b.layout?.memberCount, file: file, line: line)
        XCTAssertEqual(a.layout?.imageLength, b.layout?.imageLength, file: file, line: line)
        XCTAssertEqual(a.layout?.endOfArchiveOffset, b.layout?.endOfArchiveOffset, file: file, line: line)
        XCTAssertEqual(a.layout?.globalHeaderRanges, b.layout?.globalHeaderRanges, file: file, line: line)
        if let layout = a.layout { for i in 0..<layout.memberCount {
            XCTAssertEqual(try layout.member(at: i), try b.layout?.member(at: i), file: file, line: line)
            XCTAssertEqual(try a.headerGroup(ofMember: i), try b.headerGroup(ofMember: i), file: file, line: line)
        } }
    }
    static func digest(_ stream: EntryStream) throws -> Data {
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: Int(max(1, min(stream.remaining, 262_144))))
        while true {
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { break }
            buffer.withUnsafeBytes { hash.update(bufferPointer: .init(rebasing: $0[..<count])) }
        }
        return Data(hash.finalize())
    }
}
