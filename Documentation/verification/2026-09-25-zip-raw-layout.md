# ZIP raw layout SPI・local header 先読みの検証（2026-09-25）

基準は KaitoKit `b51801470cb1d9742039d50036f5c950387ddc94`、branch `feature/2026-09-24-review`。Swift 6 言語モード、Apple Swift 6.4、arm64、実行 OS は macOS 27.2（26B5091g）、macOS 26 deployment target。GyoshukuKit / KaitoFinder の source は変更せず、commit / tag / release は行わない。

## Step 0（Sources の変更前）

`swift test` の素の実行は既定の clang module cache への書込み権限で失敗した。以後の SwiftPM コマンドは `CLANG_MODULE_CACHE_PATH=<tmp>/p1k-module-cache`、`SWIFTPM_MODULECACHE_OVERRIDE=<tmp>/p1k-module-cache`、`--disable-sandbox --cache-path <tmp>/p1k-spm-cache` を指定した。Release は SwiftBuild の dSYM 生成が sandbox で失敗したため `-debug-info-format none` を使う。最適化や言語モードは変更していない。

| 基準の test target | 実行数（skip を含む） | skip | failure |
| --- | ---: | ---: | ---: |
| KaitoKitTests | 1,424 | 45 | 0 |
| KaitoKitCompatTests | 34 | 0 | 0 |

既存の read 計数を調査。ReopenSharingTests は独立した cache、ZipSplitVolumeTests は EOCD discovery、StoredDirectReadTests は stream の直接読み、ZipModernMethodTests の XZ AES は大きな単一 record を対象とする。既存期待値の変更は不要。非 ZIP の RAR / single-file 計数は対象外。

`git diff --quiet -- Sources` 成功後、`KAITOKIT_WRITE_ZIP_GOLDEN_INPUTS=1` で入力を生成し、再度 Sources 無変更を確認して `TZ=UTC KAITOKIT_WRITE_ZIP_GOLDEN=1` で公開値を生成した。UTC と Asia/Tokyo の照合は両方成功。P1-K の実装中は試験・入力・期待値を凍結した。後述の S2 correction 1 では依頼に従って保存形式と読込処理だけを変更し、入力・期待値の byte と比較内容は維持した。

- 入力: 266 書庫 / 269 ファイル。既存 ZIP 全 30 件、合成 236 件。6 開き方、昇順 / 逆順それぞれ新しい reader。
- 以下の試験・manifest の hash は S2 correction 1 前の記録（JSON の byte と hash は変更後も同じ）。
- `ZipPublicValueGoldenTests.swift` SHA-256: `c0cf9b40d9a623c8a8bc3ad73d86250fac31fc3e20ba6a831a238e7895886b82`
- `manifest.json`: `14c1d9b130335407f2f7791599dbf52d6b7418feb6f9bd28831040a36df794dd`
- `public-values.json`: `2fbc5230042dbebf38920228980bf6c1973764656cfeb16d748bf029237fdaee`

`.git` は読取専用のため worktree 登録は行わず、`git archive b518014` を `<tmp>/p1k-base/KaitoKit` に展開した独立した source snapshot を使用。そこへ公開 API の golden 試験と凍結入力だけをコピーし、UTC / Release で値を再生成した。作業ツリーの JSON との `cmp` は成功（byte 一致）。

## 段階ごとの確認

K1: `swift build` 成功。ZIP 全系統と RawEntryRecord / ReopenSharing / AppleDoubleSidecar / SplitVolume / StoredDirectRead の選択実行は KaitoKitTests 392（skip 3）と Compat 6、failure 0。UTC golden 成功。差分 fuzz は 5 seed × 300 = 1,500 変異、1.595 秒、差分 0。この段階では SPI 先 / 公開 API 先の同値性を比較した。

Swift 6.4 は同一 test module 内の明示的 `internal import` と既存の暗黙 import を曖昧と診断するため、KaitoKitTests target に限り `InternalImportsByDefault` を有効にした。この対応では凍結済み golden や既存の試験ファイルは変更していない。library target の公開性には影響しない。

K2 focused: 10 tests、failure 0。凍結 corpus 全開き方で `.standard` / `.disabled` の entries、公開 raw、SPI、stream の内容 / エラーが一致。差分 fuzz 1,500 件は 0.751 秒、差分 0。

