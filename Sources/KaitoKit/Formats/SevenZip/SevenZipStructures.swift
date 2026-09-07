import Foundation

// 参照仕様: LZMA SDK DOC/7zFormat.txt (18.06) と DOC/Methods.txt。
// ヘッダ内の全長・個数は、配列を確保する前に入力残量と ReadLimits の双方で検証する。

enum SevenZipFormatLimits {
    // 7zz が生成する BCJ2 + AES の複合 folder を受理しつつ、
    // graph 走査の再帰深度と decoder 構築コストを一定に抑える。
    static let maxFolderCodersAndStreams = 64
}

enum SevenZipNID: UInt8 {
    case end = 0x00
    case header = 0x01
    case archiveProperties = 0x02
    case additionalStreamsInfo = 0x03
    case mainStreamsInfo = 0x04
    case filesInfo = 0x05
    case packInfo = 0x06
    case unpackInfo = 0x07
    case subStreamsInfo = 0x08
    case size = 0x09
    case crc = 0x0A
    case folder = 0x0B
    case codersUnpackSize = 0x0C
    case numUnpackStream = 0x0D
    case emptyStream = 0x0E
    case emptyFile = 0x0F
    case anti = 0x10
    case name = 0x11
    case creationTime = 0x12
    case accessTime = 0x13
    case modificationTime = 0x14
    case windowsAttributes = 0x15
    case comment = 0x16
    case encodedHeader = 0x17
    case startPosition = 0x18
    case dummy = 0x19
}

struct SevenZipDigest: Sendable, Equatable {
    let value: UInt32?
}

struct SevenZipCoder: Sendable, Equatable {
    let methodID: [UInt8]
    let inputCount: Int
    let outputCount: Int
    let properties: [UInt8]
    let firstInput: Int
    let firstOutput: Int
}

struct SevenZipBindPair: Sendable, Equatable {
    let input: Int
    let output: Int
}

struct SevenZipFolder: Sendable, Equatable {
    var coders: [SevenZipCoder]
    let bindPairs: [SevenZipBindPair]
    let packedIndices: [Int]
    let inputCount: Int
    let outputCount: Int
    let finalOutputIndex: Int
    var unpackSizes: [UInt64]
    var digest: SevenZipDigest

    func coderIndex(containingOutput output: Int) -> Int? {
        coders.firstIndex {
            output >= $0.firstOutput && output < $0.firstOutput + $0.outputCount
        }
    }

    func boundOutput(forInput input: Int) -> Int? {
        bindPairs.first(where: { $0.input == input })?.output
    }
}

struct SevenZipPackInfo: Sendable, Equatable {
    let position: UInt64
    let sizes: [UInt64]
    let digests: [SevenZipDigest]
}

struct SevenZipSubstream: Sendable, Equatable {
    let folderIndex: Int
    let offset: UInt64
    let size: UInt64
    let digest: SevenZipDigest
}

struct SevenZipStreamsInfo: Sendable, Equatable {
    let packInfo: SevenZipPackInfo
    let folders: [SevenZipFolder]
    let substreams: [SevenZipSubstream]
}

// 7z header の各 parser が個別に上限を使い切らないよう、open 全体で
// 単調増加する論理 metadata 予算を共有する。
final class SevenZipMetadataBudget {
    private let limit: UInt64
    private(set) var used: UInt64 = 0

    init(limit: UInt64) {
        self.limit = limit
    }

    func reserve(_ bytes: UInt64, description: String) throws {
        let next = try Checked.add(used, bytes)
        guard next <= limit else {
            throw KaitoError.limitExceeded(
                "\(description) exceeds aggregate 7z metadata limit"
            )
        }
        used = next
    }

    func reserve(
        count: Int,
        bytesPerRecord: UInt64,
        description: String
    ) throws {
        guard count >= 0 else {
            throw KaitoError.malformed("negative 7z metadata record count")
        }
        try reserve(
            try Checked.mul(UInt64(count), bytesPerRecord),
            description: description
        )
    }
}

