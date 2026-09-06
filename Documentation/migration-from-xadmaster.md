# XADMaster から KaitoKit への移行

この文書は移行ガイドの骨格です。cooViewer が利用する `XADArchive` の狭い面を
`KaitoKitCompat.KaitoArchive` で再現し、M1 では ZIP と遅延ローカルヘッダ設定を追加しました。
より広い delegate、属性、進捗 API は後続版で設計し、ここへ具体例を追加します。

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
| `init?(file:)` | 同名 | `open(url:)` | tar / ZIP で実装 |
| `init?(data:)` | 同名 | `open(data:)` | tar / ZIP で実装 |
| `defaultZipLazyLocalHeaders` / `setDefaultZipLazyLocalHeaders(_:)` | 同名 | `ReaderOptions.lazyLocalHeaders` | M1 で実装 |
| `numberOfEntries()` | 同名 | `entries.count` | 実装 |
| `name(ofEntry:)` | 同名 | `entries[i].name` | 実装 |
| `contents(ofEntry:)` | 同名 | `read(_:)` / `stream(_:)` | 実装 |
| `uncompressedSize(ofEntry:)` | 同名 (`Int64`) | `uncompressedSize` (`UInt64?`) | 実装 |
| `entryHasSize(_:)` | 同名 | `uncompressedSize != nil` | 実装 |
| `entryIsDirectory(_:)` | 同名 | `kind == .directory` | 実装 |
| `entryIsEncrypted(_:)` | 同名 | `isEncrypted` | 実装 (ZIP / tar) |
| `isEncrypted()` | 同名 | `entries.contains { $0.isEncrypted }` | 実装 |
| `setPassword(_:)` | 同名 | settable `password` | ZIP の ZipCrypto / WinZip AES で実装 |
| `solidGroup(ofEntry:)` | 同名 (`Int32`) | `solidGroup` | 実装 (tar / ZIP は `-1`) |
| `extractEntry(_:to:)` | 同名 | `extract(_:to:)` | 安全な展開として実装 |
| `attributesOfEntry(_:)` | 未提供 | `ArchiveEntry` の日時・権限・属性 | 後続版 |
| `entryIsLink(_:)` | 未提供 | `kind == .symlink/.hardlink` | modern API のみ |
| `entryIsResourceFork(_:)` | 未提供 | 将来の属性 | 後続版 |
| `nameEncoding` / encoding delegate | 未提供 | `nameEncoding` / `ReaderOptions.encodingPolicy` | 書庫単位判定を modern API で実装 |
| password delegate | 未提供 | `PasswordProvider` | modern API のみ |
| progress delegate / cancel | 未提供 | 未定 | 後続版 |
| `XADSimpleUnarchiver` | 未提供 | `ArchiveReader` + `Extractor` | 後続版 |
| `XADArchiveParser` / `CSHandle` | 未提供 | format reader / `ByteSource` | 直接互換なし |

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

M1 が開ける書庫形式は非圧縮 tar コンテナと ZIP / ZIP64 です。ZIP の DOS 日時には
タイムゾーン情報がないため、現在のローカルタイムゾーンとして解釈します。RAR、7z、LHA、
gzip、bzip2、xz のシグネチャ検出はできますが、reader は後続マイルストーンまで
`KaitoError.unsupportedFormat` を返します。

通常の tar hard link member はデータ本体を持たないため、`contents(ofEntry:)` は空の
`Data` を返します。PAX linkdata member では、書庫が持つ本文を返します。
`extractEntry(_:to:)` は同じ書庫内で先に記録された参照先を非公開 staging へ展開してから
目的パスへ移します。呼出しごとに staging を破棄するため、別々の `extractEntry` 呼出しで
inode の同一性までは保持しません。