| 2,000 件の local 領域 | raw read 回数 | eager read 回数 | 読んだ byte / local byte |
| --- | ---: | ---: | ---: |
| 13 B UT extra | 3 | 3 | 100,890 / 100,890 |
| 署名を交互にした descriptor | 3 | 3 | 102,890 / 102,890 |

最終 record の固定部だけで buffer を捨てると extra / descriptor を再読し AC5 の byte 上限を超えるため、解放はその record の検証完了時とした。最後の record を返し終えるまで必要な byte を保持し、eager open 後の raw descriptor 検証は従来どおり exact read になる。

K2 全選択: KaitoKitTests 401（skip 3）、Compat 6、failure 0。UTC golden も成功。

SwiftBuild が「Build complete」後も package lock を保持したため、その実行を terminal interrupt で終了し、K3 以降は `--build-system native --scratch-path <tmp>/p1k-native` を指定する。性能比較も同じ backend で取り直す。フル test target の Release build には lock 待ちも発生したため、性能 probe は同じ試験ファイルだけを含む独立 package で library を参照した。K4 の試行だけは library source の checkpoint を参照し、受入計測は基準 source と最終 source を参照する。

K3 focused: 6 tests、failure 0。一様な 1,000 entry の辞書 storage は 1、8 枠の置換と metadata の境界は成功。golden と差分 fuzz（1,500 件、2.097 秒）も一致。

K3 全選択（上記の選択式から SevenZip を除く）: 合計 282 tests、skip 3、failure 0。UTC golden も成功。

Release の独立した consumer package は、別ファイルの `public import KaitoKit` と
`@_spi(ZipRawLayout) internal import KaitoKit` を testing flags 無しで compile できた。
SPI 指定のない第三のファイルからの呼出しは、`inaccessible due to '@_spi' protection level` で期待どおり失敗した。

## 再現コマンド

```sh
swift build
swift test --filter 'Zip|ZIP|RawEntryRecord|ReopenSharing|AppleDoubleSidecar|SplitVolume|StoredDirectRead'
TZ=UTC swift test --filter ZipPublicValueGoldenTests
swift test
swift build -c release
KAITOKIT_ARCHS=arm64 Scripts/build-framework.sh
KAITOKIT_ZIP_SCALE_PROBE="<corpus>/zip500k.zip" swift test -c release -Xswiftc -enable-testing --filter ZipScaleProbe
```

実行環境の cache と debug-info の調整は上記 Step 0 を参照。各 acceptance criterion の最終結果と Release 計測は後続節を参照。

## Corpus と fuzz の seed

3 corpus はすべて 500,000 entries。追加の UT / descriptor corpus は仕様の名前、固定日時、1 B の本文、
13 B の UT extra で生成した。descriptor corpus は seek できない出力へ書いた。

| corpus | local 領域の byte 数 | SHA-256 |
| --- | ---: | --- |
| zip500k.zip | 40,382,843 | `4abde50f80cbf36287fa3fccc8959c48e5e64c4a1e8340604b544041c651a3ab` |
| zip500k-ut.zip | 32,000,000 | `0b17c82458b2df56760d70a313b8b0e71b52e6d20f2f4b9941d6ae01e50170cd` |
| zip500k-dd.zip | 40,000,000 | `46ef1a4e8b6409789e2ce56c905174ac26f5e22b9269517632e3a93868e62bbd` |

差分 fuzz の入力は 12 件の小さな stored record、`descriptor-true-3`、`sfx-true`、`aes128-ae2`、
`shuffled`。PRNG seed は `0x50314bf022` から `0x50314bf026`。各 300 回、flip / overwrite / truncate / insert。
昇順と逆順それぞれ新しい reader で `.standard` と `.disabled` を比較する。
CRC 表記の 100 万個の乱数は seed `0x50314bc32`、並べ替えは `0x50314b`。

ASan / UBSan の seed pool は凍結 manifest の単一ファイル ZIP 全 264 件（既存 30 件を含む）。
native split / numbered split の 2 セットは単独 ZIP にならないため pool から除き、golden / window 試験で検証する。
`mutate.py` の既定 seed は `20260906`、変異は flip / overwrite / payload-flip / payload-overwrite /
truncate / insert / maxlen の巡回。pool と変異数は別に数える。

## 版の申し送り（作業には含めない）

P1-K と P1b をまとめる場合の予定は KaitoKit 0.11.0 / GyoshukuKit 0.6.0。
P1 を先行 release する場合は P1b を 0.12.0 / 0.7.0 とする。版番号の変更、commit、tag、release は実施しない。

