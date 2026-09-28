// 指定資料 Ch.03 の object・fork・solid slot 関係を全要素の索引後に解決する。
import Foundation

final class StuffItXReader: FormatReader {
    let format: ArchiveFormat = .stuffItX
    let entries: [ArchiveEntry]
    let nameEncoding: String.Encoding?
    let archiveComment: String?
    let archiveResourceFork: (any ByteSource)?
    private let source: any ByteSource
    private let descriptors: [UInt64: (StuffItXElement, UInt64)]
    private let intervals: [(stream: UInt64?, offset: UInt64, length: UInt64)]
    private let unavailableStreams: Set<UInt64>
    private var coordinators: [UInt64: StuffItXStreamCoordinator] = [:]
    private var coordinatorLimits: ReadLimits?
    private(set) var resolvedPassword: String?
    private let auxiliaryStreams: [UInt64: [UInt64]]
    private var verifiedAuxiliaries = Set<UInt64>()

    private struct Fork {
        let owner: UInt64
        let stream: UInt64
        let slot: UInt64
        let length: UInt64
        let kind: UInt64
    }

    /// 要素列の索引: object（type 2 = file、4 = directory）、fork（type 3）、stream（type 1）。
    private struct Index {
        var objects: [StuffItXElement] = []
        var objectIndex: [UInt64: Int] = [:]
        var forks: [Fork] = []
        var streams: [UInt64: StuffItXElement] = [:]
        var streamOrder: [UInt64] = []
    }

    init(source: any ByteSource, resourceFork: (any ByteSource)? = nil, options: ReaderOptions) throws {
        self.source = source; archiveResourceFork = resourceFork
        let limits = options.limits
        var password = options.password
        let elements = try StuffItXElementParser(source: source, limits: limits).parse()
        let index = try Self.index(elements, limits: limits)
        var metadataSize: UInt64 = 0
        let (records, comment) = try Self.readCatalogs(elements, objectCount: index.objects.count, source: source,
                                                       options: options, password: &password, metadataSize: &metadataSize)
        archiveComment = comment
        let encoding = EncodingDetector.detectArchiveEncoding(names: records.map(\.name), policy: options.encodingPolicy,
                                                               maximumBatchByteCount: try Checked.toInt(limits.maxMetadataSize))
        nameEncoding = encoding
        let names = records.map { EncodingDetector.resolveUndeclaredName(bytes: $0.name, policy: options.encodingPolicy,
                                                                         archiveEncoding: encoding).string }
        let paths = try Self.resolvePaths(index, names: names, limits: limits, metadataSize: &metadataSize)
        var builder = try EntryBuilder(index: index, records: records, paths: paths, comment: comment,
                                       rootVersion: elements.first(where: { $0.type == 7 })?.extra, limits: limits)
        try builder.appendStreamEntries()
        try builder.appendUnreferencedObjects()
        entries = builder.entries; intervals = builder.intervals; descriptors = builder.descriptors
        unavailableStreams = builder.unavailableStreams; auxiliaryStreams = builder.auxiliaryStreams
        resolvedPassword = password
    }

    private static func index(_ elements: [StuffItXElement], limits: ReadLimits) throws -> Index {
        var result = Index()
        for (index, element) in elements.enumerated() {
            try checkCancellation(every: index)
            switch element.type {
            case 2, 4:
                guard let id = element.attributes[1], result.objectIndex[id] == nil else { throw KaitoError.malformed("StuffIt X object ID") }
                guard result.objects.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt X objects") }
                result.objectIndex[id] = result.objects.count; result.objects.append(element)
            case 3:
                guard let owner = element.attributes[2], let stream = element.attributes[3],
                      let slot = element.attributes[4], let length = element.attributes[5], let kind = element.extra else {
                    throw KaitoError.malformed("StuffIt X fork attributes")
                }
                try Checked.size(length, limit: limits.maxEntrySize)
                result.forks.append(Fork(owner: owner, stream: stream, slot: slot, length: length, kind: kind))
            case 1:
                guard let id = element.attributes[1], result.streams[id] == nil else { throw KaitoError.malformed("StuffIt X stream ID") }
                result.streams[id] = element; result.streamOrder.append(id)
            default: break
            }
        }
        return result
    }

