import Foundation
@testable import KaitoKit

// 公開 ZIP / 7z byte 表に基づくクリーンルームの project-owned テスト入力。
// 第三者 archiver / decoder の実装 source は参照しない。
enum RawRecordArchiveBuilder {
    static func descriptorEntry(
        name: String = "entry.txt",
        contents: Data = Data("raw record 日本語\n".utf8),
        signed: Bool,
        zip64: Bool,
        localZIP64: Bool = true,
        centralZIP64: Bool = true
    ) throws -> HandZipEntry {
        let compressed = storedDeflate(contents)
        var entry = HandZipEntry(
            name: name,
            uncompressedData: contents,
            compressedData: compressed,
            method: 8,
            // local と central の extra 長が異なっても、元の local byte を運べることを確認する。
            localExtra: try ZipTestSupport.extraField(identifier: 0xCAFE, payload: Data([1, 2, 3])),
            centralExtra: try ZipTestSupport.extraField(identifier: 0xBEEF, payload: Data([4])),
            hasDataDescriptor: true
        )
        entry.dataDescriptorHasSignature = signed
        entry.dataDescriptorUsesZIP64 = zip64
        if zip64, localZIP64 {
            entry.localExtra += try ZipTestSupport.zip64Extra(values: [0, 0])
            entry.localCompressedSize = .max
            entry.localUncompressedSize = .max
        }
        if zip64, centralZIP64 {
            entry.centralExtra += try ZipTestSupport.zip64Extra(values: [
                UInt64(contents.count), UInt64(compressed.count),
            ])
            entry.centralCompressedSize = .max
            entry.centralUncompressedSize = .max
        }
        return entry
    }

    // RFC 1951 の BFINAL=1 / BTYPE=00 を使う独立した小さな deflate fixture。
    static func storedDeflate(_ contents: Data) -> Data {
        precondition(contents.count <= Int(UInt16.max))
        let length = UInt16(contents.count)
        return Data([1]) + little(length) + little(~length) + contents
    }

    // writer はテスト内だけに置く。公開 API の範囲をコピーし、CD の offset と EOCD を再構築する。
    // ZIP64 entry の extra は保持する。これらの小さな fixture の local offset は ZIP32 に収まる。
    static func rebuildZIP(
        source: Data,
        records: [RawEntryRecord],
        localOrder: [Int],
        centralOrder: [Int]? = nil
    ) throws -> Data {
        let layout = try ZipTestSupport.layout(of: source)
        let centralOrder = centralOrder ?? localOrder
        precondition(Set(localOrder) == Set(centralOrder))
        var result = Data()
        var offsets: [Int: UInt32] = [:]
        for index in localOrder {
            offsets[index] = UInt32(result.count)
            let range = records[index].recordRange
            result += source[Int(range.lowerBound)..<Int(range.upperBound)]
        }
        let centralOffset = result.count
        for index in centralOrder {
            let start = layout.centralEntryOffsets[index]
            let end = index + 1 < layout.centralEntryOffsets.count
                ? layout.centralEntryOffsets[index + 1]
                : layout.centralDirectoryOffset + layout.centralDirectorySize
            var record = Data(source[start..<end])
            guard try ZipTestSupport.readUInt32(record, at: 42) != UInt32.max,
                  let offset = offsets[index] else {
                throw ZipTestSupportError.fixture("raw-copy fixture needs a ZIP32 local offset")
            }
            try ZipTestSupport.writeUInt32(offset, to: &record, at: 42)
            result += record
        }
        let centralSize = result.count - centralOffset
        result += little(UInt32(0x0605_4B50))
        result += little(UInt16(0)) + little(UInt16(0))
        result += little(UInt16(centralOrder.count)) + little(UInt16(centralOrder.count))
        result += little(UInt32(centralSize)) + little(UInt32(centralOffset)) + little(UInt16(0))
        return result
    }

    // Copy coder 一つの folder に二つの substream を置いた最小の solid 7z。
    static func solidSevenZip() -> Data {
        let header: [UInt8] = [
            0x01, 0x04,                         // Header, MainStreamsInfo
            0x06, 0, 1, 0x09, 2, 0,            // PackInfo: offset 0, 1 stream, size 2
            0x07, 0x0B, 1, 0, 1, 1, 0,         // UnpackInfo: 1 inline folder, Copy coder
            0x0C, 2, 0,                        // CodersUnpackSize: 2
            0x08, 0x0D, 2, 0x09, 1, 0, 0,      // SubStreamsInfo: 2 streams, first size 1
            0x05, 2,                           // FilesInfo: 2 files
            0x11, 9, 0, 0x61, 0, 0, 0, 0x62, 0, 0, 0, // 名前 a / b、UTF-16LE
            0, 0,
        ]
        let packed = Data([0x41, 0x42])
        let start = little(UInt64(packed.count)) + little(UInt64(header.count))
            + little(CRC32.checksum(header))
        return Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])
            + little(CRC32.checksum(start)) + start + packed + Data(header)
    }

    static func little<T: FixedWidthInteger>(_ value: T) -> Data {
        Data((0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
