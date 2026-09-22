# WIM / XZ / 旧 GNU sparse tar の補完（2026-09-22）

実装・個別検証は一時 worktree で行い、その変更は `release/0.9.0` に統合済み（`cd2e747`）。当時の作業では main repository は変更せず、git コマンド・install・commit・push は実行していない。

## 環境と入力

実行した版確認の出力（抜粋）:

```text
$ 7zz i
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
$ bsdtar --version
bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8
$ xz --version
xz (XZ Utils) 5.8.4
liblzma 5.8.4
$ python3 --version
Python 3.14.7
$ swift --version
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.2.0
```

- WIM: repo 内の Microsoft WIM whitepaper（`inbox/wim/wim.txt` / `.rtf`）、[MS-XCA]、既存の自作 XPRESS encoder、7zz の黒箱出力。
- XZ: public domain の [`xz-file-format.txt` v1.2.1](https://tukaani.org/xz/xz-file-format.txt) §5.3.2 の ID 表（`0x0B` = RISC-V）だけを追加入力とした。filter の実装や他節のコードは取り込んでいない。
  shell のダウンロードは `curl: (6) Could not resolve host: tukaani.org` で失敗したため、既存 xz の同梱文書 `/opt/homebrew/share/doc/xz/xz-file-format.txt`（同版）を `inbox/xz/` へ複製した。44,512 byte、SHA-256 は次のとおり。
- tar: OS 同梱 `/usr/share/man/man5/tar.5`（BSD-2-Clause）の GNU header / sparse 拡張の記述と、bsdtar / Python tarfile の黒箱読み取り。

```text
acc324b995261e6d9d5793c6a504639a6dfe97f2ccaf3cf8667f20a2486fc85b  xz-file-format.txt
```

第三者の archive 実装 source（wimlib / 7-Zip / GNU tar / libarchive / xz / Python tarfile 等）は開いていない。

## A. WIM XPRESS の chunk size

`WIMResourceDecompressor` は XPRESS の 4〜64 KiB の 2 冪を受理する。LZX は 32 KiB のまま。
範囲外・非 2 冪は従来の `unsupportedMethod("WIM chunk size N")`。`length <= chunkSize + 64 KiB` は変更せず、64 KiB chunk の入力上限は 128 KiB。
chunk 表の `maxMetadataSize`、entry / 合計サイズ上限、resource SHA-1 検証も維持した。
XPRESS には従来 `maxDictionarySize` 検査が無かったため、match 履歴になる chunk size を初期化時に検査する。
64 KiB を許す設定では成功し、65,535 byte の設定では `limitExceeded`。LZX の辞書検査も維持した。

自作 encoder に `chunk_size` 引数を追加し、既定の 32 KiB は維持した。
追加 fixture は `xpress-4k.wim.b64` / `xpress-64k.wim.b64`。内容は 28、12,503、70,001 byte の自作 file 3 本。
4 KiB 版は多数の chunk、64 KiB 版は full chunk と端数を通る。manifest に payload の SHA-1 / SHA-256 と書庫の SHA-256 を加えた。

```text
$ python3 Tests/Fixtures/wim/generate-chunk-sizes.py
7zz x: xpress-4k.wim: 3 files byte-identical
xpress-4k.wim: 11969 bytes
7zz x: xpress-64k.wim: 3 files byte-identical
xpress-64k.wim: 2552 bytes
```

既存 fixture は再生成しない追加用 generator を実行した。通常の `generate.py` からも同じ追加関数を呼ぶ。
作業開始時の SHA-256 / manifest と照合した出力:

```text
Existing WIM fixtures: 6 byte-identical; all previous manifest rows unchanged
```

中間の chunk size も確認した。自作 `build_wim` に各値を渡し、`probe.bin = (bytes(range(251)) * 279)[:70001]` を
`7zz x` で展開して byte 比較した。2 KiB も同じ writer で生成して `7zz t`。LZX は既存 `lzx.wim` の header offset 20 の UInt32LE だけを 65,536 にして `7zz t` を実行した。

```text
7zz x: XPRESS chunk 4096: 70001 bytes byte-identical
7zz x: XPRESS chunk 8192: 70001 bytes byte-identical
7zz x: XPRESS chunk 16384: 70001 bytes byte-identical
7zz x: XPRESS chunk 32768: 70001 bytes byte-identical
7zz x: XPRESS chunk 65536: 70001 bytes byte-identical
7zz t: XPRESS chunk 2048: exit 2
ERROR: <tmp>/xpress-2048.wim
<tmp>/xpress-2048.wim
Open ERROR: Cannot open the file as [wim] archive


ERRORS:
Is not archive

7zz t: LZX header chunk 65536: exit 2
ERROR: <tmp>/lzx-header-65536.wim
<tmp>/lzx-header-65536.wim
Open ERROR: Cannot open the file as [wim] archive
```

Swift 回帰テストは両 fixture の一覧・SHA-1 / SHA-256・小分け読み取り・`reopen()`、XPRESS 2048 / 4097 / 65535 / 131072 と LZX 65536 の名前付き拒否、辞書上限、128 KiB + 1 byte の圧縮入力拒否を確認した。

## B. XZ RISC-V のエラー分類

非終端 filter ID が `0x0B` なら `XZResourceValidator` が native decoder の前に
`unsupportedMethod("XZ RISC-V filter")` を返す。ID `0x03`〜`0x0A`、他の未知 ID、最終 filter の判定は変更していない。

```text
$ python3 Tests/Fixtures/singlefile/generate-xz-filters.py
xz -dc: riscv.xz: 1984 bytes byte-identical; SHA-256 9406f5a1d2eae369f59bda2104d34080e67c608f7379941a8f722774acf2caa6
xz -dc: riscv.tar.xz: 10240 bytes byte-identical; SHA-256 82431d350820b09e137c71b9df7c7e14fe6e9fb72c9bc8c57f5d236d18c35440
xz -dc: x86.xz: 1984 bytes byte-identical; SHA-256 9406f5a1d2eae369f59bda2104d34080e67c608f7379941a8f722774acf2caa6
```

生成コマンドは `xz -k --threads=1 --riscv --lzma2=preset=1 <input>`（対照は `--x86`）。
tar は Python tarfile の USTAR writer を使用した。`xz -vv --list` の filter 欄はそれぞれ
`--riscv --lzma2=dict=1MiB` / `--x86 --lzma2=dict=1MiB`、RISC-V の最低版表示は `5.6.0`。
base64 を一時 file へ戻して実行した CLI の出力:

```text
kaito sha riscv.xz: exit 1
0	ERROR	failed entry 0: Unsupported archive method: XZ RISC-V filter	riscv
partial	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	
error: failed entry 0 (riscv): Unsupported archive method: XZ RISC-V filter
error: 1 archive entries failed
kaito sha riscv.tar.xz: exit 1
error: Unsupported archive method: XZ RISC-V filter
kaito sha x86.xz: exit 0
0	1984	9406f5a1d2eae369f59bda2104d34080e67c608f7379941a8f722774acf2caa6	x86
total	1	a74aeb9a61ee06a7f44d806fac1dd07aa62d83464fcd975bb2de5c82c911a324	
```

Swift 回帰テストは `.xz` / `.tar.xz` のエラー値、連結 stream 後半の RISC-V、x86 の byte 一致を確認した。

## C. 旧 GNU sparse tar

`ustar  \0` と `S` 型を検査し、offset 386 の 4 descriptor、482 の継続 flag、483 の実サイズを読む。
拡張 block は 21 descriptor と offset 504 の継続 flag。numbytes 0 で map を終え、継続 block 自体は flag が 0 になるまで消費する。
拡張 block と fragment の件数を `maxMetadataRecordCount`、header 内 map 96 byte と拡張 block の合計を `maxMetadataSize` で制限する。
`TarSparseMap` が順序・重複・実サイズ内・格納長一致を検査し、`TarSparseDecompressor` が穴を埋める。
`uncompressedSize` は実サイズ、`compressedSize` は fragment 合計。`sparse=GNU.sparse old` と `sparseFragmentCount` を公開する。
GNU header の atime / ctime / sparse 領域は ustar prefix として使わない。

`TarSparseTests` の自作 builder が 2 / 6 / 26 fragment（拡張 0 / 1 / 2 block）、空 file、後続通常 member、穴だけの file を生成する。
3・5 byte 等の非整列 fragment を padding せず連結し、本文全体だけ 512 byte に揃えた。
各書庫を `bsdtar -xf <archive> -C <out> <member>` と `python3 -c <tarfile reader> <archive>` で読み、期待する展開 bytes の SHA-256 と照合した。

```text
old GNU contiguous-2: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 85bc86310d7b7d0192b29d5afa7b54d1edb470daa6f936c55ead60fec42d47a9
old GNU extension-1: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 a556f744bb6d47ea05a696c540ad21528c4ec7ff5e2fc8880443df346386de10
old GNU extension-2: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 afc045865ca63e5e22d4b27ca1c638c8c5da60a88d8329bb7cd612d91b818205
old GNU empty: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
old GNU following: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 a556f744bb6d47ea05a696c540ad21528c4ec7ff5e2fc8880443df346386de10
old GNU holes-only: bsdtar -xf / python3 tarfile / KaitoKit SHA-256 9f1dcbc35c350d6027f98be0f5c8b43b42ca52b7604459c0c42be3aa88913d47
```

一覧、実サイズ / 格納長、7 byte ごとの stream、`reopen()`、後続 member も照合した。
重複・降順・実サイズ超過・格納長不一致は `malformed`、欠けた拡張 block は `truncated`。
fragment 数・metadata byte 数・entry サイズ・合計サイズ・空拡張 block 連鎖の上限も確認した。
star の `SCHILY.filetype=sparse` / `SCHILY.realsize`、Solaris の `SUN.holesdata` は `unsupportedMethod` を維持した。

## 前提・資料と異なった点

- 実環境の版は「bsdtar 3.7.4」ではなく **bsdtar 3.5.3 / libarchive 3.7.4**。冒頭の実出力による。
- WIM whitepaper の header offset 20 は `dwCompressionSize` で、説明は圧縮 `.wim` file の byte 数。chunk-size 欄という説明ではない。repo の `inbox/wim/wim.txt` の header 定義と `CompressionSize` 段落を確認した。chunk size としての解釈・可変サイズの受理は上記 7zz の黒箱結果に基づく。
- tar(5) の fragment ごとの 512 byte padding という説明は、今回の両 reader の結果と一致しない。本文全体だけの padding で全 6 ケースが一致した。GNU tar writer そのものは今回実行していない。
- XPRESS 経路の辞書上限検査は従来存在せず、今回追加した。圧縮入力の slack 上限は変更していない。

## build / test

通常の `swift build` は書込み不可の `<home>/.cache/clang/ModuleCache` で失敗した。
cache を一時領域に移した後も SwiftPM の二重 sandbox が失敗したため、以下の設定で検証した。
初回の WIM filter は CLI 探索だけ失敗（新規 WIM テストは通過）し、既存の `KAITO_EXECUTABLE` 設定で再実行した。

```text
<unknown>:0: error: error opening '<home>/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: <home>/.cache/clang/ModuleCache: Operation not permitted
sandbox-exec: sandbox_apply: Operation not permitted
failed: caught error: "commandFailed(\"built kaito executable was not found\")"
```

```sh
cd <repo>
export CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-small-method-gaps/clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kaitokit-small-method-gaps/module-cache
export KAITO_EXECUTABLE=/tmp/kaitokit-small-method-gaps/build/out/Products/Debug/kaito
swift build --disable-sandbox --scratch-path /tmp/kaitokit-small-method-gaps/build --cache-path /tmp/kaitokit-small-method-gaps/swiftpm-cache
swift test --disable-sandbox --scratch-path /tmp/kaitokit-small-method-gaps/build --cache-path /tmp/kaitokit-small-method-gaps/swiftpm-cache --filter WIM
swift test --disable-sandbox --scratch-path /tmp/kaitokit-small-method-gaps/build --cache-path /tmp/kaitokit-small-method-gaps/swiftpm-cache --filter XZ
swift test --disable-sandbox --scratch-path /tmp/kaitokit-small-method-gaps/build --cache-path /tmp/kaitokit-small-method-gaps/swiftpm-cache --filter Tar
swift test --disable-sandbox --scratch-path /tmp/kaitokit-small-method-gaps/build --cache-path /tmp/kaitokit-small-method-gaps/swiftpm-cache --filter ReleaseReviewDocumentationTests
```

実出力（各 target の集計行）:

```text
Build complete! (7.01秒)

WIM:
Executed 9 tests, with 0 failures (0 unexpected) in 0.919 (0.920) seconds
Executed 1 test, with 0 failures (0 unexpected) in 0.008 (0.008) seconds

XZ:
Executed 19 tests, with 0 failures (0 unexpected) in 2.925 (2.927) seconds

Tar:
Executed 97 tests, with 1 test skipped and 0 failures (0 unexpected) in 6.670 (6.678) seconds
Executed 1 test, with 0 failures (0 unexpected) in 0.086 (0.086) seconds

ReleaseReviewDocumentationTests:
Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.016) seconds
```

Tar の skip は `LHACompatibilityCorpusTests.testUnixSymbolicLinkCorpusPublishesAndExtractsTargets`。
filter `Tar` が `Targets` にも一致したためで、`KAITOKIT_LHA_CORPUS` 未指定による既存の外部コーパステストの skip。旧 GNU sparse の検証は skip 無し。

## 変更ファイル

作業開始時の file SHA-256 と照合した一覧。git の差分は使用していない。

| 区分 | file |
| --- | --- |
| 変更 | `CHANGELOG.md` |
| 変更 | `Documentation/design.md` |
| 変更 | `Documentation/verification/README.md` |
| 変更 | `README.md` |
| 変更 | `Sources/KaitoKit/Formats/SingleFile/XZResourceValidator.swift` |
| 変更 | `Sources/KaitoKit/Formats/Tar/TarReader.swift` |
| 変更 | `Sources/KaitoKit/Formats/WIM/WIMStructures.swift` |
| 変更 | `Tests/Fixtures/NOTICE` |
| 変更 | `Tests/Fixtures/wim/README.md` |
| 変更 | `Tests/Fixtures/wim/generate.py` |
| 変更 | `Tests/Fixtures/wim/manifest.json` |
| 変更 | `Tests/KaitoKitTests/TarSparseTests.swift` |
| 変更 | `Tests/KaitoKitTests/WIMReaderTests.swift` |
| 変更 | `Tests/KaitoKitTests/XZResourceLimitTests.swift` |
| 追加 | `Documentation/verification/2026-09-22-small-method-gaps.md` |
| 追加 | `Tests/Fixtures/singlefile/generate-xz-filters.py` |
| 追加 | `Tests/Fixtures/singlefile/manifest.json` |
| 追加 | `Tests/Fixtures/singlefile/riscv.tar.xz.b64` |
| 追加 | `Tests/Fixtures/singlefile/riscv.xz.b64` |
| 追加 | `Tests/Fixtures/singlefile/x86.xz.b64` |
| 追加 | `Tests/Fixtures/wim/generate-chunk-sizes.py` |
| 追加 | `Tests/Fixtures/wim/xpress-4k.wim.b64` |
| 追加 | `Tests/Fixtures/wim/xpress-64k.wim.b64` |
| 追加 | `inbox/xz/SHA256SUMS` |
| 追加 | `inbox/xz/xz-file-format.txt` |