## Framework と sanitizer build

`KAITOKIT_ARCHS=arm64 Scripts/build-framework.sh` の元のコマンドは、script の `env -i` が home の
読取専用 clang cache を選んだため manifest compile で失敗。repository の script は変更せず、
一時コピーの `ROOT_DIR` を `<repo>` に固定し、`run_swift` に上記の writable module cache と
`--disable-sandbox --cache-path <tmp>/p1k-spm-cache --build-system native --jobs 2 -debug-info-format none`
を渡して再実行した。この実行は成功し、arm64 framework を生成・署名した。
2 個の公開 `KaitoKit.swiftinterface` に `ZipRawLayout` / `ZipRawRecordLayout` / `zipRawRecordLayout` /
`centralHasZIP64Extra` / `localHasZIP64Extra` の出現は 0。binary module の SPI は引き続き利用可能。

`Scripts/fuzz/build-asan.sh` は成功（23.27 秒）。一時 PATH の `swift` wrapper が native backend、
`--jobs 2`、writable cache だけを補った。元の `-sanitize=address,undefined` はそのまま使用。

## 最終の全件と公開値

`swift build` 成功。K4 の後の無指定 `swift test` は 477.35 秒で全件成功。

| 最終 test target | 実行数（skip を含む） | skip | failure |
| --- | ---: | ---: | ---: |
| KaitoKitTests | 1,446 | 47 | 0 |
| KaitoKitCompatTests | 34 | 0 | 0 |
| 合計 | 1,480 | 47 | 0 |

基準から増えたのは新規 22 tests。既存 45 skip の集合は完全一致し、増えた 2 skip は環境変数が未指定の
ZipScaleProbe / ZipScaleProbeSPI だけ。既存試験・期待値の変更はない。
K4 後も凍結 golden は全 266 書庫 × 6 モードで一致。UTC の独立した再実行も成功（4.098 秒）。
差分 fuzz は 1,500 件、0.72498225 秒、差分 0。CRC の 1,024 通り + 境界 5 値 + 100 万乱数も一致。
new window / sharing / SPI / import / name-byte の全試験もこの全件実行に含む。
最終の CHANGELOG 編集後に ReleaseReviewDocumentationTests 10 件も再実行し、failure 0（0.043 秒）。

小さな UT / descriptor 書庫の raw / eager は各 3 reads、100,890 / 102,890 bytes で local 領域と同じ。
2 × 4 MiB と maxMetadataSize 64 の exact read 列、160 B の fill 上限と reopen の空 cache、
並べ替え・SFX・gap・split・4 GiB 超・曖昧 descriptor・故障 source・取消し済み Task の走査も成功。
差分検証の故障 source は SPI だけでなく、新しい reader で公開 raw と stream の内容 / エラーも比較した。

`git diff -U0 -- Sources` の追加 / 削除行に `checkCancellation` はなく、新規 Source にもない。
Step 0 の 3 hash は P1-K 実装完了時点（S2 correction 1 前）でも同じ。

ASan / UBSan: `run-mutants.sh --count 200 --timeout 5 <tmp>/p1k-zip-seeds` は
200 mutants、crash 0 / hang 0 / sanitizer findings 0。
`--count 100 --timeout 5 --password raw-password` も 100 mutants、同じくすべて 0。
count は seed ごとではなく各実行の総変異数。264 件の pool を辞書順に巡回するため、最初の 200 / 100 seed を使用した。

`swift build -c release` も成功（60.10 秒、cache / backend / debug-info の調整は上記）。

## GyoshukuKit の sibling layout

元の sibling checkout で `swift test --package-path <repo>/../GyoshukuKit --scratch-path <tmp>/p1k-gk` を実行し、
compile は成功。ただし試験の出力先が `#filePath` から得た `.build/verification` に固定されており、
読取専用の sibling に書こうとして 298 tests 中 276 failure / 1 skip（21 pass）となった。
この実行を動作の regression とは扱わない。

GyoshukuKit `c0df9fb904eb63ac1bb6e26c2ce94f171a267308` を `git archive HEAD` で
`<tmp>/p1k-sibling/GyoshukuKit` に展開し、隣に最終 KaitoKit checkout への `KaitoKit` symlink を置いた。
GyoshukuKit の source / manifest / tests は byte 単位で変更せず、既存の `../KaitoKit` path 依存で再実行した。
元の GyoshukuKit checkout は clean のまま。

