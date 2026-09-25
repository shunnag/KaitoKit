import Foundation
import XCTest
import zlib

enum TarGoldenInputSupport {
    static func pax(_ records: [(String, String)]) -> Data {
        var result = Data()
        for (key, value) in records {
            let body = "\(key)=\(value)\n"
            var size = body.utf8.count + 2
            while String(size).count + 1 + body.utf8.count != size { size = String(size).count + 1 + body.utf8.count }
            result.append(Data("\(size) \(body)".utf8))
        }
        return result
    }
    static func header(_ name: String, _ values: [(String, String)], type: UInt8 = 0x78) -> HandTarEntry {
        HandTarEntry(name: name, contents: pax(values), type: type)
    }
    static func octal(_ value: Int, width: Int = 12) -> Data {
        let digits = String(value, radix: 8)
        return Data((String(repeating: "0", count: width - 1 - digits.count) + digits + "\0").utf8)
    }
    static func checksum(_ bytes: inout Data) {
        bytes.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
        let value = bytes.prefix(512).reduce(0) { $0 + Int($1) }
        bytes.replaceSubrange(148..<155, with: octal(value, width: 7))
    }
    // TarSparseTests（24311ac）の旧 GNU builder と同じ配置。既存試験を変更しない。
    static func oldGNU() throws -> Data {
        let fragments = (0..<6).map { (offset: $0 * 1024, bytes: [UInt8($0 + 1)]) }
        let base = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "old", contents: Data(fragments.flatMap(\.bytes)), type: 0x53)])
        var header = Data(base.prefix(512))
        header.replaceSubrange(257..<265, with: Data("ustar  \0".utf8))
        header.replaceSubrange(345..<512, with: Data(count: 167))
        func put(_ fragment: (offset: Int, bytes: [UInt8]), _ block: inout Data, _ offset: Int) {
            block.replaceSubrange(offset..<(offset + 12), with: octal(fragment.offset))
            block.replaceSubrange((offset + 12)..<(offset + 24), with: octal(fragment.bytes.count))
        }
        for (i, f) in fragments.prefix(4).enumerated() { put(f, &header, 386 + i * 24) }
        header[482] = 1; header.replaceSubrange(483..<495, with: octal(8192)); checksum(&header)
        var ext = Data(count: 512)
        for (i, f) in fragments.dropFirst(4).enumerated() { put(f, &ext, i * 24) }
        return header + ext + base.dropFirst(512)
    }
    static func tarInputs() throws -> [(String, Data)] {
        let file = HandTarEntry(name: "file", contents: Data("body".utf8)), after = HandTarEntry(name: "after", contents: Data("last".utf8))
        let basic = try TarTestSupport.makeTar(entries: [file, after])
        var hard = try TarTestSupport.makeTar(entries: [file, HandTarEntry(name: "link", type: 0x31, linkName: "file"), after])
        hard.replaceSubrange((1024 + 124)..<(1024 + 136), with: octal(4))
        var h = Data(hard[1024..<1536]); checksum(&h); hard.replaceSubrange(1024..<1536, with: h)
        let sparseBody = Data([1, 2, 3, 4])
        var map = Data("2\n0\n2\n4096\n2\n".utf8); map.append(Data(count: 512 - map.count))
        return try [
            ("ustar", basic),
            ("pax-long", TarTestSupport.makeTar(entries: [header("pax", [("path", String(repeating: "long/", count: 40) + "file"), ("uid", "1234"), ("mtime", "1700000000.25")]), file])),
            ("gnu-long", TarTestSupport.makeTar(entries: [HandTarEntry(name: "L", contents: Data((String(repeating: "long", count: 50) + "\0").utf8), type: 0x4c), HandTarEntry(name: "K", contents: Data((String(repeating: "target", count: 30) + "\0").utf8), type: 0x4b), HandTarEntry(name: "link", type: 0x32, linkName: "short")])),
            ("global", TarTestSupport.makeTar(entries: [header("g", [("uid", "42")], type: 0x67), file, header("g2", [("path", "renamed"), ("size", "4")], type: 0x67), after])),
            ("interleaved", TarTestSupport.makeTar(entries: [header("x", [("path", "local")]), header("g", [("gid", "23")], type: 0x67), file])),
            ("hardlink-ambiguous", hard),
            ("hardlink-empty", TarTestSupport.makeTar(entries: [file, HandTarEntry(name: "link", type: 0x31, linkName: "file"), after])),
            ("hardlink-pax", TarTestSupport.makeTar(entries: [file, header("pax", [("size", "4")]), HandTarEntry(name: "link", contents: Data("body".utf8), type: 0x31, linkName: "file"), after])),
            ("sparse-old", oldGNU()),
            ("sparse00", TarTestSupport.makeTar(entries: [header("pax", [("GNU.sparse.size", "8192"), ("GNU.sparse.numblocks", "2"), ("GNU.sparse.offset", "0"), ("GNU.sparse.numbytes", "2"), ("GNU.sparse.offset", "4096"), ("GNU.sparse.numbytes", "2")]), HandTarEntry(name: "sparse", contents: sparseBody), after])),
            ("sparse01", TarTestSupport.makeTar(entries: [header("pax", [("GNU.sparse.size", "8192"), ("GNU.sparse.map", "0,2,4096,2")]), HandTarEntry(name: "sparse", contents: sparseBody), after])),
            ("sparse10", TarTestSupport.makeTar(entries: [header("pax", [("GNU.sparse.major", "1"), ("GNU.sparse.minor", "0"), ("GNU.sparse.name", "sparse"), ("GNU.sparse.realsize", "8192")]), HandTarEntry(name: "GNUSparseFile.42", contents: map + sparseBody), after])),
            ("other-types", TarTestSupport.makeTar(entries: [UInt8(0x33), 0x34, 0x36, 0x56, 0x41].map { HandTarEntry(name: "other\($0)", type: $0) })),
            ("one-zero", Data(basic.dropLast(512))),
            ("no-zero", Data(basic.dropLast(1024))),
            ("trailing-nonzero", basic + Data([1, 2, 3])),
            ("many-entries", TarTestSupport.makeTar(entries: (0..<70).map { HandTarEntry(name: "f\($0)", contents: Data([UInt8($0)])) }))
        ]
    }
    static func denseGzip(_ image: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TarTestSupportError.commandFailed("dense gzip init")
        }
        defer { deflateEnd(&stream) }
        var result = Data()
        for start in stride(from: 0, to: image.count, by: 64) {
            let input = Data(image[start..<min(image.count, start + 64)])
            var output = Data(count: 1024)
            let status = input.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count); stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(dst.count)
                return deflate(&stream, start + 64 >= image.count ? Z_FINISH : Z_BLOCK)
            } }
            guard status == Z_OK || status == Z_STREAM_END else { throw TarTestSupportError.commandFailed("dense deflate") }
            output.removeLast(Int(stream.avail_out)); result.append(output)
        }
        return result
    }
    static func compressedInputs() throws -> [(String, String, Data)] {
        let tar = try TarTestSupport.makeTar(entries: [HandTarEntry(name: "payload", contents: Data(repeating: 65, count: 140_000))])
        let gz = try GyoshukuFramingTestSupport.gzip(tar, chunkSize: 65_536).data
        let bz = try GyoshukuFramingTestSupport.bzip2(tar, level: 9, chunkSize: 65_536).data
        let xz = try GyoshukuFramingTestSupport.xz(tar, chunkSize: 65_536).data
        var rich = Data([0x1f, 0x8b, 8, 0x1e, 0, 0, 0, 0, 0, 3, 3, 0, 1, 2, 3]) + Data("archive.tar\0".utf8) + Data(repeating: 65, count: 270_000) + Data([0])
        rich.append(GyoshukuFramingTestSupport.le(GyoshukuFramingTestSupport.crc(rich)).prefix(2))
        rich.append(gz.dropFirst(10))
        var gzipCRC = gz; gzipCRC[gzipCRC.count - 8] ^= 1
        var gzipSize = gz; gzipSize[gzipSize.count - 4] ^= 1
        var brokenBZ = bz; brokenBZ[25] ^= 64
        var falseBZ = bz; falseBZ.insert(contentsOf: [0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59], at: 30)
        let footer = xz.count - 12, index = footer - Int(GyoshukuFramingTestSupport.uint32(xz, footer + 4) + 1) * 4
        var indexRecord = xz; indexRecord[index + 2] ^= 1
        var indexCRC = xz; indexCRC[footer - 1] ^= 1
        var blockCheck = xz; blockCheck[index - 1] ^= 1
        return [
            ("gzip-rich-header", "tar.gz", rich), ("gzip-dense-blocks", "tar.gz", try denseGzip(tar)),
            ("gzip-1m", "tar.gz", try GyoshukuFramingTestSupport.gzip(tar).data),
            ("gzip-multiple", "tar.gz", gz + (try GyoshukuFramingTestSupport.gzip(Data()).data)),
            ("gzip-zero-tail", "tar.gz", gz + Data([0])), ("gzip-garbage", "tar.gz", gz + Data([1])),
            ("gzip-crc", "tar.gz", gzipCRC), ("gzip-isize", "tar.gz", gzipSize), ("gzip-truncated", "tar.gz", Data(gz.dropLast(5))),
            ("bzip2-level9", "tar.bz2", bz), ("bzip2-empty-stream", "tar.bz2", bz + (try GyoshukuFramingTestSupport.bzip2(Data()).data) + bz),
            ("bzip2-garbage", "tar.bz2", bz + Data([1])), ("bzip2-corrupt", "tar.bz2", brokenBZ),
            ("bzip2-truncated", "tar.bz2", Data(bz.dropLast(5))), ("bzip2-false-candidate", "tar.bz2", falseBZ),
            ("xz-none", "tar.xz", try GyoshukuFramingTestSupport.xz(tar, chunkSize: 65_536, check: 0).data),
            ("xz-multiple", "tar.xz", xz + xz), ("xz-padding", "tar.xz", xz + Data(count: 4)),
            ("xz-index-record", "tar.xz", indexRecord), ("xz-index-crc", "tar.xz", indexCRC),
            ("xz-block-check", "tar.xz", blockCheck), ("xz-truncated", "tar.xz", Data(xz.dropLast(4)))
        ]
    }
}
