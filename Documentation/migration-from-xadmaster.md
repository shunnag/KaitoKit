# XADMaster から KaitoKit への移行

KaitoKit は二つの API 層を提供します。既存コードを少ない変更で動かす場合は
`KaitoKitCompat.KaitoArchive`（`XADArchive` typealias を含む）、新規コードでは throwing API、
ストリーミング、`ReadLimits` を直接扱える `KaitoKit.ArchiveReader` を使います。

## 1. SwiftPM 依存を追加する

`Package.swift` にリポジトリと必要な product を追加します。移行中に両 API を使う target は
`KaitoKit` と `KaitoKitCompat` の両方へ依存させます。

```swift
dependencies: [
    .package(
        url: "https://github.com/shunnag/KaitoKit.git",
        branch: "main"
    ),
],
targets: [
    .target(
        name: "ArchiveClient",
        dependencies: [
            .product(name: "KaitoKit", package: "KaitoKit"),
            .product(name: "KaitoKitCompat", package: "KaitoKit"),
        ]
    ),
]
```

アプリ target からは Xcode の Package Dependencies で同じ URL を追加し、使用する product を
リンクします。KaitoKit は macOS 26 以降と Swift 6 を対象にしています。

## 2. import と生成を置き換える

既存の型名を残す最小変更は import の置換です。

```swift
// import XADMaster
import KaitoKitCompat

guard let archive = XADArchive(file: path) else { return }
print(archive.numberOfEntries())
```

URL、`Data`、詳細なエラーを扱う新規コードでは modern API を使います。

```swift
import Foundation
import KaitoKit

let url = URL(fileURLWithPath: path)
let reader = try ArchiveReader.open(url: url)

for entry in reader.entries {
    print(entry.index, entry.uncompressedSize as Any, entry.name)
}
```

## 3. `XADArchive` の対応表

| XADArchive | KaitoArchive / XADArchive | ArchiveReader | 差異 |
|---|---|---|---|
| `init?(file:)` | `init?(file:)` | `open(url:options:)` | compat は失敗を `nil`、modern は `KaitoError` を throw |
| `init?(data:)` | `init?(data:)` | `open(data:options:)` | Data 由来の multi-volume 継続は不可 |
| URL から生成 | `init?(fileURL:)` | `open(url:options:)` | compat の追加 Swift overload |
| `filename()` | `filename()` | 呼出側が URL を保持 | Data-backed compat は `nil` |
| `formatName()` | `formatName()` | `format.rawValue` | compat は安定した container 名を返す |
| `numberOfEntries()` | 同名 (`Int32`) | `entries.count` | compat は `Int32`、modern は `Int` |
| `name(ofEntry:)` | 同名 | `entries[i].name` | compat の directory 名だけ末尾 separator を除去 |
| `contents(ofEntry:)` | 同名 | `read(_:)` | compat は `nil`、modern は throw |
| entry data の別名 | `dataForEntry(_:)` / `data(forEntry:)` | `read(_:)` | 三つの compat spelling は同じ処理 |
| `extractEntry(_:to:)` | 同名、戻り値 `Bool` | `extract(_:to:options:)` | `to:` は entry の完成 path ではなく展開先 directory |
| `entryHasSize(_:)` | 同名 | `uncompressedSize != nil` | サイズ不明を区別する |
| `uncompressedSize(ofEntry:)` | 同名 (`Int64`) | `uncompressedSize: UInt64?` | compat は不明時 `Int64.max`、範囲外は 0 |
| `entryIsDirectory(_:)` | 同名 | `kind == .directory` | 範囲外は `false` |
| `entryIsLink(_:)` | 同名 | `.symlink` / `.hardlink` | compat は二種類を一つにまとめる |
| `entryIsResourceFork(_:)` | 同名 | 直接対応なし | resource fork を別 entry にしないため常に `false` |
| `attributesOfEntry(_:)` | 同名 | `modificationDate`、`posixPermissions`、`kind` | compat は `.modificationDate`、`.posixPermissions`、`.type` を返す |
| `entryIsEncrypted(_:)` | 同名 | `isEncrypted` | 範囲外は `false` |
| `isEncrypted()` | 同名 | `entries.contains { $0.isEncrypted }` | 公開 entry を集計 |
| `setPassword(_:)` | 同名 | settable `password` / `PasswordProvider` | header 暗号化は modern の provider を初期 open に渡せる |
| `nameEncoding` | `nameEncoding: String.Encoding?` | 同名 | compat/modern の `nil` は推測不要を表す |
| `setNameEncoding(_:)` | 同名 | `ReaderOptions(encodingPolicy: .fixed(...))` | compat は保持した URL/Data から reader を再構築 |
| `solidGroup(ofEntry:)` | 同名 (`Int32`) | `solidGroup: Int` | 独立 entry は `-1` |
| `entryIsSolid(_:)` | なし | 直接対応なし | continuation flag と dependency group は同じ意味ではない |
| `delegate` | weak `KaitoArchiveDelegate?` | password provider と呼出側の stream loop | compat delegate は初期化後に設定 |
| error code / `lastError` | `lastError: KaitoError?` | thrown `KaitoError` | compat の成功 read/extract/password/encoding 操作でクリア |
| `defaultZipLazyLocalHeaders` | 同名 + setter | `ReaderOptions.lazyLocalHeaders` | class 値は後から開く compat instance にだけ適用 |