再実行は 298 tests、skip 1、failure 0、494.52 秒で成功。tracked files を元 checkout と比較し、相違は 0。

## K4 の採否

最初の K3 / K4 計測は host load が変化していたため採否に使わず、全 build / test の終了後に
同じ probe source / build 設定から保存した各 Release binary を K3 → (a) → (a+b) → (a) → K3 の順で実行した。
各回 15 opens、K3 と (a) は合計 30 samples の中央値、(a+b) は 15 samples の中央値。
(b) は checkpoint のみで試行し、最終 source には入れていない。

| corpus | K3 ms | (a) ms | (a) の短縮 | (a+b) ms | (b) の追加短縮 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zip500k.zip | 289.011 | 221.187 | 23.468% | 220.406 | 0.353% |
| zip500k-ut.zip | 367.766 | 296.072 | 19.495% | 293.662 | 0.814% |
| zip500k-dd.zip | 364.054 | 296.725 | 18.494% | 295.650 | 0.362% |

(a) は 3 corpus とも 2% を超えるため採用。(b) はすべて 2% 未満のため不採用。
3 corpus の各 500,000 CD records を走査して UTF-8 flag が 0 件であることも確認した。
そのため (b) の小さな差は ASCII shortcut が実行された効果とは解釈しない。
最終の UTF-8 復号は元の Foundation 経路のまま。name / pathComponents の byte oracle と golden は全件成功。

## Release 受入計測（AC11）

各値は 5 回の中央値（ms）。基準は `b518014` の source snapshot、最終版はこの checkout の library を
参照する独立 probe package。両者とも同じ公開 `ZipScaleProbeTests.swift`、最終版だけ同じ
`ZipScaleProbeSPITests.swift` も使用した。probe は `-c release -Xswiftc -enable-testing`、
CLI は testing flag のない `swift build -c release --product kaito`。backend / cache / debug-info の条件は共通。
全 build と full test を終了してから、corpus ごとに基準 → 最終 probe → 基準 CLI → 最終 CLI を順番に実行した。

[TSV（全 samples・read 回数・bytes・K4 gate）](2026-09-25-zip-raw-layout-probe.tsv)を同梱。

| corpus | lazy open 基準 → 最終 | eager open 基準 → 最終 | 公開 raw 基準 → 最終 | 最終 SPI | SPI / 基準 raw |
| --- | ---: | ---: | ---: | ---: | ---: |
| zip500k.zip | 402.137 → 215.851 | 571.540 → 252.704 | 973.396 → 385.112 | 136.584 | 14.032% |
| zip500k-ut.zip | 477.769 → 293.756 | 866.301 → 387.578 | 1193.887 → 431.869 | 183.254 | 15.349% |
| zip500k-dd.zip | 487.160 → 293.375 | 868.438 → 386.577 | 1376.218 → 440.076 | 201.173 | 14.618% |

| corpus | raw local reads 基準 → 最終（公開 / SPI 共通） | 最終 raw local bytes | AC11 read 上限 | CLI open 基準 → 最終 | CLI extract 基準 → 最終 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zip500k.zip | 500,000 → 157 | 40,382,843 | 1248.387 | 434.203 → 246.340 | 1347.747 → 1161.015 |
| zip500k-ut.zip | 1,000,000 → 125 | 32,000,000 | 992.562 | 517.742 → 324.764 | 737.546 → 409.273 |
| zip500k-dd.zip | 1,500,000 → 155 | 40,000,000 | 1236.703 | 514.694 → 324.170 | 736.243 → 409.459 |

SPI は 3 corpus とも基準 raw の 50% 以下。local read 回数は `local bytes / 32768 + 16` 以下で、
読む byte は local 領域を一巡した量と一致。eager / CLI open はすべて基準以下。
元の `zip500k.zip` の CLI open 246.340 ms は仕様の絶対目標 463 ms も満たす。
公開 API の raw も速くなったが、二つの同一性検査は維持している。

probe の eager 全体の local 計数には、変更前からある format detection の 2 reads / 1,024 bytes が含まれる。
window 自体の read / byte 数は raw と同じ。AC5 の ZipReader 直接試験は parsing の read を分けて上限を確認する。

## Acceptance criteria の対応

