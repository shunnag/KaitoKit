# StuffIt slice 8 検証（2026-09-13、bd `cooViewer-gu28.8`）

指定 3 書庫は展開失敗 0、展開後の全 data / resource SHA が一致した。
全 1,046 tests（41 skip、失敗 0）、build / test / release の警告 0。
支給 `compare.py` は mismatch 0 で、集計・出力とも修正前と一致した。

## 変更と実装入力

resource fork の entry 表現（`.file`、`name/..namedfork/rsrc`、`fork=resource`）を維持し、
抽出だけを fork 対応にした。認識は kind と `pathComponents` の末尾 2 成分で行い、
`formatSpecific` の有無や書庫形式には依存しない。それ以外の `..namedfork` は通常の path として扱う。

- parent は既存の `ExtractionDirectoryAccess.open(create: true)` で開く。
  data leaf は `fstatat(AT_SYMLINK_NOFOLLOW)` で検査し、存在しない場合だけ
  `openat(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC)` で空の通常ファイルを作る。
  symlink は `ELOOP`、directory 等の非通常ファイルは `EISDIR` で拒否する。
- parent dirfd 相対の `<leaf>/..namedfork/rsrc` を
  `openat(O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_CLOEXEC)` で開き、既存の stream/write を使う。
  `overwriteExisting: false` は切り詰め前に fork の `fstat.st_size` を確認し、非空なら `EEXIST`。
  data ファイルが存在しても、resource が未作成または空なら初回書き込みを許す。
- fork descriptor の `fchmod` / `futimens` はこの macOS で `EPERM` になった。
  属性は開いた data descriptor へ復元し、`ExtractionResult.fileIdentity` もその inode を返す。
  data ファイルの通常抽出（CRC 検証後の `renameat` による不可分置換）は変更しない。
- CLI は既存の deferred 配列に resource fork も入れ、data / hardlink → resource → 深い directory の順に処理する。
  ライブラリの単発抽出では data が未存在なら空ファイルを作る。後から data を不可分置換すると
  先に書いた resource は失われるため、呼出側もこの順序を守る。
- classic / SIT5 の `ArchiveEntry.name` は reader で `pathComponents` を結合した完全な相対パスにする。
  resource も `A/B/..namedfork/rsrc` になり、一覧・Compat の `name(ofEntry:)`・展開で親階層を保持する。
  `Extractor` は全形式で `entry.name` を使い、StuffIt 固有の path 分岐は設けない。
- classic / SIT5 の archive encoding が `.shiftJIS` のとき、CP932 から単名 fallback に落ちた名だけ
  `CFStringEncodings.macJapanese` で再試行する。CP932 成功・厳密 UTF-8・他 encoding の結果と
  SITX の処理は維持し、`nameEncoding` や format metadata は追加・変更しない。
  CoreFoundation の 0xFF decode は `U+2026 U+F87F` だったため、この組の round-trip 私用タグを除き
  `U+2026` だけをファイル名へ保持する。

実装入力は依頼文、既存 KaitoKit コード、ローカル Darwin の `openat(2)` / `fstatat(2)` /
`fstat(2)` / `getxattr(2)` man page、CoreFoundation の実測。Web、`inbox/stuffit/` のレポート、
XADMaster / The Unarchiver 等のソースは開いていない。codec・容器 parser・暗号・`ArchiveEntry` の公開 API は変更していない。
`inbox` は読み取り用とし、支給 `compare.py` は実行のみ。git checkout / restore / stash / reset / commit / push は実行していない。

## 日本語 fixture

支給 `inbox/stuffit-corpus/jp/` の 3 書庫と生成器をそのままコピーした。
次のコマンドで再生成したバイナリも全 byte 一致（`cmp` exit 0）。

```sh
mkdir -p .build/slice8-generated
python3 Tests/Fixtures/stuffit/tools/make-classic-jp.py .build/slice8-generated/jp-sjis.sit shift_jis
python3 Tests/Fixtures/stuffit/tools/make-classic-jp.py .build/slice8-generated/jp-macjp.sit shift_jis macjp
python3 Tests/Fixtures/stuffit/tools/make-classic-jp.py .build/slice8-generated/jp-euc.sit euc_jp
```