struct SevenZipHeaderCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int
    private let upperBound: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.upperBound = bytes.count
    }

    private init(bytes: [UInt8], offset: Int, upperBound: Int) {
        self.bytes = bytes
        self.offset = offset
        self.upperBound = upperBound
    }

    var remaining: Int { upperBound - offset }
    var isAtEnd: Bool { offset == upperBound }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw KaitoError.truncated }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readUInt32LE() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(try readUInt8()) << shift
        }
        return value
    }

    mutating func readUInt64LE() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(try readUInt8()) << shift
        }
        return value
    }

    // 先頭 byte の連続 1 の数が後続 byte 数になる 7z UINT64。
    mutating func readNumber() throws -> UInt64 {
        let first = try readUInt8()
        var mask: UInt8 = 0x80
        var value: UInt64 = 0

        for byteIndex in 0..<8 {
            if first & mask == 0 {
                let prefix = UInt64(first & (mask &- 1))
                let shift = UInt64(byteIndex * 8)
                return try Checked.add(value, try Checked.shiftLeft(prefix, by: shift))
            }
            let byte = UInt64(try readUInt8())
            value |= byte << UInt64(byteIndex * 8)
            mask >>= 1
        }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let end = offset + count
        let result = Array(bytes[offset..<end])
        offset = end
        return result
    }

    mutating func readSubcursor(_ count: Int) throws -> SevenZipHeaderCursor {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        let start = offset
        offset += count
        return SevenZipHeaderCursor(bytes: bytes, offset: start, upperBound: start + count)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw KaitoError.truncated }
        offset += count
    }

    mutating func readBitVector(count: Int) throws -> [Bool] {
        guard count >= 0 else { throw KaitoError.malformed("negative 7z bit-vector size") }
        let byteCount = (count + 7) / 8
        guard byteCount <= remaining else { throw KaitoError.truncated }
        var result = [Bool](repeating: false, count: count)
        var mask: UInt8 = 0
        var byte: UInt8 = 0
        for index in 0..<count {
            if mask == 0 {
                byte = try readUInt8()
                mask = 0x80
            }
            result[index] = byte & mask != 0
            mask >>= 1
        }
        return result
    }

    mutating func readDefinedVector(count: Int) throws -> [Bool] {
        let allDefined = try readUInt8()
        switch allDefined {
        case 0:
            return try readBitVector(count: count)
        case 1:
            return [Bool](repeating: true, count: count)
        default:
            throw KaitoError.malformed("invalid 7z all-defined flag")
        }
    }
}

enum SevenZipStreamsParser {
    // Swift の Array/Dictionary backing storage も含めた保守的な論理量。
    // count 比例の確保前に maxTotalMetadataSize へ照合する。
    private static let packStreamMetadataBytes: UInt64 = 64
    private static let folderMetadataBytes: UInt64 = 256
    private static let substreamMetadataBytes: UInt64 = 64
    private static let coderMetadataBytes: UInt64 = 64
    private static let coderStreamMetadataBytes: UInt64 = 16
    private static let bindPairMetadataBytes: UInt64 = 32
    private static let packedIndexMetadataBytes: UInt64 = 16
    private static let unpackSizeMetadataBytes: UInt64 = 16

