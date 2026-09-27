@_spi(SevenZipEditLayout)
public struct SevenZipEditingSnapshot: Sendable {
    /// 各範囲は 7z 署名を原点とし、物理位置は baseOffset を足した値。
    public let baseOffset: UInt64
    public let versionMajor: UInt8, versionMinor: UInt8
    public let nextHeaderRange: Range<UInt64>
    public let header: SevenZipEditHeader
    public let plainHeaderLength: UInt64
    public let packPosition: UInt64
    public let packs: [SevenZipEditPack]
    public let folders: [SevenZipEditFolder]
    public let substreams: [SevenZipEditSubstream]
    public let files: [SevenZipEditFile]
    public let mainPackEnd: UInt64
    public let filePropertyOrder: [UInt8]
    public let unrepresentedReason: SevenZipEditUnrepresentedReason?
}

@_spi(SevenZipEditLayout)
public enum SevenZipEditHeader: Sendable, Equatable {
    case plain
    case encoded(folders: [SevenZipEditFolder], packRanges: [Range<UInt64>])

    public var isEncrypted: Bool {
        guard case let .encoded(folders, _) = self else { return false }
        return folders.contains { $0.coders.contains(where: \.isAES) }
    }

    public var isCompressed: Bool {
        guard case let .encoded(folders, _) = self else { return false }
        return folders.contains { $0.coders.contains { !$0.isAES && $0.methodID != [0] } }
    }
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditCoder: Sendable, Equatable {
    public let methodID: [UInt8]
    public let inputCount: Int, outputCount: Int
    public let isComplex: Bool
    public let properties: [UInt8]?
    public var isAES: Bool { methodID == [0x06, 0xF1, 0x07, 0x01] }
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditBindPair: Sendable, Equatable {
    public let input: Int
    public let output: Int
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditFolder: Sendable, Equatable {
    public let coders: [SevenZipEditCoder]
    public let bindPairs: [SevenZipEditBindPair]
    public let packedInputs: [Int]
    public let unpackSizes: [UInt64]
    public let finalOutput: Int
    public let crc32: UInt32?
    public let packIndices: Range<Int>
    public let substreamIndices: Range<Int>
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditPack: Sendable, Equatable {
    public let range: Range<UInt64>
    public let crc32: UInt32?
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditSubstream: Sendable, Equatable {
    public let folderIndex: Int
    public let offset: UInt64
    public let size: UInt64
    public let crc32: UInt32?
}

@_spi(SevenZipEditLayout)
public struct SevenZipEditFile: Sendable, Equatable {
    /// UTF-16LE の名前。終端の NUL は含まない。
    public let rawName: [UInt8]
    public let substreamIndex: Int?
    public let isEmptyFile: Bool, isAnti: Bool
    public let creationTime: UInt64?, accessTime: UInt64?, modificationTime: UInt64?
    public let attributes: UInt32?
    public let startPosition: UInt64?
    public var hasStream: Bool { substreamIndex != nil }
}

@_spi(SevenZipEditLayout)
public enum SevenZipEditUnrepresentedReason: Sendable, Equatable {
    case archiveProperties
    case additionalStreams
    case externalData
    case unknownFileProperty(UInt8)
}