範囲外 index を渡した compat query は XADArchive 型の `nil` / `false` / 0 / `-1` を返し、
`lastError` に `.notFound` を残します。opening error そのものが必要なら `ArchiveReader.open` を使います。

## 4. `XADArchiveDelegate` の対応表

`KaitoArchiveDelegate` は `AnyObject` protocol で、`delegate` は weak です。XADMaster の optional
Objective-C method に相当する三つの requirement には default implementation があるため、必要な
method だけ実装できます。

| XADArchiveDelegate | KaitoArchiveDelegate | 動作上の差異 |
|---|---|---|
| `archiveNeedsPassword(_:)` | 同名 | delegate 内で `archive.setPassword(...)` を呼ぶ。entry 読み取り前に呼ばれるが、failable initializer 中には delegate が未設定 |
| `archive(_:nameEncodingForData:guess:confidence:)` | 同じ label、戻り値 `String.Encoding?` | encoding を返すと `.fixed` で再構築、`nil` は自動判定を採用。delegate 設定直後に一度 consult |
| `archive(_:extractionProgressForEntry:bytes:of:)` | 同じ label、`Int32` / `Int64` | data read は chunk ごと、file-system extraction は完了時に一度通知 |

```swift
final class ArchiveDelegate: KaitoArchiveDelegate {
    let password: String?

    init(password: String?) {
        self.password = password
    }

    func archiveNeedsPassword(_ archive: KaitoArchive) {
        archive.setPassword(password)
    }

    func archive(
        _ archive: KaitoArchive,
        nameEncodingForData data: Data,
        guess: String.Encoding,
        confidence: Double
    ) -> String.Encoding? {
        confidence < 0.5 ? .shiftJIS : nil
    }

    func archive(
        _ archive: KaitoArchive,
        extractionProgressForEntry entry: Int32,
        bytes: Int64,
        of total: Int64
    ) {
        print(entry, bytes, total)
    }
}

let delegate = ArchiveDelegate(password: password) // weak property のため強参照を保持
archive.delegate = delegate
```

header まで暗号化された 7z/RAR は compat initializer が delegate 設定前に parsing を行うため、
初期 password callback を使えません。この場合は `ReaderOptions(password:passwordProvider:)` を
`ArchiveReader.open` へ渡します。

## 5. `XADSimpleUnarchiver` から `Extractor` へ

