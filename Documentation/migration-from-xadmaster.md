# XADMaster から KaitoKit への移行

KaitoKit は二つの API 層を提供します。既存コードを少ない変更で動かす場合は
`KaitoKitCompat.KaitoArchive`（`XADArchive` typealias を含む）、新規コードでは throwing API、
ストリーミング、`ReadLimits` を直接扱える `KaitoKit.ArchiveReader` を使います。

> **Migrating from XADMaster to KaitoKit**
>
> KaitoKit offers two API layers. To move existing code with minimal change, use
> `KaitoKitCompat.KaitoArchive` (which includes an `XADArchive` typealias). For new code, use
> `KaitoKit.ArchiveReader`, which gives you the throwing API, streaming and `ReadLimits` directly.

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

> **1. Add the SwiftPM dependency**
>
> Add the repository and the products you need to `Package.swift`, as shown above. A target that
> uses both APIs during migration should depend on both `KaitoKit` and `KaitoKitCompat`.
>
> From an app target, add the same URL through Xcode's Package Dependencies and link the products
> you use. KaitoKit targets macOS 26 or later and Swift 6.

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

> **2. Replace the import and the construction**
>
> The smallest change keeps the existing type names and replaces only the import, as in the first
> example above. For new code that needs URLs, `Data` and detailed errors, use the modern API shown
> in the second example.

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
| `entryIsResourceFork(_:)` | 同名 | `formatSpecific["fork"] == "resource"` | StuffIt / UDF / ZIP・tar の AppleDouble 統合が公開する `name/..namedfork/rsrc` entry で `true` |
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

> **3. Mapping for `XADArchive`**
>
> The columns of the table above are: XADArchive / KaitoArchive or XADArchive / ArchiveReader /
> Differences. `同名` means the name is unchanged, and `直接対応なし` means there is no direct
> equivalent. The Differences column reads:
>
> - `init?(file:)`: compat returns `nil` on failure, the modern API throws `KaitoError`.
> - `init?(data:)`: multi-volume continuation from `Data` is not possible.
> - Construction from a URL: an additional Swift overload on the compat layer.
> - `filename()`: the caller keeps the URL; a `Data`-backed compat instance returns `nil`.
> - `formatName()`: compat returns a stable container name.
> - `numberOfEntries()`: compat returns `Int32`, the modern API `Int`.
> - `name(ofEntry:)`: only the compat directory name has its trailing separator removed.
> - `contents(ofEntry:)`: compat returns `nil`, the modern API throws.
> - The alternate entry-data spellings: all three compat spellings do the same thing.
> - `extractEntry(_:to:)`: it returns `Bool`, and `to:` is the destination directory, not the
>   completed path of the entry.
> - `entryHasSize(_:)`: distinguishes an unknown size.
> - `uncompressedSize(ofEntry:)`: compat returns `Int64.max` when unknown and 0 when out of range.
> - `entryIsDirectory(_:)`: `false` when out of range.
> - `entryIsLink(_:)`: compat merges the two link kinds into one.
> - `entryIsResourceFork(_:)`: `true` for the `name/..namedfork/rsrc` entries published by StuffIt, UDF and the
>   AppleDouble merge of ZIP / tar (`formatSpecific["fork"] == "resource"`).
> - `attributesOfEntry(_:)`: compat returns `.modificationDate`, `.posixPermissions` and `.type`.
> - `entryIsEncrypted(_:)`: `false` when out of range.
> - `isEncrypted()`: aggregates over the published entries.
> - `setPassword(_:)`: header encryption can take the modern provider at the initial open.
> - `nameEncoding`: `nil` in both layers means no guess was needed.
> - `setNameEncoding(_:)`: compat rebuilds the reader from the retained URL or `Data`.
> - `solidGroup(ofEntry:)`: an independent entry is `-1`.
> - `entryIsSolid(_:)`: the continuation flag and the dependency group do not mean the same thing.
> - `delegate`: the compat delegate is set after initialization.
> - Error codes and `lastError`: cleared by a successful compat read, extract, password or encoding
>   operation.
> - `defaultZipLazyLocalHeaders`: the class value applies only to compat instances opened later.
>
> A compat query given an out-of-range index returns the XADArchive-shaped `nil`, `false`, 0 or
> `-1` and leaves `.notFound` in `lastError`. When you need the opening error itself, use
> `ArchiveReader.open`.

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

