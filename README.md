# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りフレームワークです。M0 は ustar、pax、
GNU 拡張 tar を実装し、書庫の検出から列挙、ストリーミング読み取り、安全な展開までを
一つのパイプラインとして提供します。ZIP / RAR / 7z / LHA と圧縮 tar は後続マイルストーンで
追加します。

- 対象: macOS 26 以上、Swift 6、Apple Silicon / Intel
- 外部依存: なし。zlib、libbz2 など OS 同梱ライブラリだけを使用
- ライセンス: MIT。XADMaster / The Unarchiver のソースは参照も流用もしていません

## SwiftPM

```swift
import Foundation
import KaitoKit

let archive = try ArchiveReader.open(url: URL(fileURLWithPath: "/tmp/book.tar"))
for entry in archive.entries {
    print(entry.index, entry.uncompressedSize ?? 0, entry.name)
    if entry.kind == .file {
        let contents = try archive.read(entry)
        print("read \(contents.count) bytes")
    }
}

let destination = URL(fileURLWithPath: "/tmp/unpacked", isDirectory: true)
for entry in archive.entries where entry.kind != .directory {
    _ = try archive.extract(entry, to: destination)
}
let directories = archive.entries.filter { $0.kind == .directory }.sorted {
    if $0.pathComponents.count != $1.pathComponents.count {
        return $0.pathComponents.count > $1.pathComponents.count
    }
    return $0.index < $1.index
}
for entry in directories {
    _ = try archive.extract(entry, to: destination)
}
```

ディレクトリは子を展開した後に深い順で処理すると、書庫内の最終パーミッションと
更新日時を保持できます。`kaito extract` もこの順序を使用します。
本文を持たない hard link は、同じ `ArchiveReader` で同じ出力ルートへ参照先を先に
展開した場合だけ作成されます。この provenance は出力ルートを切り替えるか `reopen()`
するとリセットされるため、上のように書庫順で展開してください。
展開中の出力ルートは呼出側が排他的に所有し、別スレッドや別プロセスから変更しないでください。

`ArchiveReader` はスレッドセーフではありません。並列展開では `reopen()` で同じ
`ByteSource` を共有する独立 reader を作ってください。既存 XADMaster 利用コード向けには
`KaitoKitCompat` の `KaitoArchive` と `XADArchive` typealias もあります。

## コマンドライン

```console
$ swift run kaito detect samples/book.tar
tar
$ swift run kaito list samples/book.tar
0\t12345\tfile\t表紙.jpg
$ swift run kaito list samples/book.tar --raw
$ swift run kaito extract samples/book.tar -o /tmp/book
$ swift run kaito sha samples/book.tar
$ swift run kaito bench samples/book.tar 5
```

`sha` はエントリ順の SHA-256 と総合ダイジェストを出力し、別の展開実装との
差分テストに利用できます。`--raw` は名前の元バイト列を 16 進数で併記します。

## 開発

```console
swift build
swift test
swift build -c release
bash -n Scripts/build-framework.sh Scripts/fuzz/*.sh
python3 -m py_compile Scripts/fuzz/mutate.py
```

`Scripts/build-framework.sh` は Apple Silicon / Intel 両対応のユニバーサル `KaitoKit.framework` を生成します。SwiftPM を介さず利用する場合は、ネストされた `KaitoKitCompat` モジュールを見つけられるよう `-I Frameworks/KaitoKit.framework/Modules` も指定してください。

設計判断、安全規則、参照可能な仕様は [Documentation/design.md](Documentation/design.md)、
XADMaster からの移行状況は
[Documentation/migration-from-xadmaster.md](Documentation/migration-from-xadmaster.md) を参照してください。
