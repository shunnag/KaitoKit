# KaitoKit (解凍Kit)

KaitoKit は macOS 向けの純 Swift 書庫読み取りライブラリです。書庫の検出・列挙・ストリーミング読み取り・安全な展開を一つの API で扱えます。tar、ZIP、7z、RAR などの書庫と、LZ4・LZMA（`.lzma` / `.tlz`）などの圧縮形式に対応します。書き込みには姉妹ライブラリ [GyoshukuKit](https://github.com/shunnag/GyoshukuKit) を組み合わせてください。

## 動作要件

- 実行: macOS 26 以上、Apple Silicon / Intel
- ビルド: Xcode 27 / Swift 6.4 以上
- 外部依存: なし。zlib、libbz2 など OS 同梱ライブラリだけを使用

## English

> **KaitoKit (解凍Kit)**
>
> A pure-Swift archive reader for macOS: detect, list, stream and extract archives through one API.
> Supports tar, ZIP, 7z, RAR and more, including LZ4 and LZMA (`.lzma` / `.tlz`). Pair it with GyoshukuKit for writing.
> Runs on macOS 26+ (Apple Silicon and Intel); building requires Xcode 27 / Swift 6.4+.
> Uses only OS-bundled libraries. MIT licensed; no XADMaster or The Unarchiver code is incorporated.
> The [full format matrix](Documentation/formats.md) and the linked guides include English summaries.

## SwiftPM

現行リリースは **0.13.0** です（[変更履歴](CHANGELOG.md)）。`Package.swift` に依存を追加します。
次の指定は 0.13.x の更新を受け取ります。

```swift
dependencies: [
    .package(
        url: "https://github.com/shunnag/KaitoKit.git",
        .upToNextMinor(from: "0.13.0")
    )
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "KaitoKit", package: "KaitoKit")
    ])
]
```

## 製品

| Product | 用途 |
|---|---|
| `KaitoKit` | 新規 Swift コード向け。`ArchiveReader`、throwing API、stream、資源上限 |
| `KaitoKitCompat` | XADMaster からの移行向け。`KaitoArchive` と `XADArchive` typealias |
| `KaitoKitDynamic` | `KaitoKit` と `KaitoKitCompat` を含む動的ライブラリ |
| `kaito` | 検出・一覧・展開・SHA-256・計測・名前の文字コード診断を行う CLI |

## クイックスタート

以下の例は同じ Swift ファイル内で順に使えます。

### 1. 検出して開く

```swift
import Foundation
import KaitoKit

let url = URL(fileURLWithPath: "/tmp/book.zip")
let format = try FormatDetector.detect(url: url) // 検出だけ必要な場合
print(format)
let archive = try ArchiveReader.open(url: url)   // open 自体も形式を検出
```

URL からの open は分割巻や拡張子 hint も扱います。メモリ上の書庫には `open(data:)` を使えます。

### 2. 一覧と本文を読む

```swift
for entry in archive.entries {
    print(entry.index, entry.name, entry.uncompressedSize as Any)
}
if let entry = archive.entries.first(where: { $0.kind == .file }) {
    let contents = try archive.read(entry)
    print("read \(contents.count) bytes")
}
```

サイズ不明の entry は `uncompressedSize == nil` です。大きい本文には `stream(_:)` を使ってください。

### 3. 通常ファイルを展開し、進捗とキャンセルを扱う

```swift
func extractDataFiles(
    _ reader: ArchiveReader, to destination: URL,
    progress: (Int, Int) -> Void
) throws {
    let files = reader.entries.filter {
        $0.kind == .file &&
        !$0.pathComponents.suffix(2).elementsEqual(["..namedfork", "rsrc"])
    }
    for (index, entry) in files.enumerated() {
        try Task.checkCancellation()
        _ = try reader.extract(entry, to: destination)
        progress(index + 1, files.count)
    }
}

try extractDataFiles(archive, to: URL(fileURLWithPath: "/tmp/unpacked")) { done, total in
    print("\(done) / \(total)")
}
```

この例の進捗・キャンセル確認は entry 単位です。byte 単位で制御する [stream の例](Documentation/embedding.md#進捗とキャンセル) もあります。
リンク・resource fork・ディレクトリの metadata を含む書庫全体の復元は、[展開順序の例](Documentation/embedding.md#書庫全体の展開順序) を参照してください。

### 4. パスワード付き書庫

```swift
let encrypted = try ArchiveReader.open(
    url: URL(fileURLWithPath: "/tmp/private.7z"),
    options: ReaderOptions(password: "secret")
)
print(encrypted.entries.count)
```

暗号化 header は open 時に password が必要です。必要時に取得する [PasswordProvider の例](Documentation/embedding.md#passwordprovider) もあります。
`passwordRequired` / `wrongPassword` の扱いと形式別の違いは [対応形式の詳細](Documentation/formats.md) を参照してください。

## 対応状況

表は読み取り・展開範囲の概要です。方式・version・分割巻・検証条件は [完全な対応表](Documentation/formats.md#対応状況) を参照してください。

| 形式群 | 読み取り・展開 | 暗号化 |
|---|---|---|
| tar / cpio（`.tar` / `.cpio` / `.cpgz` など） | ファイル一覧・展開、圧縮された tar / cpio | なし |
| ZIP / ZIP64（`.zip` / `.zipx`） | 単一・分割書庫、自己解凍書庫 | ZipCrypto、WinZip AES-128/192/256 |
| 7z（`.7z`） | 単一・分割書庫、自己解凍書庫 | 7zAES-256（data / header） |
| RAR4 / RAR5（`.rar`） | 単一・分割書庫、自己解凍書庫（組み合わせに制限あり） | AES-128 / AES-256（data / header） |
| LHA / LZH（`.lha` / `.lzh`） | 主要な圧縮方式、自己解凍書庫 | なし |
| StuffIt classic / StuffIt 5（`.sit` / `.sea`） | data / resource fork、classic の分割書庫 | classic 改変 DES（条件あり）、StuffIt 5 RC4 |
| StuffIt X（`.sitx`） | data / resource fork、JPEG の復元 | AES / Blowfish / DES / RC4、暗号化 catalog |
| gzip / bzip2 / xz / zstd / LZ4 / LZMA / lzip / brotli / `.Z` / pbzx（`.gz` / `.bz2` / `.xz` など） | 単一ファイルと圧縮 tar / cpio | なし |
| ISO 9660 / UDF・BIN/CUE（`.iso` / `.udf` / `.bin` / `.cue` など） | 通常・生 sector image、BIN/CUE の data track | なし |
| MacBinary / AppleSingle / BinHex（`.bin` / `.as` / `.hqx`） | data / resource fork、名前・日時 | なし（StuffIt の本文は形式側で処理） |
| Windows Imaging（`.wim` / `.swm`） | 複数 image のファイル一覧・展開（分割に制限あり） | なし |
| Compound File（`.msi` / `.doc` / `.xls` / `.ppt` / `.msg`） | 内部ファイルの一覧・展開 | なし |
| CHM（`.chm`）/ ARJ（`.arj` / `.exe`） | ヘルプファイル、ARJ の書庫・自己解凍書庫 | ARJ の暗号化ファイルは一覧のみ。他はなし |
| xar（`.pkg`）/ CAB（`.cab`）/ RPM（`.rpm`）/ ar（`.deb` / `.a`） | 配布 package 内のファイル一覧・展開 | なし |
| Apple Disk Image（`.dmg` / `.img`） | HFS+ / HFSX のファイル、内包 ISO / UDF | なし |

## 既知の制限

- ACE、RAR の旧方式や custom VM、一部の 7z / ZIP / LHA / StuffIt 方式は未対応です。[形式別の制限](Documentation/limitations.md#既知の制限)
- APFS / ADC chunk、WIM solid / ESD や他 `.swm` part の resource、後続 ISO session などは対象外です。[完全な制限一覧](Documentation/limitations.md)
- 名前のない `Data` では圧縮 tar / cpio の連鎖や brotli などを識別できません。名前の hint が必要な形式には URL を使ってください。[検出条件](Documentation/limitations.md)
- 破損書庫の救済は opt-in です。不完全 entry の checksum / 認証は保証されません。[救済と RAR5 の例外](Documentation/limitations.md#既知の制限)

## 組み込みの注意

- **Sandbox**: 入力・出力・分割巻の兄弟ファイルへのアクセス権を呼出側で管理します。[アクセスと staging](Documentation/embedding.md#sandbox-とファイルアクセス)
- **スレッド**: reader / stream の操作を直列化し、並列処理は `reopen()` で独立 reader を作ります。[並列処理と solid 群](Documentation/embedding.md#組み込みの注意) / [展開順序](Documentation/embedding.md#書庫全体の展開順序)
- **上限と検証**: `ReadLimits` を open 前に設定し、stream は最後まで読んで検証します。`stagingFreeSpaceReserve` と `maxSevenZipHeaderKDFWork` も調整できます。[資源上限](Documentation/embedding.md#組み込みの注意)

> **Integration notes**
>
> Serialize each reader / stream; use `reopen()` for independent workers. Configure `ReadLimits`, including
> `stagingFreeSpaceReserve` and `maxSevenZipHeaderKDFWork`, before opening. Read streams to completion for verification.

## コマンドライン

```console
swift run kaito detect book.zip
swift run kaito list book.zip
swift run kaito extract book.zip -o /tmp/book
swift run kaito list private.7z -p secret
swift run kaito sha book.zip
```

`sha` / `extract` は entry ごとの失敗を報告して続行し、一件でも失敗すれば終了コード 1 です。
`--raw`、`--forks`、`bench`、出力形式と計測条件は [CLI ガイド](Documentation/cli.md) を参照してください。

## ドキュメント

| 読みたいこと | 文書 |
|---|---|
| 形式・方式・暗号化・分割巻の詳細 | [formats.md](Documentation/formats.md) / [limitations.md](Documentation/limitations.md) |
| 展開順序・名前・stream・資源上限・Sandbox | [embedding.md](Documentation/embedding.md) |
| CLI / 開発・framework・fuzz | [cli.md](Documentation/cli.md) / [development.md](Documentation/development.md) |
| 設計・堅牢性・参照仕様 | [design.md](Documentation/design.md) |
| XADMaster からの移行 | [migration-from-xadmaster.md](Documentation/migration-from-xadmaster.md) |
| 名前の自動文字コード判定 | [name-encoding-design.md](Documentation/name-encoding-design.md) |
| StuffIt の実装範囲と計画 | [stuffit-plan.md](Documentation/stuffit-plan.md) |
| 実測・互換性・リリース検証 | [verification/](Documentation/verification/README.md) |

## 開発

```console
swift build
swift test
```

[テスト構成・CI・framework・fuzz の開発手順](Documentation/development.md) を参照してください。
過去のリリースレビュー: [0.9.0](Documentation/verification/2026-09-22-release-review-0.9.0.md)、[0.8.1](Documentation/verification/2026-09-22-release-review-0.8.1.md)。

## ライセンス

[MIT](LICENSE)。XADMaster / The Unarchiver のコードは実装へ取り込んでいません。
同梱データ・参照資料の出自は [NOTICE](NOTICE) と [設計書](Documentation/design.md) に記録しています。
