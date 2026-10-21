import Foundation
@testable import KaitoKit

/// 公開 7z header と既存の raw LZMA2 vector だけで、外部 tool 不要の solid 書庫を作る。
enum SevenZipParallelTestSupport {
    struct Fixture: Sendable {
        var packed: Data
        let payloads: [Data]
        var property: UInt8 = 8 // 64 KiB
        var filters: [([UInt8], [UInt8])] = []
        var folderCRC: UInt32?
        var entryCRCs: [UInt32]?

        var output: Data { payloads.reduce(into: Data()) { $0.append($1) } }
        var folder: SevenZipFolder {
            let methods = [([UInt8](arrayLiteral: 0x21), [property])] + filters
            let coders = methods.enumerated().map { index, method in
                SevenZipCoder(methodID: method.0, inputCount: 1, outputCount: 1,
                              properties: method.1, firstInput: index, firstOutput: index)
            }
            return SevenZipFolder(coders: coders,
                bindPairs: (1..<coders.count).map { SevenZipBindPair(input: $0, output: $0 - 1) },
                packedIndices: [0], inputCount: coders.count, outputCount: coders.count,
                finalOutputIndex: coders.count - 1,
                unpackSizes: Array(repeating: UInt64(output.count), count: coders.count),
                digest: SevenZipDigest(value: folderCRC))
        }

        func factory(workers: Int, limits: ReadLimits = ReadLimits(),
                     diagnostics: ParallelIndependentDecompressor.Diagnostics? = nil,
                     source: (any ByteSource)? = nil,
                     avoidsHeaderScans: Bool = false,
                     resetIndexCache: SevenZipLZMA2ResetIndexCache = SevenZipLZMA2ResetIndexCache()) throws -> SevenZipFolderDecoderFactory {
            try SevenZipFolderDecoderFactory(source: source ?? DataByteSource(packed), folder: folder,
                packedRanges: [0: SevenZipPackRange(offset: 0, size: UInt64(packed.count),
                                                   digest: SevenZipDigest(value: nil))],
                limits: limits, password: nil, keyCache: SevenZipAESKeyCache(),
                maximumAESCyclesPower: 24, workers: workers, parallelDiagnostics: diagnostics,
                resetIndexCache: resetIndexCache, avoidsHeaderScans: avoidsHeaderScans)
        }

        func archive() -> Data {
            var header: [UInt8] = [0x01, 0x04, 0x06] + number(0) + number(1)
                + [0x09] + number(UInt64(packed.count)) + [0, 0x07, 0x0B] + number(1) + [0]
            header += number(UInt64(folder.coders.count))
            for coder in folder.coders {
                header += [UInt8(coder.methodID.count) | (coder.properties.isEmpty ? 0 : 0x20)] + coder.methodID
                if !coder.properties.isEmpty {
                    header += number(UInt64(coder.properties.count)) + coder.properties
                }
            }
            for pair in folder.bindPairs { header += number(UInt64(pair.input)) + number(UInt64(pair.output)) }
            header += [0x0C]
            for size in folder.unpackSizes { header += number(size) }
            if let folderCRC { header += [0x0A, 1] + SevenZipEditTestBytes.little(folderCRC) }
            header += [0, 0x08, 0x0D] + number(UInt64(payloads.count)) + [0x09]
            for payload in payloads.dropLast() { header += number(UInt64(payload.count)) }
            // 複数 substream の CRC は folder CRC とは別に保持する。
            if payloads.count > 1 || folderCRC == nil {
                header += [0x0A, 1]
                for crc in entryCRCs ?? payloads.map({ CRC32.checksum($0) }) {
                    header += SevenZipEditTestBytes.little(crc)
                }
            }
            header += [0, 0, 0x05] + number(UInt64(payloads.count))
            var names: [UInt8] = [0]
            for index in payloads.indices {
                for unit in "entry-\(index).bin".utf16 { names += SevenZipEditTestBytes.little(unit) }
                names += [0, 0]
            }
            header += [0x11] + number(UInt64(names.count)) + names + [0, 0]
            return SevenZipEditTestBytes.archive(header: header, packed: Array(packed))
        }
    }

    static func rawUnit(_ payload: Data) -> Data {
        precondition(!payload.isEmpty)
        var result = Data(), offset = 0
        while offset < payload.count {
            let size = min(65_536, payload.count - offset)
            result.append(contentsOf: [offset == 0 ? 1 : 2, UInt8((size - 1) >> 8), UInt8(truncatingIfNeeded: size - 1)])
            result.append(payload[offset..<(offset + size)])
            offset += size
        }
        return result
    }

    static func raw(sizes: [Int] = [65_003, 131_077, 65_539, 70_001]) -> Fixture {
        let payloads = sizes.enumerated().map { id, size in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ id) })
        }
        let packed = payloads.reduce(into: Data()) { $0.append(rawUnit($1)) } + Data([0])
        return Fixture(packed: packed, payloads: payloads, folderCRC: CRC32.checksum(payloads.reduce(into: Data()) { $0.append($1) }))
    }

    static func compressed() throws -> Fixture {
        // LZMA2DecoderTests の公開 raw vector（xz 5.8.3、lc=0 / 3 / 4）を連結する。
        let vectors = try ["e00011000800003099abddc0cb070000", "e0001100085d00309888aa0207d00000",
                           "e0001100085e00309888aa0207d00000"].map(Hex.data)
        let packed = vectors.reduce(into: Data()) { $0.append($1.dropLast()) } + Data([0])
        let payloads = Array(repeating: Data("abcabcabcabcabcabc".utf8), count: vectors.count)
        return Fixture(packed: packed, payloads: payloads)
    }

    private static func number(_ value: UInt64) -> [UInt8] {
        for count in 0..<8 where value < (UInt64(1) << (7 + count * 7)) {
            let prefix = UInt8(truncatingIfNeeded: 0xFF << (8 - count))
            return [prefix | UInt8(value >> (count * 8))]
                + (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        return [0xFF] + SevenZipEditTestBytes.little(value)
    }
}