| ファイル | bytes | SHA-256 |
|---|---:|---|
| `jp-sjis.sit` | 1,326 | `40401b2820e9f9110e675c0d0cf0d3d8cb96c584a5d4885cfb268340c32955ac` |
| `jp-macjp.sit` | 1,569 | `96b37b6a18973ef4ffeeedb185916b729c20bfc9c5ab11f306fd8a42ed14ad3e` |
| `jp-euc.sit` | 1,326 | `5ee96908c609ee31fb3399615ceffefbd30aa97af72325712d3cb3f0c4450d97` |
| `tools/make-classic-jp.py` | — | `40db3faf0545dd527f9f890c383b9a65b7803b9c146ba7ed8af18d658f099434` |

XCTest で 8 / 10 / 8 entry の kind、名前、pathComponents、fork metadata、stream の長さと CRC を確認した。
共通の全階層名は `写真.jpg`、`第１巻`、`第１巻/ページ０１.jpg`、`第１巻/ページ０２.jpg`、
`～テスト～.txt`（EUC-JP は U+301C の `〜`）、`Vol.1 表紙.png`、
`アイコン付き.jpg/..namedfork/rsrc`、`アイコン付き.jpg`。
MacJapanese はこれに `メモ….txt`（U+2026）と `©メモ.txt`（U+00A9）を加えた全 10 entry。

人工 classic / SIT5 でも `.fixed(.shiftJIS)` を指定し、0x80 / 0xA0 / 0xFD / 0xFE / 0xFF を検証した。
それぞれ `U+005C` / `U+00A0` / `U+00A9` / `U+2122` / `U+2026` になり、rawName bytes は変わらない。
厳密 UTF-8 との混在、CP932 の U+FF5E、他 encoding policy、MacJapanese でも失敗する単独 lead byte、
既存 SITX UTF-8 名も回帰検証した。

## XCTest と build

全 1,046 tests（KaitoKit 1,023、Compat 23、41 skip）は失敗 0。
追加した 12 tests（resource 抽出 6、名前 4、CLI 2）も全体実行内で成功した。
resource-only の 600,003 bytes を複数 chunk で書き、空 data / resource 内容 / xattr / data inode の一致を確認した。
data と resource 両方の再抽出 `EEXIST`、上書き時の短い内容への切り詰め、空既存 fork、
既存・dangling symlink と directory の拒否、リンク先内容の不変、hardlink provenance、
通常の `..namedfork` path と `..` 拒否、CLI の階層・fork 順序・directory の最終 mode/mtime を含む。

通常の `swift build` はホーム側 cache への書き込み制限で manifest compile に失敗したため、
既存 slice と同様に cache / config / security / Clang module cache を worktree 内へ指定した。
Release は `GenerateDSYMFile` が `Operation not permitted` で失敗したため、
既存 slice と同じ `-debug-info-format none` を付けた。
環境は macOS 27.0（26A428）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
```

この指定で build / test / release はすべて exit 0、`warning:` は各 0 件。
初回の KaitoKit tests は 291.412 秒、Compat は 0.693 秒、Release build は 40.53 秒で完了した。

## 実書庫の抽出と全体比較

修正前の CC0 `testfile.stuffit651_dlx.mac9.sit` は entry 2 / 5 / 8 が `EISDIR`（errno 21）で失敗し、
`Test Image` も directory になった。修正前バイナリは検証用一時ディレクトリへ保存して比較した。

修正後の Release CLI で各書庫を独立した出力先へ展開した。通常の `sha` の各ファイルを実 data fork と、
`sha --forks` の全 resource 行を実 fork path から読んだ SHA-256 と照合した。
全 resource の `xattr -px com.apple.ResourceFork` もサイズ・SHA を確認し、
`ls -la@` / `xattr -l` で各書庫の属性を確認した。展開木に実 directory / file としての `..namedfork` はない。

| 書庫 | entry | data SHA 一致 | resource SHA 一致 | resource-only file | directory | 失敗 |
|---|---:|---:|---:|---:|---:|---:|
| `cc0/testfile.stuffit651_dlx.mac9.sit` | 9 | 6 | 4 | 1 | 0 | 0 |
| `cc0/testfile.stuffit7_dlx.mac9.sitx` | 9 | 6 | 4 | 1 | 0 | 0 |
| `perf/theplanets.sit` | 82 | 78 | 76 | 74 | 2 | 0 |

data SHA の列は resource-only の空 data ファイルを含む。全 90 data ファイルと 84 resource fork が一致。
依頼文の theplanets「77/80」は通常 `sha` の 80 行中、size 0 の 77 行という集計と一致する。
その 77 行には directory 2 件と、明示的な空 data entry `Desktop DF` 1 件が含まれる。
実際の resource-only は 74 通常ファイルで、すべて data size 0 と非空 resource fork を確認した。
容器 parser の列挙結果は変更していない。

| 入力書庫 | SHA-256 |
|---|---|
| `testfile.stuffit651_dlx.mac9.sit` | `238f1e460cd7aa71fa21e31d06e741265df2cafb8151614488baee9af2e4990a` |
| `testfile.stuffit7_dlx.mac9.sitx` | `f557d88b0ebde7b85f230e36ff6ae16247d2a623eedae721a8a96532e6cec963` |
| `theplanets.sit` | `f7f5b633d1de60fedca86dde49c9d2b2d49667e0541d17910794b13b44717c29` |

classic / SITX 両方の `Test Image` は次の状態になった。

```text
-rw-r--r--@ 1 nagash wheel 0 Feb 4 2023 Test Image
    com.apple.ResourceFork 9134