| AC | 結果 | 実行と根拠 |
| --- | --- | --- |
| 1 | pass | 基準 1,424 + 34、最終 1,446 + 34。既存 skip 集合不変、新規 probe skip 2、failure 0 |
| 2 | pass | Sources 無変更で凍結。全 266 書庫 × 6 モード、K1–K4 と UTC で一致。b518014 で独立生成した JSON と `cmp` 一致 |
| 3 | pass | 全 golden の SPI / 公開 raw、3 呼出順、nil、範囲外、禁止 password provider、local ZIP64 oracle、非 testable SPI import |
| 4 | pass | byte 各位置 256 通り、境界 5、seed 固定の 100 万値で旧 CRC 表記と一致 |
| 5 | pass | 9 window tests。両 policy、read / byte 上限、exact read 列、全凍結 corpus、故障 source、split、4 GiB 超、取消し、reopen |
| 6 | pass | 5 seed × 300 = 1,500 変異、全 entry / raw / SPI / stream、昇順 / 逆順、0.725 秒、差分 0 |
| 7 | pass | 14 種の隣接 metadata と FIFO 置換、COW、論理上限ちょうど / 1 B 不足、1,000 件で storage 1 |
| 8 | pass | 旧 split の byte oracle、bridged / NFC / NFD / CP932 / 全 ASCII / BOM / 不正 UTF-8 / path 上限 |
| 9 | pass（環境調整あり） | Debug / Release build と arm64 framework 成功、公開 interface に SPI 名 0。元の framework command の cache 権限失敗は上記 |
| 10 | pass | ASan / UBSan 200 + 100 mutants、5 秒 timeout、crash / hang / findings はすべて 0 |
| 11 | pass | 上記 3 corpus の全閾値。K4(a) 採用、(b) は 2% 未満で不採用 |
| 12 | pass（配置調整あり） | GyoshukuKit 無変更 snapshot + sibling path 依存で 298 tests、skip 1、failure 0。SPI consumer の Release 成功 / SPI 無しの期待する compile error |
| 13 | pass | Unreleased、design §11、検証 README、本文と TSV。既存 CHANGELOG 見出し不変。本文に実機の絶対 path なし |
| 14 | 未実行・オーケストレータ担当 | KaitoFinder P0b の updater_open / verification_open / reload_open / preparation / commit は本作業では計測していない |

## 実際の再実行方法

通常のコマンドは前節の一覧どおり。この sandbox では次のように SwiftPM 共通設定を渡した。

```sh
export CLANG_MODULE_CACHE_PATH="<tmp>/p1k-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="<tmp>/p1k-module-cache"
swift build --disable-sandbox --cache-path "<tmp>/p1k-spm-cache" --build-system native --jobs 2 --scratch-path "<tmp>/p1k-native"
swift test --disable-sandbox --cache-path "<tmp>/p1k-spm-cache" --build-system native --jobs 2 --scratch-path "<tmp>/p1k-native"
swift build --disable-sandbox --cache-path "<tmp>/p1k-spm-cache" --build-system native --jobs 2 --scratch-path "<tmp>/p1k-native" -c release -debug-info-format none
TZ=UTC xcrun xctest -XCTest KaitoKitTests.ZipPublicValueGoldenTests "<tmp>/p1k-native/arm64-apple-macosx/debug/KaitoKitPackageTests.xctest"
swift test --disable-sandbox --cache-path "<tmp>/p1k-spm-cache" --build-system native --jobs 2 --package-path "<tmp>/p1k-sibling/GyoshukuKit" --scratch-path "<tmp>/p1k-gk"
```

probe harness は platform macOS 26 / Swift v6、library の `.product(name: "KaitoKit", package: "KaitoKit")`
への path 依存と、上記の probe 試験ファイルだけを持つ。最終側の test target は repository と同じ
`InternalImportsByDefault`。harness build / test の module cache は `<tmp>/p1k-isolated-module-cache` に設定した。基準 / 最終でそれぞれ次を実行した（K4 gate のみ checkpoint 版）。

```sh
swift build --build-tests --package-path "<tmp>/p1k-final-harness" --disable-sandbox --cache-path "<tmp>/p1k-isolated-cache" --build-system native --jobs 2 -c release -debug-info-format none -Xswiftc -enable-testing
KAITOKIT_ZIP_SCALE_PROBE="<corpus>/zip500k.zip" swift test --package-path "<tmp>/p1k-final-harness" --disable-sandbox --cache-path "<tmp>/p1k-isolated-cache" --build-system native --jobs 2 -c release -debug-info-format none -Xswiftc -enable-testing --skip-build --filter ZipScaleProbe
"<tmp>/p1k-native/arm64-apple-macosx/release/kaito" bench "<corpus>/zip500k.zip" 5
```

