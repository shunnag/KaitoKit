# StuffIt X slice 4 検証記録

日付: 2026-09-13。対象: bd `cooViewer-gu28.4`、worktree `kk-stuffit`、ブランチ `feat/stuffit`。

## 実装結果

compression 0（Brimstone）、6（Iron version 0）、Blend submethod 3、前処理 0（English）・2（x86）を追加した。
既存の range decoder と coordinator を使用し、前処理後の出力を checksum と fork 分割へ渡す。
最初の到達点である CC0 StuffIt 7 Mac `.sitx` の catalog/list は成功した。
SMSSenderPro3osx.sitx は通常 Reader / CLI で開き、全 95 entry の名前・長さ・SHA-256 が支給期待値と一致した。

指定された native profile と旧 vector、および支給比較スクリプトの期待値の層には相違がある。
旧期待値や入力ファイルを変更せず、後述の通り区別して検証した。
そのため「旧 Iron 4 vector の出力も native decoder で一致」と「支給 compare.py が mismatch 0」は
文字通りには達成していない。別 profile への自動切替や、fixture 固有の runtime 分岐は実装していない。

## 入力と出自

実装入力は Ch.09、Ch.08、Ch.42、Ch.10、Ch.38、Ch.07 §2、stuffitx-vectors.json、
english-dictionary.txt の指定 8 ファイル。すべて SHA256SUMS と一致した。
archive-verification.json も `c127aacee4f7580af31dde584424acbdab1e575319cfa06c8bbd6fe4db5023f7`
で SHA256SUMS と一致した。コーパス・支給オラクル・支給 compare.py は変更していない。

XADMaster、The Unarchiver、stuffit-go、libxad、PPMd を含む外部実装ソースと Web は参照していない。
既存 KaitoKit の PPMd ソースも参照していない。Brimstone は Ch.09 の記述だけから実装した。
既存の StuffIt X・ByteSource・Decompressor・ReadLimits・CRC32 の契約に従った。

English 辞書の出自は「XADMaster 内蔵の StuffItXEnglishDictionary.c を展開した語リスト
(`research/THIRD_PARTY_DATA.md`)。利用者が 2026-09-13 に組み込みを決定」。
同じ出自を Swift ファイル先頭、NOTICE、design.md §10 に記載した。

- 語数: 100,366、LF 込みの長さ: 881,863 バイト。
- SHA-256: `6095ebdbadd794ac50fe5b53b12a744b5833e046658777ee37dcb6da82512a31`。
- writer: Python 標準 zlib、level 9、raw Deflate（`wbits=-15`）。
- 配布形式: `StuffItXEnglishDictionary.swift` の単一 base64 文字列リテラル。SwiftPM resource bundle は使用しない。
- 初回使用: KaitoKit の DeflateDecompressor で展開し、長さ・SHA-256 を確認して `[Substring]` に分割する。
  `static let Result` が成功・失敗を一度だけ保持する。
- XCTest は展開済み語列から入力を再構成し、生成スクリプトの `--check` を実行する。inbox がなくても実行する。

## Brimstone

arena は明示的な byte offset を使用する。context の 12 バイトと state の 6 バイトは
Swift の構造体のサイズ・alignment に依存させず、field を個別に読み書きする。
`floor(2^e / 12)` unit の予算とは別に、null offset 用の 12 バイトを確保する。
38 クラス、gap の高位端からの context 確保、低位端からの配列確保、LIFO free list、
大きいクラスの split、先に確保する grow、既存空き block を優先する shrink を再現した。
隣接 block を coalesce しない。解放済み block の先頭を free-list link に使う。

A / D / F、placeholder、order deficit、補助 suffix 更新、no / one / two-level skip promotion を区別した。
binary table、escape estimator、exclusion、promotion 用参照列は固定長ポインタ。
モデル class が Swift Array を保持することはなく、offset に対する検査を context 処理の境界に集約した。
restart は arena・graph・確率・exclusion を初期化し、既存 range coder を継続する。
指数 31、order 0、初期 graph が入らない予算は拒否する。欠けた successor を作って復号を継続しない。
単独の既知長出力と Blend は指定長で停止し、中間長未知の経路は root の外への escape を終端にする。

実装順は allocator → 初期 graph / binary / 多状態復号 → graph 更新 → promotion → restart。
9 vector の全出力が chunk 1 / 4096 で一致した。引数がない先頭 3 本は order 4・1 MiB とした。
イベント付き 6 本では次の全項目が支給数値と一致した。

