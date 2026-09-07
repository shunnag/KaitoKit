# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りフレームワークです。ustar、pax、GNU 拡張
tar、ZIP / ZIP64、7z、RAR4 / RAR5 に加え、M4 では LHA / LZH reader を実装しています。
書庫の検出から列挙、ストリーミング読み取り、安全な展開までを一つのパイプラインとして
提供します。圧縮 tar は後続マイルストーンで追加します。

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
| LHA コンテナ | header level 0 / 1 / 2、独立 member (`solidGroup == -1`)、`-lhd-` directory |
| LHA 圧縮方式 | stored: `-lh0-` / `-lz4-` / `-pm0-`、compressed: `-lh1-` / `-lh4-` / `-lh5-` / `-lh6-` / `-lh7-` / `-lz5-` / `-lzs-` |
| LHA ファイル名 | legacy 名の書庫単位判定、level 0 / 1 の `\` 区切り、0x01 / 0x02、0x46 codepage 932 / 65001 / 936 |
| LHA メタデータ | DOS / Unix / Windows 日時、64-bit size、MS-DOS 属性、Unix permission / uid / gid / group / user、comment |
| LHA 整合性 | level 0 / 1 header byte sum、level 2 の 0x00 header CRC16 (存在時)、展開後 CRC16、拡張 header の件数・サイズ・前進上限 |
| LHA 非対応 | header level 3、`-pm2-`、`-lh2-` / `-lh3-` ほか上記 matrix 外の method |
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
| RAR4 コンテナ | main / file / end header、header CRC、64-bit size、RAR Unicode 名、legacy 名の書庫単位判定、DOS 日時 / `EXT_TIME`、上限付き SFX prefix、old (`.rar` / `.r00`) / new (`.partN.rar`) multi-volume |
| RAR4 圧縮方式 | stored (`0x30`)、unpack version 29 の LZ / PPMd-H (`0x31`〜`0x35`) と相互 block transition、E8 / E8E9 / Itanium / Delta / RGB / Audio の 6 native standard filter |
| RAR4 solid | LZ window、Huffman table、距離、filter program、PPMd model を entry 間で継続。順方向 skip と group 先頭からの後方再開、暗号化 solid を実装 |
| RAR4 暗号化 | per-file RAR3 AES-128-CBC と `-hp` header encryption、RAR3 KDF、password provider / key cache |
| RAR4 整合性 | header CRC、展開後 CRC32、分割 entry の非最終 part に存在する packed CRC32 |
| RAR4 非対応 | unpack version 15 / 20 / 26 を含む version 29 以外の圧縮、custom RAR VM、stored member または dictionary size 変更を含む solid group、Data / 任意 `ByteSource` からの volume 継続、SFX prefix と multi-volume の組合せ |
| RAR5 コンテナ | main / file / service / encryption / end header、header CRC32、vint、UTF-8 名、64-bit size、日時・属性・extra record、URL-backed multi-volume |
| RAR5 圧縮方式 | stored (method 0)、圧縮アルゴリズム version 0 の LZ (method 1〜5)、Delta / E8 / E8E9 / ARM filter |
| RAR5 solid | 圧縮 / stored member の混在、member ごとの dictionary minimum 変更、順方向 skip と group 先頭からの後方再開 |
| RAR5 暗号化 | per-file AES-256-CBC、archive `-hp` header encryption、PBKDF2-HMAC-SHA256、password check、CRC / BLAKE2sp HashMAC、暗号化 multi-volume |
| RAR5 整合性 | header CRC32、展開後 CRC32、任意の BLAKE2sp-256 (既定で検証)、分割 entry の非最終 volume に存在する packed CRC32 / BLAKE2sp |
| RAR5 非対応 | ユーザー指定により圧縮アルゴリズム version 1 はすべて明示的に拒否、file-copy redirection、RAR5 SFX、Data / 任意 `ByteSource` からの volume 継続、サイズ不明の暗号化 stored entry |

cooViewer の `book.lzh` は level 2 の `-lh0-` 4 member をすべて lhasa の black-box
出力と SHA-256 比較しています。`-lh5-` の literal / match / preset-window vector も、
hand-built archive を lhasa と KaitoKit の双方で展開して一致を確認しています。release の
`kaito bench book.lzh 9` は open 0.049 ms、合計 33,104 bytes の extract 0.189 ms でした。

RAR4 の `st1200-pts.rar` は 19 file 全件が RAR 7.23 の black-box 出力と一致し、
PPMd↔LZ 変換の 241,647,978-byte entry も一致しました。さらに RAR4 corpus 20 書庫では
47 regular file の byte count / SHA-256 と 5 symlink の名前 / target bytes が一致しました。
既知 password 集合では oracle を得られない暗号化 entry が 1 件あり、破損した
`seek_data_cursor0` 書庫は RAR 7.23 と KaitoKit の双方が拒否します。

RAR4 / RAR5 の URL-backed multi-volume は、最初の volume と同じ directory の deterministic
sibling 名だけを、保持した directory descriptor から symlink を追わず regular file として開き、
既定 128 volume の `ReadLimits.maxVolumeCount` で制限します。RAR4 は old / new numbering、
RAR5 は `.partN.rar` と暗号化 data / header の継続に対応します。`reopen()` は検証済みの全
volume handle を共有し、path を再解決しません。Data / 任意 `ByteSource` は sibling volume を
一意に特定できないため、未解決の分割 entry を読むと
`unsupportedMethod("multi-volume from Data")` を返します。

RAR5 archive header の KDF は、個々の `count` を
`ReaderOptions.maxRAR5KDFCountPower` (既定かつ上限 24) で制限します。さらに、header encryption
を使う全 volume を通した実際の派生処理を `ReadLimits.maxRAR5HeaderKDFWork` で累積します。
work は HMAC-SHA256 iteration 単位で、各 context を `2^count + 32` と数えます。既定値は
`4 * (2^24 + 32)`、つまり最大コストの `count = 24` context 4 件分です。同じ
`(password, salt, count)` context を複数 volume が
再利用すると key cache が使われ、一度だけ加算されます。異なる context は volume をまたいで
累積されます。

RAR5 のサイズ不明 entry は `uncompressedSize == nil` のまま、復号器の終端まで逐次
streaming します。`read(_:)` も宣言サイズを仮定せず、設定された上限内で段階的にバッファを
増やします。codec の辞書サイズ上限は `ReadLimits.maxDictionarySize` で設定し、既定値は
1 GiB です。

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
$ swift run kaito list samples/book-encrypted.7z -p secret
$ swift run kaito extract samples/book.tar -o /tmp/book
$ swift run kaito sha samples/book.tar
$ swift run kaito sha samples/book-encrypted.7z -p secret
$ swift run kaito bench samples/book.tar 5
$ swift run kaito bench --data samples/book.tar 5
$ swift run kaito bench --random samples/book-solid.7z 5
$ swift run kaito bench --random samples/book-encrypted.7z 5 -p secret
```

