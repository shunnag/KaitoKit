# XADMaster から KaitoKit への移行

この文書は移行ガイドの骨格です。cooViewer が利用する `XADArchive` の狭い面を
`KaitoKitCompat.KaitoArchive` で再現し、M4 までに ZIP、7z、RAR4 / RAR5、LHA / LZH を
追加しました。より広い delegate、属性、進捗 API は後続版で設計し、ここへ具体例を
追加します。

## 最小移行

依存と import を置き換えます。既存の型名を残す場合は、公開 typealias により呼び出し側の
`XADArchive` を変更する必要はありません。

```swift
// import XADMaster
import KaitoKitCompat

guard let archive = XADArchive(file: path) else { return }
```

新規コードでは `import KaitoKit` と `ArchiveReader` を推奨します。`ArchiveReader` は
throwing API なので、非対応形式、破損、上限超過、I/O エラーを区別できます。

## API 対応表

| XADArchive | KaitoArchive | ArchiveReader | 対応状況 |
|---|---|---|---|
| `init?(file:)` | 同名 | `open(url:)` | tar / ZIP / 7z / RAR4 / RAR5 / LHA で実装 |
| `init?(data:)` | 同名 | `open(data:)` | tar / ZIP / 7z / RAR4 / RAR5 / LHA で実装 |
| `defaultZipLazyLocalHeaders` / `setDefaultZipLazyLocalHeaders(_:)` | 同名 | `ReaderOptions.lazyLocalHeaders` | M1 で実装 |
| `numberOfEntries()` | 同名 | `entries.count` | 実装 |
| `name(ofEntry:)` | 同名 | `entries[i].name` | 実装。directory は互換層だけ末尾 separator を除去 |
| `contents(ofEntry:)` | 同名 | `read(_:)` / `stream(_:)` | 実装 |
| `uncompressedSize(ofEntry:)` | 同名 (`Int64`) | `uncompressedSize` (`UInt64?`) | 実装 |
| `entryHasSize(_:)` | 同名 | `uncompressedSize != nil` | 実装 |
| `entryIsDirectory(_:)` | 同名 | `kind == .directory` | 実装 |
| `entryIsEncrypted(_:)` | 同名 | `isEncrypted` | 実装 (暗号対応は ZIP / 7z / RAR) |
| `isEncrypted()` | 同名 | `entries.contains { $0.isEncrypted }` | 実装 |
| `setPassword(_:)` | 同名 | settable `password` | ZIP / 7z / RAR4 / RAR5 で実装・実 oracle 検証済み |
| `solidGroup(ofEntry:)` | 同名 (`Int32`) | `solidGroup` | 7z / RAR4 / RAR5 で実装。LHA など独立 entry は `-1` |
| `entryIsSolid(_:)` | 未提供 | 直接対応なし | continuation flag であり `solidGroup` とは意味が異なる |
| `extractEntry(_:to:)` | 同名 | `extract(_:to:)` | `to:` を展開先 directory として実装 |
| `attributesOfEntry(_:)` | 未提供 | `ArchiveEntry` の日時・権限・属性 | 後続版 |
| `entryIsLink(_:)` | 未提供 | `kind == .symlink/.hardlink` | modern API のみ |
| `entryIsResourceFork(_:)` | 未提供 | 将来の属性 | 後続版 |
| `nameEncoding` / encoding delegate | 未提供 | `nameEncoding` / `ReaderOptions.encodingPolicy` | 書庫単位判定を modern API で実装 |
| password delegate | 未提供 | `PasswordProvider` | modern API のみ |
| progress delegate / cancel | 未提供 | 未定 | 後続版 |
| `XADSimpleUnarchiver` | 未提供 | `ArchiveReader` + `Extractor` | 後続版 |
| `XADArchiveParser` / `CSHandle` | 未提供 | format reader / `ByteSource` | 直接互換なし |

## `solidGroup` と `entryIsSolid`

`solidGroup` は展開の依存単位を表します。`-1` は単独で展開できる entry、0 以上は同じ
値を持つ entry を同一グループとして直列に扱う必要があることを示します。RAR では group id
に先頭 entry の index を使い、後続に continuation が一つでもあれば、continuation flag を
持たない先頭 entry にも同じ group id を付けます。

一方、XADMaster の `entryIsSolid(_:)` に相当する per-header の値は「この entry が直前の
辞書状態を引き継ぐか」を表すため、グループ先頭では `false`、後続 entry では `true` です。
したがって `solidGroup >= 0` を `entryIsSolid` の置換として使うことはできません。
`KaitoKitCompat` は現在 `solidGroup(ofEntry:)` だけを公開し、`entryIsSolid(_:)` は提供しません。