> **4. Mapping for `XADArchiveDelegate`**
>
> `KaitoArchiveDelegate` is an `AnyObject` protocol and `delegate` is weak. The three requirements
> that correspond to XADMaster's optional Objective-C methods have default implementations, so you
> can implement only the ones you need. The behavioral differences in the table above are:
>
> - `archiveNeedsPassword(_:)`: call `archive.setPassword(...)` inside the delegate. It is invoked
>   before an entry is read, but no delegate is set during the failable initializer.
> - `archive(_:nameEncodingForData:guess:confidence:)`: same labels, returning `String.Encoding?`.
>   Returning an encoding rebuilds the reader with `.fixed`; `nil` accepts the automatic detection.
>   It is consulted once, immediately after the delegate is set.
> - `archive(_:extractionProgressForEntry:bytes:of:)`: same labels, with `Int32` and `Int64`. Data
>   reads notify per chunk, while file-system extraction notifies once on completion.
>
> Keep a strong reference to the delegate, as shown above, because the property is weak.
>
> For a 7z or RAR whose headers are also encrypted, the compat initializer parses before a delegate
> can be set, so the initial password callback cannot be used. Pass
> `ReaderOptions(password:passwordProvider:)` to `ArchiveReader.open` instead.

## 5. `XADSimpleUnarchiver` から `Extractor` へ

| XADSimpleUnarchiver | KaitoKit | 備考 |
|---|---|---|
| archive 全体の列挙 | `ArchiveReader.entries` | archive order を維持 |
| destination 設定 | `ArchiveReader.extract(_:to:)` の directory | `Extractor` が各 entry path を追加 |
| overwrite policy | `ExtractionOptions.overwriteExisting` | 既定 `true` |
| resource fork / finder 情報 | fork entry（`..namedfork/rsrc`）を data file の直後に展開 | Finder 情報・xattr は復元しない |
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

> **5. From `XADSimpleUnarchiver` to `Extractor`**
>
> The table above maps each `XADSimpleUnarchiver` capability to KaitoKit: enumerating the whole
> archive becomes `ArchiveReader.entries`, which keeps archive order; the destination becomes the
> directory passed to `ArchiveReader.extract(_:to:)`, with `Extractor` appending each entry path;
> the overwrite policy becomes `ExtractionOptions.overwriteExisting`, default `true`; resource forks
> are fork entries (`..namedfork/rsrc`) extracted right after their data file, while Finder
> information and xattrs are not restored; permissions
> and timestamps become `ExtractionOptions.preserveMetadata`, default `true`; symbolic links become
> `ExtractionOptions.createSymbolicLinks`, default `true`, with relative targets validated; progress
> is the caller's own loop over `EntryStream` or the compat delegate, since the modern API leaves
> counting produced bytes to the caller; and cancellation is the caller ending the stream loop,
> because no built-in cancellation token is provided.
>
> `Extractor` is the extraction engine of KaitoKit, and its public entry point is
> `ArchiveReader.extract`. Processing directory entries after their children, deepest first,
> preserves the final timestamps and permissions, as the example above shows.

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

> **6. Migrating `CSHandle` streaming**
>
> The table above maps each XADMaster streaming type to KaitoKit: a `CSHandle` used as archive input
> becomes `ByteSource`, providing random access through `length` and `read(into:at:)`; a parser
> cursor becomes `ByteReader`, a 256 KiB cursor with little- and big-endian reads and `seek(to:)`;
> an entry-contents handle becomes `EntryStream`, forward-only decompressed bytes;
> `remainingFileContents` becomes `EntryStream.readAll()` or `ArchiveReader.read(_:)`, both bounded
> by `ReadLimits.maxInMemorySize`; an incremental `readAtMost` becomes `EntryStream.read(into:)`,
> reading into a caller-owned buffer; and an independent handle becomes `ArchiveReader.reopen()`,
> which shares the immutable `ByteSource` while keeping decoder state separate.
>
> The CRC and the decoder footer are finalized by the last `read`. Do not publish a partially read
> chunk as a finished result; drain to 0 or to an error. `read(_:)`, `readAll()`, `extract`, the
> compat API and the CLI all enforce this contract.

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