    static func parse(
        cursor: inout SevenZipHeaderCursor,
        limits: ReadLimits,
        externalStreams: [Data] = [],
        budget suppliedBudget: SevenZipMetadataBudget? = nil
    ) throws -> SevenZipStreamsInfo {
        let budget = suppliedBudget
            ?? SevenZipMetadataBudget(limit: limits.maxTotalMetadataSize)
        var packInfo = SevenZipPackInfo(position: 0, sizes: [], digests: [])
        var folders: [SevenZipFolder] = []
        var sawPackInfo = false
        var sawUnpackInfo = false
        var substreamCounts: [Int]?
        var explicitSubstreamSizes: [[UInt64]]?
        var substreamDigests: [SevenZipDigest]?

        while true {
            guard let nid = SevenZipNID(rawValue: try cursor.readUInt8()) else {
                throw KaitoError.malformed("unknown 7z streams-info property")
            }
            switch nid {
            case .end:
                if substreamCounts == nil {
                    try budget.reserve(
                        count: folders.count,
                        bytesPerRecord: substreamMetadataBytes,
                        description: "7z substream metadata"
                    )
                }
                let substreams = try makeSubstreams(
                    folders: folders,
                    counts: substreamCounts,
                    explicitSizes: explicitSubstreamSizes,
                    digests: substreamDigests
                )
                let requiredPackedStreams = folders.reduce(into: 0) {
                    $0 += $1.packedIndices.count
                }
                guard requiredPackedStreams == packInfo.sizes.count else {
                    throw KaitoError.malformed("7z folder and pack-stream counts differ")
                }
                return SevenZipStreamsInfo(
                    packInfo: packInfo,
                    folders: folders,
                    substreams: substreams
                )

            case .packInfo:
                guard !sawPackInfo else {
                    throw KaitoError.malformed("duplicate 7z PackInfo")
                }
                sawPackInfo = true
                packInfo = try parsePackInfo(
                    cursor: &cursor,
                    limits: limits,
                    budget: budget
                )

            case .unpackInfo:
                guard !sawUnpackInfo else {
                    throw KaitoError.malformed("duplicate 7z UnpackInfo")
                }
                sawUnpackInfo = true
                folders = try parseUnpackInfo(
                    cursor: &cursor,
                    limits: limits,
                    externalStreams: externalStreams,
                    budget: budget
                )

            case .subStreamsInfo:
                guard sawUnpackInfo, substreamCounts == nil else {
                    throw KaitoError.malformed("misplaced or duplicate 7z SubStreamsInfo")
                }
                let parsed = try parseSubStreamsInfo(
                    cursor: &cursor,
                    folders: folders,
                    limits: limits,
                    budget: budget
                )
                substreamCounts = parsed.counts
                explicitSubstreamSizes = parsed.sizes
                substreamDigests = parsed.digests

            default:
                throw KaitoError.malformed("unexpected 7z streams-info property 0x\(String(nid.rawValue, radix: 16))")
            }
        }
    }

    private static func parsePackInfo(
        cursor: inout SevenZipHeaderCursor,
        limits: ReadLimits,
        budget: SevenZipMetadataBudget
    ) throws -> SevenZipPackInfo {
        let position = try cursor.readNumber()
        let count = try boundedCount(
            try cursor.readNumber(),
            remaining: cursor.remaining,
            limit: limits.maxEntryCount,
            description: "7z pack stream count"
        )
        try budget.reserve(
            count: count,
            bytesPerRecord: packStreamMetadataBytes,
            description: "7z pack-stream metadata"
        )
        var sizes: [UInt64] = []
        var nid = SevenZipNID(rawValue: try cursor.readUInt8())
        if nid == .size {
            sizes.reserveCapacity(count)
            for _ in 0..<count {
                sizes.append(try cursor.readNumber())
            }
            nid = SevenZipNID(rawValue: try cursor.readUInt8())
        } else if count != 0 {
            // 文法上 Size は省略可能だが、非空 stream は各 packed input の
            // サイズがなければ安全に位置を決定できない。
            throw KaitoError.malformed("7z PackInfo is missing sizes")
        }

        var digests = [SevenZipDigest](
            repeating: SevenZipDigest(value: nil),
            count: count
        )
        if nid == .crc {
            digests = try parseDigests(cursor: &cursor, count: count)
            nid = SevenZipNID(rawValue: try cursor.readUInt8())
        }
        guard nid == .end else {
            throw KaitoError.malformed("7z PackInfo has an unexpected property")
        }
        return SevenZipPackInfo(position: position, sizes: sizes, digests: digests)
    }