| vector | restart | rescale | promotion | 新状態 | 多状態→一状態 | suffix hit | fast transition |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| random order 4 / 4 KiB | 137 | 0 | 3846 | 4990 | 0 | 4770 | 0 |
| random order 4 / 64 KiB | 7 | 0 | 2346 | 17994 | 0 | 17599 | 0 |
| random order 4 / 1 MiB | 0 | 5 | 2678 | 19747 | 0 | 17528 | 0 |
| changing order 2 / 64 KiB | 0 | 79 | 18 | 61 | 4 | 53 | 19933 |
| changing order 4 / 64 KiB | 0 | 20 | 323 | 1004 | 4 | 864 | 18929 |
| changing order 8 / 64 KiB | 1 | 0 | 2196 | 3983 | 0 | 2375 | 15985 |

allocator 単体では gap と free list の優先順位、残余 11 unit の 10+1 分解、LIFO、
grow 失敗時の旧内容保持、shrink の移動・残余再利用も検証する。

## Iron と旧 vector

Ch.42 の native 固定頻度上限 `(64,64,256)` を唯一の production profile とした。
最初の 3 個の宣言指数は符号付き 32 bit の正値上限まで読み、shift や確保量へ変換しない。
Ch.42 で constructor が設定した上限を parameter reader が再計算しないと確認されていること、
利用者が native を指定したことが採用理由である。通常の vendor header `(6,6,8)` では両解釈が一致する。
確率 shift は 1〜31。二重 binary weight は平均で決定した後、それぞれ固有の shift で更新する。

N は `2^31−1` 以下、圧縮 block の N×6 は maxDictionarySize 以下、ST4 は N<`2^23`。
線形 scratch は byte column、UInt32 link、byte history/mark の計 6N バイト。
モデルと pair histogram の固定長領域は別に保持する。ST4 の bit 23 は alias の印としてのみ使用し、
所有者の cursor を共有する。BWT は安定した occurrence permutation を移動してから出力する。
空 raw block を終端にせず、次の block を読む。圧縮 33 は未対応。

支給 106×4 の header は **宣言指数 `(4,5,6)`**、実際の符号化上限は `(16,32,64)`。
これらの入力・期待値は slice4-vectors.json に変更せず保存し、native decoder が拒否することを検証した。
同じ平文を native 上限で符号化した 4 本、および 2048 run を超える履歴・反復 context・複数 block を含む
4 本を、Ch.08 / Ch.42 から独立に作った Python writer で固定した。
writer は区間選択を記録し、最終 code から逆算して正規化 octet を決める。外部 encoder は利用しない。
BWT と ST4 の forward sort から既知の平文を作り、復元結果を chunk 1 / 7 / 4096 で確認した。

旧 4 本の native での拒否、native 8 本の出力一致、4096 個の空 raw block の後の継続、
巨大な未使用宣言指数、確率 shift、N×6・ST4 の上限、primary、終端と余剰 byte を検証する。

## English / x86 と pipeline

English は 4 marker、bijective base-52 の各 digit ごとの上限、case toggle、terminator の escape、
EOF で終わる token を扱う。marker が等しい場合の escape / uppercase の優先順位も維持する。
5 vector を常時実行し、短い prefix、escape 不足、index 範囲外、最終長の過不足を検査する。

最終 fork 長を中間 decoder に渡さないため、Codec.make の size を optional にした。
Brimstone・Iron に加え、既存 Cyanide・Darkhorse・Deflate・Blend・RC4-stored・未圧縮も、
中間長が未知なら圧縮形式または入力範囲の終端まで読む。出力量は maxTotalUncompressedSize で制限する。
既知長での既存挙動は保持する。Blend の未知長経路は次の有効 header を探し、末尾の走査対象が尽きれば終了する。

前処理は一つの decoder を要素全体で保持する。checksum は前処理後の byte に掛ける。
人工の一バイト frame と一バイト fork で、word token・case・x86 operand が境界を跨ぐこと、
逆順アクセスでの再起動、前処理前の CRC を与えた場合の拒否を検証した。
Deflate と English の組合せでは中間長が最終長より長い場合と短い場合の両方を確認した。

x86 は Ch.38 の native 規則で候補に六バイトを要求する。五バイトだけの末尾は変換しない。
4 vector のうち旧期待値が異なる 2 本を次のように区別している。

| vector | native の期待値 |
| --- | --- |
| x86-address-0 | `e806000000`（全五バイトを保持） |
| x86-address-1 | `616263e90700000058595ae8ffffffff`（最後の命令を保持） |
| x86-address-2 / 3 | 元の期待値と一致 |