> **7. Migrating `XADString` and name encoding**
>
> The table above maps the name-handling surface: the raw bytes of an `XADString` become
> `ArchiveEntry.rawName.bytes` and `RawName`, kept separately from the display name; the declared
> encoding becomes `RawName.declaredEncoding`, reflecting the UTF-8 flag, Unicode extra fields and
> so on; the display string becomes `ArchiveEntry.name`, already resolved by the archive-wide
> policy; automatic encoding detection becomes `EncodingPolicy.automatic(likelyLanguage:)`, which
> does not pass strict UTF-8 through the guesser; a fixed encoding becomes
> `EncodingPolicy.fixed(_:)`, applied to every undecorated name; UTF-8 only becomes
> `EncodingPolicy.utf8Only`, where undecodable bytes yield the replacement character; the
> archive-wide selection becomes `ArchiveReader.nameEncoding`, which is `nil` when every name is
> declared or UTF-8; and the encoding delegate becomes `KaitoArchiveDelegate`, rebuilding the reader
> on selection.

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

> **8. Mapping the error codes**
>
> The table above maps each XADMaster error to a `KaitoError`. `XADNoError` means the throwing call
> simply returns. `XADUnknownError` maps to whichever typed case applies, falling back to the compat
> `.malformed(description)`, so catch it in the modern API to show the detail. `XADInputError` and
> `XADOpenFileError` map to `.io(errno)` or `.notFound(description)`, preserving the POSIX code.
> `XADOutputError`, `XADMakeDirectoryError` and `XADFileExistsError` map to `.io(errno)`, with
> overwriting controlled by `ExtractionOptions`. `XADBadParametersError` maps to
> `.notFound(description)` or `.malformed(description)`, distinguishing an index from a structure.
> `XADFiletypeError` maps to `.unsupportedFormat`, meaning no reader could be chosen from the
> signature or extension hint. `XADNotSupportedError` maps to `.unsupportedFormat` or
> `.unsupportedMethod(name)`, distinguishing the container from the method. `XADDataFormatError` and
> `XADDecrunchError` map to `.malformed(description)` or `.truncated`, distinguishing an
> inconsistent envelope from an early EOF. `XADPasswordError` maps to `.passwordRequired`; set a
> password, a provider or a delegate. `XADWrongPasswordError` maps to `.wrongPassword`, and the
> reader can be reused after swapping the password. `XADChecksumError` and `XADVerifyError` map to
> `.checksumMismatch(entry:)`, preserving the entry index. `XADOutOfMemoryError` maps to
> `.limitExceeded(description)`, reported as a `ReadLimits` decision made before allocation.
> `XADSkipError` and `XADBreakError` have no direct equivalent: the caller ends the stream loop, and
> no built-in cancellation is provided.
>
> The compat API lets you inspect `lastError` after it returns `nil` or `false`. The detail of the
> open itself cannot be obtained from a failable initializer, so move any path that needs
> diagnostics to `ArchiveReader.open`.

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
multi-volume RAR、split ZIP（`.z01`…`.zip` / `.zx01`…`.zipx`）と `.001` バイト分割セットは URL open を使い、nested ZIP/PDF/EPUB のように既にメモリ上にある内容は Data open
を使います。大きな entry は `read(_:)` の前に宣言サイズと `ReadLimits` を確認し、必要なら
`EntryStream` へ切り替えます。