同じ group の後方 entry をランダムに読む場合、group 先頭から対象までを再復号して途中の出力を
捨てる必要があり、再開コストは対象より前の非圧縮データ量に比例します。7z は folder stream と
一部の dictionary-reset index を利用します。RAR4 / RAR5 は per-group coordinator が archive 順に
先行 entry を検証しながら進め、後方 seek では group 先頭から再開します。同じ reader の新しい
solid stream は以前の未完了 stream を無効化します。独立して読みたい場合は `reopen()` で byte
source を共有しつつ別の password / decoder state を持つ reader を作り、各 reader 内では直列に
処理してください。

## LHA / LZH

M4 は header level 0 / 1 / 2 / 3 と `-lh0-` / `-lh1-` / `-lh4-`〜`-lh7-` /
`-lhx-` / `-lz4-` / `-lz5-` / `-lzs-` / `-pm0-` / `-lhd-` を扱います。`-lhx-` の
dictionary は 1 MiB で、OS marker が示す `-lh7-` の LHArk dialect も復号します。LHA member は
独立しているため、`solidGroup(ofEntry:)` は `-1` です。最大 1 MiB の executable prefix 内で
認証できる member header を探す LHA SFX にも対応します。

legacy 名は ZIP / RAR4 と同じ書庫単位の判定を使い、0x46 codepage が 932 / 65001 / 936 を
宣言した名前は推測しません。末尾 separator と directory 属性を entry 種別へ反映し、先頭 slash
または drive prefix は相対化します。`..` は残すため安全な展開層で拒否されます。filename field は
最初の NUL までを pathname として扱います。これにより、OS/2 extended-attribute payload を持つ
subdirectory や古い writer の unusual な名前も、子 entry を失わず列挙できます。

OS-9 LHA 2.01 が raw creator ID に 0x4B (既存 mapping では OS/68K marker) を記録する level-2
header size の 2-byte 不足は、extension chain が一意に完結する場合だけ許容します。無効な DOS timestamp は
`modificationDate == nil` とします。zero terminator がなく、最終の境界検証済み payload の直後で
exact EOF に達する archive は、最終 member が LArc の場合、または書庫内に構造検証済みの匿名通常 member を
少なくとも 1 件含む場合だけ受理します。この条件を満たさない non-LArc archive には許容しません。
`-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` は一覧できますが、読み取り時に
`KaitoError.unsupportedMethod` となります。

MacLHA の Macintosh OS marker を持つ member は、MacBinary / MacBinary II standard proposals に基づく
有効な header を確認できた場合だけ、`contents(ofEntry:)` / `read(_:)` から data fork を返します。
LHA CRC16 は header、padding、resource fork、compatible trailing extension を含む全出力について検証し、
MacBinary ではない Macintosh member はそのまま返します。`ArchiveEntry.uncompressedSize` と互換層の
`uncompressedSize(ofEntry:)` は LHA header の envelope size を保持するため、data fork の実バイト数とは
異なる場合があります。

## サイズ不明の RAR5 entry

modern API は RAR5 が非圧縮サイズを宣言しない entry を `uncompressedSize == nil` として
公開し、`EntryStream` は復号器の終端まで逐次読み取ります。`remaining` は終端確認まで
`UInt64.max`、確認後は 0 です。`read(_:)` は宣言サイズによる事前確保をせず、
`maxEntrySize` と `maxInMemorySize` の範囲で段階的に読み込みます。既定の codec 辞書上限は
`ReadLimits.maxDictionarySize == 1 GiB` です。

互換層では XADMaster と同じく `entryHasSize(_:) == false`、
`uncompressedSize(ofEntry:) == Int64.max` となります。この値は実際のサイズではないため、
空 entry の判定、事前確保、複数 entry のサイズ加算では必ず `entryHasSize(_:)` を先に確認して
ください。範囲外の entry index に対しては 0 を返します。サイズ不明の暗号化
stored RAR5 entry は現時点では明示的に非対応です。

## RAR4 / RAR5 multi-volume と `reopen()`

URL-backed RAR4 / RAR5 は最初の volume と同じ directory の deterministic な continuation 名を
検証し、分割 entry を一つの stream として公開します。RAR4 は新形式の `.partNNNN.rar` と旧形式の
`.rar` / `.r00` の両方、RAR5 は `.part1.rar` 系列に対応します。volume 数は
`ReadLimits.maxVolumeCount` (既定 128) で制限され、非最終 part の packed CRC32、RAR5 の任意の
BLAKE2sp (`verifyRAR5Blake2sp == true` が既定) を読み取り前に検証します。通常暗号化と header
暗号化を含む volume chain に対応します。open 完了後の `reopen()` は
同じ検証済み file handle 一式を共有するため、volume path を再検索せず、各 reader の password /
decoder state だけを独立させます。Data / 任意 `ByteSource` には sibling 検索の provenance がないため、
multi-volume continuation は利用できません。RAR4 の SFX prefix と multi-volume continuation の
組合せも M3 では非対応です。