| XADSimpleUnarchiver | KaitoKit | 備考 |
|---|---|---|
| archive 全体の列挙 | `ArchiveReader.entries` | archive order を維持 |
| destination 設定 | `ArchiveReader.extract(_:to:)` の directory | `Extractor` が各 entry path を追加 |
| overwrite policy | `ExtractionOptions.overwriteExisting` | 既定 `true` |
| resource fork / finder 情報 | 直接対応なし | `entryIsResourceFork` は `false` |
| permissions / timestamp | `ExtractionOptions.preserveMetadata` | 既定 `true` |
| symbolic link | `ExtractionOptions.createSymbolicLinks` | 既定 `true`、relative target を検証 |
| progress | `EntryStream` の caller loop / compat delegate | modern API は produced byte 数を caller が集計 |
| cancellation | stream loop を caller が終了 | 組込み cancellation token は未提供 |

`Extractor` は KaitoKit の展開 engine で、公開入口は `ArchiveReader.extract` です。directory entry は
子 entry の後に深い順で処理すると、最終 timestamp と permissions を保てます。

```swift
let destination = URL(fileURLWithPath: outputPath, isDirectory: true)
for entry in reader.entries where entry.kind != .directory {
    _ = try reader.extract(entry, to: destination)
}
for entry in reader.entries.filter({ $0.kind == .directory }).sorted(by: {
    $0.pathComponents.count > $1.pathComponents.count
}) {
    _ = try reader.extract(entry, to: destination)
}
```

## 6. `CSHandle` streaming の移行

| XADMaster | KaitoKit | 用途 |
|---|---|---|
| archive 入力用 `CSHandle` | `ByteSource` | random-access の `length` と `read(into:at:)` |
| parser cursor | `ByteReader` | 256 KiB cursor、LE/BE read、`seek(to:)` |
| entry contents handle | `EntryStream` | forward-only decompressed bytes |
| `remainingFileContents` | `EntryStream.readAll()` / `ArchiveReader.read(_:)` | `ReadLimits.maxInMemorySize` を適用 |
| incremental `readAtMost` | `EntryStream.read(into:)` | caller-owned buffer に逐次 read |
| independent handle | `ArchiveReader.reopen()` | immutable `ByteSource` を共有、decoder state は独立 |

```swift
let stream = try reader.stream(entry)
var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
while true {
    let count = try buffer.withUnsafeMutableBytes { bytes in
        try stream.read(into: bytes)
    }
    if count == 0 { break }
    consume(buffer[0..<count])
}
```

CRC や decoder footer の確認は最後の `read` で完了します。途中まで得た chunk だけを完成結果として
公開せず、0 または error まで drain してください。`read(_:)`、`readAll()`、`extract`、compat API、
CLI はこの contract を実施します。

## 7. `XADString` と名前 encoding の移行

| XADMaster | KaitoKit | 備考 |
|---|---|---|
| `XADString` の raw bytes | `ArchiveEntry.rawName.bytes` / `RawName` | 表示名と別に保持 |
| 宣言 encoding | `RawName.declaredEncoding` | UTF-8 flag、Unicode extra 等を反映 |
| 表示文字列 | `ArchiveEntry.name` | archive-wide policy で解決済み |
| 自動 encoding 判定 | `EncodingPolicy.automatic(likelyLanguage:)` | 厳密な UTF-8 は guesser を通さない |
| 固定 encoding | `EncodingPolicy.fixed(_:)` | undecorated name 全体へ適用 |
| UTF-8 限定 | `EncodingPolicy.utf8Only` | decode 不能 byte は replacement character |
| archive-wide selection | `ArchiveReader.nameEncoding` | 全名が宣言済み/UTF-8 なら `nil` |
| encoding delegate | `KaitoArchiveDelegate` | 選択時に reader を再構築 |

```swift
let options = ReaderOptions(encodingPolicy: .fixed(.shiftJIS))
let reader = try ArchiveReader.open(url: url, options: options)
for entry in reader.entries {
    inspect(raw: entry.rawName.bytes, display: entry.name)
}
```

## 8. error code の対応表