> **9. cooViewer's `ArchiveSource`**
>
> The usage surface of design document §2 collapses into a small value that can build a reader the
> same way from a URL or from `Data`, as the first example shows. Keep a mmap-backed `Data` for a
> local, fixed single volume, and a URL for multi-volume RAR, split ZIP (`.z01`…`.zip` / `.zx01`…`.zipx`), or `.001` byte splits so that siblings can be resolved.
>
> Each operation of the cooViewer adapter maps as follows: the entry count is
> `reader.entries.count`; the display name is `entry.name`; a directory is
> `entry.kind == .directory`; whether a size is known is `entry.uncompressedSize != nil`; the 64-bit
> size is `entry.uncompressedSize` as a `UInt64?`; encryption is `entry.isEncrypted` or an
> archive-wide `contains`; the unit of solid parallelism is `entry.solidGroup`; whole-entry data is
> `reader.read(entry)`; a nested archive is the outer entry's `Data` passed to
> `ArchiveReader.open(data:)`; and an extraction pool holds one reader per actor or worker, created
> by `reopen()` from the first reader, as the second example shows.
>
> A single `ArchiveReader` and a single `EntryStream` are not thread-safe. Serialize per-reader
> operations with an actor, and parallelize across instances produced by `reopen()`. Process entries
> sharing the same `solidGroup >= 0` on the same worker in archive order; entries with `-1` can be
> distributed per entry.
>
> Map with `Data(contentsOf:options:.mappedIfSafe)` only a local single file whose contents do not
> change. Use a URL open for multi-volume RAR, split ZIP, or `.001` byte splits, and a `Data` open for content already in memory, such
> as a nested ZIP, PDF or EPUB. For a large entry, check the declared size and `ReadLimits` before
> `read(_:)` and switch to `EntryStream` when needed.

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
- **resource forks / AppleDouble**: StuffIt と UDF の resource fork、および ZIP / tar の `__MACOSX/._name` /
  `._name` sidecar が持つ resource fork は `name/..namedfork/rsrc` の fork entry として data file の直後に
  並びます。XADMaster の `XADMacArchiveParser` が sidecar を fork に畳むのと同じ見え方で、Finder 情報や xattr
  だけの sidecar は既定（`ReaderOptions.appleDoublePolicy = .merge`）で消えます。`.hide` は fork も出さず、
  `.expose` は書庫どおりに全 entry を並べます。`entryIsResourceFork` は fork entry で `true` です。
- **multi-volume**: URL-backed RAR4/RAR5、split ZIP（`.z01`…`.zip` / `.zx01`…`.zipx`）、
  `.7z.001` / `.zip.001` 等のバイト分割に対応します。既定上限は 128 巻です。
  split ZIP は最終巻または任意の `.zNN` / `.zxNN` から開け、ZIP64 と `.z100` 以降も扱います。
  最終巻の宣言巻数で上限を先に検査し、欠番は巻名付きエラーにし、宣言数を超えた兄弟は無視します。
  空の中間巻も巻数に含みます。分割セットでは damaged-directory recovery を実行しません。
  `.001` バイト分割は欠番まで同じ親の兄弟を連結し、`.002` 等から先頭へは戻りません。
  明示的に開いた symlink は兄弟を探索しない単独扱いで、兄弟の symlink は拒否します。
  Data/任意 `ByteSource` は continuation を解決しません。`reopen()` は全巻の削除後も読み出せます。
  split ZIP の `rawRecord(of:)` は連結ストリームの絶対範囲を返し、`.001` バイト分割では `nil` です。
  同名メディア交換型 spanned と split PKSFX（先頭 `.exe`）は対象外です。

