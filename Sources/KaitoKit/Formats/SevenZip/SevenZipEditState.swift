// open では生値だけを保持し、既存の folder graph の SPI 化は要求時に行う。
struct SevenZipEditState: Sendable {
    var baseOffset: UInt64 = 0
    var versionMajor: UInt8 = 0
    var versionMinor: UInt8 = 0
    var nextHeaderRange: Range<UInt64> = 0..<0
    var encodedStreams: SevenZipStreamsInfo?
    var plainHeaderLength: UInt64 = 0
    var files: [SevenZipEditFile] = []
    var filePropertyOrder: [UInt8] = []
    var unrepresentedReason: SevenZipEditUnrepresentedReason?

    func snapshot(streams: SevenZipStreamsInfo?) -> SevenZipEditingSnapshot {
        let packs = Self.packs(streams)
        let header: SevenZipEditHeader
        if let encodedStreams {
            header = .encoded(folders: Self.folders(encodedStreams),
                              packRanges: Self.packs(encodedStreams).map(\.range))
        } else {
            header = .plain
        }
        return SevenZipEditingSnapshot(
            baseOffset: baseOffset, versionMajor: versionMajor, versionMinor: versionMinor,
            nextHeaderRange: nextHeaderRange, header: header, plainHeaderLength: plainHeaderLength,
            packPosition: streams?.packInfo.position ?? 0, packs: packs,
            folders: Self.folders(streams), substreams: (streams?.substreams ?? []).map {
                SevenZipEditSubstream(folderIndex: $0.folderIndex, offset: $0.offset,
                                      size: $0.size, crc32: $0.digest.value)
            }, files: files, mainPackEnd: packs.last?.range.upperBound ?? (32 + (streams?.packInfo.position ?? 0)),
            filePropertyOrder: filePropertyOrder, unrepresentedReason: unrepresentedReason)
    }

    private static func packs(_ streams: SevenZipStreamsInfo?) -> [SevenZipEditPack] {
        guard let streams else { return [] }
        // SevenZipFolderLayout が open 時に加算と source 内の範囲を検証済み。
        var offset = 32 + streams.packInfo.position
        return streams.packInfo.sizes.enumerated().map { index, size in
            defer { offset += size }
            return SevenZipEditPack(range: offset..<(offset + size),
                crc32: index < streams.packInfo.digests.count ? streams.packInfo.digests[index].value : nil)
        }
    }

    private static func folders(_ streams: SevenZipStreamsInfo?) -> [SevenZipEditFolder] {
        guard let streams else { return [] }
        var packIndex = 0, substreamIndex = 0
        return streams.folders.enumerated().map { index, folder in
            let packEnd = packIndex + folder.packedIndices.count
            let substreamStart = substreamIndex
            while substreamIndex < streams.substreams.count,
                  streams.substreams[substreamIndex].folderIndex == index { substreamIndex += 1 }
            defer { packIndex = packEnd }
            return SevenZipEditFolder(coders: folder.coders.map {
                SevenZipEditCoder(methodID: $0.methodID, inputCount: $0.inputCount,
                    outputCount: $0.outputCount, isComplex: $0.flags & SevenZipCoderFlag.complex != 0,
                    properties: $0.flags & SevenZipCoderFlag.hasProperties != 0 ? $0.properties : nil)
            }, bindPairs: folder.bindPairs.map { SevenZipEditBindPair(input: $0.input, output: $0.output) },
            packedInputs: folder.packedIndices, unpackSizes: folder.unpackSizes,
            finalOutput: folder.finalOutputIndex, crc32: folder.digest.value,
            packIndices: packIndex..<packEnd, substreamIndices: substreamStart..<substreamIndex)
        }
    }
}

// 解析中だけ使う。reader と reopen が共有するのは上の値型だけ。
final class SevenZipEditRecorder {
    var state = SevenZipEditState()

    func note(_ reason: SevenZipEditUnrepresentedReason) {
        if state.unrepresentedReason == nil { state.unrepresentedReason = reason }
    }
}