| XADMaster error | KaitoError | 移行時の扱い |
|---|---|---|
| `XADNoError` | error なし | throwing call が return |
| `XADUnknownError` | 該当する typed case、なければ compat `.malformed(description)` | modern API の catch で詳細を表示 |
| `XADInputError` / `XADOpenFileError` | `.io(errno)` / `.notFound(description)` | POSIX code を保持 |
| `XADOutputError` / `XADMakeDirectoryError` / `XADFileExistsError` | `.io(errno)` | overwrite は `ExtractionOptions` で指定 |
| `XADBadParametersError` | `.notFound(description)` / `.malformed(description)` | index と構造を区別 |
| `XADFiletypeError` | `.unsupportedFormat` | signature / extension hint で reader を選べない |
| `XADNotSupportedError` | `.unsupportedFormat` / `.unsupportedMethod(name)` | container と method を区別 |
| `XADDataFormatError` / `XADDecrunchError` | `.malformed(description)` / `.truncated` | envelope 不整合と早い EOF を区別 |
| `XADPasswordError` | `.passwordRequired` | `password` / provider / delegate を設定 |
| `XADWrongPasswordError` | `.wrongPassword` | password を入れ替えて reader を再利用可能 |
| `XADChecksumError` / `XADVerifyError` | `.checksumMismatch(entry:)` | entry index を保持 |
| `XADOutOfMemoryError` | `.limitExceeded(description)` | allocation 前の `ReadLimits` 判定として報告 |
| `XADSkipError` / `XADBreakError` | 直接対応なし | caller が stream loop を終了、組込み cancellation は未提供 |

compat API は `nil` / `false` を返した後に `lastError` を確認できます。open 自体の詳細は failable
initializer から取得できないため、診断が必要な経路を `ArchiveReader.open` に移してください。

## 9. cooViewer の `ArchiveSource`

設計書 §2 の利用面は、URL または `Data` から同じ形で reader を作れる小さな value にまとめられます。
ローカルで固定された単一 volume は mmap-backed `Data`、RAR multi-volume は sibling file を解決できる
URL を維持します。

```swift
import Foundation
import KaitoKit

struct ArchiveSource: Sendable {
    enum Backing: Sendable {
        case file(URL)
        case data(Data)
    }

    let backing: Backing
    var options = ReaderOptions()

    func open() throws -> ArchiveReader {
        switch backing {
        case let .file(url):
            try ArchiveReader.open(url: url, options: options)
        case let .data(data):
            try ArchiveReader.open(data: data, options: options)
        }
    }
}
```

cooViewer adapter の各操作は次のように対応します。

| ArchiveSource 利用面 | KaitoKit |
|---|---|
| entry 数 | `reader.entries.count` |
| 表示名 | `entry.name` |
| directory | `entry.kind == .directory` |
| サイズ有無 | `entry.uncompressedSize != nil` |
| 64-bit サイズ | `entry.uncompressedSize` (`UInt64?`) |
| 暗号化 | `entry.isEncrypted` / archive-wide `contains` |
| solid 並列単位 | `entry.solidGroup` |
| whole entry data | `reader.read(entry)` |
| nested archive | outer entry の `Data` を `ArchiveReader.open(data:)` へ渡す |
| extraction pool | 最初の reader から `reopen()` して actor/worker ごとに一つ保持 |

```swift
let primary = try source.open()
let readers = try (0..<workerCount).map { index in
    index == 0 ? primary : try primary.reopen()
}
```

一つの `ArchiveReader` と一つの `EntryStream` は non-thread-safe です。actor で reader ごとの操作を
直列化し、並列化は `reopen()` した instance 間で行います。同じ `solidGroup >= 0` の entry は同じ
worker で archive 順に処理し、`-1` は per-entry に分配できます。

ローカルで内容が変化しない単一 file だけを `Data(contentsOf:options:.mappedIfSafe)` で map します。
multi-volume RAR は URL open を使い、nested ZIP/PDF/EPUB のように既にメモリ上にある内容は Data open
を使います。大きな entry は `read(_:)` の前に宣言サイズと `ReadLimits` を確認し、必要なら
`EntryStream` へ切り替えます。

## 10. 重要な動作差

- **thread contract**: XADMaster と同様、archive instance は同時使用しません。KaitoKit は
  `reopen()` を明示し、共有 input と独立 decoder state を分けます。
