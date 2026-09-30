import Foundation

/// 編集 snapshot の header group を保持済み image から復元し、記録した範囲と照合する。
enum TarEditingLayoutRestorer {
    static func headerGroup(_ member: TarMemberLayout, layout: TarArchiveLayout,
                            source: any ByteSource, limits: ReadLimits) throws -> TarHeaderGroup {
        let paxLocal = [UInt8(ascii: "x"), UInt8(ascii: "X")]
        let gnuLong = [UInt8(ascii: "L"), UInt8(ascii: "K")]
        do {
            var global = TarPAXRecords(), local = TarPAXRecords()
            for range in layout.globalHeaderRanges where range.lowerBound < member.headerOffset {
                let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: range.lowerBound, count: TarHeaderBlock.size))
                try header.validateChecksum()
                guard header.typeFlag == UInt8(ascii: "g") else { throw KaitoError.truncated }
                let size = try header.size()
                try Checked.size(size, limit: limits.maxMetadataSize)
                let body = try Checked.add(range.lowerBound, UInt64(TarHeaderBlock.size))
                guard try TarParser.nextHeaderOffset(dataOffset: body, size: size, source: source) == range.upperBound else { throw KaitoError.truncated }
                let paxRecords = try TarPAXRecords.parse(TarParser.readPayload(source: source, offset: body, size: size), recordLimit: limits.maxMetadataRecordCount)
                try paxRecords.rejectGlobalSparse()
                try global.merge(paxRecords.retained(), limits: limits)
            }
            var cursor = member.groupRange.lowerBound
            var extensions: [TarHeaderGroup.Extension] = []
            while cursor < member.headerOffset {
                let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: cursor, count: TarHeaderBlock.size))
                try header.validateChecksum()
                let type = header.typeFlag
                guard (paxLocal + gnuLong).contains(type) else { throw KaitoError.truncated }
                let size = try header.size()
                try Checked.size(size, limit: limits.maxMetadataSize)
                let body = try Checked.add(cursor, UInt64(TarHeaderBlock.size))
                let end = try TarParser.nextHeaderOffset(dataOffset: body, size: size, source: source)
                guard end <= member.headerOffset else { throw KaitoError.truncated }
                let payload = try TarParser.readPayload(source: source, offset: body, size: size)
                if paxLocal.contains(type) {
                    local = try TarPAXRecords.parse(payload, recordLimit: limits.maxMetadataRecordCount).retained()
                } else { _ = try TarParser.parseGNULongValue(payload, fieldName: type == UInt8(ascii: "L") ? "name" : "link") }
                extensions.append(.init(typeFlag: type, headerOffset: cursor, payloadRange: body..<(body + size), end: end))
                cursor = end
            }
            guard cursor == member.headerOffset else { throw KaitoError.truncated }
            let header = TarHeaderBlock(bytes: try readByteRange(source: source, offset: cursor, count: TarHeaderBlock.size))
            try header.validateChecksum()
            let type = header.typeFlag
            guard !(paxLocal + gnuLong + [UInt8(ascii: "g")]).contains(type) else { throw KaitoError.truncated }
            try global.merge(local, limits: limits)
            let headerSize = try header.size()
            let effectiveSize = try global["size"].map { try TarPAXRecords.unsigned($0, fieldName: "size") } ?? headerSize
            let extensionStart = try Checked.add(cursor, UInt64(TarHeaderBlock.size))
            var body = extensionStart
            if type == UInt8(ascii: "S") {
                body = try TarSparseMap.parseOldGNU(
                    header: header, dataOffset: body, storedSize: effectiveSize, source: source, limits: limits
                ).dataOffset
            }
            var reader = try ByteReader(source: source, bufferCapacity: 4 * 1024)
            let size = try TarParser.storedBodySize(typeByte: type, declaredSize: effectiveSize,
                                          hasAuthoritativePAXSize: global["size"] != nil, dataOffset: body,
                                          source: source, reader: &reader, recoverDamagedArchives: false)
            guard body == member.bodyRange.lowerBound, size == member.bodyRange.upperBound - body,
                  try TarParser.nextHeaderOffset(dataOffset: body, size: size, source: source) == member.groupRange.upperBound else {
                throw KaitoError.truncated
            }
            return TarHeaderGroup(extensions: extensions, headerOffset: cursor, typeFlag: type,
                                  sparseExtensionRange: body > extensionStart ? extensionStart..<body : nil)
        } catch {
            throw KaitoError.malformed("tar layout does not match the image")
        }
    }
}