    private static func parseUnpackInfo(
        cursor: inout SevenZipHeaderCursor,
        limits: ReadLimits,
        externalStreams: [Data],
        budget: SevenZipMetadataBudget
    ) throws -> [SevenZipFolder] {
        guard SevenZipNID(rawValue: try cursor.readUInt8()) == .folder else {
            throw KaitoError.malformed("7z UnpackInfo is missing folders")
        }
        let count = try boundedCount(
            try cursor.readNumber(),
            remaining: cursor.remaining,
            limit: limits.maxEntryCount,
            description: "7z folder count"
        )
        try budget.reserve(
            count: count,
            bytesPerRecord: folderMetadataBytes,
            description: "7z folder metadata"
        )
        var folders: [SevenZipFolder] = []
        folders.reserveCapacity(count)
        let external = try cursor.readUInt8()
        switch external {
        case 0:
            for _ in 0..<count {
                folders.append(try parseFolder(
                    cursor: &cursor,
                    limits: limits,
                    budget: budget
                ))
            }
        case 1:
            let index64 = try cursor.readNumber()
            guard index64 < UInt64(externalStreams.count) else {
                throw KaitoError.malformed("invalid external 7z folder stream")
            }
            var definitions = SevenZipHeaderCursor(
                [UInt8](externalStreams[try Checked.toInt(index64)])
            )
            for _ in 0..<count {
                folders.append(try parseFolder(
                    cursor: &definitions,
                    limits: limits,
                    budget: budget
                ))
            }
            guard definitions.isAtEnd else {
                throw KaitoError.malformed("external 7z folder stream has trailing bytes")
            }
        default:
            throw KaitoError.malformed("invalid external 7z folder flag")
        }
        guard SevenZipNID(rawValue: try cursor.readUInt8()) == .codersUnpackSize else {
            throw KaitoError.malformed("7z UnpackInfo is missing coder output sizes")
        }
        for index in folders.indices {
            try budget.reserve(
                count: folders[index].outputCount,
                bytesPerRecord: unpackSizeMetadataBytes,
                description: "7z coder unpack-size metadata"
            )
            var sizes: [UInt64] = []
            sizes.reserveCapacity(folders[index].outputCount)
            for _ in 0..<folders[index].outputCount {
                sizes.append(try cursor.readNumber())
            }
            folders[index].unpackSizes = sizes
        }

        var nid = SevenZipNID(rawValue: try cursor.readUInt8())
        if nid == .crc {
            let digests = try parseDigests(cursor: &cursor, count: count)
            for index in folders.indices {
                folders[index].digest = digests[index]
            }
            nid = SevenZipNID(rawValue: try cursor.readUInt8())
        }
        guard nid == .end else {
            throw KaitoError.malformed("7z UnpackInfo has an unexpected property")
        }
        return folders
    }