ISO 9660 は `ISO 9660` として列挙できます。木の優先順位は UDF > Rock Ridge（NM あり）>
Joliet > PVD です。XADMaster の Joliet 優先と異なり、両方ある画像の symlink を保持します。
NM は書庫全体の UTF-8 / CP932 / EUC-JP 判定、Joliet は UCS-2BE、PVD 名は大文字のままです。
UDF の名前は OSTA Compressed Unicode（8 / 16 bit）をそのまま Unicode に写し、`formatSpecific["nameSource"]`
は `udf`、`udfRevision` に LVD の domain revision（`1.02`〜`2.60`）が入ります。ISO 9660 構造を持たない
UDF image は `ArchiveFormat.udf`（`"udf"`、compat の `formatName()` は `UDF`）として検出します。
XADMaster は UDF を読めません。BIN/CUE などの生 sector image（2352 / 2448 / 2336 byte sector）は user data を
取り出して同じ `ISO 9660` / `UDF` として開き、`.cue` の path は data track の image を辿ります（EDC / ECC は
検証しません）。

> **10. Behavioral differences that matter**
>
> - **Thread contract**: as with XADMaster, an archive instance is never used concurrently. KaitoKit
>   makes `reopen()` explicit, separating the shared input from independent decoder state.
> - **Solid group**: `solidGroup == -1` means independent, and 0 or above is a dependency unit. The
>   first entry of a group carries the same ID, so this is not a replacement for XADMaster's
>   per-header `entryIsSolid`.
> - **Limits**: `ReadLimits` controls a single entry, the total across entries, in-memory reads,
>   metadata, the entry count, path components, the dictionary, the volume count, RAR5 header KDF
>   work, and the memory staging of a compressed tar. It cannot be disabled from the compat layer
>   either.
> - **Unknown size**: the modern API reports `nil`; compat reports `entryHasSize == false` and
>   `Int64.max`.
> - **Directory spelling**: the compat `name(ofEntry:)` removes a trailing separator; the modern
>   name keeps it.
> - **Extraction destination**: the compat `to:` is also a directory. Do not append the entry name
>   again on the caller side.
> - **Symbolic links**: a `..` target that resolves from the link's parent and stays inside the
>   extraction root is allowed. Absolute targets, targets that leave the root along the way, and
>   targets that pass through an existing symbolic link are rejected. Every component up to the last
>   `..` must be an existing real directory; components after it need not exist yet. A hard-link
>   target still does not allow `..`.
> - **Directory modes**: the sticky and setgid bits recorded in the archive are restored. This can
>   differ from what rar 6 and 7 produce on macOS, but it follows the attribute-preserving policy of
>   XADMaster and `bsdtar -xp`.
> - **RAR3 passwords**: the old SHA-1 update rule for long passwords is supported, as is preferring
>   UTF-16 for characters outside the BMP with a fallback to the low 16 bits of the Unix scalars.
>   The scheme is not decided from host OS metadata alone. There are at most two candidates, and
>   they are verified by the header CRC or by the entry's CRC after expansion. Selecting on file data
>   uses a small scratch buffer and an independent decoder, and in a solid group the scheme is
>   decided once, on the first non-empty encrypted member. The header CRC decision is reused as well.
>   The password is limited to the same maximum of 127 wide characters the writer uses before it
>   reaches the KDF, cut at 127 code units for the UTF-16 candidate and 127 Unicode scalars for the
>   Unix candidate. RAR3 has no independent authentication tag, so corrupt ciphertext and a wrong
>   password cannot be told apart completely.
> - **Delegate timing**: the delegate is set after compat initialization. A name encoding can feed
>   the rebuild that follows immediately, but a header password needs the modern initializer option.
> - **Resource forks / AppleDouble**: the resource forks of StuffIt and UDF, and those carried by the
>   `__MACOSX/._name` / `._name` sidecars of ZIP and tar, are fork entries (`name/..namedfork/rsrc`)
>   listed right after their data file, the same shape XADMaster's `XADMacArchiveParser` produces.
>   Sidecars holding only Finder information or xattrs disappear under the default
>   `ReaderOptions.appleDoublePolicy = .merge`; `.hide` drops the forks too and `.expose` lists the
>   archive as stored. `entryIsResourceFork` is `true` for fork entries.
> - **Multi-volume**: URL-backed RAR4/RAR5, split ZIP (`.z01`…`.zip` / `.zx01`…`.zipx`),
>   and byte splits such as `.7z.001` / `.zip.001` are supported. The default limit is 128 volumes.
>   Split ZIP opens from the last or any numbered segment, including ZIP64 and `.z100` onward.
>   Its declared count is checked before opening numbered siblings; missing volumes fail by name,
>   and extra siblings are ignored. Empty intermediate volumes retain their disk numbers.
>   Damaged-directory recovery is disabled for split ZIP. Byte splits join from `.001` until a gap;
>   their continuations do not rewind. Explicit symlinks use single-file behavior; sibling symlinks
>   are rejected. Data/custom-source inputs do not discover continuations. `reopen()` works after
>   all volumes are deleted. Split ZIP raw records use absolute concatenated ranges; `.001` raw
>   records remain `nil`. Same-name removable-media spanning and split PKSFX are out of scope.
>
> ISO 9660 is listed as `ISO 9660`. The tree priority is UDF > Rock Ridge (with NM) > Joliet > PVD.
> Unlike XADMaster's preference for Joliet, this preserves the symbolic links of an image that has
> both. UDF names are OSTA Compressed Unicode mapped straight to Unicode; `formatSpecific["nameSource"]`
> is `udf` and `udfRevision` carries the LVD domain revision. A UDF image without ISO 9660 structures
> is detected as `ArchiveFormat.udf` (`"udf"`; the compat `formatName()` is `UDF`). XADMaster cannot
> read UDF. Raw-sector images such as BIN/CUE (2352-, 2448- and 2336-byte sectors) open as the same
> `ISO 9660` / `UDF` through their user data, and a `.cue` path follows its data track's image (EDC /
> ECC are not verified). NM uses the archive-wide
> UTF-8, CP932 and EUC-JP detection, Joliet uses UCS-2BE, and PVD names stay uppercase.

