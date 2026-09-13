// MZ の署名候補を位置順に調べ、容器 header の検証に通った最初の起点を採用する。
import Foundation

enum StuffItSFX {
    static func find(source: any ByteSource, maximumScanSize: UInt64, limits: ReadLimits) throws -> UInt64? {
        let bound = min(maximumScanSize, FormatDetector.maximumSFXScanSize)
        guard bound > 0, source.length >= 2,
              try readByteRange(source: source, offset: 0, count: 2) == [0x4d, 0x5a] else { return nil }
        // 起点だけを scan bound で制限し、候補署名と検証用 header はその先まで読める。
        let count = Int(min(source.length, bound + 100))
        let bytes = try readByteRange(source: source, offset: 0, count: count)
        let last = min(Int(bound), count - 8)
        guard last >= 1 else { return nil }
        for offset in 1...last where bytes[offset] == 0x53 {
            let prefix = Array(bytes[offset..<min(offset + 100, count)])
            let kind = StuffItHeader.signature(prefix)
            guard kind != nil || prefix.starts(with: "StuffIt!".utf8) else { continue }
            let candidate = try RebasedByteSource(source: source, baseOffset: UInt64(offset))
            do {
                if try validHeader(candidate, kind: kind, limits: limits) { return UInt64(offset) }
            } catch let error as KaitoError {
                switch error {
                case .truncated, .malformed, .limitExceeded: continue
                default: throw error
                }
            }
        }
        return nil
    }

    private static func validHeader(_ source: any ByteSource, kind: String?, limits: ReadLimits) throws -> Bool {
        if kind == "classic" {
            let header = try readByteRange(source: source, offset: 0, count: 22)
            let end = StuffItHeader.be32(header, 6)
            guard end >= 134, end <= source.length else { return false }
            let entry = try readByteRange(source: source, offset: 22, count: 112)
            return CRC16.checksum(Array(entry.prefix(110))) == StuffItHeader.be16(entry, 110)
        }
        if kind == "stuffit5" {
            let fixed = try readByteRange(source: source, offset: 0, count: 100)
            let first = StuffItHeader.be32(fixed, 94), end = StuffItHeader.be32(fixed, 84)
            guard fixed[82] == 5, first >= 100, first <= end, end <= source.length else { return false }
            try Checked.size(first, limit: limits.maxMetadataSize)
            var header = try readByteRange(source: source, offset: 0, count: Checked.toInt(first))
            let expected = StuffItHeader.be16(header, 98)
            header[98] = 0; header[99] = 0
            return CRC16.checksum(header) == expected
        }
        // Root 一要素の packed header を走査する。catalog の復号や全書庫の展開はここでは行わない。
        let bounded = try BoundedByteSource(source: source, baseOffset: 0, length: min(source.length, limits.maxMetadataSize))
        let input = try StuffItXBitReader(source: bounded, offset: 8)
        _ = try input.bits(1)
        guard try input.p2() == 7 else { return false }
        for algorithms in [false, true] {
            var records = 0
            while true {
                let key = try input.p2()
                if key == 0 { break }
                records += 1
                guard records <= limits.maxMetadataRecordCount else { return false }
                _ = try input.p2()
                if algorithms && key == 4 { _ = try input.p2() }
            }
        }
        _ = try input.p2(); input.align()
        return true
    }
}
