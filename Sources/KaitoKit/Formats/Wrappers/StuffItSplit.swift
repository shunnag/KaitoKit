import Foundation

// 参照資料: 利用者所有の再構築レポート inbox/stuffit/report/06-wrappers-and-segments.md
// §"Classic StuffIt split files"（design.md §10 の StuffIt 出自一覧に含まれる散文）。各 part は
// 100 byte の header（署名 B0 56、part 番号、元 file 名、type / creator / Finder flags / 日付、
// 再構築後の resource fork 長 R と data fork 長 D）に続く連続した断片で、全 part の header を外して
// 番号順に連結すると [0, R) が resource fork、[R, R+D) が data fork（.sit / .sea 本体）になる。
// 合成 part を unar 1.10.8 が "StuffIt in StuffIt split file" として読むことを黒箱で確認した。
struct StuffItSplitHeader: Equatable {
    static let size = 100
    static let signature: [UInt8] = [0xB0, 0x56]

    let partNumber: Int
    let fileName: [UInt8]
    /// bytes 68〜93: type / creator / Finder flags / 日付 / R / D。全 part で一致しなければならない。
    let identity: [UInt8]
    let resourceLength: UInt64
    let dataLength: UInt64

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.size, Array(bytes[0..<2]) == Self.signature, bytes[2] == 0 else { return nil }
        let nameLength = Int(bytes[4])
        guard (1...63).contains(nameLength) else { return nil }
        let name = Array(bytes[5..<(5 + nameLength)])
        guard !name.contains(0) else { return nil }
        partNumber = Int(bytes[3])
        fileName = name
        identity = Array(bytes[68..<94])
        resourceLength = UInt64(bytes[86]) << 24 | UInt64(bytes[87]) << 16 | UInt64(bytes[88]) << 8 | UInt64(bytes[89])
        dataLength = UInt64(bytes[90]) << 24 | UInt64(bytes[91]) << 16 | UInt64(bytes[92]) << 8 | UInt64(bytes[93])
    }

    /// 同じ分割セットの part か（part 番号以外の header が一致する）。
    func belongsToSameSet(as other: StuffItSplitHeader) -> Bool {
        fileName == other.fileName && identity == other.identity
    }
}

/// 分割セットを連結した論理 stream。`length` と read は data fork（書庫本体）を指し、
/// resource fork は別 source として持つ。
final class StuffItSplitSource: ByteSource {
    let dataFork: BoundedByteSource
    let resourceFork: BoundedByteSource?
    let partCount: Int
    let header: StuffItSplitHeader

    init(parts: [any ByteSource], header: StuffItSplitHeader, limits: ReadLimits) throws {
        let segments = try parts.map { part -> SourceSegment in
            guard part.length >= UInt64(StuffItSplitHeader.size) else { throw KaitoError.truncated }
            return SourceSegment(source: part, offset: UInt64(StuffItSplitHeader.size),
                                 length: part.length - UInt64(StuffItSplitHeader.size))
        }
        let joined = try ConcatenatedByteSource(
            segments: segments, maximumLength: .max,
            maximumSegmentCount: max(limits.maxVolumeCount, 1), label: "StuffIt split set"
        )
        let total = try Checked.add(header.resourceLength, header.dataLength)
        guard joined.length >= total else { throw KaitoError.truncated }
        dataFork = try BoundedByteSource(source: joined, baseOffset: header.resourceLength, length: header.dataLength)
        resourceFork = header.resourceLength > 0
            ? try BoundedByteSource(source: joined, baseOffset: 0, length: header.resourceLength) : nil
        partCount = parts.count
        self.header = header
    }

    var length: UInt64 { dataFork.length }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try dataFork.read(into: buffer, at: offset)
    }
}