## 11. 対応外形式・方式

現時点で container reader を提供しない主な形式は ACE です（ARJ は対応。method 4・garbled・multi-volume の続き file は `unsupportedMethod`）。対応済み container 内でも次は
未対応です（README の「既知の制限」の要約。未リリースの変更を含む現行 main の状態）。

- ISO の raw 2352/2336-byte sector、後続 session、interleaved / sparse 展開、zisofs2（ZF version 2）。
  UDF の複数 volume、ext_ad、device / FIFO / socket、resource fork 以外の named stream。
- ZIP の同名メディア交換型 spanned、split PKSFX（先頭 `.exe`）、method 96 (JPEG) / 97 (WavPack)。
  `.z01`…`.zip` / `.zx01`…`.zipx` の split ZIP と `.zip.001` バイト分割は対応。
- 7z の RISC-V filter (method 0x0B) と、7-Zip ZS の LZ4 / Brotli / LZ5 / Lizard coder。
- RAR4 の unpack version 15/20/26、custom VM、dictionary size が変わる solid 構成、SFX と multi-volume の組合せ。
- RAR5 compression version 1、SFX と multi-volume の組合せ、サイズ不明の暗号化 stored entry（file copy の参照は参照先の本文を返す `.file` として公開）。
- LHA `-pm1-` / `-pm2-` / `-lh2-` / `-lh3-`（一覧はできるが読み取りは `unsupportedMethod`）。
- CAB の Quantum（一覧のみ）と、複数 cabinet にまたがる file。
- RPM の rpm 6 簡略 cpio (`07070X`)、drpm、cpio でない payload（圧縮済み payload を 1 entry として公開）。
- cpio の PWB / newcx、HP-UX device number の解釈、device node の再作成（`.cpgz` / `.cpio.<codec>` と pbzx の Payload は展開して列挙）。
- tar の旧 GNU sparse（typeflag `S`）と star / Solaris の sparse 表現（pax GNU.sparse 0.0 / 0.1 / 1.0 は展開）。
- zstd / LZ4 の外部辞書。
- StuffIt の method 4/7/9〜12 と classic の暗号 flag `0x10`、StuffIt X の Iron version 1・その他の
  前処理・Root 暗号・recovery・segment・base-N transport。

