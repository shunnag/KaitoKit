// 参照仕様: 公開ドメインの LZMA SDK `C/Ppmd7.c`、`C/Ppmd7.h`、
// `C/Ppmd7Dec.c` と Dmitry Shkarin の PPMd var.H model description。

/// 共有の PPMd variant H model（`PPMd7Model`）が使う range coder の操作。
///
/// 部分区間の更新では意図して normalize しない。model は記号の選択後と各 suffix への
/// 降下前に normalize を呼ぶ。これは 7z の coder では部分区間ごとの refill と等価で、
/// RAR の carry-less coder ではこの位置が必須になる。
protocol PPMd7RangeDecoding: AnyObject {
    func threshold(total: Int) throws -> Int
    func remove(start: Int, size: Int) throws
    func decodeBinary(probability: Int) throws -> Bool
    func normalize() throws
}
