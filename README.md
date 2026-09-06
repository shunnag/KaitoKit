# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りフレームワークです。ustar、pax、GNU 拡張
tar、ZIP / ZIP64 に加え、M2 では 7z を実装しています。書庫の検出から列挙、
ストリーミング読み取り、安全な展開までを一つのパイプラインとして提供します。
RAR / LHA と圧縮 tar は後続マイルストーンで追加します。

- 対象: macOS 26 以上、Swift 6、Apple Silicon / Intel
- 外部依存: なし。zlib、libbz2 など OS 同梱ライブラリだけを使用
- ライセンス: MIT。XADMaster / The Unarchiver のコードは実装へ取り込んでいません

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
自動判定が必要な未宣言名を持つ書庫では、`nameEncoding` から書庫全体に選択された
文字コードを取得できます。自動判定時にすべての名前が形式で宣言済みまたは
厳密に有効な UTF-8 なら `nil` です。

## 対応状況

| 形式・機能 | 対応状況 |
|---|---|
| tar | ustar、pax、GNU long name/link |
| ZIP コンテナ | 中央ディレクトリ、ZIP64、SFX prefix、遅延ローカルヘッダ |
| ZIP 圧縮方式 | stored (0)、deflate (8)、Deflate64 (9)、bzip2 (12)、LZMA (14) |
| ZIP 暗号化 | Traditional PKWARE (ZipCrypto)、WinZip AES-128/192/256 (AE-1/AE-2) |
| ZIP ファイル名 | UTF-8 flag、Info-ZIP Unicode Path、CP932 / EUC-JP / UTF-8 の書庫単位自動判定 |
| ZIP メタデータ | ZIP64、extended timestamp、NTFS timestamp、UNIX symlink・permission |
| ZIP 整合性 | 展開後 CRC32、WinZip AES authentication code |
| ZIP 非対応 | multi-disk / spanned、zstd (93)、xz (95)、JPEG (96)、PPMd (98) |
| 7z コンテナ | signature / start / next header CRC、plain / encoded header、UTF-16LE 名、日時・Windows / UNIX 属性、empty / anti item |
| 7z 圧縮方式 | Copy、LZMA1、LZMA2、PPMd7 (var.H)、Deflate、BZip2 |
| 7z フィルタ | Delta、BCJ (x86 / ARM / ARMT / ARM64 / PPC)、BCJ2 |
| 7z 暗号化 | 7zAES (AES-256-CBC + SHA-256 KDF)、data / header encryption、派生鍵 cache |
| 7z solid | folder stream の継続利用、`solidGroup`、block-split、pure LZMA2 の後方 seek 用 dictionary-reset index |
| 7z 整合性 | start / next header、packed stream、folder、substream の CRC32 |
| 7z 非対応 | IA64 / SPARC filter |

ZIP の DOS 日時にはタイムゾーン情報がないため、現在のローカルタイムゾーンとして解釈します。
Extended timestamp と NTFS timestamp は UTC の時刻として扱います。ZIP のローカルヘッダを
open 時にすべて検証したい場合は `ReaderOptions(lazyLocalHeaders: false)` を指定してください。

7zAES には独立した認証 tag がないため、KaitoKit は最初に復号した stream の CRC 不一致、
または復号後の coder 構造が不正な場合を `wrongPassword` と判定します。このため、暗号化
stream 自体の破損も `wrongPassword` として報告される場合があります。KDF の計算量上限は
`ReaderOptions.maxSevenZipAESCyclesPower` で設定できます。

## コマンドライン

```console
$ swift run kaito detect samples/book.tar
tar
$ swift run kaito list samples/book.zip
0\t12345\tfile\tdeflate\tplain\t表紙.jpg
$ swift run kaito list samples/book.zip --raw
$ swift run kaito extract samples/book.tar -o /tmp/book
$ swift run kaito sha samples/book.tar
$ swift run kaito bench samples/book.tar 5
$ swift run kaito bench --data samples/book.tar 5
$ swift run kaito bench --random samples/book-solid.7z 5
```

`sha` はエントリ順の SHA-256 と総合ダイジェストを出力し、別の展開実装との
差分テストに利用できます。`list` は index、size、kind、method、暗号方式 (`plain`、
`ZipCrypto`、`AES-128/192/256`、`7zAES-256`)、name の順でタブ区切り表示し、`--raw` は
名前の元バイト列を末尾へ 16 進数で併記します。`bench --data` は `mappedIfSafe` で作った `Data`
から書庫を開き、map 作成を含む `open-median-ms` を表示します。`bench --random` は
固定 seed で選んだ最大 20 件の非ディレクトリエントリをランダム順に読み、solid 書庫の
後方シークを含むアクセスを再現可能な条件で計測します。表示する `bytes` は選択した
エントリの合計です。

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