gzip、bzip2、xz、zstd、LZ4、LZMA (`.lzma`)、lzip (`.lz`)、brotli (`.br`)、UNIX compress (`.Z`)、pbzx（cpio でないもの）は単一 entry として扱います。
`.tar.gz` / `.tgz`、`.tar.bz2` / `.tbz2` / `.tbz`、`.tar.xz` / `.txz`、`.tar.zst` / `.tzst`、`.tar.lz4`、
`.tar.lzma` / `.tlz`、`.tar.lz`、`.tar.br` / `.tbr`、`.tar.Z` / `.taz` / `.tz` は展開した stream を `TarReader` へ渡し、tar entry を直接
列挙します。method と encryption/multi-volume の全表は README の「対応状況」を参照してください。
追加候補の整理は [2026-09-20 の候補調査](verification/2026-09-20-format-candidates.md) を参照してください。

> **11. Formats and methods that are not supported**
>
> The main format for which no container reader is provided today is ACE (ARJ is supported; its method 4, garbled files and continued multi-volume members are `unsupportedMethod`). Within the
> containers that are supported, the following are not (a summary of "既知の制限" in the README for
> the current main branch, including unreleased changes):
>
> - ISO: raw 2352- and 2336-byte sectors, later sessions, interleaved or sparse expansion, and
>   zisofs2 (ZF version 2). UDF: multi-volume sets, ext_ad, device / FIFO / socket files, and named
>   streams other than the resource fork.
> - ZIP: same-name removable-media spanning, split PKSFX (`.exe` first segment), and methods
>   96 (JPEG) / 97 (WavPack). Split ZIP (`.z01`…`.zip` / `.zx01`…`.zipx`) and `.zip.001` byte splits are supported.
> - 7z: the RISC-V filter (method 0x0B) and the LZ4 / Brotli / LZ5 / Lizard coders of 7-Zip ZS.
> - RAR4: unpack versions 15, 20 and 26, the custom VM, solid configurations whose dictionary size
>   changes, and SFX combined with multi-volume.
> - RAR5: compression version 1, SFX combined with multi-volume, and encrypted
>   stored entries of unknown size (file-copy references are exposed as `.file` entries that return the
>   target's content).
> - LHA: `-pm1-`, `-pm2-`, `-lh2-` and `-lh3-` (listed, but reading fails with `unsupportedMethod`).
> - CAB: Quantum (listed only) and a file that spans several cabinets.
> - RPM: the simplified rpm 6 cpio (`07070X`), drpm, and any payload that is not cpio. Each of these is
>   exposed as a single entry holding the compressed payload.
> - cpio: PWB and newcx, HP-UX device number interpretation, and recreating device nodes
>   (`.cpgz` / `.cpio.<codec>` and pbzx payloads are expanded and listed).
> - tar: old GNU sparse entries (typeflag `S`) and the star / Solaris sparse attributes (pax
>   GNU.sparse 0.0 / 0.1 / 1.0 are expanded).
> - zstd / LZ4: external dictionaries.
> - StuffIt: methods 4/7/9–12 and the classic encryption flag `0x10`; StuffIt X: Iron version 1, the
>   other preprocessors, Root-level encryption, recovery records, segments and base-N transport.
>
> gzip, bzip2, xz, zstd, LZ4, LZMA (`.lzma`), lzip (`.lz`), brotli (`.br`), UNIX compress (`.Z`) and non-cpio pbzx are treated as a single entry.
> `.tar.gz` / `.tgz`, `.tar.bz2` / `.tbz2` / `.tbz`, `.tar.xz` / `.txz`, `.tar.zst` / `.tzst`, `.tar.lz4`,
> `.tar.lzma` / `.tlz`, `.tar.lz`, `.tar.br` / `.tbr` and `.tar.Z` / `.taz` / `.tz` hand their expanded stream to `TarReader` and list the
> tar entries directly. For the full table of methods, encryption and multi-volume support, see
> "対応状況" (Supported formats) in the README. The candidates for further formats are collected in
> [the 2026-09-20 survey](verification/2026-09-20-format-candidates.md).