- **solid group**: `solidGroup == -1` は独立、0 以上は依存単位です。group の先頭にも同じ ID が付き、
  XADMaster の per-header `entryIsSolid` の置換ではありません。
- **limits**: `ReadLimits` は単一 entry、全 entry の合計、in-memory read、metadata、entry 数、path
  component、dictionary、volume 数、RAR5 header KDF work、圧縮 tar の memory staging を制御します。
  compat 層からも無効にはなりません。
- **unknown size**: modern API は `nil`、compat は `entryHasSize == false` と `Int64.max` です。
- **directory spelling**: compat の `name(ofEntry:)` は末尾 separator を除去し、modern name は保持します。
- **extraction destination**: compat の `to:` も directory です。entry name を caller 側で再度追加しません。
- **symbolic links**: link の親から解決して展開 root 内に留まる `..` target を許容します。
  absolute target、途中で root 外へ出る target、既存 symlink を経由する target は拒否します。
  最後の `..` までの全成分には既存の実 directory が必要です。その後の未作成成分は許容します。
  hard-link target は従来どおり `..` を許容しません。
- **directory modes**: 書庫に記録された sticky / setgid bit を復元します。macOS 上の rar 6/7 の
  展開結果と異なることがありますが、XADMaster / bsdtar -xp と一致する属性保持の方針です。
- **RAR3 passwords**: 長い password の旧 SHA-1 更新規則と、BMP 外の文字に対する UTF-16 優先 / Unix
  scalar 下位 16 bit fallback に対応します。host OS metadata だけでは方式を決めません。
  候補は最大二つで、header CRC または entry の展開後 CRC で検証します。file data の選択には
  小さな scratch buffer と独立 decoder を使い、solid では最初の非空の暗号化 member で一度だけ方式を
  決めます。header CRC の選択も再利用します。writer と同じ最大 127 wide characters に制限してから
  KDF へ渡し、UTF-16 候補は 127 code units、Unix 候補は 127 Unicode scalars で区切ります。
  RAR3 は独立した認証 tag を持たないため、破損暗号文と誤 password を完全には区別できません。
- **delegate timing**: delegate は compat initialization 後に設定します。name encoding は設定直後の rebuild
  へ反映できますが、header password は modern initializer option が必要です。
- **resource forks**: separate entry として公開しないため `entryIsResourceFork` は常に `false` です。
- **multi-volume**: sibling volume を扱えるのは URL-backed RAR4/RAR5 です。Data/任意 `ByteSource` は
  continuation を解決しません。

ISO 9660 は `ISO 9660` として列挙できます。木の優先順位は Rock Ridge（NM あり）>
Joliet > PVD です。XADMaster の Joliet 優先と異なり、両方ある画像の symlink を保持します。
NM は書庫全体の UTF-8 / CP932 / EUC-JP 判定、Joliet は UCS-2BE、PVD 名は大文字のままです。

## 11. 対応外形式・方式

現時点で container reader を提供しない主な形式は CAB、ARJ、ACE、StuffIt/SIT、zstd
stream です。対応済み container 内でも次は未対応です。

- ISO の UDF、raw 2352/2336-byte sector、後続 session、interleaved / sparse / zisofs 展開。
- ZIP multi-disk/spanned と zstd/xz/JPEG/PPMd method。
- 7z IA-64/SPARC filter。
- RAR4 の unpack version 15/20/26、custom VM、一部の solid 構成、SFX と multi-volume の組合せ。
- RAR5 compression version 1、file-copy redirection、RAR5 SFX、サイズ不明の暗号化 stored entry。
- LHA `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-`。

gzip、bzip2、xz、UNIX compress (`.Z`) は単一 entry として扱います。`.tar.gz` / `.tgz`、
`.tar.bz2` / `.tbz2`、`.tar.xz` / `.txz` は展開した stream を `TarReader` へ渡し、tar entry を直接
列挙します。method と encryption/multi-volume の全表は README の「対応状況」を参照してください。