`sha` はエントリ順の SHA-256 と総合ダイジェストを出力し、別の展開実装との
差分テストに利用できます。`list` は index、size、kind、method、暗号方式 (`plain`、
`ZipCrypto`、`AES-128/192/256`、`7zAES-256`)、name の順でタブ区切り表示し、LHA では
末尾に `level=N` を追加します。`--raw` は
名前の format 上の論理バイト列を末尾へ 16 進数で併記します。LHA の 0x02 directory + 0x01
filename は一つの path に組み立て、0xFF directory 区切りは `/` に正規化されます。
`bench --data` は `mappedIfSafe` で作った `Data`
から書庫を開き、map 作成を含む `open-median-ms` を表示します。`bench --random` は
固定 seed で選んだ最大 20 件の非ディレクトリエントリをランダム順に読み、solid 書庫の
後方シークを含むアクセスを再現可能な条件で計測します。表示する `bytes` は選択した
エントリの合計です。

`bench` の時間は process 内の open / extract だけを複数回計測した median で、process 起動、
SHA-256、標準出力は含みません。`swift run` には SwiftPM の planning / build も含まれるため、
CLI 全体の性能は release build 済みの `.build/release/kaito` を直接実行して比較します。
`sha` は再利用する 4 MiB buffer で逐次 hash します。release binary を warm 条件で直接測ると、
変更前→変更後の median は book RAR5 が 155.346→155.431 ms、TIFF RAR5 が
637.541→610.447 ms でした。最終確認の wall time はそれぞれ 0.15 / 0.61 s です。
以前観測した約 0.62 秒の差は decoder ではなく、`swift run` の cold-start / build planning を
測定へ混ぜたことが原因でした。

`list`、`extract`、`sha`、`bench` は `-p <password>` を受け付けます。ヘッダも暗号化された
7z / RAR は、一覧やベンチマークの開始時にも password が必要です。

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
