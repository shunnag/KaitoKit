# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りフレームワークです。tar、ZIP / ZIP64、7z、
RAR4 / RAR5、LHA / LZH に加え、gzip、bzip2、xz、UNIX compress (`.Z`) と圧縮 tar を扱います。
書庫の検出から列挙、ストリーミング読み取り、展開までを一つのパイプラインとして提供します。

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

| 形式 | コンテナ・圧縮方式 | 暗号化 | multi-volume / multi-stream |
|---|---|---|---|
| tar | POSIX/ustar、pax、GNU long name/link、stored member | なし | volume 分割なし |
| gzip | RFC 1952、FTEXT/FHCRC/FEXTRA/FNAME/FCOMMENT、DEFLATE、CRC32/ISIZE | なし | concatenated member 対応 |
| bzip2 | BZip2 block size 1〜9 | なし | concatenated stream 対応 |
| xz | XZ container、Apple Compression の LZMA、footer/padding | なし | concatenated stream 対応 |
| UNIX compress (`.Z`) | LZW、9〜16 bit、block mode | なし | なし |
| 圧縮 tar | `.tgz` / `.tar.gz`、`.tbz2` / `.tar.bz2`、`.txz` / `.tar.xz` を展開後に TarReader で列挙 | なし | なし |
| ZIP / ZIP64 | stored (0)、Deflate (8)、Deflate64 (9)、BZip2 (12)、LZMA (14)、中央 directory、SFX | ZipCrypto、WinZip AES-128/192/256 (AE-1/AE-2) | multi-disk / spanned は非対応 |
| 7z | Copy、LZMA1、LZMA2、PPMd7 var.H、Deflate、BZip2、Delta、BCJ (x86/ARM/ARMT/ARM64/PPC)、BCJ2、solid folder、上限付き Mach-O/PE SFX prefix | 7zAES-256、data/header encryption | external volume 分割なし、solid/block split 対応 |
| RAR4 | stored、unpack version 29 の LZ/PPMd-H、E8/E8E9/Itanium/Delta/RGB/Audio、solid、上限付き SFX | RAR3 AES-128 per-file、`-hp` header encryption | URL-backed old `.r00` / new `.partN.rar` |
| RAR5 | stored、compression version 0 の LZ、Delta/E8/E8E9/ARM、solid | AES-256 per-file、`-hp` header encryption、HashMAC | URL-backed `.partN.rar`、暗号化 volume 対応 |
| LHA / LZH | level 0/1/2/3、`-lh0-`/`-lh1-`/`-lh4-`〜`-lh7-`/`-lhx-`/`-lz4-`/`-lz5-`/`-lzs-`/`-pm0-`、LHArk `-lh7-`、上限付き SFX | なし | なし、全 member は独立 (`solidGroup == -1`) |

名前は ZIP/RAR4/LHA/tar/gzip FNAME の undecorated bytes に対して archive-wide の UTF-8、CP932、
EUC-JP 判定を行い、format が宣言する Unicode 名を優先します。単一 file 形式の FNAME がない場合は
source file の拡張子を除いた名前を entry 名にします。

圧縮 tar の展開結果は `ReadLimits.inMemorySingleFileLimit` 以下なら memory、それより大きければ
直ちに unlink した一時 file descriptor に保持します。どちらも同じ `TarReader` API を公開します。

LHA の directory 属性は method だけでなく末尾 separator と MS-DOS directory bit からも判定します。
このため OS/2 の extended-attribute payload を持つ subdirectory も子 entry の親として扱えます。
先頭 slash と drive prefix は除いて相対名にしますが、`..` は解決せず、展開層で従来どおり
拒否します。古い writer が filename field の NUL より後ろへ付けた metadata は pathname に含めません。
level 0〜3 の 0xFF と、文字コード復号後の backslash は directory separator として扱い、
CP932 の二バイト文字の一部である 0x5C は保持します。level-0 Unix `U` 拡張の
mtime / permissions / uid / gid も公開します。

MacLHA の Macintosh OS marker を持つ member は、MacBinary / MacBinary II standard proposals に基づいて
復号後の header が有効と確認できた場合だけ、data fork を `stream(_:)` / `read(_:)` に公開します。
LHA CRC16 は padding と resource fork を含む MacBinary 全体と compatible trailing extension について検証し、
MacBinary ではない member はそのまま返します。公開 `uncompressedSize` は互換性のため LHA header が
宣言した envelope size を保持します。

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

## 既知の制限

- CAB、ARJ、ACE、StuffIt/SIT、ISO disk image、zstd stream は未対応です。
- ZIP は multi-disk/spanned と method 93 (zstd)、95 (xz)、96 (JPEG)、98 (PPMd) を扱いません。
- 7z は IA-64 / SPARC filter を扱いません。
- RAR4 は unpack version 15/20/26、custom VM、dictionary size が変わる solid 構成、SFX と multi-volume の組合せを
  扱いません。RAR5 は compression version 1、file-copy redirection、SFX、サイズ不明の暗号化
  stored entry を扱いません。
