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
    private let encryptedAuxiliaries: [UInt64: [UInt64]]
    private var verifiedAuxiliaries = Set<UInt64>()

    private struct Fork {
        let owner: UInt64
        let stream: UInt64
        let slot: UInt64
        let length: UInt64
        let kind: UInt64
    }

    init(source: any ByteSource, resourceFork: (any ByteSource)? = nil, options: ReaderOptions) throws {
        self.source = source; archiveResourceFork = resourceFork
        let limits = options.limits
        var password = options.password
        let elements = try StuffItXElementParser(source: source, limits: limits).parse()
        var objects: [StuffItXElement] = [], objectIndex: [UInt64: Int] = [:]
        var forks: [Fork] = [], streams: [UInt64: StuffItXElement] = [:], streamOrder: [UInt64] = []
        for element in elements {
            switch element.type {
            case 2, 4:
                guard let id = element.attributes[1], objectIndex[id] == nil else { throw KaitoError.malformed("StuffIt X object ID") }
                guard objects.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt X objects") }
                objectIndex[id] = objects.count; objects.append(element)
            case 3:
                guard let owner = element.attributes[2], let stream = element.attributes[3],
                      let slot = element.attributes[4], let length = element.attributes[5], let kind = element.extra else {
                    throw KaitoError.malformed("StuffIt X fork attributes")
                }
                try Checked.size(length, limit: limits.maxEntrySize)
                forks.append(Fork(owner: owner, stream: stream, slot: slot, length: length, kind: kind))
            case 1:
                guard let id = element.attributes[1], streams[id] == nil else { throw KaitoError.malformed("StuffIt X stream ID") }
                streams[id] = element; streamOrder.append(id)
            default: break
            }
        }
        var records = [StuffItXCatalog.Record](repeating: .init(), count: objects.count)
        var catalogSeen = false, comment: String?
        var metadataSize: UInt64 = 0
        for (index, element) in elements.enumerated() where element.type == 5 {
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
                records = try StuffItXCatalog.parse(decoded, count: objects.count, limits: limits); catalogSeen = true
            }
        }
        guard catalogSeen || objects.isEmpty else { throw KaitoError.malformed("StuffIt X missing catalog") }
        archiveComment = comment
        let encoding = EncodingDetector.detectArchiveEncoding(names: records.map(\.name), policy: options.encodingPolicy,
                                                               maximumBatchByteCount: try Checked.toInt(limits.maxMetadataSize))
        nameEncoding = encoding
        let names = records.map { EncodingDetector.resolveUndeclaredName(bytes: $0.name, policy: options.encodingPolicy,
                                                                         archiveEncoding: encoding).string }
        var paths: [Int: [String]] = [:]
        for i in objects.indices {
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
        var byStream: [UInt64: [Fork]] = [:], auxiliaries: [UInt64: [String]] = [:]
        var encryptedAuxiliaries: [UInt64: [UInt64]] = [:]
        for fork in forks {
            guard objectIndex[fork.owner] != nil else { throw KaitoError.malformed("StuffIt X missing fork owner") }
            guard streams[fork.stream] != nil else { throw KaitoError.unsupportedMethod("StuffIt X missing or segmented stream \(fork.stream)") }
            byStream[fork.stream, default: []].append(fork)
            if fork.kind > 1 {
                auxiliaries[fork.owner, default: []].append("kind=\(fork.kind),stream=\(fork.stream),slot=\(fork.slot),forkLength=\(fork.length),streamLength=\(streams[fork.stream]?.attributes[5] ?? 0)")
                if fork.kind == 3, streams[fork.stream]!.algorithms.contains(where: { $0.key == 4 }) {
                    encryptedAuxiliaries[fork.owner, default: []].append(fork.stream)
                }
            }
        }
        var descriptors: [UInt64: (StuffItXElement, UInt64)] = [:], unavailableStreams = Set<UInt64>()
        var result: [ArchiveEntry] = [], intervals: [(UInt64?, UInt64, UInt64)] = []
        var referenced = Set<UInt64>(), total: UInt64 = 0
        func append(owner: UInt64, fork: Fork?, offset: UInt64 = 0, solid: Bool = false) throws {
            guard let j = objectIndex[owner], let path = paths[j] else { throw KaitoError.malformed("StuffIt X object path") }
            guard result.count < limits.maxEntryCount else { throw KaitoError.limitExceeded("StuffIt X entries") }
            let object = objects[j], record = records[j], stream = fork.flatMap { streams[$0.stream] }
            let size = fork?.length ?? 0, resource = fork?.kind == 1
            let components = path + (resource ? ["..namedfork", "rsrc"] : [])
            guard components.count <= limits.maxPathComponentCount else { throw KaitoError.limitExceeded("StuffIt X fork path") }
            total = try Checked.add(total, size); try Checked.size(total, limit: limits.maxTotalUncompressedSize)
            var metadata = record.metadata
            metadata["container"] = "stuffitx"
            if let version = elements.first(where: { $0.type == 7 })?.extra { metadata["rootVersion"] = String(version) }
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
            result.append(ArchiveEntry(index: result.count, rawName: RawName(bytes: record.name, isDirectoryHint: object.type == 4),
                name: components.joined(separator: "/"), pathComponents: components,
                kind: object.type == 4 ? .directory : (record.link && !resource ? .symlink : .file),
                uncompressedSize: size, compressedSize: compressed, modificationDate: record.modified,
                posixPermissions: record.permissions,
                isEncrypted: (stream?.algorithms.contains { $0.key == 4 } ?? false) || encryptedAuxiliaries[owner] != nil,
                solidGroup: group, crc32: nil, methodDescription: object.type == 4 ? "Directory" : StuffItXCodec.name(stream?.compression),
                formatSpecific: metadata))
            intervals.append((fork?.stream, offset, size)); referenced.insert(owner)
        }
        for id in streamOrder {
            guard let element = streams[id] else { continue }
            let streamForks = byStream[id] ?? []
            var slots: [UInt64: Fork] = [:]
            for fork in streamForks {
                if let previous = slots[fork.slot] {
                    guard previous.length == fork.length, previous.kind == fork.kind else { throw KaitoError.malformed("StuffIt X shared slot disagreement") }
                } else { slots[fork.slot] = fork }
            }
            let auxiliaryOnly = !streamForks.isEmpty && streamForks.allSatisfy { $0.kind == 3 }
            var offsets: [UInt64: UInt64] = [:], sum: UInt64 = 0
            for i in 0..<slots.count {
                guard let fork = slots[UInt64(i)] else { throw KaitoError.malformed("StuffIt X sparse slots") }
                offsets[UInt64(i)] = sum; sum = try Checked.add(sum, fork.length)
            }
            if auxiliaryOnly {
                guard let declared = element.attributes[5] else { throw KaitoError.malformed("StuffIt X auxiliary length") }
                sum = declared
            } else if streamForks.contains(where: { $0.kind > 1 }) {
                unavailableStreams.insert(id)
            }
            try Checked.size(sum, limit: limits.maxTotalUncompressedSize)
            descriptors[id] = (element, sum)
            if auxiliaryOnly {
                total = try Checked.add(total, sum)
                try Checked.size(total, limit: limits.maxTotalUncompressedSize)
                // 非公開の補助 stream も実長の終端まで検証し、prefix を通常 fork と誤認させない。
                // 暗号化補助 stream は列挙を妨げず、所有 entry の取得時に検証する。
                if !element.algorithms.contains(where: { $0.key == 4 }) {
                    do {
                        let coordinator = StuffItXStreamCoordinator(source: source, element: element, size: sum, limits: limits)
                        let decoder = try coordinator.stream(offset: 0, length: sum)
                        try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { buffer in
                            while try decoder.read(into: buffer) > 0 {}
                        }
                    } catch KaitoError.unsupportedMethod(let detail) {
                        for fork in streamForks { auxiliaries[fork.owner, default: []].append("unsupportedMethod=\(detail)") }
                    }
                }
            }
            for fork in streamForks.sorted(by: { $0.slot < $1.slot }) where fork.kind <= 1 {
                try append(owner: fork.owner, fork: fork, offset: offsets[fork.slot]!, solid: slots.count > 1)
            }
        }
        for object in objects {
            let id = object.attributes[1]!
            if !referenced.contains(id) { try append(owner: id, fork: nil) }
        }
        entries = result; self.intervals = intervals; self.descriptors = descriptors; self.unavailableStreams = unavailableStreams
        self.encryptedAuxiliaries = encryptedAuxiliaries; resolvedPassword = password
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
            for id in encryptedAuxiliaries[owner] ?? [] where !verifiedAuxiliaries.contains(id) {
                guard !unavailableStreams.contains(id), let (element, size) = descriptors[id] else {
                    throw KaitoError.unsupportedMethod("StuffIt X mixed auxiliary slots")
                }
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
