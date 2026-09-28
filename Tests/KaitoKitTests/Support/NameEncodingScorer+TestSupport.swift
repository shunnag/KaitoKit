@testable import KaitoKit

// 採点器と書庫名 sample の、テストの assertion だけが使う形。製品の経路は各型の本体を直接呼ぶ。

extension NameEncodingCandidates.Candidate {
    /// 区点ごとの、ASCII の綴りに食い込む交差復号の減点（Zone.latinIntrusion）。
    func latinIntrusions(_ bytes: [UInt8]) -> [Double] { zones(bytes).map(\.latinIntrusion) }

    /// 区点配置による文字得点（Zone.score）。
    func zoneScores(_ bytes: [UInt8]) -> [Double] { zones(bytes).map(\.score) }
}

extension NameEncodingScorer {
    /// イタリア語の語末 grave と仏・葡語の ç の位置の加点の合計。
    static func westernOrthographicEvidence(_ properties: [Traits]) -> Double { westernEvidence(properties).sum() }

    /// 全位置の acute と ß の位置の加点の合計。
    static func latinStressEvidence(_ properties: [Traits]) -> Double {
        properties.indices.reduce(0) { $0 + latinStressEvidence(properties, at: $1) }
    }
}

extension EncodingDetector {
    /// 名前の順に、区切りを含めて byte 上限に収まる名前だけを連結する。上限を超える名前は飛ばす。
    /// 製品の Foundation hint は重複数を保つ orderStableArchiveNameSample を使う。
    static func boundedArchiveNameSample(
        _ names: [[UInt8]],
        separator: UInt8,
        maximumByteCount: Int
    ) -> [UInt8] {
        let limit = max(0, maximumByteCount)
        guard limit > 0 else { return [] }

        var byteCount = 0
        var includedNameCount = 0
        for name in names {
            let separatorCount = includedNameCount == 0 ? 0 : 1
            let remaining = limit - byteCount
            guard separatorCount <= remaining,
                  name.count <= remaining - separatorCount else {
                continue
            }
            byteCount += separatorCount + name.count
            includedNameCount += 1
        }

        var combined: [UInt8] = []
        combined.reserveCapacity(byteCount)
        var remainingByteCount = byteCount
        var appendedNameCount = 0
        for name in names where remainingByteCount > 0 {
            let separatorCount = appendedNameCount == 0 ? 0 : 1
            guard separatorCount <= remainingByteCount,
                  name.count <= remainingByteCount - separatorCount else {
                continue
            }
            if separatorCount == 1 { combined.append(separator) }
            combined.append(contentsOf: name)
            remainingByteCount -= separatorCount + name.count
            appendedNameCount += 1
        }
        return combined
    }
}