- LHA は `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` を一覧できますが、読み取り時に
  `unsupportedMethod` になります。resource fork は separate entry として公開しません。
- XZ は Apple Compression が扱う XZ container が対象で、raw `.lzma` は対象外です。gzip/bzip2/xz の
  concatenated stream は一つの entry として連結した出力を返します。
- gzip/bzip2/xz/`.Z` の出力サイズは読み終えるまで不明です。modern API では `nil`、compat API では
  `entryHasSize == false` / `Int64.max` になります。
- 圧縮 tar の判定には URL の拡張子 hint を使います。filename を持たない Data/任意 `ByteSource` は
  単一 file stream として開きます。
- 組込み cancellation token は未提供です。incremental 処理は caller が `EntryStream` の read loop を
  終了して制御します。

## 組み込みの注意

`ArchiveReader` と `EntryStream` は thread-safe ではありません。一つの instance の操作は actor や
serial queue で直列化し、並列展開には `reopen()` で作った独立 reader を使ってください。同じ
`solidGroup >= 0` の entry は同じ worker へ割り当て、`solidGroup == -1` は entry 単位で並列化できます。

`ReadLimits` は `maxEntrySize`、`maxTotalUncompressedSize`、`maxInMemorySize`、
`inMemorySingleFileLimit`、entry/metadata/path/dictionary/volume 上限などをまとめます。利用する corpus と
端末の memory budget に合わせて open 前に設定してください。`read(_:)` より大きい entry は
`EntryStream` で処理し、最後の 0 または error まで読み切って CRC と stream footer を確定します。

`Data(contentsOf:options:.mappedIfSafe)` は、呼出中に内容が変わらないローカルの単一 file で使います。
RAR multi-volume は sibling file を解決できる `ArchiveReader.open(url:)` を使い、nested archive のように
既に memory 上にある bytes は `open(data:)` を使います。SFX prefix scan は URL open で有効、Data と
任意 `ByteSource` では `ReaderOptions.scanForSFXInData` が既定 `false` です。

展開先 root は処理中に caller が排他的に所有し、別 thread/process から名前や directory を変更しないで
ください。directory entry は子を展開した後、深い順に処理すると archive の最終日時と permissions を
保持できます。

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
差分テストに利用できます。`sha` / `extract` は entry ごとの失敗を stderr へ報告して後続を処理し、
失敗が一件でもあれば終了コード 1 を返します。`sha` の失敗行は `index<TAB>ERROR<TAB>message<TAB>name`、
末尾は成功 entry だけを集計した `partial` となり、完全な `total` は出力しません。`list` は index、size、kind、method、暗号方式 (`plain`、
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
RAR3 は長いパスワードの旧 SHA-1 入力更新規則に対応します。
writer と同じ最大127文字（UTF-16 候補は127 code units、Unix 候補は127 scalars）で区切ります。BMP 外の文字を含む RAR3 password は
UTF-16 を先に試し、検証失敗時に Unix RAR の Unicode scalar 下位 16 bit 表現へ再試行します。
file data は独立した stream で CRC を最後まで検証してから公開するため、この場合だけ追加の展開が生じます。

RAR5 は先頭127 Unicode scalars の UTF-8 を優先し、有効な password 検査値が一致しなければ
入力全体の UTF-8 を試します。127 scalars 以下の password は変更しません。

## 開発

```console
swift build
swift test
swift build -c release
bash -n Scripts/build-framework.sh Scripts/fuzz/*.sh
python3 -m py_compile Scripts/fuzz/mutate.py
```

7zz / xz を使う差分テストは、`KAITO_7ZZ` / `KAITO_XZ`、`PATH`、既知の Homebrew path
の順で executable を探します。通常は tool が無ければ該当テストを skip します。CI と同じく
不足を failure にする場合は次のように実行します。

```console
brew install sevenzip xz
KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 swift test
```

圧縮 payload を含む ZIP / 7z seed を実際の 7zz で作り、malformed / unusual archive の
robustness mutant を ASan/UBSan build で走らせる手順は次のとおりです。AES seed の password は
`KaitoFuzz` で、`--password` は暗号化されていない seed と同じ directory に対しても指定できます。

```console
Scripts/fuzz/make-compressed-seeds.sh /tmp/kaito-compressed-seeds
Scripts/fuzz/run-mutants.sh --count 200 --password KaitoFuzz \
  --require-payload-ranges /tmp/kaito-compressed-seeds
```

`Scripts/build-framework.sh` は Apple Silicon / Intel 両対応のユニバーサル `KaitoKit.framework` を生成します。SwiftPM を介さず利用する場合は、ネストされた `KaitoKitCompat` モジュールを見つけられるよう `-I Frameworks/KaitoKit.framework/Modules` も指定してください。

設計判断、堅牢性規則、参照可能な仕様は [Documentation/design.md](Documentation/design.md)、
XADMaster からの移行状況は
[Documentation/migration-from-xadmaster.md](Documentation/migration-from-xadmaster.md) を参照してください。
設計書が引く性能・安定性の実測ログは
[Documentation/verification/](Documentation/verification/README.md) にあります。
