import Foundation

// 命名規則は KaitoKit の SplitVolumeSet / ZipSplitVolumeSet と共有する。
// 出自は両 reader のコメントを参照。新たな外部実装は参照していない。

/// URL から実際に組み立てた分割巻と、その組み立て時点の同一性。
/// 名前や属性はスナップショットであり、現在のパスの存在・同一性を保証しない。
public struct ArchiveVolumeSet: Sendable, Equatable {
    public enum Scheme: Sendable, Equatable {
        /// `<stem>.001` などのバイト分割。width を超える巻番号は桁を伸ばす。
        case numbered(stem: String, width: Int)

        /// `<stem>.z01` / `.zx01` などと、最後の `.zip` / `.zipx`。
        /// volumePrefix は先頭の番号付き巻を開いた綴り、lastExtension は最終巻の綴り。
        /// 巻ごとに大小文字が異なる場合の名前は `volumes` に保持する。
        case zipSpanned(stem: String, volumePrefix: String, lastExtension: String)

        /// 総巻数 count に対する 0 始まりの巻名を生成する（I/O なし）。
        /// numbered は count によらず index + 1、ZIP は index == count - 1 のみ最終巻名。
        /// index >= count も番号付き巻名を返す。index >= 0、count >= 1 が前提。
        /// parse の結果から先頭巻名を求める場合も利用できる。
        public func fileName(forVolumeAt index: Int, count: Int) -> String {
            precondition(index >= 0 && count > 0)
            switch self {
            case .numbered(let stem, let width):
                return SplitVolumeSet.volumeName(.init(stem: stem, width: width), number: UInt64(index))
            case .zipSpanned(let stem, let volumePrefix, let lastExtension):
                if index == count - 1 { return stem + "." + lastExtension }
                // 非負の Int を UInt64 に拡張してから足すので、Int.max でも overflow しない。
                return ZipSplitVolumeSet.volumeName(
                    .init(stem: stem, prefix: volumePrefix, openedNumber: nil), number: UInt64(index) + 1
                )
            }
        }
    }

    /// 読み取りに使う FileByteSource の保持 fd を fstat した値。mode はファイル種別も含む。
    public struct Volume: Sendable, Equatable {
        /// 親 URL と、実際の open / openat に使った巻名（symlink は解決しない）。
        public let url: URL
        public let length: UInt64
        public let device: UInt64
        public let inode: UInt64
        public let mode: UInt16
        public let modificationSeconds: Int64
        public let modificationNanoseconds: Int64
    }

    public let scheme: Scheme
    /// 論理順。ZIP の最終 `.zip` / `.zipx` は最後に置く。常に 2 巻以上。
    public let volumes: [Volume]
    /// 呼び出し元の URL が指した巻の、0 始まりの位置。
    public let openedVolumeIndex: Int

    /// セットの入口となる巻。numbered は先頭、ZIP は最終巻。
    public var gateIndex: Int {
        switch scheme {
        case .numbered: return 0
        case .zipSpanned: return volumes.count - 1
        }
    }

    /// 現在の巻数での名前。index >= 0 が前提で、volumes.count 以降も生成できる。
    /// ZIP の最終巻の位置を動かす場合は `fileName(forVolumeAt:count:)` を使う。
    public func fileName(forVolumeAt index: Int) -> String {
        fileName(forVolumeAt: index, count: volumes.count)
    }

    /// 出力を count 巻にする場合の名前。index >= 0、count >= 1 が前提。
    /// ZIP は index == count - 1 が元の最終巻名になり、それ以外は index + 1 番の名前。
    /// 既存の番号付き巻は元の綴りを使い、新しい番号は scheme の prefix で生成する。
    /// 例: 3 巻の a.z01 / a.z02 / a.zip を 4 巻にすると、index 2 は a.z03、3 は a.zip。
    /// index >= count は番号付き巻名を返す（最終巻名を繰り返さない）。
    public func fileName(forVolumeAt index: Int, count: Int) -> String {
        precondition(index >= 0 && count > 0)
        if case .zipSpanned = scheme, index != count - 1, index < volumes.count - 1 {
            return volumes[index].url.lastPathComponent
        }
        return scheme.fileName(forVolumeAt: index, count: count)
    }

    /// ファイル名だけを解析する。I/O を行わず、セットの存在や総巻数は確認しない。
    /// numbered は 3 桁以上の ASCII 数字、ZIP は z / zx と 2 桁以上の ASCII 数字を受理する。
    /// 正の巻番号を 0 始まりの index に変換し、0 や Int に収まらない index は nil。
    /// `.zip` / `.zipx`（大小文字を問わない）は最終巻を表すが、位置不明のため index は -1。
    /// numbered の width は見えている桁数（桁あふれ前の幅は推定できない）。ZIP の prefix は
    /// reader と同じく拡張子の先頭文字で大小文字を選ぶ。兄弟巻の実際の綴りは推定できない。
    /// この解析に成功しても、途中の numbered 巻を open(url:) が巻き戻すことはない。
    public static func parse(fileName: String) -> (scheme: Scheme, index: Int)? {
        guard let separator = fileName.lastIndex(of: "."), separator != fileName.startIndex else { return nil }
        let stem = String(fileName[..<separator])
        let ext = String(fileName[fileName.index(after: separator)...])
        if ext.utf8.count >= 3, ext.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let number = UInt64(ext), number > 0, let index = Int(exactly: number - 1) else { return nil }
            return (.numbered(stem: stem, width: ext.utf8.count), index)
        }
        guard let naming = ZipSplitVolumeSet.naming(for: fileName) else { return nil }
        let index: Int
        if let number = naming.openedNumber {
            guard let value = Int(exactly: number - 1) else { return nil }
            index = value
        } else {
            index = -1
        }
        return (.zipSpanned(stem: naming.stem, volumePrefix: naming.prefix,
                            lastExtension: naming.openedNumber == nil ? ext : naming.lastExtension), index)
    }
}