    /// type 5 の要素を復号する。直前の type 9 が指すものは書庫 comment、それ以外は唯一の file catalog。
    /// 暗号化された catalog は password を一度だけ問い合わせ、以後の stream にも使う。
    private static func readCatalogs(_ elements: [StuffItXElement], objectCount: Int, source: any ByteSource,
                                     options: ReaderOptions, password: inout String?,
                                     metadataSize: inout UInt64) throws -> (records: [StuffItXCatalog.Record], comment: String?) {
        let limits = options.limits
        var records = [StuffItXCatalog.Record](repeating: .init(), count: objectCount)
        var catalogSeen = false, comment: String?
        for (index, element) in elements.enumerated() {
            try checkCancellation(every: index)
            guard element.type == 5 else { continue }
            guard let size = element.attributes[5] else { throw KaitoError.malformed("StuffIt X catalog length") }
            try Checked.size(size, limit: limits.maxMetadataSize)
            metadataSize = try Checked.add(metadataSize, size)
            try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
            if element.algorithms.contains(where: { $0.key == 4 }), password == nil {
                password = try options.passwordProvider?.password(for: .stuffItX)
                guard password != nil else { throw KaitoError.passwordRequired }
            }
            let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: size, limits: limits, password: password)
            let decoder = try coordinator.stream(offset: 0, length: size)
            let decoded = try Self.collect(decoder, size: size)
            let previous = index > 0 ? elements[index - 1] : nil
            let isComment = previous?.type == 9 && previous?.attributes[7] == 0
                && previous?.attributes[6] != nil && previous?.attributes[6] == element.attributes[1]
            if isComment {
                comment = try StuffItXCatalog.parse(decoded, count: 1, commentOnly: true, limits: limits)[0].metadata["comment"]
            } else {
                guard !catalogSeen else { throw KaitoError.unsupportedMethod("StuffIt X additional file catalog") }
                records = try StuffItXCatalog.parse(decoded, count: objectCount, limits: limits); catalogSeen = true
            }
        }
        guard catalogSeen || objectCount == 0 else { throw KaitoError.malformed("StuffIt X missing catalog") }
        return (records, comment)
    }

    /// object ごとに親（attribute 2）を root まで辿り、path component 列を作る。辿った途中の object も同時に埋める。
    private static func resolvePaths(_ index: Index, names: [String], limits: ReadLimits,
                                     metadataSize: inout UInt64) throws -> [Int: [String]] {
        let objects = index.objects, objectIndex = index.objectIndex
        var paths: [Int: [String]] = [:]
        for i in objects.indices {
            try checkCancellation(every: i)
            var chain: [Int] = [], seen = Set<Int>(), current: Int? = i
            while let j = current, paths[j] == nil {
                guard seen.insert(j).inserted else { throw KaitoError.malformed("StuffIt X parent cycle") }
                chain.append(j)
                guard chain.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt X parent depth") }
                if let parent = objects[j].attributes[2], let p = objectIndex[parent] {
                    guard objects[p].type == 4 else { throw KaitoError.malformed("StuffIt X parent is not a directory") }
                    current = p
                } else {
                    guard objects[j].attributes[2] == nil || objects[j].attributes[2] == 0 else { throw KaitoError.malformed("StuffIt X missing parent") }
                    current = nil
                }
            }
            var base = current.flatMap { paths[$0] } ?? []
            for j in chain.reversed() {
                base.append(names[j])
                guard base.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt X path components") }
                metadataSize = try Checked.add(metadataSize, UInt64(base.reduce(0) { $0 + $1.utf8.count + 16 }))
                try Checked.size(metadataSize, limit: limits.maxTotalMetadataSize)
                paths[j] = base
            }
        }
        return paths
    }

    /// fork を stream ごとにまとめ、solid slot の offset を決めて entry を作る。stream の記述子
    /// （復号に使う要素と展開後の長さ）と、補助 fork（kind > 1）の所有者も集める。
    private struct EntryBuilder {
        let objects: [StuffItXElement]
        let objectIndex: [UInt64: Int]
        let streams: [UInt64: StuffItXElement]
        let streamOrder: [UInt64]
        let records: [StuffItXCatalog.Record]
        let paths: [Int: [String]]
        let comment: String?
        let rootVersion: UInt64?
        let limits: ReadLimits
        let byStream: [UInt64: [Fork]]
        let auxiliaries: [UInt64: [String]]
        let auxiliaryStreams: [UInt64: [UInt64]]
        let encryptedAuxiliaryOwners: Set<UInt64>
        private(set) var entries: [ArchiveEntry] = []
        private(set) var intervals: [(stream: UInt64?, offset: UInt64, length: UInt64)] = []
        private(set) var descriptors: [UInt64: (StuffItXElement, UInt64)] = [:]
        private(set) var unavailableStreams = Set<UInt64>()
        private var referenced = Set<UInt64>()
        private var total: UInt64 = 0

        init(index: Index, records: [StuffItXCatalog.Record], paths: [Int: [String]], comment: String?,
             rootVersion: UInt64?, limits: ReadLimits) throws {
            objects = index.objects; objectIndex = index.objectIndex
            streams = index.streams; streamOrder = index.streamOrder
            self.records = records; self.paths = paths; self.comment = comment
            self.rootVersion = rootVersion; self.limits = limits
            var byStream: [UInt64: [Fork]] = [:], auxiliaries: [UInt64: [String]] = [:]
            var auxiliaryStreams: [UInt64: [UInt64]] = [:], encryptedAuxiliaryOwners = Set<UInt64>()
            for (index, fork) in index.forks.enumerated() {
                try checkCancellation(every: index)
                guard objectIndex[fork.owner] != nil else { throw KaitoError.malformed("StuffIt X missing fork owner") }
                guard streams[fork.stream] != nil else { throw KaitoError.unsupportedMethod("StuffIt X missing or segmented stream \(fork.stream)") }
                byStream[fork.stream, default: []].append(fork)
                if fork.kind > 1 {
                    auxiliaries[fork.owner, default: []].append("kind=\(fork.kind),stream=\(fork.stream),slot=\(fork.slot),forkLength=\(fork.length),streamLength=\(streams[fork.stream]?.attributes[5] ?? 0)")
                    if fork.kind == 3 {
                        auxiliaryStreams[fork.owner, default: []].append(fork.stream)
                        if streams[fork.stream]!.algorithms.contains(where: { $0.key == 4 }) {
                            encryptedAuxiliaryOwners.insert(fork.owner)
                        }
                    }
                }
            }
            self.byStream = byStream; self.auxiliaries = auxiliaries
            self.auxiliaryStreams = auxiliaryStreams; self.encryptedAuxiliaryOwners = encryptedAuxiliaryOwners
        }

        /// stream の出現順に、その stream の fork を slot 順で entry にする。slot が 2 個以上なら solid。
        mutating func appendStreamEntries() throws {
            for (index, id) in streamOrder.enumerated() {
                try checkCancellation(every: index)
                guard let element = streams[id] else { continue }
                let streamForks = byStream[id] ?? []
                var slots: [UInt64: Fork] = [:]
                for (index, fork) in streamForks.enumerated() {
                    try checkCancellation(every: index)
                    if let previous = slots[fork.slot] {
                        guard previous.length == fork.length, previous.kind == fork.kind else { throw KaitoError.malformed("StuffIt X shared slot disagreement") }
                    } else { slots[fork.slot] = fork }
                }
                let auxiliaryOnly = !streamForks.isEmpty && streamForks.allSatisfy { $0.kind == 3 }
                var offsets: [UInt64: UInt64] = [:], sum: UInt64 = 0
                for i in 0..<slots.count {
                    try checkCancellation(every: i)
                    guard let fork = slots[UInt64(i)] else { throw KaitoError.malformed("StuffIt X sparse slots") }
                    offsets[UInt64(i)] = sum; sum = try Checked.add(sum, fork.length)
                }
                if auxiliaryOnly {
                    guard let declared = element.attributes[5] else { throw KaitoError.malformed("StuffIt X auxiliary length") }
                    try Checked.size(declared, limit: limits.maxEntrySize)
                    sum = declared
                } else if streamForks.contains(where: { $0.kind > 1 }) {
                    unavailableStreams.insert(id)
                }
                try Checked.size(sum, limit: limits.maxTotalUncompressedSize)
                descriptors[id] = (element, sum)
                if auxiliaryOnly {
                    total = try Checked.add(total, sum)
                    try Checked.size(total, limit: limits.maxTotalUncompressedSize)
                }
                for (index, fork) in streamForks.sorted(by: { $0.slot < $1.slot }).enumerated() {
                    try checkCancellation(every: index)
                    guard fork.kind <= 1 else { continue }
                    try append(owner: fork.owner, fork: fork, offset: offsets[fork.slot]!, solid: slots.count > 1)
                }
            }
        }

        /// data / resource fork の entry にならなかった object（directory、空の file など）を fork 無しの entry にする。
        mutating func appendUnreferencedObjects() throws {
            for (index, object) in objects.enumerated() {
                try checkCancellation(every: index)
                let id = object.attributes[1]!
                if !referenced.contains(id) { try append(owner: id, fork: nil) }
            }
        }

        private mutating func append(owner: UInt64, fork: Fork?, offset: UInt64 = 0, solid: Bool = false) throws {
            guard let j = objectIndex[owner], let path = paths[j] else { throw KaitoError.malformed("StuffIt X object path") }
            guard entries.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt X entries") }
            let object = objects[j], record = records[j], stream = fork.flatMap { streams[$0.stream] }
            let size = fork?.length ?? 0, resource = fork?.kind == 1
            let components = path + (resource ? ["..namedfork", "rsrc"] : [])
            guard components.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt X fork path") }
            total = try Checked.add(total, size); try Checked.size(total, limit: limits.maxTotalUncompressedSize)
            var metadata = record.metadata
            metadata["container"] = "stuffitx"
            if let version = rootVersion { metadata["rootVersion"] = String(version) }
            metadata["objectID"] = String(owner)
            if let order = object.attributes[7] { metadata["catalogOrder"] = String(order) }
            if let auxiliary = auxiliaries[owner] { metadata["auxiliaryForks"] = auxiliary.joined(separator: ";") }
            if let comment { metadata["archiveComment"] = comment }
            if object.type != 4 { metadata["fork"] = resource ? "resource" : "data" }
            if let fork {
                metadata["streamID"] = String(fork.stream); metadata["slot"] = String(fork.slot)
                metadata["compression"] = stream?.compression.map(String.init) ?? "stored"
                metadata["algorithms"] = stream?.algorithms.map { "\($0.key):\($0.value)" + ($0.keyLength.map { ":\($0)" } ?? "") }.joined(separator: ",")
            }
            let compressed: UInt64?
            if let stream, let declared = stream.attributes[5], declared > 0 {
                let estimate = Double(size) * Double(stream.framedSize) / Double(declared)
                compressed = estimate < Double(UInt64.max) ? UInt64(estimate) : nil
            } else { compressed = size == 0 ? 0 : nil }
            let group = solid ? try Checked.toInt(fork!.stream) : -1
            entries.append(ArchiveEntry(index: entries.count, rawName: RawName(bytes: record.name, isDirectoryHint: object.type == 4),
                name: components.joined(separator: "/"), pathComponents: components,
                kind: object.type == 4 ? .directory : (record.link && !resource ? .symlink : .file),
                uncompressedSize: size, compressedSize: compressed, modificationDate: record.modified,
                posixPermissions: record.permissions,
                isEncrypted: (stream?.algorithms.contains { $0.key == 4 } ?? false) || encryptedAuxiliaryOwners.contains(owner),
                solidGroup: group, crc32: nil, methodDescription: object.type == 4 ? "Directory" : StuffItXCodec.name(stream?.compression),
                formatSpecific: metadata))
            intervals.append((fork?.stream, offset, size)); referenced.insert(owner)
        }
    }

    private static func collect(_ decoder: any Decompressor, size: UInt64) throws -> Data {
        var data = Data(count: try Checked.toInt(size)), position = 0
        try data.withUnsafeMutableBytes { bytes in
            while position < bytes.count {
                let n = try decoder.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[position...]))
                guard n > 0, n <= bytes.count - position else { throw KaitoError.truncated }; position += n
            }
        }
        return data
    }
    func validateEncryptionSupport(for entry: ArchiveEntry) throws {
        if let id = intervals[entry.index].stream, let (element, _) = descriptors[id] {
            try StuffItXCrypto.validate(element.algorithms)
        }
    }
    func setPassword(_ password: String?) {
        guard resolvedPassword.map({ Array($0.utf8) }) != password.map({ Array($0.utf8) }) else { return }
        resolvedPassword = password; verifiedAuxiliaries.removeAll()
        for coordinator in coordinators.values { coordinator.setPassword(password) }
    }
    func stream(for entry: ArchiveEntry, limits: ReadLimits) throws -> EntryStream {
        guard entries.indices.contains(entry.index), entries[entry.index] == entry else { throw KaitoError.notFound("StuffIt X entry") }
        let interval = intervals[entry.index]
        if coordinatorLimits != limits {
            coordinators.removeAll(); verifiedAuxiliaries.removeAll(); coordinatorLimits = limits
        }
        if let owner = entry.formatSpecific["objectID"].flatMap(UInt64.init) {
            // 非公開の補助 stream も実長の終端まで検証し、prefix を通常 fork と誤認させない。
            // 暗号化の有無によらず、所有 entry の stream を返す前に一度だけ検証する。
            for id in auxiliaryStreams[owner] ?? [] where !verifiedAuxiliaries.contains(id) {
                guard !unavailableStreams.contains(id), let (element, size) = descriptors[id] else {
                    throw KaitoError.unsupportedMethod("StuffIt X mixed auxiliary slots")
                }
                try Checked.size(size, limit: limits.maxEntrySize)
                let coordinator = coordinators[id] ?? StuffItXStreamCoordinator(source: source, element: element, size: size,
                                                                                limits: limits, password: resolvedPassword)
                coordinators[id] = coordinator
                let auxiliary = try coordinator.stream(offset: 0, length: size)
                try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
                    while try auxiliary.read(into: buffer) > 0 {}
                }
                verifiedAuxiliaries.insert(id)
            }
        }
        let decoder: any Decompressor
        if let id = interval.stream, let (element, size) = descriptors[id] {
            if unavailableStreams.contains(id) { throw KaitoError.unsupportedMethod("StuffIt X mixed auxiliary slots") }
            let coordinator = coordinators[id] ?? StuffItXStreamCoordinator(source: source, element: element, size: size,
                                                                            limits: limits, password: resolvedPassword)
            coordinators[id] = coordinator
            decoder = try coordinator.stream(offset: interval.offset, length: interval.length)
        } else { decoder = try CopyDecompressor(source: source, offset: 0, compressedSize: 0) }
        return try EntryStream(decompressor: decoder, length: interval.length, expectedCRC32: nil, entryIndex: entry.index, limits: limits)
    }
}