同じ手順を UT / descriptor にも実施。gate は `KAITOKIT_ZIP_SCALE_PROBE_OPEN_ONLY=1` で
公開 probe の lazy open を 15 回実行する追加モードを使用した。既定の 5 回測定は変更していない。

## S2 correction 1: golden の保存量を削減

依頼された保存形式だけの変更。production source は変更せず、266 書庫 / 269 論理ファイル、既存 ZIP 全 30 件、
6 モード、昇順 / 逆順の新規 reader、全公開フィールドと UTF-8 byte、全行の SHA-256 と先頭 / 末尾、
UTC の日時比較を維持した。`publicRows` / `summary` / 比較式は変更前と同じ。

`public-values.json` は Foundation の `NSData.compressed(using: .lzfse)` で圧縮し、
試験も Foundation で展開する。KaitoKit の codec には依存しない。展開した byte は元の JSON と完全一致し、
保存した `public-values.json.sha256` でも毎回検査する。
`large-stored` / `small-ut` / `small-dd` は元の builder と固定 seed（順に 0 / 120 / 120）で生成する。
manifest の元の SHA-256 は全 269 ファイルとも変更せず、生成した byte にも同じ検査を適用する。

| 保存する内容 | 変更前の byte | 変更後の byte |
| --- | ---: | ---: |
| 公開値の JSON / LZFSE | 12,192,438 | 72,795 |
| large-stored.zip.b64 | 2,833,263 | 0（manifest の recipe から生成） |
| small-ut.zip.b64 | 313,138 | 0（同上） |
| small-dd.zip.b64 | 280,717 | 0（同上） |
| zip-golden 全体（README / manifest / hash を含む） | 16,115,312 | 572,286 |

全体は 272 → 270 ファイル、15.369 → 0.546 MiB、**96.45% 削減**。
数値は保存対象の通常ファイルの byte 数の合計で、filesystem の割当量や Git pack 圧縮後の量ではない。

変更後の hash:

- `ZipPublicValueGoldenTests.swift`: `06884fa24266ed364f1030f883af5937f6c274462e164634addde6a8a4d2c394`
- `manifest.json`: `bddb2ba7ecc6461cb1c80aa714abd4a9b5dff662fb9bd8a42accfc13e23312b1`
- `public-values.json.lzfse`: `fc9ef71f72d17da04491fa613e891e34bba25233824bc99136e64698bbc07902`
- 展開後の JSON（変更前と同じ）: `2fbc5230042dbebf38920228980bf6c1973764656cfeb16d748bf029237fdaee`

この修正で再実行した検証:

| 実行 | 結果 |
| --- | --- |
| 最終版 `TZ=UTC swift test --filter ZipPublicValueGoldenTests` + readable dump | 1 test、failure 0、3.768 秒。元の JSON と `cmp` 一致 |
| b518014 snapshot で新しい試験の `KAITOKIT_WRITE_ZIP_GOLDEN=1` と dump | 1 test、failure 0、4.266 秒。再生成 JSON は元の JSON / 最終版の展開 JSON と byte 一致 |
| 無指定 `swift test` | 1,480 tests、skip 47、failure 0、452.999 秒。KaitoKitTests 1,446 / Compat 34 |
| 全件に含まれる非 UTC golden | 266 書庫 × 6 モード、failure 0、2.489 秒 |
| 全件に含まれる差分 fuzz | seed `0x50314bf022`–`0x50314bf026`、1,500 変異、差分 0、0.684963292 秒 |
| failure dump の確認 | 一時 baseline の期待値 1 field を変え、期待どおり failure。`expected.json` は注入値、`actual.json` は元の JSON と byte 一致、`all-rows.json` は全 1,596 キーを保持。基準の fixture は復元済み |

独立再生成に使った snapshot の Sources 全 200 ファイルを `git cat-file` の b518014 と byte 比較し、相違は 0。
この修正では Release / framework / sanitizer / sibling / ZipScaleProbe は再実行せず、上記の P1-K 受入結果を保持した。
再生成、展開、失敗時の `diff -u` コマンドは [golden README](../../Tests/Fixtures/zip-golden/README.md) に記載。
cache / native backend / scratch path は前節の同じ設定を使った。