    private static func parseFolder(
        cursor: inout SevenZipHeaderCursor,
        limits: ReadLimits,
        budget: SevenZipMetadataBudget
    ) throws -> SevenZipFolder {
        let coderCount = try boundedCount(
            try cursor.readNumber(),
            remaining: cursor.remaining,
            limit: SevenZipFormatLimits.maxFolderCodersAndStreams,
            description: "7z coder count"
        )
        guard coderCount > 0 else {
            throw KaitoError.malformed("7z folder has no coders")
        }
        try budget.reserve(
            count: coderCount,
            bytesPerRecord: coderMetadataBytes,
            description: "7z coder metadata"
        )

        var coders: [SevenZipCoder] = []
        coders.reserveCapacity(coderCount)
        var totalInputs = 0
        var totalOutputs = 0
        for _ in 0..<coderCount {
            let flags = try cursor.readUInt8()
            guard flags & 0xC0 == 0 else {
                throw KaitoError.malformed("reserved 7z coder flags are set")
            }
            let idSize = Int(flags & 0x0F)
            guard (1...8).contains(idSize), idSize <= cursor.remaining else {
                throw KaitoError.malformed("invalid 7z coder method-id size")
            }
            try budget.reserve(
                UInt64(idSize),
                description: "7z coder method-id metadata"
            )
            let method = try cursor.readBytes(idSize)
            let inputCount: Int
            let outputCount: Int
            if flags & 0x10 != 0 {
                inputCount = try boundedCount(
                    try cursor.readNumber(),
                    remaining: cursor.remaining,
                    limit: SevenZipFormatLimits.maxFolderCodersAndStreams,
                    description: "7z coder input count"
                )
                outputCount = try boundedCount(
                    try cursor.readNumber(),
                    remaining: cursor.remaining,
                    limit: SevenZipFormatLimits.maxFolderCodersAndStreams,
                    description: "7z coder output count"
                )
            } else {
                inputCount = 1
                outputCount = 1
            }
            guard inputCount > 0, outputCount > 0,
                  totalInputs <= SevenZipFormatLimits.maxFolderCodersAndStreams - inputCount,
                  totalOutputs <= SevenZipFormatLimits.maxFolderCodersAndStreams - outputCount else {
                throw KaitoError.limitExceeded("7z folder stream count")
            }
            try budget.reserve(
                count: inputCount + outputCount,
                bytesPerRecord: coderStreamMetadataBytes,
                description: "7z coder-stream metadata"
            )

            let properties: [UInt8]
            if flags & 0x20 != 0 {
                let propertySize64 = try cursor.readNumber()
                try Checked.size(propertySize64, limit: limits.maxMetadataSize)
                try budget.reserve(
                    propertySize64,
                    description: "7z coder properties"
                )
                let propertySize = try Checked.toInt(propertySize64)
                guard propertySize <= cursor.remaining else { throw KaitoError.truncated }
                properties = try cursor.readBytes(propertySize)
            } else {
                properties = []
            }
            coders.append(SevenZipCoder(
                methodID: method,
                inputCount: inputCount,
                outputCount: outputCount,
                properties: properties,
                firstInput: totalInputs,
                firstOutput: totalOutputs
            ))
            totalInputs += inputCount
            totalOutputs += outputCount
        }

        guard totalOutputs > 0 else {
            throw KaitoError.malformed("7z folder has no output stream")
        }
        let bindCount = totalOutputs - 1
        try budget.reserve(
            count: bindCount,
            bytesPerRecord: bindPairMetadataBytes,
            description: "7z bind-pair metadata"
        )
        var bindPairs: [SevenZipBindPair] = []
        bindPairs.reserveCapacity(bindCount)
        var usedInputs = Set<Int>()
        var usedOutputs = Set<Int>()
        for _ in 0..<bindCount {
            let input = try boundedIndex(
                try cursor.readNumber(), upperBound: totalInputs,
                description: "7z bind input index"
            )
            let output = try boundedIndex(
                try cursor.readNumber(), upperBound: totalOutputs,
                description: "7z bind output index"
            )
            guard usedInputs.insert(input).inserted,
                  usedOutputs.insert(output).inserted else {
                throw KaitoError.malformed("duplicate 7z bind-pair index")
            }
            bindPairs.append(SevenZipBindPair(input: input, output: output))
        }

        let packedCount = totalInputs - bindCount
        guard packedCount > 0,
              packedCount <= SevenZipFormatLimits.maxFolderCodersAndStreams else {
            throw KaitoError.malformed("invalid 7z packed-stream count")
        }
        try budget.reserve(
            count: packedCount,
            bytesPerRecord: packedIndexMetadataBytes,
            description: "7z packed-stream index metadata"
        )
        let packedIndices: [Int]
        if packedCount == 1 {
            guard let index = (0..<totalInputs).first(where: { !usedInputs.contains($0) }) else {
                throw KaitoError.malformed("7z folder has no unbound input")
            }
            packedIndices = [index]
        } else {
            var values: [Int] = []
            values.reserveCapacity(packedCount)
            var usedPacked = Set<Int>()
            for _ in 0..<packedCount {
                let index = try boundedIndex(
                    try cursor.readNumber(), upperBound: totalInputs,
                    description: "7z packed-stream index"
                )
                guard !usedInputs.contains(index), usedPacked.insert(index).inserted else {
                    throw KaitoError.malformed("invalid or duplicate 7z packed-stream index")
                }
                values.append(index)
            }
            packedIndices = values
        }

        guard let finalOutput = (0..<totalOutputs).first(where: { !usedOutputs.contains($0) }) else {
            throw KaitoError.malformed("7z folder has no final output")
        }
        let folder = SevenZipFolder(
            coders: coders,
            bindPairs: bindPairs,
            packedIndices: packedIndices,
            inputCount: totalInputs,
            outputCount: totalOutputs,
            finalOutputIndex: finalOutput,
            unpackSizes: [],
            digest: SevenZipDigest(value: nil)
        )
        try validateGraph(folder)
        return folder
    }

