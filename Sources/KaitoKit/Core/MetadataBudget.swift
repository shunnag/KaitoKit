import Foundation

/// 形式 metadata の読み取り量を合算し、上限で止める。ISO・UDF・WIM・CFB・CAB の header 走査が使う。
/// ISO / UDF は二つの木の走査と捨てた候補にも同じ予算を使うので参照型にする。
final class MetadataBudget {
    let limits: ReadLimits
    private let totalLimit: UInt64
    private(set) var total: UInt64 = 0

    /// 合算の上限は `maxTotalMetadataSize`。
    convenience init(_ limits: ReadLimits) {
        self.init(limits, totalLimit: limits.maxTotalMetadataSize)
    }

    /// 合算の上限を別に指定する。
    init(_ limits: ReadLimits, totalLimit: UInt64) {
        self.limits = limits
        self.totalLimit = totalLimit
    }

    func charge(_ bytes: UInt64) throws {
        total = try Checked.add(total, bytes)
        try Checked.size(total, limit: totalLimit)
    }

    /// `count × stride` の配列を一つの割り当てとして `maxMetadataSize` で検査してから合算に足す。
    func array(count: Int, stride: Int) throws {
        let size = try Checked.mul(UInt64(count), UInt64(stride))
        try Checked.size(size, limit: limits.maxMetadataSize)
        try charge(size)
    }
}
