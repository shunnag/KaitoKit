/// CAB folder の CFDATA 列を先頭から順に展開する decoder。MSZIP と stored は `MSZIPDecompressor`、LZX は
/// `LZXFolderDecompressor` が実装し、`CabReader` の solid coordinator が folder ごとに保持する。
/// CAB のチェックサムはエントリーと交差する CFDATA だけで検査する。先行フレームは履歴の復元に使う。
protocol CabFolderDecoder: AnyObject {
    var position: UInt64 { get }
    func skip(to offset: UInt64, entryIndex: Int) throws
    func read(into buffer: UnsafeMutableRawBufferPointer, entryIndex: Int) throws -> Int
}