```

classic の `Test Image` の data SHA は空ファイルの
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`、
resource SHA は `4b8175653903645616d9e07627957ae0dba4c7ac3b3e9aa6afc8e07144dcfbb0`。
`cat "<file>/..namedfork/rsrc" | shasum -a 256` でも同じ値になった。
theplanets の `The Planets v 2.0/The Planets` も個別に `shasum` で再確認し、
data は `28bca1d9d7674f498017457dd1298fca0eb7e661a88f46066637384f34058120`、
resource は `53fab604f517e7b277dae9bd4b9e8268b4e1923b0f1d421e7f245545c917e070` で一致した。

```sh
.build/out/Products/Release/kaito extract inbox/stuffit-corpus/cc0/testfile.stuffit651_dlx.mac9.sit -o /private/tmp/kaitokit-slice8-verification/extracted/cc0-classic
.build/out/Products/Release/kaito extract inbox/stuffit-corpus/cc0/testfile.stuffit7_dlx.mac9.sitx -o /private/tmp/kaitokit-slice8-verification/extracted/cc0-sitx
.build/out/Products/Release/kaito extract inbox/stuffit-corpus/perf/theplanets.sit -o /private/tmp/kaitokit-slice8-verification/extracted/theplanets
.build/out/Products/Release/kaito list Tests/Fixtures/stuffit/jp-macjp.sit
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito
```

Release `list` の追加 2 entry は `メモ….txt` / `©メモ.txt` で、escape や私用タグは含まれない。
支給 `compare.py` は実行のみで、修正前後の stdout は `cmp` でも全 byte 一致した。

| compare.py 集計 | 修正前 | 修正後 |
|---|---:|---:|
| match | 197 | 197 |
| name_diff | 0 | 0 |
| superset | 4 | 4 |
| no_oracle | 0 | 0 |
| kaito_error | 15 | 15 |
| mismatch | 0 | 0 |

既存の未対応 15 件と receipt 由来の superset 4 件は変わっていない。
ログ、SHA 行、`ls` / `xattr` 出力、照合集計は `/private/tmp/kaitokit-slice8-verification/` に保存した。

## レビュー反映: reader の完全パス名

`StuffItReader` の `name: suffix.joined(separator: "/")` を
`name: path.joined(separator: "/")` へ修正した。`ArchiveEntry.name` 自体に親階層が入り、
`Extractor` の `reader.format == .stuffIt` 分岐とコメントを削除した。
`name` は全 reader 共通の完全な相対パスという契約に揃い、resource fork も
`The Planets v 2.0/Read Me/..namedfork/rsrc` のように公開される。

