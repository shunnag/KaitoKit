# アプリへの組み込み

[README のクイックスタート](../README.md#クイックスタート) に続く、展開順序・並列処理・名前・資源上限の説明です。
形式別の挙動は [対応表](formats.md)、API の移行例は [移行ガイド](migration-from-xadmaster.md) にあります。

## 組み込みの注意

`ArchiveReader` と `EntryStream` は thread-safe ではありません。一つの instance の操作は actor や
serial queue で直列化し、並列展開には `reopen()` で作った独立 reader を使ってください。同じ
`solidGroup >= 0` の entry は同じ worker へ割り当て、`solidGroup == -1` は entry 単位で並列化できます。

`ReadLimits` は `maxEntrySize`、`maxTotalUncompressedSize`、`maxInMemorySize`、
`inMemorySingleFileLimit`、`stagingFreeSpaceReserve`、`maxSevenZipHeaderKDFWork`、
entry/metadata/path/dictionary/volume 上限などをまとめます。利用する corpus と
端末の memory budget に合わせて open 前に設定してください。`read(_:)` より大きい entry は
`EntryStream` で処理し、最後の 0 または error まで読み切って CRC と stream footer を確定します。
`stagingFreeSpaceReserve` は一時 volume の空き容量下限（既定 1 GiB）です。disk staging の開始前と
256 MiB 書き込みごとに確認し、下回れば `limitExceeded("staging free space")` を返します。
`maxSevenZipHeaderKDFWork` は 7z の open 中に行う header KDF の SHA-256 round 総数を制限します
（既定 `4 * (1 << 24)`）。cache hit と direct key は消費せず、entry 読み取り時の派生は対象外です。

`Data(contentsOf:options:.mappedIfSafe)` は、呼出中に内容が変わらないローカルの単一 file で使います。
RAR multi-volume は sibling file を解決できる `ArchiveReader.open(url:)` を使い、nested archive のように
既に memory 上にある bytes は `open(data:)` を使います。SFX prefix scan は URL open で有効、Data と
任意 `ByteSource` では `ReaderOptions.scanForSFXInData` が既定 `false` です。

展開先 root は処理中に caller が排他的に所有し、別 thread/process から名前や directory を変更しないで
ください。directory entry は子を展開した後、深い順に処理すると archive の最終日時と permissions を
保持できます。

> **Integration notes**
>
> `ArchiveReader` and `EntryStream` are not thread-safe. Serialize the operations of one instance
> with an actor or a serial queue, and use independent readers created by `reopen()` for parallel
> extraction. Assign entries sharing the same `solidGroup >= 0` to the same worker; entries with
> `solidGroup == -1` can be parallelized one entry at a time.
>
> `ReadLimits` collects `maxEntrySize`, `maxTotalUncompressedSize`, `maxInMemorySize`,
> `inMemorySingleFileLimit`, `stagingFreeSpaceReserve`, `maxSevenZipHeaderKDFWork`, and the entry,
> metadata, path, dictionary and volume limits. Configure
> it before opening, to match your corpus and the device's memory budget. Handle entries larger than
> `read(_:)` allows with `EntryStream`, reading through to the final 0 or error so that the CRC and
> the stream footer are finalized.
> `stagingFreeSpaceReserve` defaults to 1 GiB of available temporary-volume space. It is checked
> before disk staging and every 256 MiB written; falling below it throws
> `limitExceeded("staging free space")`. `maxSevenZipHeaderKDFWork` limits the aggregate SHA-256
> rounds used by 7z header KDFs during open, defaulting to `4 * (1 << 24)`. Cache hits and direct
> keys consume no rounds, and entry-time derivations are excluded.
>
> Use `Data(contentsOf:options:.mappedIfSafe)` only for a local single file whose contents do not
> change during the call. Use `ArchiveReader.open(url:)` for multi-volume RAR so that sibling files
> can be resolved, and `open(data:)` for bytes already in memory, such as a nested archive. The SFX
> prefix scan is enabled for URL opens; for `Data` and custom `ByteSource` inputs,
> `ReaderOptions.scanForSFXInData` defaults to `false`.
>
> The caller owns the destination root exclusively while extraction is in progress; do not rename or
> restructure it from another thread or process. Processing directory entries after their children,
> deepest first, preserves the final dates and permissions recorded in the archive.

## Sandbox とファイルアクセス

Sandbox アプリでは、入力・出力および分割巻の兄弟ファイルを開けるアクセス権を呼出側で確保してください。
security-scoped URL を使う場合は、reader / stream の利用が終わるまでアクセスの有効期間を管理します。
KaitoKit の URL open はファイルを開く処理であり、アプリのアクセス権の取得を代行しません。
圧縮書庫の staging には、一時 volume の容量も必要です。

## 書庫全体の展開順序

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
func isResourceFork(_ entry: ArchiveEntry) -> Bool {
    entry.kind == .file && entry.pathComponents.suffix(2).elementsEqual(["..namedfork", "rsrc"])
}
var deferred: [ArchiveEntry] = []
for entry in archive.entries where entry.kind != .directory {
    if isResourceFork(entry) {
        deferred.append(entry)
    } else if entry.kind == .hardlink,
              let target = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
              target > entry.index {
        deferred.append(entry)
    } else {
        _ = try archive.extract(entry, to: destination)
    }
}
for entry in deferred where !isResourceFork(entry) {
    _ = try archive.extract(entry, to: destination)
}
for entry in deferred where isResourceFork(entry) {
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
するとリセットされます。書庫順を保ち、前方参照だけ参照先の展開後まで遅らせてください。
resource fork（`.file` かつ末尾が `..namedfork/rsrc`）は、data fork と hard link の後、
directory の前に展開します。data fork の不可分置換は既存 resource fork も失うため、この順序が必要です。
単発の `extract` は対象 data ファイルがなければ空の通常ファイルを作り、resource fork を付けます。
`overwriteExisting: false` は既存の非空 resource fork に `EEXIST` を返します。
展開中の出力ルートは呼出側が排他的に所有し、別スレッドや別プロセスから変更しないでください。

`ArchiveReader` はスレッドセーフではありません。並列展開では `reopen()` で同じ
`ByteSource` を共有する独立 reader を作ってください。既存 XADMaster 利用コード向けには
`KaitoKitCompat` の `KaitoArchive` と `XADArchive` typealias もあります。
自動判定が必要な未宣言名を持つ書庫では、`nameEncoding` から書庫全体に選択された
文字コードを取得できます。自動判定時にすべての名前が形式で宣言済みまたは
厳密に有効な UTF-8 なら `nil` です。

> **Extraction order**
>
> Process directories after their children, deepest first, to preserve the final permissions and
> modification dates recorded in the archive. `kaito extract` uses the same order.
> A hard link with no body of its own is created only when the same `ArchiveReader` has already
> extracted its target into the same output root. That provenance is reset when you switch output
> roots or call `reopen()`. Keep archive order, deferring forward links until their targets exist.
> Extract resource forks (`.file` with the final components `..namedfork/rsrc`) after data and hard
> links, before directories. Atomic data-file replacement discards any existing resource fork.
> A single resource extraction creates an empty regular data file if missing. With
> `overwriteExisting: false`, an existing nonempty resource fork fails with `EEXIST`.
> The caller owns the output root exclusively during extraction; do not modify it from another
> thread or process.
>
> `ArchiveReader` is not thread-safe. For parallel extraction, use `reopen()` to create independent
> readers that share the same `ByteSource`. For existing XADMaster call sites, `KaitoKitCompat`
> provides `KaitoArchive` and an `XADArchive` typealias.
> For archives whose names are undeclared and need automatic detection, `nameEncoding` reports the
> character encoding chosen for the whole archive. It is `nil` when every name is either declared by
> the format or strictly valid UTF-8.

## 進捗とキャンセル

`ArchiveReader.extract(_:to:options:)` に進捗 callback や cancellation token はありません。
[README の例](../README.md#クイックスタート) は entry 間で task の cancellation を確認します。
byte 単位の進捗とキャンセルは `EntryStream` の read loop で実装できます。次の例は通常の
data file の本文を、呼出側が選んで開いた出力へ書きます。パス・metadata・リンク・resource fork
の復元には、上記の順序で `extract` を使ってください。

```swift
import Foundation
import KaitoKit

func copyDataFile(
    _ reader: ArchiveReader, entry: ArchiveEntry, to output: FileHandle,
    progress: (UInt64, UInt64?) -> Void
) throws {
    precondition(entry.kind == .file &&
        !entry.pathComponents.suffix(2).elementsEqual(["..namedfork", "rsrc"]))
    let stream = try reader.stream(entry)
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var written: UInt64 = 0
    while true {
        try Task.checkCancellation()
        let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
        if count == 0 { break }
        try output.write(contentsOf: Data(buffer[..<count]))
        written += UInt64(count)
        progress(written, entry.uncompressedSize)
    }
}
```

出力 handle の作成・close と、失敗やキャンセル時の部分出力の削除は呼出側で管理します。
最後まで読む前の byte は、entry 全体の checksum / 認証の成功を意味しません。

## 名前の文字コードと圧縮 tar の staging

名前は ZIP/RAR4/LHA/tar/gzip FNAME の undecorated bytes に対して、書庫全体の多言語符号化判定を行い、format が宣言する Unicode 名を優先します。単一 file 形式の FNAME がない場合は
source file の拡張子を除いた名前を entry 名にします。
厳密 UTF-8 を最優先にし、legacy 候補は CoreFoundation に基づく復号表、文字集合、文字体系・綴りの規則で比較します。
`likelyLanguage` は BCP-47 の主要 subtag、中国語の文字体系、`sr-Latn` を解釈し、証拠量で減衰する事前確率として使います。

| 言語 | 自動判定の候補 |
|---|---|
| 日本語 | CP932、EUC-JP |
| 中国語（簡体字） | GB18030（GBK / GB2312 を包含） |
| 中国語（繁体字） | CP950、Big5-HKSCS（CP950 で復号不能の場合） |
| 韓国語 | CP949（EUC-KR を包含） |
| タイ語 / ベトナム語 | CP874・MacThai / CP1258 |
| uk / ru / bg / sr / mk / be | CP1251、KOI8-U/R、CP866、ISO-8859-5、MacCyrillic、CP855、MacUkrainian |
| es / pt / fr / de / it / en / da / nb / sv / fi / is / nl | CP1252、ISO-8859-15、MacRoman、CP850、CP865、MacIcelandic、ISO-8859-10、CP437 |
| pl / cs / hu / ro / hr / sl / sk / sr-Latn | CP1250、ISO-8859-2、MacCE、ISO-8859-16、MacRomanian、CP852、MacCroatian |
| ギリシア語 | CP1253、ISO-8859-7、CP737、CP869、MacGreek |
| トルコ語 | CP1254、ISO-8859-9、CP857、MacTurkish |
| ヘブライ語 | CP1255、ISO-8859-8、CP862、MacHebrew |
| アラビア語 / ペルシア語 | CP1256、ISO-8859-6、CP864、MacArabic、MacFarsi |
| リトアニア語 / ラトビア語 / エストニア語 | CP1257、ISO-8859-4、ISO-8859-13、CP775 |

ISO-2022-JP、VISCII、TCVN3 は自動判定の対象外です。CP861 は CF の表が CP775 と同一のため候補に含めません。
CP1256 の欠落8文字は判定用の表にだけ補っており、ペルシア語の ک などは、正しい encoding を選べても既存の CF 復号で復元できず、名前全体が fallback 表記になる場合があります。MacArabic / MacFarsi の CF が挿入する方向制御は採点から除きますが、reader の出力には残ります。
既定の `likelyLanguage: "ja"` では、単独の韓国語・中国語の短名（8音節未満）が日本語に解決されることがあります。他アプリは対象の言語に合わせた `likelyLanguage` を渡してください。

54 legacy候補・CLDRの40集合（測定39言語と補助の英語）を使用します（Unicode License v3、[NOTICE](../NOTICE)）。漢字だけの短名、文字配置が重なる欧州系 code page、他の文字体系への交差復号には曖昧性・規則不足が残ります。候補に含まれることは正解率の保証ではありません。CP864 と生成codecのないMac系候補には統計評価の不足もあります。4方式の測定値、旧49群との比較、精度の残差、テスト結果と性能の測定値は[Task C-Bの検証記録](verification/2026-09-14-name-encoding-languages.md)を参照してください。
`kaito detect-encoding --check-orthography <tsv>` は正解 text に言語別の位置規則を適用し、違反位置を出力します。

圧縮 tar の展開結果は `ReadLimits.inMemorySingleFileLimit` 以下なら memory、それより大きければ
直ちに unlink した一時 file descriptor に保持します。どちらも同じ `TarReader` API を公開します。
`reopen()` はこの展開済み source を共有し、再展開・一時 file の再作成を行いません。
staging は chunk ごとに task の cancellation を確認します。

> **Names and compressed tar staging**
>
> Names are resolved by archive-wide multilingual encoding detection over the undecorated bytes
> of ZIP, RAR4, LHA, tar and gzip FNAME, preferring any Unicode name the format declares. When a
> single-file format carries no FNAME, the entry name is the source file name with its extension
> removed.
>
> The expansion of a compressed tar is held in memory when it is at or below
> `ReadLimits.inMemorySingleFileLimit`, and otherwise in an immediately unlinked temporary file
> descriptor. Both paths expose the same `TarReader` API.
> `reopen()` shares that staged source without decoding or creating another temporary file.
> Staging checks task cancellation at each chunk.

## PasswordProvider

必要時に password を取得するには、`ReaderOptions(passwordProvider:)` に provider を渡します。
`PasswordProvider` は `Sendable` で、`password(for:)` は同期の throwing 呼出しです。
`nil` を返すと提供を辞退します。次の例では 7z にだけ password を提供します。

```swift
import Foundation
import KaitoKit

struct ArchivePasswordProvider: PasswordProvider {
    let lookup: @Sendable (ArchiveFormat) throws -> String?

    func password(for format: ArchiveFormat) throws -> String? {
        try lookup(format)
    }
}

let options = ReaderOptions(passwordProvider: ArchivePasswordProvider { format in
    format == .sevenZip ? "secret" : nil
})
let archive = try ArchiveReader.open(
    url: URL(fileURLWithPath: "/tmp/private.7z"), options: options
)
```

> **Password provider**
>
> A provider is `Sendable` and called synchronously; return `nil` to decline.
> Pass it through `ReaderOptions(passwordProvider:)`. The example supplies a password only for 7z.

## RAR5 の KDF とサイズ不明 entry

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

> **RAR5 key derivation and unknown sizes**
>
> The KDF for RAR5 archive headers bounds each individual `count` with
> `ReaderOptions.maxRAR5KDFCountPower`, whose default and maximum are both 24. On top of that,
> `ReadLimits.maxRAR5HeaderKDFWork` accumulates the derivations actually performed across every
> volume that uses header encryption. Work is measured in HMAC-SHA256 iterations, counting each
> context as `2^count + 32`. The default is `4 * (2^24 + 32)`, that is four contexts at the most
> expensive `count = 24`. When several volumes reuse the same `(password, salt, count)` context the
> key cache is used and the work is charged once. Different contexts accumulate across volumes.
>
> A RAR5 entry of unknown size keeps `uncompressedSize == nil` and is streamed incrementally to the
> decoder's end marker. `read(_:)` likewise assumes no declared size and grows its buffer in stages
> within the configured limits. The codec dictionary size limit is set by
> `ReadLimits.maxDictionarySize` and defaults to 1 GiB.
