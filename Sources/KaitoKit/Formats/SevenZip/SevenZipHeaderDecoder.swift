import Foundation

// 参照仕様: LZMA SDK DOC/7zFormat.txt (18.06) の SignatureHeader・Header・kEncodedHeader。

/// open の間だけ使い、start header から kHeader の解析までを行う。kEncodedHeader と
/// additional streams の復号に使う password・鍵導出の予算・編集記録をこの object が持ち回る。
/// reader には保持させない。
final class SevenZipHeaderDecoder {
    /// start header が指す next header の byte 列と、その署名原点からの位置。
    struct NextHeader {
        let bytes: [UInt8]
        let absoluteOffset: UInt64
    }

    /// 解析する kHeader の byte 列。kEncodedHeader から得たときは、その folder が 7zAES を含むか。
    struct DecodedHeader {
        let bytes: [UInt8]
        let isEncrypted: Bool
    }

    /// header の復号に使う 7zAES 鍵導出の SHA-256 回数の残り。
    private struct KDFWorkBudget {
        var remaining: UInt64

        mutating func charge(_ rounds: UInt64) throws {
            guard rounds <= remaining else {
                throw KaitoError.limitExceeded("7z header KDF work")
            }
            remaining -= rounds
        }
    }

    private static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    private static let signatureHeaderSize: UInt64 = 32

    private let source: any ByteSource
    /// next header の先頭。pack stream はここを越えない。
    private let packedDataEnd: UInt64
    private let limits: ReadLimits
    private let maximumAESCyclesPower: UInt8
    private let keyCache: SevenZipAESKeyCache
    private let packedStreamVerifier: SevenZipPackedStreamVerifier
    private let metadataBudget: SevenZipMetadataBudget
    private let passwordProvider: (any PasswordProvider)?
    private let editRecorder: SevenZipEditRecorder?
    private var kdfBudget: KDFWorkBudget
    /// options の password。header の復号で provider に尋ねたときは、その答え。
    private(set) var password: String?

    init(
        source: any ByteSource,
        packedDataEnd: UInt64,
        options: ReaderOptions,
        keyCache: SevenZipAESKeyCache,
        packedStreamVerifier: SevenZipPackedStreamVerifier,
        metadataBudget: SevenZipMetadataBudget,
        editRecorder: SevenZipEditRecorder?
    ) {
        self.source = source
        self.packedDataEnd = packedDataEnd
        self.limits = options.limits
        self.maximumAESCyclesPower = options.maxSevenZipAESCyclesPower
        self.keyCache = keyCache
        self.packedStreamVerifier = packedStreamVerifier
        self.metadataBudget = metadataBudget
        self.passwordProvider = options.passwordProvider
        self.editRecorder = editRecorder
        self.kdfBudget = KDFWorkBudget(remaining: options.limits.maxSevenZipHeaderKDFWork)
        self.password = options.password
    }

    /// start header（32 byte: 署名 6、version 2、start header の CRC 4、next header の
    /// offset 8・size 8・CRC 4）を検証し、next header を CRC 付きで読む。
    static func readNextHeader(
        source: any ByteSource,
        limits: ReadLimits,
        editRecorder: SevenZipEditRecorder?
    ) throws -> NextHeader {
        guard source.length >= signatureHeaderSize else { throw KaitoError.truncated }
        let fixed = try readByteRange(source: source, offset: 0, count: 32)
        guard Array(fixed[0..<6]) == signature else {
            throw KaitoError.unsupportedFormat
        }
        guard fixed[6] == 0, fixed[7] <= 4 else {
            throw KaitoError.unsupportedMethod("7z version \(fixed[6]).\(fixed[7])")
        }
        let recordedStartCRC = LittleEndian.uint32(fixed, at: 8)
        let startBytes = Array(fixed[12..<32])
        guard CRC32.checksum(startBytes) == recordedStartCRC else {
            throw KaitoError.malformed("7z start-header CRC mismatch")
        }

        let nextOffset = LittleEndian.uint64(fixed, at: 12)
        let nextSize = LittleEndian.uint64(fixed, at: 20)
        let nextCRC = LittleEndian.uint32(fixed, at: 28)
        try Checked.size(nextSize, limit: limits.maxMetadataSize)
        let absoluteOffset = try Checked.add(signatureHeaderSize, nextOffset)
        let end = try Checked.add(absoluteOffset, nextSize)
        guard end <= source.length else {
            throw KaitoError.truncated
        }
        let bytes = try readByteRange(
            source: source,
            offset: absoluteOffset,
            count: try Checked.toInt(nextSize)
        )
        guard CRC32.checksum(bytes) == nextCRC else {
            throw KaitoError.malformed("7z next-header CRC mismatch")
        }
        editRecorder?.state.versionMajor = fixed[6]
        editRecorder?.state.versionMinor = fixed[7]
        editRecorder?.state.nextHeaderRange = absoluteOffset..<end
        return NextHeader(bytes: bytes, absoluteOffset: absoluteOffset)
    }