日本語 fixture の期待名を `第１巻/ページ０１.jpg` / `第１巻/ページ０２.jpg` に直し、
CLI `list` でも親付き表示を検査した。classic の人工 nested entry は `A/A` を検査する。
CC0 manifest では既存の `path` 列を完全パスの期待値として使い、fork 検証にも `entry.name` の一致を加えた。
go の既存 XCTest は名前列を `entry.pathComponents` の再結合から `entry.name` に変更した。
親なしの `A/..namedfork/rsrc`、`SimpleText/..namedfork/rsrc` は従来どおり。

### go オラクルの名前照合

`oracle/go/<name>.sha` 全 17 本を使い、元の `go/<name>` を修正後の Debug CLI の `sha` で読んだ。
`.hqx` / `.sit` の wrapper は reader に透過させ、暗号名の 2 本だけ `-p password123` を付けた。
`unwrapped-go/doom-i-101.hqx.data` は書庫本体であり、オラクルとしては使っていない。

`total` / `partial`、resource fork の末尾 `/..namedfork/rsrc` を除外し、directory は `list` の kind で除外した。
通常の `sha` は data fork view なので、resource-only の空 data 行は比較に含める。
行番号や列挙順には依存せず、同じ `(size, SHA-256)` の行群で名前の多重集合を照合し、
不足行と名前差分を分けた。成功した各 `sha` では、`list` の file 名（resource は suffix を外した名）も
すべて対応する data 行に存在した。

サイズ・SHA が対応した **21 行（非空 10、空 data 11）は全て名前一致、名前差分 0**。
オラクルは計 26 行、Kaito は計 43 行で、対応しないオラクル 5 行 / Kaito 22 行は以下のとおり分離した。
この go オラクル集合には親フォルダ付きの名前列がないため、外部オラクルで nested 名が一致したとは数えない。
親階層は上記の XCTest と `kaito list`（jp / theplanets / doom）で確認した。

| go 書庫 | oracle data 行 | kaito data 行 | size / SHA / 名前一致 | sha exit |
|---|---:|---:|---:|---:|
| `SITv1-13.sit` | 1 | 1 | 1 | 0 |
| `SITv1-2.sit` | 1 | 2 | 0 | 0 |
| `doom-i-101.hqx` | 1 | 19 | 0 | 0 |
| `v1-fhf-faster.sit` | 2 | 2 | 1 | 0 |
| `v1-huffman-optimal.sit` | 2 | 2 | 2 | 0 |
| `v1-huffman.sit` | 1 | 1 | 1 | 0 |
| `v1-lzm-des-password123.sit` | 2 | 1 | 1 | 1 |
| `v1-lzm-newde-password123.sit` | 2 | 1 | 1 | 1 |
| `v1-lzw+h-better.sit` | 2 | 2 | 2 | 0 |
| `v1-lzw+huffman.sit` | 1 | 1 | 1 | 0 |
| `v1-lzw-fast.sit` | 2 | 2 | 2 | 0 |
| `v1-lzw.sit` | 1 | 1 | 1 | 0 |
| `v1-nocompression.sit` | 2 | 2 | 2 | 0 |
| `v1-optimal-with-comment.sit` | 2 | 2 | 2 | 0 |
| `v1.5-lzw-comment.sit` | 2 | 2 | 2 | 0 |
| `v5-comment.sit` | 1 | 1 | 1 | 0 |
| `v5-selfextractor.sea` | 1 | 1 | 1 | 0 |

- `SITv1-2.sit.sha` は `fixer.sit` 自体の 3,732 bytes / SHA
  `79f5164110bf6d45df62493126236f58fbce92b552b0995fd4e062471cfa09c9` の 1 行。
  Kaito はその内側の `fixer.c`（2,909 bytes）と `fixer`（空 data）を返す。
- `doom-i-101.hqx.sha` は `DOOM I (shareware edition….sit` 自体の 2,545,575 bytes / SHA
  `a1776a8fa4ad0eac6a1952fd2bb8c92bd97ae9dda6a213c894b3af7abc83ab63` の 1 行。
  この SHA は支給 `unwrapped-go/doom-i-101.hqx.data` と一致し、Kaito はその中の 19 data 行を返す。
  以上 2 本は内側の member 名を比較できるオラクルではない。