補正は `a−p−6`、到達可能な mask 0/2/4/8、shift 16/8/0、25 bit 符号拡張に従う。
抽象閉包も再計算し、post-candidate 51 状態、pre-candidate 27 状態、accepted mask 4 種と一致した。
Ch.38 の検証 helper と同じ `2×入力長+16` の補正作業上限を採用した。
これは形式全体で反復が二回以内という主張ではなく、破損入力に対する明示的な資源 profile である。

## 実行コマンド

slice 3 と同様、cache を worktree 内へ置き、Release はデバッグ情報なしで実行した。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
STUFFITX_CORPUS="$PWD/inbox/stuffit-corpus" STUFFITX_VERIFY_STREAMS=1 STUFFITX_INVENTORY=slice4-inventory.json swift test -c release -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItX
python3 Scripts/fixtures/make-stuffit-english-dictionary.py --check
python3 Scripts/fixtures/make-stuffit-iron-vectors.py --check
git diff --check
```

最終の全体 XCTest は KaitoKit 997 tests（40 skip）+ Compat 23 tests、合計 1,020 tests、失敗 0。
Debug build とテストのコンパイラ警告は 0。外部コーパスを有効にした Release 検証は
43 tests、1 skip、失敗 0、5.394 秒。skip は本 slice で変更していない既存の 32 MiB Deflate 距離検証。
Brimstone / Iron / English / x86 の固定 vector はすべて常時実行した。
Blend の `blend-all-four-submethods` は全出力一致へ更新し、旧 31 バイトだけの検証を置き換えた。

## 指定 compare.py の出力と追加照合

```sh
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only sitx
```

支給スクリプトを変更せず実行した結果（exit 1）:

```text
match: 4
name_diff: 0
no_oracle: 4
kaito_error: 28
mismatch: 12
```

28 error は暗号 16、Root recovery 10、JPEG を含む書庫 2。いずれも対象外の明示的な拒否だった。
4 no_oracle は Mac 7 の通常版と comment 版の `.sitx`（Mac 9 / Mac OS X）。
12 mismatch はその 4 書庫の `.as` / `.bin` / `.hqx` wrapper。
支給 oracle/cc0 の 12 ファイルは**内側の圧縮書庫自体**の単一 SHA であり、展開後の entry 群ではない。
例えば mac9.sitx wrapper の期待値は 2074 bytes / `f557d88b0ebde7b85f230e36ff6ae16247d2a623eedae721a8a96532e6cec963`。
スクリプトの説明文にある archive-verification.json の fallback は本体には実装されていなかった。
従ってこの集計を codec の SHA 不一致として隠したり、成功した compare.py として報告したりはしない。

```sh
python3 Tests/Fixtures/stuffit/verify_slice4_corpus.py .build/out/Products/Release/kaito
```

追加照合は指定 archive-verification.json の名前付き fork と通常 CLI `sha --forks` を比較する。
Mac 7 の同じ CC0 ファイル集合の 16 変種は、Mac 9 レコードの名前付き全 fork と比較した。
Windows の期待値は対応する research record または oracle/cc0 を使用する。
12 wrapper の内部 bytes も、別途支給の圧縮書庫 SHA と一致した。

```text
CC0: match=20, partial_jpeg=2, encrypted=16, recovery=10, mismatch=0, sha_forks=156, wrapper_sha=12
```

156 は全 fork を表示する CLI の非空出力。JPEG を含む 2 書庫については、成功した対応 fork を照合し、
各一つの JPEG entry だけが未対応であることを確認した。20 match にその 2 書庫を加算していない。
圧縮書庫 SHA 12 件も展開後 fork の一致件数に加算していない。

## perf 5 本

すべて通常 CLI `sha` と `sha --forks` が exit 0。外部 XCTest が全 stream CRC を確認した。
以下の SHA 一致 entry 数は directory と空 data entry を含む通常 CLI の行数。
CRC fork 数は非公開 auxiliary ではなく、この 5 書庫の実際の data/resource fork の数である。

| 書庫 | 通常 entry | 名前・長さ・展開後 SHA 一致 entry | CRC 一致 fork | 展開後 SHA 未収録 fork | 通常 sha 秒 |
| --- | ---: | ---: | ---: | ---: | ---: |
| SMSSenderPro3osx.sitx | 95 | 95 | 63 | 1 resource | 3.782 |
| BirdFluWAVE.sitx | 20 | 20 | 31 | 14 resource | 0.687 |
| warriors_screen.sitx | 1 | 1 | 2 | 1 resource | 0.146 |
| theconceptosx.sitx | 1 | 0 | 1 | 1 data | 0.200 |
| Tickershock.sitx | 1 | 0 | 1 | 1 data | 0.101 |

時間はこの環境で一回測った値で、ベンチマークの反復平均ではない。
BirdFluWAVE の `Icon\r` はオラクルの実 CR と CLI の表示用 escape を正規化して比較した。
SMSSender の表示順はオラクルと異なるが、95 個すべての `(名前,長さ,SHA-256)` の多重集合が一致した。
English stream は 97 / 103 / 109 / 110 の 4 本。これらを含む全 63 fork が CRC 検証を通過した。

指定のコマンド:

```sh
.build/out/Products/Release/kaito sha inbox/stuffit-corpus/perf/SMSSenderPro3osx.sitx
```

95 entry を出力し、末尾は次の通り（exit 0）。total は CLI の出力順に依存するため、
オラクルの total と同値であるとの主張ではない。

```text
total  95  8672fcc7047f88bad6bab26bbc722061233381d404d781eabb633601acec3d2e
```

残る 4 本の通常 CLI の total:

```text
BirdFluWAVE.sitx   total  20  905c7a17ea33aaba8242c58eeea3327ebef3d77a2a02c56dc17cfb3098b074b3
warriors_screen.sitx total 1  99746ed592134f84f17e57ab28ff0ec6da43cd20ea12707b67f5f09e656741a2
theconceptosx.sitx total   1  d2e8172e2d7cfe4799dbdf8abf4258247b7bc85c0d559679ed3ae3444f98c92b
Tickershock.sitx  total    1  1e17138931befc3c3bf57db94d9c7f160eccd13e49a1fb9ab1081a3fa0d95e5c
```

theconceptosx / Tickershock の支給オラクルは MacBinary 内の圧縮 `.sitx` の SHA。
それぞれ 1,803,385 / 937,644 バイトの圧縮書庫の一致を別に確認した。
実際の展開結果 1,834,476 / 960,034 バイトの SHA は次の通りで、支給の展開後期待値はない。

```text
theconceptosx: 8aab8f7d62872ec85ed0e5f82fe3960e2a2791c5d315015c1d51f7a1811a2a7d
Tickershock:   9e5c9bec7057ddc3c4bc6a7113af742316ecd1ade55946f9ac7113b86e5c63d6
```

合計 98 fork の CRC が一致。展開後 SHA 不在の 18 fork は CRC 検証までとし、
通常 Reader / CLI と直接 coordinator の出力一致も検査した。

## 変更ファイル

本体の新規ファイル（すべて `Sources/KaitoKit/Codecs/StuffItX/`）:

- StuffItXBrimstoneAllocator.swift / StuffItXBrimstoneModel.swift / StuffItXBrimstoneDecoder.swift
- StuffItXIron.swift（ST4 を含む）
- StuffItXEnglish.swift / StuffItXEnglishDictionary.swift / StuffItXX86.swift

本体の接続変更:

- StuffItXCodec.swift、StuffItXBlend.swift、Formats/StuffItX/StuffItXStreamCoordinator.swift
- StuffItXCyanide.swift、StuffItXDarkhorse.swift、StuffItXDeflate.swift、StuffItXRC4Stored.swift
  （English の未知の中間長を扱うため）

テスト・生成物・文書:

- 新規 StuffItXSlice4Tests.swift / StuffItXIronTests.swift / StuffItXPreprocessingTests.swift
- 更新 StuffItXCodecTests.swift / StuffItXReaderTests.swift / StuffItXFixtureTests.swift / StuffItXCorpusTests.swift
- Tests/Fixtures/stuffit/slice4-vectors.json / slice4-iron-native-vectors.json / verify_slice4_corpus.py
- Scripts/fixtures/make-stuffit-english-dictionary.py / make-stuffit-iron-vectors.py
- README.md / CHANGELOG.md / Documentation/design.md §10・§11 / Tests/Fixtures/NOTICE / 本記録

ログは `.build/slice4-*.log` / `.err`、stream の検査結果は `.build/slice4-inventory.json`、
集計は `.build/slice4-corpus-summary.json`。git checkout / restore / stash / reset / commit / push は実行していない。


## 最終差分での再実行

最終の Brimstone 参照表も固定バッファに置き、prefix の order / exponent / メモリ上限を
range 初期化前に検査する状態で再実行した。全コマンドのコンパイラ警告は 0。

```text
swift build: Build complete! (0.35秒)、exit 0
swift test: Build complete! (0.24秒)、exit 0
  KaitoKit: Executed 997 tests, with 40 tests skipped and 0 failures in 279.992 seconds
  Compat: Executed 23 tests, with 0 failures in 0.813 seconds
