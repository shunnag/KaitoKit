import Foundation
@testable import KaitoKit
import XCTest

// 公開 APPNOTE のフィールドだけを書き換え、任意のバイト位置で巻を区切る。
// 外部実装のソースは参照せず、既存の単巻 fixture を比較対象にする。
struct ZipSplitFixture {
    var bytes: Data
    let layout: ZipFixtureLayout
    let starts: [Int]
    let urls: [URL]

    init(_ original: Data, below directory: URL, name: String = "split.zip",
         wide: Bool = false, sentinelDisk: Bool = false,
         boundaries: (ZipFixtureLayout) -> [Int]) throws {
        let originalLayout = try ZipTestSupport.layout(of: original)
        var bytes = Data([0x50, 0x4b, 0x07, 0x08])
        bytes.append(original[originalLayout.archiveBase..<originalLayout.centralDirectoryOffset])
        let cd = bytes.count
        var centralOffsets: [Int] = []
        var localOffsets: [Int] = []
        var wideFields: [Int?] = []
        for (index, entry) in originalLayout.centralEntryOffsets.enumerated() {
            let nameLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 28))
            let extraLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 30))
            let commentLength = Int(try ZipTestSupport.readUInt16(original, at: entry + 32))
            let extraStart = entry + 46 + nameLength
            var record = Data(original[entry..<extraStart])
            let local = originalLayout.localHeaderOffsets[index] - originalLayout.archiveBase + 4
            localOffsets.append(local)
            var extra = Data(original[extraStart..<(extraStart + extraLength)])
            var offsetField: Int?
            if wide {
                // サイズ・位置の sentinel に応じる 0x0001 の順序を全幅の形で検証する。
                var old: Int = 0
                var preserved = Data()
                while old < extra.count {
                    let size = Int(try ZipTestSupport.readUInt16(extra, at: old + 2))
                    if try ZipTestSupport.readUInt16(extra, at: old) != 1 {
                        preserved.append(extra[old..<(old + 4 + size)])
                    }
                    old += 4 + size
                }
                var payload = Data()
                let reader = try ArchiveReader.open(data: original)
                let info = reader.entries[index]
                ZipTestSupport.appendUInt64(try XCTUnwrap(info.uncompressedSize), to: &payload)
                ZipTestSupport.appendUInt64(try XCTUnwrap(info.compressedSize), to: &payload)
                ZipTestSupport.appendUInt64(UInt64(local), to: &payload)
                ZipTestSupport.appendUInt32(0, to: &payload)
                offsetField = bytes.count + record.count + preserved.count + 4 + 16
                preserved.append(try ZipTestSupport.extraField(identifier: 1, payload: payload))
                extra = preserved
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 20)
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 24)
                try ZipTestSupport.writeUInt32(.max, to: &record, at: 42)
                try ZipTestSupport.writeUInt16(.max, to: &record, at: 34)
            } else {
                try ZipTestSupport.writeUInt32(UInt32(local), to: &record, at: 42)
            }
            try ZipTestSupport.writeUInt16(UInt16(extra.count), to: &record, at: 30)
            centralOffsets.append(bytes.count)
            wideFields.append(offsetField)
            bytes.append(record)
            bytes.append(extra)
            bytes.append(original[(extraStart + extraLength)..<(extraStart + extraLength + commentLength)])
        }
        let cdSize = bytes.count - cd
        var zip64End: Int?
        var locator: Int?
        if wide || originalLayout.zip64EndRecordOffset != nil {
            zip64End = bytes.count
            ZipTestSupport.appendUInt32(0x0606_4b50, to: &bytes)
            ZipTestSupport.appendUInt64(44, to: &bytes)
            ZipTestSupport.appendUInt16(45, to: &bytes)
            ZipTestSupport.appendUInt16(45, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(centralOffsets.count), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(centralOffsets.count), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(cdSize), to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(cd), to: &bytes)
            locator = bytes.count
            ZipTestSupport.appendUInt32(0x0706_4b50, to: &bytes)
            ZipTestSupport.appendUInt32(0, to: &bytes)
            ZipTestSupport.appendUInt64(UInt64(zip64End!), to: &bytes)
            ZipTestSupport.appendUInt32(1, to: &bytes)
        }
        let end = bytes.count
        ZipTestSupport.appendUInt32(0x0605_4b50, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        ZipTestSupport.appendUInt16(UInt16(centralOffsets.count), to: &bytes)
        ZipTestSupport.appendUInt16(UInt16(centralOffsets.count), to: &bytes)
        ZipTestSupport.appendUInt32(UInt32(cdSize), to: &bytes)
        ZipTestSupport.appendUInt32(zip64End == nil ? UInt32(cd) : .max, to: &bytes)
        ZipTestSupport.appendUInt16(0, to: &bytes)
        let layout = ZipFixtureLayout(archiveBase: 0, centralDirectoryOffset: cd,
            centralDirectorySize: cdSize, centralEntryOffsets: centralOffsets,
            localHeaderOffsets: localOffsets, endRecordOffset: end,
            zip64EndRecordOffset: zip64End, zip64LocatorOffset: locator)
        let cuts = boundaries(layout)
        guard cuts == cuts.sorted(), cuts.allSatisfy({ $0 >= 0 && $0 <= (locator ?? end) }) else {
            throw ZipTestSupportError.fixture("invalid split boundaries")
        }
        let starts = [0] + cuts
        func disk(_ offset: Int) -> Int { starts.lastIndex(where: { $0 <= offset })! }
        let lastDisk = starts.count - 1
        let cdDisk = disk(cd)
        let entriesOnLastDisk = centralOffsets.filter { disk($0) == lastDisk }.count
        for (index, entry) in centralOffsets.enumerated() {
            let local = localOffsets[index]
            let number = disk(local)
            let relative = local - starts[number]
            if let field = wideFields[index] {
                try ZipTestSupport.writeUInt64(UInt64(relative), to: &bytes, at: field)
                try ZipTestSupport.writeUInt32(UInt32(number), to: &bytes, at: field + 8)
            } else {
                try ZipTestSupport.writeUInt32(UInt32(relative), to: &bytes, at: entry + 42)
                try ZipTestSupport.writeUInt16(UInt16(number), to: &bytes, at: entry + 34)
            }
        }
        try ZipTestSupport.writeUInt16(sentinelDisk ? .max : UInt16(lastDisk), to: &bytes, at: end + 4)
        try ZipTestSupport.writeUInt16(UInt16(cdDisk), to: &bytes, at: end + 6)
        try ZipTestSupport.writeUInt16(UInt16(entriesOnLastDisk), to: &bytes, at: end + 8)
        if let zip64End, let locator {
            try ZipTestSupport.writeUInt32(UInt32(lastDisk), to: &bytes, at: zip64End + 16)
            try ZipTestSupport.writeUInt32(UInt32(cdDisk), to: &bytes, at: zip64End + 20)
            try ZipTestSupport.writeUInt64(UInt64(entriesOnLastDisk), to: &bytes, at: zip64End + 24)
            try ZipTestSupport.writeUInt64(UInt64(cd - starts[cdDisk]), to: &bytes, at: zip64End + 48)
            let recordDisk = disk(zip64End)
            try ZipTestSupport.writeUInt32(UInt32(recordDisk), to: &bytes, at: locator + 4)
            try ZipTestSupport.writeUInt64(UInt64(zip64End - starts[recordDisk]), to: &bytes, at: locator + 8)
            try ZipTestSupport.writeUInt32(UInt32(starts.count), to: &bytes, at: locator + 16)
        } else {
            try ZipTestSupport.writeUInt32(UInt32(cd - starts[cdDisk]), to: &bytes, at: end + 16)
        }
        let naming = try XCTUnwrap(ZipSplitVolumeSet.naming(for: name))
        self.urls = starts.indices.map { index in
            directory.appendingPathComponent(index == lastDisk ? name
                : ZipSplitVolumeSet.volumeName(naming, number: UInt64(index + 1)))
        }
        self.bytes = bytes
        self.layout = layout
        self.starts = starts
        try write()
    }

    func write() throws {
        for index in urls.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            try Data(bytes[starts[index]..<end]).write(to: urls[index])
        }
    }
}