    private static func validateGraph(_ folder: SevenZipFolder) throws {
        var edges = [[Int]](repeating: [], count: folder.coders.count)
        for pair in folder.bindPairs {
            guard let producer = folder.coderIndex(containingOutput: pair.output),
                  let consumer = folder.coders.firstIndex(where: {
                      pair.input >= $0.firstInput && pair.input < $0.firstInput + $0.inputCount
                  }) else {
                throw KaitoError.malformed("7z bind pair does not name a coder stream")
            }
            edges[producer].append(consumer)
        }

        var colors = [UInt8](repeating: 0, count: folder.coders.count)
        func visit(_ node: Int) throws {
            if colors[node] == 1 {
                throw KaitoError.malformed("cyclic 7z coder graph")
            }
            if colors[node] == 2 { return }
            colors[node] = 1
            for target in edges[node] { try visit(target) }
            colors[node] = 2
        }
        for index in folder.coders.indices { try visit(index) }

        // 最終出力から逆向きに辿って全 coder が使われることも確認する。
        guard let finalCoder = folder.coderIndex(containingOutput: folder.finalOutputIndex) else {
            throw KaitoError.malformed("invalid 7z final output index")
        }
        var reachable = Set<Int>()
        func visitInputs(_ coderIndex: Int) {
            guard reachable.insert(coderIndex).inserted else { return }
            let coder = folder.coders[coderIndex]
            for input in coder.firstInput..<(coder.firstInput + coder.inputCount) {
                if let output = folder.boundOutput(forInput: input),
                   let sourceCoder = folder.coderIndex(containingOutput: output) {
                    visitInputs(sourceCoder)
                }
            }
        }
        visitInputs(finalCoder)
        guard reachable.count == folder.coders.count else {
            throw KaitoError.malformed("disconnected 7z coder graph")
        }
    }

    private static func parseSubStreamsInfo(
        cursor: inout SevenZipHeaderCursor,
        folders: [SevenZipFolder],
        limits: ReadLimits,
        budget: SevenZipMetadataBudget
    ) throws -> (counts: [Int], sizes: [[UInt64]], digests: [SevenZipDigest]?) {
        var counts = [Int](repeating: 1, count: folders.count)
        var sizes = [[UInt64]](repeating: [], count: folders.count)
        var digests: [SevenZipDigest]?
        var sawCounts = false
        var sawSizes = false
        var reservedSubstreamCount = 0

        func reserveSubstreams(_ count: Int) throws {
            guard count > reservedSubstreamCount else { return }
            try budget.reserve(
                count: count - reservedSubstreamCount,
                bytesPerRecord: substreamMetadataBytes,
                description: "7z substream metadata"
            )
            reservedSubstreamCount = count
        }

        while true {
            guard let nid = SevenZipNID(rawValue: try cursor.readUInt8()) else {
                throw KaitoError.malformed("unknown 7z substream property")
            }
            switch nid {
            case .end:
                let total = try counts.reduce(UInt64(0)) {
                    try Checked.add($0, UInt64($1))
                }
                guard total <= UInt64(limits.maxEntryCount) else {
                    throw KaitoError.limitExceeded("7z substream count")
                }
                try reserveSubstreams(try Checked.toInt(total))
                return (counts, sizes, digests)

            case .numUnpackStream:
                guard !sawCounts else {
                    throw KaitoError.malformed("duplicate 7z substream counts")
                }
                sawCounts = true
                var total = 0
                for index in folders.indices {
                    let count = try boundedCount(
                        try cursor.readNumber(),
                        remaining: cursor.remaining,
                        limit: limits.maxEntryCount,
                        description: "7z folder substream count"
                    )
                    guard count <= limits.maxEntryCount - total else {
                        throw KaitoError.limitExceeded("7z substream count")
                    }
                    total += count
                    counts[index] = count
                }
                try reserveSubstreams(total)

            case .size:
                guard !sawSizes else {
                    throw KaitoError.malformed("duplicate 7z substream sizes")
                }
                sawSizes = true
                try reserveSubstreams(counts.reduce(0, +))
                for folderIndex in folders.indices {
                    let explicitCount = max(0, counts[folderIndex] - 1)
                    sizes[folderIndex].reserveCapacity(explicitCount)
                    for _ in 0..<explicitCount {
                        sizes[folderIndex].append(try cursor.readNumber())
                    }
                }

            case .crc:
                guard digests == nil else {
                    throw KaitoError.malformed("duplicate 7z substream CRCs")
                }
                var count = 0
                for index in folders.indices {
                    if counts[index] == 1, folders[index].digest.value != nil { continue }
                    guard count <= limits.maxEntryCount - counts[index] else {
                        throw KaitoError.limitExceeded("7z substream digest count")
                    }
                    count += counts[index]
                }
                try reserveSubstreams(counts.reduce(0, +))
                digests = try parseDigests(cursor: &cursor, count: count)

            default:
                throw KaitoError.malformed("unexpected 7z SubStreamsInfo property")
            }
        }
    }