swift build -c release --product kaito: Build complete! (36.23秒)、exit 0
Release の外部コーパス検証: 43 tests、1 skip、0 failures、5.394秒、exit 0
指定 compare.py: match 4 / name_diff 0 / no_oracle 4 / kaito_error 28 / mismatch 12、exit 1
追加 verify_slice4_corpus.py: match 20 / partial_jpeg 2 / encrypted 16 / recovery 10 / mismatch 0、exit 0
辞書と Iron native vector の --check: 一致、exit 0
git diff --check: 出力なし、exit 0
```

全体テストに表示される `zip error: Not supported (Compression method bzip2 not enabled)` は
既存テストが起動する外部 zip の環境診断であり、コンパイラ警告や XCTest の失敗ではない。
最終ログは `slice4-final-build.log` / `slice4-final-all-tests.log` / `slice4-final-release.log` /
`slice4-final-release-tests.log` / `slice4-final-compare.log` / `slice4-final-corpus-verification.log`。
各 perf の 95 / 20 / 1 / 1 / 1 行の出力は `.build/slice4-<書庫名>-sha.log` に保存した。

## orchestrator による独立検証(slice 3 + 4)

Codex の検証とは別に、orchestrator が release / ASan の `kaito` を組み直して実施した。

**XADMaster が開けない StuffIt 7 Mac `.sitx`。** `testfile.stuffit7_dlx.mac9.sitx` と `…comment.sitx` の
非空 fork 9 本(data / resource)の (length, sha256) が `archive-verification.json` の独立検証値と
**完全一致**。mac9 / macx1 × comment × 素 / `.as` / `.bin` / `.hqx` の 16 変種すべてが同一の fork 集合を返す。

**実書庫(`perf/`)。**

| 書庫 | compression | 結果 | `kaito sha` 実時間 |
|---|---|---|---:|
| SMSSenderPro3osx.sitx(56.8 MB、95 entry) | Cyanide 17 MB + Brimstone 3.7 MB(English 前処理 4 stream)+ Darkhorse 1.8 MB | 非空 62 entry すべて XADMaster と一致 | 3.49 秒 |
| BirdFluWAVE.sitx(10.7 MB) | Cyanide | 17 entry 一致 | 0.64 秒 |
| warriors_screen.sitx | Cyanide | 一致 | 0.14 秒 |
| theconceptosx.sitx / Tickershock.sitx(MacBinary 包み) | Cyanide | **XADMaster は内側を開けない**。KaitoKit は stream CRC-32 一致で展開し、取り出した `theConcept.dmg` を `hdiutil imageinfo` が正しい UDZO イメージとして認識(2004 年の checksum つき) | — |
| Windows 2009 / 2010 `.sitx` | Iron + JPEG + RC4-stored | Iron の txt / png は一致。JPEG(compression 7)は未対応(slice 7) | — |

**compare.py の mismatch 12 の正体。** いずれも StuffIt 7 Mac `.sitx` の変種で、XADMaster が開けないため
ハーネスが wrapper を 1 entry として見た XADMaster 出力を期待値に使ってしまう構造上の問題。上の
`archive-verification.json` との一致と 16 変種の同一性で代替した。残る `kaito_error` 28 は暗号(slice 6)、
recovery Root(見送り)、JPEG(slice 7)のみ。

**敵対的入力(ASan)。** `.sitx` と `.sitx.{bin,as,hqx}` 48 書庫に、切り詰め 7 段・先頭 4 KiB の bit 反転 40・
全体 bit 反転 24・payload 乱数化 3 を流した。**3,552 実行で sanitizer 報告・crash・タイムアウトは 0。**

**テスト。** `swift test` 1,020 件(997 + 23)、40 skip、失敗 0、`warning:` 0。

**性能の早期シグナル(`kaito bench` vs `xadbench extract`、各 3 回の中央値)。**
SMSSenderPro3osx.sitx: kaito 3,368 ms / XADMaster 5,413 ms(**KaitoKit が 1.6 倍速い**)。
BirdFluWAVE.sitx(Cyanide): 637 / 625 ms、warriors_screen.sitx: 134 / 123 ms(kaito は resource fork も
展開するため数十 KB 多い)。Cyanide はほぼ同等、classic method 13 の 1.9 倍遅は slice 5 の対象。
