# XADMaster から KaitoKit への移行

この文書は移行ガイドの骨格です。cooViewer が利用する `XADArchive` の狭い面を
`KaitoKitCompat.KaitoArchive` で再現し、M3 までに ZIP、7z、段階実装中の RAR4 / RAR5 を
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
| `init?(file:)` | 同名 | `open(url:)` | tar / ZIP / 7z / RAR4 / RAR5 で実装 |
| `init?(data:)` | 同名 | `open(data:)` | tar / ZIP / 7z / RAR4 / RAR5 で実装 |
| `defaultZipLazyLocalHeaders` / `setDefaultZipLazyLocalHeaders(_:)` | 同名 | `ReaderOptions.lazyLocalHeaders` | M1 で実装 |
| `numberOfEntries()` | 同名 | `entries.count` | 実装 |
| `name(ofEntry:)` | 同名 | `entries[i].name` | 実装 |
| `contents(ofEntry:)` | 同名 | `read(_:)` / `stream(_:)` | 実装 |
| `uncompressedSize(ofEntry:)` | 同名 (`Int64`) | `uncompressedSize` (`UInt64?`) | 実装 |
| `entryHasSize(_:)` | 同名 | `uncompressedSize != nil` | 実装 |
| `entryIsDirectory(_:)` | 同名 | `kind == .directory` | 実装 |
| `entryIsEncrypted(_:)` | 同名 | `isEncrypted` | 実装 (暗号対応は ZIP / 7z / RAR) |
| `isEncrypted()` | 同名 | `entries.contains { $0.isEncrypted }` | 実装 |
| `setPassword(_:)` | 同名 | settable `password` | ZIP / 7z / RAR5 で実装。RAR4 は実 oracle 未検証 |
| `solidGroup(ofEntry:)` | 同名 (`Int32`) | `solidGroup` | 7z / RAR4 / RAR5 で実装 (独立 entry は `-1`) |
| `entryIsSolid(_:)` | 未提供 | 直接対応なし | continuation flag であり `solidGroup` とは意味が異なる |
| `extractEntry(_:to:)` | 同名 | `extract(_:to:)` | 安全な展開として実装 |
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

同じ group の後方 entry をランダムに読む場合、一般には group 先頭から対象までを再復号して
途中の出力を捨てる必要があり、再開コストは対象より前の非圧縮データ量に比例します。7z は
folder stream と一部の dictionary-reset index を利用します。RAR は将来この再開動作を実装する
予定ですが、圧縮 solid stream は現時点では展開せず `unsupportedMethod` を返します。
`reopen()` で reader を増やしても依存と辞書メモリは消えないため、利用側は group ごとに一つの
job として直列化してください。RAR の `solidGroup` は依存関係を事前に組むための metadata であり、
展開対応の保証ではありません。

## サイズ不明の RAR5 entry

modern API は RAR5 が非圧縮サイズを宣言しない entry を `uncompressedSize == nil` として
公開し、`EntryStream` は復号器の終端まで逐次読み取ります。`remaining` は終端確認まで
`UInt64.max`、確認後は 0 です。`read(_:)` は宣言サイズによる事前確保をせず、
`maxEntrySize` と `maxInMemorySize` の範囲で段階的に読み込みます。既定の codec 辞書上限は
`ReadLimits.maxDictionarySize == 1 GiB` です。

互換層では従来どおり `entryHasSize(_:) == false`、`uncompressedSize(ofEntry:) == 0` となるため、
空 entry と区別するには必ず `entryHasSize(_:)` を併用してください。サイズ不明の暗号化
stored RAR5 entry は現時点では明示的に非対応です。

## RAR5 multi-volume と `reopen()`

URL-backed RAR5 は `.part1.rar` と同じ directory の continuation を検証し、分割 entry を
一つの stream として公開します。volume 数は `ReadLimits.maxVolumeCount` (既定 128) で制限され、
非最終 part に packed CRC32 があれば検証し、BLAKE2sp があれば `verifyRAR5Blake2sp` が true
(既定) のとき読み取り前に検証します。open 完了後の `reopen()` は
同じ検証済み file handle 一式を共有するため、volume path を再検索せず、各 reader の password /
decoder state だけを独立させます。Data / 任意 `ByteSource` には sibling 検索の provenance がないため、
multi-volume continuation は利用できません。

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

## 互換動作

`KaitoArchive` は失敗を `nil` / `false` に変換する、範囲外のエントリ番号を拒否する、
サイズ不明を 0 として返す、設定済みパスワードを reader へ渡す、という XADArchive 型の
利用で期待される基本動作を再現します。一方、KaitoKit の安全上限とパストラバーサル拒否は
互換層からも無効化しません。

M3 が開ける書庫形式は非圧縮 tar コンテナ、ZIP / ZIP64、7z、RAR4 / RAR5 です。
RAR の reader は段階実装です。RAR5 は URL から同じディレクトリの非暗号化 volume を継続できますが、
Data / 任意 `ByteSource` では分割 entry、RAR4 では全 volume 継続が非対応です。非対応の圧縮方式、
solid continuation、暗号化 header などは `KaitoError.unsupportedMethod` を返します。ZIP の DOS 日時にはタイムゾーン
情報がないため、現在のローカルタイムゾーンとして解釈します。LHA、gzip、bzip2、xz は
シグネチャ検出だけを行い、reader は `KaitoError.unsupportedFormat` を返します。

通常の tar hard link member はデータ本体を持たないため、`contents(ofEntry:)` は空の
`Data` を返します。PAX linkdata member では、書庫が持つ本文を返します。
`extractEntry(_:to:)` は同じ書庫内で先に記録された参照先を非公開 staging へ展開してから
目的パスへ移します。呼出しごとに staging を破棄するため、別々の `extractEntry` 呼出しで
inode の同一性までは保持しません。