RAR5 archive header の KDF は、個々の `count` を
`ReaderOptions.maxRAR5KDFCountPower` (既定かつ上限 24) で制限します。全 header-encrypted volume の
異なる `(password, salt, count)` context は `ReadLimits.maxRAR5HeaderKDFWork` へ累積され、同じ
context の key-cache hit は再加算されません。work は HMAC-SHA256 iteration 単位で、各 context を
`2^count + 32` と数えます。既定値は `4 * (2^24 + 32)`、つまり最大コストの `count = 24`
context 4 件分です。

## ZIP ローカルヘッダの検証時期

XADMaster fork と同じ静的 API を使えます。既定値は `true` で、値の読み書きは
concurrency-safe です。変更は、その後 `file:` または `data:` initializer で作る書庫に適用され、
すでに開いた `KaitoArchive` には影響しません。

```swift
KaitoArchive.setDefaultZipLazyLocalHeaders(false)
defer { KaitoArchive.setDefaultZipLazyLocalHeaders(true) }

guard let archive = KaitoArchive(file: path) else { return }
print(KaitoArchive.defaultZipLazyLocalHeaders) // false
```

`true` は各エントリの初回読み取りまで ZIP ローカルヘッダ検証を遅延します。`false` は open
時に全ローカルヘッダを検証するため、破損を早く報告する代わりに、多数エントリの open が
遅くなります。modern API では書庫ごとに
`ReaderOptions(lazyLocalHeaders: false)` を `ArchiveReader.open` へ渡してください。

Info-ZIP の `zip -P` が 5-byte file を STORED ZipCrypto entry として書いた ZIP では、
XADMaster の `XADArchive(file:)` / `XADArchive(data:)` が `nil` を返す一方、KaitoKit は通常どおり
archive を開きます。これは意図した互換差で、password 設定後に entry を読み取れます。

## directory 名と単独 entry の展開先

XADMaster の `name(ofEntry:)` は directory entry の格納名が `folder/` でも `folder` を返します。
`KaitoArchive` も全形式の directory entry について末尾 separator を除去します。modern API の
`ArchiveEntry.name` は従来の表現を維持するため、同じ ZIP entry では `folder/` のままです。

`KaitoArchive.extractEntry(_:to:)` の `to:` は XADMaster と同じく directory です。たとえば
`page.txt` を `/tmp/output` へ展開すると destination は `/tmp/output/page.txt` になります。
directory entry を展開しても、呼出側が渡した root directory の mode / modification time を
archive entry の値へ置き換えません。

archive に POSIX permissions が無い場合、新規 file は `0666 & ~umask`、新規 directory と
implicit parent directory は `0777 & ~umask` で作成します。modern API で
`ExtractionOptions(preserveMetadata: false)` を指定した場合も archive の permissions を使わず、
同じ umask 準拠の mode になります。

## 互換動作

`KaitoArchive` は失敗を `nil` / `false` に変換する、範囲外のエントリ番号を拒否する、
サイズ不明を `Int64.max` として返す、設定済みパスワードを reader へ渡す、という XADArchive 型の
利用で期待される基本動作を再現します。一方、KaitoKit の読み取り上限と不正な相対パスの拒否は
互換層からも無効化しません。

M4 が開ける書庫形式は非圧縮 tar コンテナ、ZIP / ZIP64、7z、RAR4 / RAR5、LHA / LZH です。
RAR4 は stored と unpack version 29 の LZ / PPMd-H、6 種の標準 filter、solid、SFX、旧・新
multi-volume、通常暗号化と header 暗号化に対応します。RAR5 は stored と compression version 0 の
LZ / filter、solid、multi-volume、通常暗号化と header 暗号化に対応します。RAR4 の圧縮
unpack version 15 / 20 / 26、custom RAR VM program、RAR5 compression version 1、RAR5 file-copy
redirection と SFX、および RAR4 の SFX prefix と multi-volume の組合せは明示的に
`KaitoError.unsupportedMethod` を返します。Data / 任意
`ByteSource` では continuation volume を検索できません。ZIP と LHA header level 0 / 1 の
有効な DOS 日時にはタイムゾーン情報がないため、現在のローカルタイムゾーンとして解釈します。
LHA の `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-` は読み取り時に
`KaitoError.unsupportedMethod`、gzip、bzip2、xz はシグネチャ検出だけを行い、reader は
`KaitoError.unsupportedFormat` を返します。

通常の tar hard link member はデータ本体を持たないため、`contents(ofEntry:)` は空の
`Data` を返します。PAX linkdata member では、書庫が持つ本文を返します。
`extractEntry(_:to:)` は hard link の場合、同じ書庫内で先に記録された参照先を非公開 staging へ
展開してから、指定 directory 以下の entry path へ移します。呼出しごとに staging を破棄するため、
別々の `extractEntry` 呼出しで inode の同一性までは保持しません。