- `v1-fhf-faster.sit` の `About System 7.5` は、オラクルでは size 0 / 空 SHA、
  Kaito では 19,696 bytes / `d78c0b5547fc230e734ce2fc05ae7fada9f075e601a819a9d4d0f2b33b883bef`。
  size / SHA が異なるため名前一致の集計に含めない。同書庫の `SimpleText` は一致した。
- 暗号 2 本の `About System 7.5` は既存の
  `unsupportedMethod("StuffIt encryption without archive resource fork")` で失敗する。
  各 `SimpleText` の空 data 行は名前も一致。暗号方式や parser は変更していない。

go の stdout / stderr / list、全対応行と入力オラクルの SHA-256 は
`/private/tmp/kaitokit-slice8-review/go/`、集計はその親の `go-names.log` に保存した。

### レビュー後の再検証

上記と同じ cache / config / security 指定で `swift build` と `swift test` 全体を再実行した。
build は exit 0、警告 0。全 1,046 tests（KaitoKit 1,023、Compat 23、41 skip）は失敗 0、警告 0。
KaitoKit は 289.677 秒、Compat は 0.798 秒。変更した jp / CC0 / go の名前期待値と
CLI の一覧・抽出テスト、既存の全 resource fork テストもこの実行に含む。

Release も `-debug-info-format none` 付きで成功（36.73 秒、exit 0、警告 0）。
そのバイナリで jp と theplanets の `list` を確認し、data / resource とも完全な相対パスになった。
`python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito` は exit 0、
match 197 / name_diff 0 / superset 4 / no_oracle 0 / kaito_error 15 / mismatch 0。
レビュー修正前の比較出力と `cmp` でも全 byte 一致した。`git diff --check` も exit 0。
再検証のログは `/private/tmp/kaitokit-slice8-review/` に保存した。

## orchestrator の独立検証（受理）

| 検証 | 結果 |
|---|---|
| `swift build` / release build | warning 0 |
| `swift test` | 1,023 + 23 件、41 skip、失敗 0 |
| `kaito extract`（release）`cc0/testfile.stuffit651_dlx.mac9.sit` | 失敗 0。`Test Image` は 0 バイトの通常ファイル + `com.apple.ResourceFork` 9,134、`testfile.PICT` は data 2,694 + fork 44,549。`<file>/..namedfork/rsrc` の sha256（`4b817565…`、`011604ad…`）は `kaito sha --forks` および `research/archive-verification.json` の fork sha と一致 |
| `kaito extract` `perf/theplanets.sit`（80 entry、うち resource-only 63） | 失敗 0。`The Planets v 2.0/Read Me` に fork 96,386 バイト |
| `kaito extract` `jp-sjis.sit` | `第１巻/ページ０１.jpg` 等の階層と日本語名がそのまま展開される |
| 入れ子の名前（reader の `name` 修正） | `perf/theplanets.sit` の XADMaster オラクル（`oracle/perf/theplanets.sit.sha`、80 行）と `kaito sha`（data fork 80 行）を `(size, sha, name)` で照合: 通常名 17 行は**名前まで完全一致**（`The Planets v 2.0/…`）。残り 63 行は tab / 空白だけの名前の resource-only entry で、XADMaster 側の出力は空白を落として `The Planets v 2.0/` と出るのに対し kaito は `\t` にエスケープして出す（サイズ・sha は一致） |
| MacJapanese | `jp-macjp.sit` の entry 8 / 9 が `メモ….txt` / `©メモ.txt`（修正前は `\u{83}\u{81}…ÿ.txt` のエスケープ） |
| ASan（`inbox/bench/mutate.py`、classic / SIT5 / wrapper、ASan 付き `kaito sha`） | 2,192 runs、所見 0 |
| `compare.py` | mismatch 0（slice 6 base のため JPEG 3 本は既知 error のまま） |

`ArchiveEntry.name` の修正は orchestrator の指摘（cooViewer は `name(ofEntry:)` = `entry.name` でフォルダ構造を得るため、
classic / SIT5 の末尾名だけの `name` はフォルダを失う）によるもの。
