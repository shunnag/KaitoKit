/// `ArchiveReader.sevenZipEditingSnapshot()` が返す、7z の header と pack 配置の生値。
/// `ReaderOptions.recordsSevenZipEditLayout` を有効にして開いた 7z だけが持つ。
/// 範囲と位置は特記がなければ 7z 署名を原点とする。
@_spi(SevenZipEditLayout)
public struct SevenZipEditingSnapshot: Sendable {
    /// 各範囲は 7z 署名を原点とし、物理位置は baseOffset を足した値。
    public let baseOffset: UInt64
    /// start header の format version（byte 6 と 7）。
    public let versionMajor: UInt8, versionMinor: UInt8
    /// 署名原点からの next header の範囲。
    public let nextHeaderRange: Range<UInt64>
    /// `.plain` は kHeader そのまま、`.encoded` は kEncodedHeader の folder と pack 範囲。
    public let header: SevenZipEditHeader
    /// 復号・展開後の kHeader の byte 数。`.plain` では next header の長さと同じ。
    public let plainHeaderLength: UInt64
    /// main streams の PackInfo の位置。署名原点 + 32（start header の直後）からの相対位置。
    public let packPosition: UInt64
    /// main streams の pack 範囲と CRC。PackInfo の順。
    public let packs: [SevenZipEditPack]
    /// main streams の folder。UnpackInfo の順。
    public let folders: [SevenZipEditFolder]
    /// main streams の substream。folder 順、folder 内は出力順。
    public let substreams: [SevenZipEditSubstream]
    /// FilesInfo の file。header に書かれた順。
    public let files: [SevenZipEditFile]
    /// 最後の pack の上限（pack が無ければ 32 + packPosition）。
    public let mainPackEnd: UInt64
    /// FilesInfo の property ID の出現順（Dummy・未知を含む。kEnd は含まない）。
    public let filePropertyOrder: [UInt8]
    /// 最初に見つけた、この snapshot で再構成できない header 要素。
    public let unrepresentedReason: SevenZipEditUnrepresentedReason?
}

/// next header の種類。
@_spi(SevenZipEditLayout)
public enum SevenZipEditHeader: Sendable, Equatable {
    /// next header が kHeader そのもの。
    case plain
    /// next header が kEncodedHeader。kHeader は `packRanges`（署名原点）の pack を `folders` で復号・展開したもの。
    case encoded(folders: [SevenZipEditFolder], packRanges: [Range<UInt64>])

    /// `.encoded` で、7zAES の coder を含む。
    public var isEncrypted: Bool {
        guard case let .encoded(folders, _) = self else { return false }
        return folders.contains { $0.coders.contains(where: \.isAES) }
    }

    /// `.encoded` で、AES 以外かつ Copy 以外の coder を含む。
    public var isCompressed: Bool {
        guard case let .encoded(folders, _) = self else { return false }
        return folders.contains { $0.coders.contains { !$0.isAES && $0.methodID != [0] } }
    }
}

/// folder 内の coder 一つ。
@_spi(SevenZipEditLayout)
public struct SevenZipEditCoder: Sendable, Equatable {
    /// method ID の生の byte 列（1…8 byte）。
    public let methodID: [UInt8]
    /// coder の入力 stream 数と出力 stream 数。`isComplex` でなければどちらも 1。
    public let inputCount: Int, outputCount: Int
    /// coder flags 0x10 の生値。入力数・出力数を明示して書く coder。
    public let isComplex: Bool
    /// coder flags 0x20 が立つときの properties の生値。flag が無ければ nil。
    public let properties: [UInt8]?
    /// method ID が 7zAES（06 F1 07 01）。
    public var isAES: Bool { methodID == [0x06, 0xF1, 0x07, 0x01] }
}

/// folder 内で、ある coder の出力を別の coder の入力へつなぐ組。
@_spi(SevenZipEditLayout)
public struct SevenZipEditBindPair: Sendable, Equatable {
    /// folder 全体で通し番号にした coder 入力の index。
    public let input: Int
    /// folder 全体で通し番号にした coder 出力の index。
    public let output: Int
}

/// main streams または kEncodedHeader の folder 一つ。
@_spi(SevenZipEditLayout)
public struct SevenZipEditFolder: Sendable, Equatable {
    /// coder。header に書かれた順。
    public let coders: [SevenZipEditCoder]
    public let bindPairs: [SevenZipEditBindPair]
    /// pack から直接読む coder 入力の index（folder 全体の通し番号）。k 番目が pack `packIndices.lowerBound + k` を読む。
    public let packedInputs: [Int]
    /// coder 出力ごとの展開後の byte 数（CodersUnpackSize）。index は folder 全体の通し番号。
    public let unpackSizes: [UInt64]
    /// どの bind pair にもつながらない出力。folder の展開結果になる。
    public let finalOutput: Int
    /// folder の展開結果の CRC（UnpackInfo の CRC）。記録が無ければ nil。
    public let crc32: UInt32?
    /// `packs` への半開区間。
    public let packIndices: Range<Int>
    /// `substreams` への半開区間。
    public let substreamIndices: Range<Int>
}

/// pack stream 一つ。
@_spi(SevenZipEditLayout)
public struct SevenZipEditPack: Sendable, Equatable {
    /// 署名原点の byte 範囲。
    public let range: Range<UInt64>
    /// PackInfo の CRC。記録が無ければ nil。
    public let crc32: UInt32?
}

/// folder の展開結果を file ごとに区切った substream 一つ。
@_spi(SevenZipEditLayout)
public struct SevenZipEditSubstream: Sendable, Equatable {
    /// `folders` への index。
    public let folderIndex: Int
    /// folder の展開結果の中での開始位置。
    public let offset: UInt64
    public let size: UInt64
    /// substream の CRC。substream が一つの folder で folder の CRC があれば、それを引き継ぐ。
    public let crc32: UInt32?
}

/// FilesInfo の file 一つ。日時と属性は header の生値。
@_spi(SevenZipEditLayout)
public struct SevenZipEditFile: Sendable, Equatable {
    /// UTF-16LE の名前。終端の NUL は含まない。
    public let rawName: [UInt8]
    /// `substreams` への index。empty stream は nil。
    public let substreamIndex: Int?
    /// EmptyFile と Anti の bit。empty stream の file だけが true になりうる。
    public let isEmptyFile: Bool, isAnti: Bool
    /// FILETIME（1601-01-01 UTC からの 100 ns 単位）の生値。未定義なら nil。
    public let creationTime: UInt64?, accessTime: UInt64?, modificationTime: UInt64?
    /// Windows 属性の生値。0x8000 が立てば上位 16 bit が Unix mode。
    public let attributes: UInt32?
    /// StartPos property の生値。
    public let startPosition: UInt64?
    public var hasStream: Bool { substreamIndex != nil }
}

/// snapshot が表せない header 要素。解析中に最初に見つけたものだけを記録する。
@_spi(SevenZipEditLayout)
public enum SevenZipEditUnrepresentedReason: Sendable, Equatable {
    /// kArchiveProperties がある。
    case archiveProperties
    /// kAdditionalStreamsInfo がある。
    case additionalStreams
    /// folder 定義か file property が External（additional streams 参照）で書かれている。
    case externalData
    /// FilesInfo に、snapshot が値を持たない property ID（kComment や未知の ID）がある。
    case unknownFileProperty(UInt8)
}