enum StuffItSplitSet {
    /// 開いた part の名前に含まれる part 番号の桁列を差し替えて兄弟の名前の候補を作る。
    /// `whole.sit.1` / `whole.1.sit` / `whole.sit.01` のような命名を、番号と一致する最後の桁列で扱う。
    /// 開いた part の桁数が target より多ければゼロ埋めした綴りを先に、埋めない綴りを後に返す
    /// （`disk.sit.10` から開いた場合、part 1 は `disk.sit.01` か `disk.sit.1` のどちらかで、名前だけでは
    /// 決まらない）。番号を含まない名前は空。
    static func siblingNames(of name: String, partNumber: Int, target: Int) -> [String] {
        let characters = Array(name)
        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < characters.count {
            if characters[index].isASCII, characters[index].isNumber {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                runs.append((index, end))
                index = end
            } else {
                index += 1
            }
        }
        for run in runs.reversed() {
            let digits = String(characters[run.start..<run.end])
            guard let value = Int(digits), value == partNumber else { continue }
            let prefix = String(characters[..<run.start])
            let suffix = String(characters[run.end...])
            let plain = String(target)
            var candidates = [String]()
            if digits.count > plain.count {
                candidates.append(prefix + String(repeating: "0", count: digits.count - plain.count) + plain + suffix)
            }
            candidates.append(prefix + plain + suffix)
            return candidates
        }
        return []
    }

    /// 候補の綴りを順に開き、最初に見つかった regular file を返す。
    private static func openSibling(
        of name: String, partNumber: Int, target: Int,
        directory: FileByteSource.DirectoryAnchor
    ) throws -> (any ByteSource)? {
        for candidate in siblingNames(of: name, partNumber: partNumber, target: target) {
            if let opened = try directory.openRegularFile(named: candidate, label: "StuffIt split") {
                return opened
            }
        }
        return nil
    }

    /// URL で開いた file が分割 part なら、同じ親の兄弟 part を番号順に集めて連結する。
    /// 分割でなければ nil。兄弟を開けない環境（Data）では単独 part が R+D を覆う場合だけ成立する。
    static func assemble(
        firstVolumeURL: URL?,
        source: any ByteSource,
        directory: FileByteSource.DirectoryAnchor?,
        limits: ReadLimits
    ) throws -> StuffItSplitSource? {
        guard source.length >= UInt64(StuffItSplitHeader.size) else { return nil }
        let prefix = try readByteRange(source: source, offset: 0, count: StuffItSplitHeader.size)
        guard let header = StuffItSplitHeader(prefix) else { return nil }
        guard header.partNumber >= 1 else {
            throw KaitoError.malformed("StuffIt split part number is zero")
        }
        guard limits.maxVolumeCount > 0, header.partNumber <= limits.maxVolumeCount else {
            throw KaitoError.limitExceeded("StuffIt split part count")
        }

        var parts: [any ByteSource] = []
        var canWalkSiblings = false
        if let directory, let fileSource = source as? FileByteSource, let firstVolumeURL {
            let name = firstVolumeURL.lastPathComponent
            if !siblingNames(of: name, partNumber: header.partNumber, target: header.partNumber).isEmpty {
                do {
                    try directory.verifyFirstVolumeIdentity(of: fileSource, named: name, label: "StuffIt split")
                    canWalkSiblings = true
                } catch {
                    // 明示的に開いた symlink は単独 part として扱い、兄弟を開かない。
                    canWalkSiblings = false
                }
            }
            if canWalkSiblings {
                var number = 1
                while true {
                    guard number <= limits.maxVolumeCount else {
                        throw KaitoError.limitExceeded("StuffIt split part count")
                    }
                    let part: any ByteSource
                    if number == header.partNumber {
                        part = source
                    } else {
                        guard let opened = try openSibling(of: name, partNumber: header.partNumber, target: number,
                                                           directory: directory) else {
                            break
                        }
                        part = opened
                    }
                    guard part.length >= UInt64(StuffItSplitHeader.size),
                          let partHeader = StuffItSplitHeader(try readByteRange(source: part, offset: 0, count: StuffItSplitHeader.size)),
                          partHeader.partNumber == number, partHeader.belongsToSameSet(as: header) else {
                        throw KaitoError.malformed("StuffIt split part \(number) does not belong to the set")
                    }
                    parts.append(part)
                    number += 1
                }
            }
        }
        if !canWalkSiblings {
            // 兄弟を探せないときは、この part だけで R+D を覆う単独 part に限る。
            guard header.partNumber == 1 else {
                throw KaitoError.unsupportedMethod("StuffIt split file from Data")
            }
            let body = try Checked.sub(source.length, UInt64(StuffItSplitHeader.size))
            guard body >= (try Checked.add(header.resourceLength, header.dataLength)) else {
                throw KaitoError.unsupportedMethod("StuffIt split file from Data")
            }
            parts = [source]
        }
        guard !parts.isEmpty else { throw KaitoError.truncated }
        return try StuffItSplitSource(parts: parts, header: header, limits: limits)
    }
}