    /// next header が kHeader ならそのまま返し、kEncodedHeader なら復号・展開した kHeader を返す。
    func decodeNextHeader(_ bytes: [UInt8]) throws -> DecodedHeader {
        guard let first = bytes.first else {
            throw KaitoError.malformed("empty 7z next header")
        }
        if first == SevenZipNID.header.rawValue {
            return DecodedHeader(bytes: bytes, isEncrypted: false)
        }
        guard first == SevenZipNID.encodedHeader.rawValue else {
            throw KaitoError.malformed("unknown 7z next-header kind")
        }

        var cursor = SevenZipHeaderCursor(Array(bytes.dropFirst()))
        let streams = try SevenZipStreamsParser.parse(
            cursor: &cursor,
            limits: limits,
            budget: metadataBudget,
            editRecorder: editRecorder
        )
        guard cursor.isAtEnd else {
            throw KaitoError.malformed("7z encoded header has trailing bytes")
        }
        let decoded = try decodeStreamsResolvingPassword(streams, limit: limits.maxMetadataSize)
        guard decoded.count == 1 else {
            throw KaitoError.malformed("7z encoded header must contain one substream")
        }
        let stream = streams.substreams[0]
        guard streams.folders.indices.contains(stream.folderIndex) else {
            throw KaitoError.malformed("7z encoded header references an invalid folder")
        }
        let isEncrypted = streams.folders[stream.folderIndex].coders.contains {
            SevenZipMethod.kind(for: $0.methodID) == .aes
        }
        editRecorder?.state.encodedStreams = streams
        return DecodedHeader(bytes: [UInt8](decoded[0]), isEncrypted: isEncrypted)
    }

    /// kHeader を解析する。additional streams もここで復号する。暗号化された header の
    /// 構造の破損は `wrongPassword` として投げる。
    func parseHeader(_ decoded: DecodedHeader) throws -> SevenZipParsedHeader {
        editRecorder?.state.plainHeaderLength = UInt64(decoded.bytes.count)
        do {
            return try SevenZipHeaderParser.parse(
                bytes: decoded.bytes,
                limits: limits,
                budget: metadataBudget,
                editRecorder: editRecorder
            ) { streams, limit in
                try decodeStreamsResolvingPassword(streams, limit: limit)
            }
        } catch {
            guard decoded.isEncrypted else { throw error }
            throw SevenZipFolderDecoderFactory.wrongPasswordIfStructural(error)
        }
    }

    /// password が無くて復号できないときだけ provider に一度尋ね、その答えで復号し直す。
    private func decodeStreamsResolvingPassword(
        _ streams: SevenZipStreamsInfo,
        limit: UInt64
    ) throws -> [Data] {
        do {
            return try decodeStreams(streams, limit: limit)
        } catch KaitoError.passwordRequired {
            guard password == nil, let passwordProvider,
                  let supplied = try passwordProvider.password(for: .sevenZip) else {
                throw KaitoError.passwordRequired
            }
            password = supplied
            return try decodeStreams(streams, limit: limit)
        }
    }

    /// header 用の streams を全て展開し、substream ごとの byte 列を CRC 付きで返す。
    private func decodeStreams(
        _ streams: SevenZipStreamsInfo,
        limit: UInt64
    ) throws -> [Data] {
        let ranges = try SevenZipFolderLayout.ranges(
            for: streams,
            sourceLength: source.length,
            packedDataEnd: packedDataEnd
        )
        var folderData: [Data] = []
        folderData.reserveCapacity(streams.folders.count)
        var aggregate: UInt64 = 0
        for index in streams.folders.indices {
            try checkCancellation(every: index)
            let factory = try SevenZipFolderDecoderFactory(
                source: source,
                folder: streams.folders[index],
                packedRanges: ranges[index],
                limits: limits,
                password: password,
                keyCache: keyCache,
                maximumAESCyclesPower: maximumAESCyclesPower,
                packedStreamVerifier: packedStreamVerifier
            )
            aggregate = try Checked.add(aggregate, factory.finalSize)
            try Checked.size(aggregate, limit: limit)
            folderData.append(try factory.decodeAll(limit: limit) {
                try kdfBudget.charge($0)
            })
        }

        var result: [Data] = []
        result.reserveCapacity(streams.substreams.count)
        for (index, stream) in streams.substreams.enumerated() {
            try checkCancellation(every: index)
            guard stream.folderIndex >= 0, stream.folderIndex < folderData.count else {
                throw KaitoError.malformed("7z substream references an invalid folder")
            }
            let data = folderData[stream.folderIndex]
            let start = try Checked.toInt(stream.offset)
            let size = try Checked.toInt(stream.size)
            guard start <= data.count, size <= data.count - start else {
                throw KaitoError.malformed("7z substream exceeds decoded folder data")
            }
            let slice: Data
            if start == 0, size == data.count {
                // 典型的な encoded header は folder 全体が 1 substream なので CoW 共有する。
                slice = data
            } else {
                slice = Data(data[start..<(start + size)])
            }
            if let expected = stream.digest.value,
               CRC32.checksum(slice) != expected {
                let encrypted = streams.folders[stream.folderIndex].coders.contains {
                    SevenZipMethod.kind(for: $0.methodID) == .aes
                }
                if encrypted { throw KaitoError.wrongPassword }
                throw KaitoError.checksumMismatch(entry: -1)
            }
            result.append(slice)
        }
        return result
    }
}
