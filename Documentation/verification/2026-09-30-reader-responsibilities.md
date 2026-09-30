# Reader の責務整理と検証 (2026-09-30)

`refactor/code-quality` で `6b72047` を基準に、LHA と tar の解析・entry 公開・編集用配置復元、
および入力情報から形式別 reader を組み立てる処理を整理した。公開 API と decoder の hot loop は維持した。

## 所有者と互換性

- `LHAHeaderParser` は level 0–3 の構造・境界・offset を検査し、`LHAEntryPublisher` は名前と metadata を公開する。
  pending entry は公開後に解放する。未公開 member と公開 ordinal の対応は `LHAStructures` に保持する。
- `TarParser` は header と拡張を解析し、`TarEntryPublisher` は名前・link・metadata を確定する。
  reader は immutable な解析結果と COW の layout storage を共有する。
  編集 snapshot の header 範囲復元は `TarEditingLayoutRestorer` が担当する。
- `OpenedArchiveInput` は source、nominal URL、実際に開いた volume、directory anchor、検出 hint を区別し、
  `FormatReaderFactory` に渡す。`ArchiveReader` は stream・password・reopen・抽出を公開する。
  reopen ごとの password/output budget/抽出 provenance の独立性を維持した。
- tar と RAR5 で同一だった extraction path の正規化を `ArchivePath` に集約した。
  DOS drive と root の扱いが異なる LHA の正規化はその形式内に置く。
- LHA の DOS 時刻は parse ごとに一つの `DOSTimestampDecoder` を使う。
  不正な日付は引き続き nil、Unix 拡張の時刻は優先される。

## 検証

Xcode 27.0 (27A266a)、Swift 6.4、macOS の arm64 で実行した。

| 検証 | 結果 |
| --- | --- |
| 変更前の全 `swift test` | 本体 1,562 + compat 34、0 failure、50 skip |
| 変更後の LHA 対象テスト | 178、0 failure、21 skip |
| 変更後の全 `swift test` | 本体 1,565 + compat 34、0 failure、50 skip |
| release CLI (変更前・変更後を別の build directory で作成) | 両方成功 |
| 公開 declaration の source 差分 | 変更なし |
| 7 種の `kaito sha` 全出力比較 | すべて byte 単位で一致 |

追加した 3 テストは、invalid DOS date でも本文を読めること、leap day と複数 member/reopen の一致、
invalid DOS date に Unix 拡張がある場合の優先順位を公開 entry API で確かめる。
skip 数は変更前と同じで、任意の外部 specimen・計測など既存の環境条件による。

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift test
```

## 性能比較

[生成器と比較手順](../../Tests/Measurement/reader-structure/README.md)を使い、同じ toolchain の release CLI を比較した。
変更前は `6b72047`、変更後はこの責務整理の source。計測中は別の build/test を止めた。
各ケース 6 round、各呼び出し 5 repetition。実行順を round ごとに反転した。
数値は round ごとの平均値の中央値 (ms)。

| 入力 | open 前 | open 後 | 変化 | extract 前 | extract 後 | 変化 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| lha-0-ascii.lzh | 42.2745 | 33.0895 | -21.7% | 6.8835 | 6.6660 | -3.2% |
| lha-0-cp932.lzh | 79.5165 | 70.5945 | -11.2% | 6.8805 | 6.7785 | -1.5% |
| lha-2-ascii.lzh | 37.5060 | 38.0740 | +1.5% | 7.1335 | 6.9015 | -3.3% |
| tar-10000.tar | 20.8760 | 21.8505 | +4.7% | 7.2930 | 7.1360 | -2.2% |
| tar-10000.tar.gz | 21.2370 | 22.2210 | +4.6% | 4.2475 | 4.2745 | +0.6% |
| zip-deflate.zip | 0.2440 | 0.2430 | -0.4% | 2.1300 | 2.0950 | -1.6% |
| zip-stored.zip | 0.2415 | 0.2550 | +5.6% | 1.0710 | 1.0880 | +1.6% |

LHA level 0 の open は ASCII で約 22%、CP932 で約 11% 短縮した。
それ以外の open の増加は最大約 1 ms、extract の差は約 −3.2%〜+1.6% だった。
この入力では大きな低下は観測しなかった。metadata の多い書庫と stored/deflate の read の計測であり、
全 codec corpus・GUI 全体・異なる記憶媒体の性能を保証する計測ではない。
全 sample と SHA の一致は [測定結果 JSON](2026-09-30-reader-responsibilities.json) に記録した。

## English

Split format parsing, entry publication, editing-layout restoration and reader construction into named internal owners.
Kept the public API, decoder hot loops, immutable/COW sharing and independent reopen state.
The final suite ran 1,599 tests across the main and compatibility products, with zero failures and the same 50 skips as the baseline.
Seven deterministic release-CLI cases produced identical SHA output. LHA level-0 opening improved;
other measured open increases were at most about 1 ms. These measurements cover the changed metadata/read paths, not overall application performance.