    private static func makeSubstreams(
        folders: [SevenZipFolder],
        counts: [Int]?,
        explicitSizes: [[UInt64]]?,
        digests: [SevenZipDigest]?
    ) throws -> [SevenZipSubstream] {
        let actualCounts = counts ?? [Int](repeating: 1, count: folders.count)
        let actualSizes = explicitSizes ?? [[UInt64]](repeating: [], count: folders.count)
        guard actualCounts.count == folders.count, actualSizes.count == folders.count else {
            throw KaitoError.malformed("7z substream metadata count mismatch")
        }

        var result: [SevenZipSubstream] = []
        var digestIndex = 0
        for folderIndex in folders.indices {
            let folder = folders[folderIndex]
            guard folder.unpackSizes.count == folder.outputCount,
                  folder.finalOutputIndex < folder.unpackSizes.count else {
                throw KaitoError.malformed("missing 7z coder output size")
            }
            let count = actualCounts[folderIndex]
            if count == 0 {
                guard folder.unpackSizes[folder.finalOutputIndex] == 0 else {
                    throw KaitoError.malformed("nonempty 7z folder has no substreams")
                }
                continue
            }
            guard actualSizes[folderIndex].count == max(0, count - 1) else {
                throw KaitoError.malformed("7z substream size count mismatch")
            }

            let folderSize = folder.unpackSizes[folder.finalOutputIndex]
            var offset: UInt64 = 0
            for streamIndex in 0..<count {
                let size: UInt64
                if streamIndex + 1 == count {
                    size = try Checked.sub(folderSize, offset)
                } else {
                    size = actualSizes[folderIndex][streamIndex]
                    offset = try Checked.add(offset, size)
                    guard offset <= folderSize else {
                        throw KaitoError.malformed("7z substream sizes exceed folder output")
                    }
                }

                let digest: SevenZipDigest
                if count == 1, folder.digest.value != nil {
                    digest = folder.digest
                } else if let digests {
                    guard digestIndex < digests.count else {
                        throw KaitoError.malformed("missing 7z substream digest")
                    }
                    digest = digests[digestIndex]
                    digestIndex += 1
                } else {
                    digest = SevenZipDigest(value: nil)
                }
                let streamOffset = streamIndex + 1 == count
                    ? try Checked.sub(folderSize, size)
                    : try Checked.sub(offset, size)
                result.append(SevenZipSubstream(
                    folderIndex: folderIndex,
                    offset: streamOffset,
                    size: size,
                    digest: digest
                ))
            }
        }
        if let digests, digestIndex != digests.count {
            throw KaitoError.malformed("unused 7z substream digests")
        }
        return result
    }

    private static func parseDigests(
        cursor: inout SevenZipHeaderCursor,
        count: Int
    ) throws -> [SevenZipDigest] {
        let defined = try cursor.readDefinedVector(count: count)
        var result = [SevenZipDigest](
            repeating: SevenZipDigest(value: nil),
            count: count
        )
        for index in 0..<count where defined[index] {
            result[index] = SevenZipDigest(value: try cursor.readUInt32LE())
        }
        return result
    }

    static func boundedCount(
        _ value: UInt64,
        remaining: Int,
        limit: Int,
        description: String
    ) throws -> Int {
        guard limit >= 0, value <= UInt64(limit) else {
            throw KaitoError.limitExceeded(description)
        }
        // 最密の bit vector でも 1 byte 当たり 8 項目なので、入力残量に
        // 全く裏付けられない巨大 count を配列確保へ進ませない。
        let evidence = try Checked.add(try Checked.mul(UInt64(max(0, remaining)), 8), 8)
        guard value <= evidence else {
            throw KaitoError.malformed("\(description) exceeds containing header")
        }
        return try Checked.toInt(value)
    }

    private static func boundedIndex(
        _ value: UInt64,
        upperBound: Int,
        description: String
    ) throws -> Int {
        guard value < UInt64(upperBound) else {
            throw KaitoError.malformed("\(description) is out of range")
        }
        return try Checked.toInt(value)
    }
}
