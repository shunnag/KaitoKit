# 2026-10-12 RAR5 先行復号の保持上限（KaitoKit 0.14.1）

0.14.0（`fd0741d`）の `RAR5EntryPrefetcher` は実行中の batch 数だけを worker 数に制限していた。
復号が終わると実行枠が空くため、取得されていない出力を残したまま次の batch を投入できた。
`ReadLimits.parallelDecodeMemory` の予算が大きい環境では、ゆっくり読む利用者のために
書庫全体を先に復号して保持し得る。

## 再現時の実測

報告された M4 Max での 0.14.0 の計測。Compat の `contents(ofEntry:)` を200 ms間隔で1件ずつ呼んだ。
今回の修正後のメモリ計測値ではない。

| 入力 | 0.14.0 の観測 |
|---|---|
| `-m3` の実 JPEG 65枚、26 MB | 11件目で71 MB |
| テキスト300件、205 MiB | 10件目で228 MB、CPU 0.71 s |
| 同じテキスト、`decodeThreads = 1` | 5.5 MB、CPU 0.04 s |

## 修正

`schedule(after:)` の投入条件に `batches.count < 2 * workers` を加えた。
7z の `SevenZipFolderPrefetcher.hasWindowRoom` と同じく、実行中と復号済み未取得の batch の合計を
worker 数の2倍以下に抑える。既存の実行枠と byte 予算の検査も続ける。
`take` が batch の最後の出力を取得するか、読み飛ばした batch を捨てると、次の `schedule(after:)` が再開する。
batch の組み立て・decoder・出力の検証・失敗時の直列復号には変更がなく、公開 API は維持する。

tar 編集の差分 fuzz は macos-26-intel の push CI（run `38135308440`）で128.9秒となり、
120秒の上限を超えた。x86_64 だけ360秒へ広げ、arm64 の120秒と変異・比較の検査を維持する。

## 構造による回帰テスト

`@testable import KaitoKit` で偽の `candidate` / `decodeBatch` から prefetcher を直接作る。
internal の `waitForScheduledBatchesForTesting()` は condition で復号の完了を待ち、
復号済み未取得の状態を作る。sleep や壁時計で消費速度を調整しない。

- `testSlowConsumerKeepsCompletedBatchesWithinPrefetchWindow`:
  worker 数2・3・8（共有 pool の capacity まで）、大小の byte 予算で、1件ずつ schedule → 完了待ち → take を繰り返す。
  各段階で保持 batch 数が worker 数の2倍以下、保持 byte 数が予算以下であることを検査する。
  window が満杯になったこと、再開後に全 member の正しい byte 列が一度ずつ返ったことも検査する。
- `testDroppingPassedBatchesReopensPrefetchWindow`:
  window を満たし、追加投入が止まることを確認する。先の member の取得で通過済み batch を捨てたあと、
  再び window が満ちることと、残りの全 member の byte 列・保持上限を検査する。

投入条件を変更する前に最初のテストを実行し、終了コード1で失敗した。出力の抜粋:

```text
XCTAssertLessThanOrEqual failed: ("6") is greater than ("4") - scheduled member 2
XCTAssertLessThanOrEqual failed: ("6") is greater than ("4") - completed member 2
Executed 1 test, with 2 failures (0 unexpected)
```

条件の変更後は新規2件とも成功した（0失敗）。

## 実行環境とコマンド

macOS 27.2 / arm64、Xcode 27 の Swift 6.4。
`test -w .` は終了コード0。SwiftPM の既定 module cache への書き込みは sandbox に拒否されたため、
cache を書き込み可能な `<tmp>` へ移し、SwiftPM の subprocess sandbox を無効にして実行した。
性能比較用の base の release build では dSYM 生成も拒否されたため、両側の build に
`-debug-info-format none` を使った。最適化は release のまま。

以下の `spm` は、実際に使った共通オプションをまとめた表記。

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/kaitokit-0141-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kaitokit-0141-module-cache
spm() {
  swift "$@" --disable-sandbox \
    --cache-path /tmp/kaitokit-0141-swiftpm-cache \
    --config-path /tmp/kaitokit-0141-swiftpm-config \
    --security-path /tmp/kaitokit-0141-swiftpm-security
}

# 条件の修正前: 終了1。
spm test --filter 'RAR5PrefetchTests.testSlowConsumerKeepsCompletedBatchesWithinPrefetchWindow'
# 修正後の新規2件: 終了0。
spm test --filter 'RAR5PrefetchTests.testSlowConsumerKeepsCompletedBatchesWithinPrefetchWindow|RAR5PrefetchTests.testDroppingPassedBatchesReopensPrefetchWindow'

spm test --filter 'RAR5'
spm test --filter 'TarEditDifferentialFuzzTests'
spm test --filter 'Documentation|ReleaseReview|MigrationGuide'
KAITO_EXECUTABLE="$PWD/.build/release/kaito" spm test \
  --filter 'Tar|SevenZipFolderPrefetchTests|LeafDecodePoolTests|CLISmokeTests' \
  --skip 'TarEditDifferentialFuzzTests'
spm build -c release -debug-info-format none
git diff --check
```

| 検証 | 結果 |
|---|---|
| RAR5 | 132件、0失敗 |
| TarEditDifferentialFuzzTests | 2件、0失敗。2,400変異、差分0、35.91 s |
| Documentation / ReleaseReview / MigrationGuide | 15件（KaitoKit 11件 + Compat 4件）、0失敗 |
| Tar / 7z prefetch / LeafDecodePool / release CLI の追加検証 | 179件（KaitoKit 178件 + Compat 1件）、既存3 skip、0失敗。Tar splice は7,000変異 |
| release build | 成功、64.57 s |
| git diff --check | 終了0 |

追加検証の skip は LHA の外部 corpus 1件と、明示的な入力・設定を必要とする tar 大規模 probe 2件。

全件の `swift test` はここでは実行せず、オーケストレーターが別途実行する。

## 速く読み切る CLI 経路の照合

0.14.0（`fd0741d`）を `git archive` で `<tmp>/kaitokit-0141-base` に取り出し、
同じ toolchain・build オプションで release CLI を新しく build した。
入力は固定の文字列から作った2 KiBのテキスト50,000件（計102,400,000 byte）を
`rar -ma5 -m3` で圧縮した非 solid RAR5。書庫は8,179,677 byte、SHA-256 は
`16f01b6ebe84b69c7a4c3c9a7ef37d20e36cf1ce4ea8e379ebb0a9187514844a`。

自動並列数と `--threads 1` / `3` / `16` の通常の `kaito sha` を両側で実行し、
stdout が完全一致し、終了コードはすべて0だった。stdout の SHA-256 は全設定で
`6fc6000eaeb713332b0dfaddc3b2521ab247b8bd6baf1980b879d0ae0548364d`。

既存の `Tests/Measurement/decode-ab/ab.py` で base 対 base の5回の交互計測を行い、
次に base 対修正後を5回ずつ2組測った。計測中に build / test は走らせなかった。
`time -l` の `sysctl kern.clockrate` が sandbox に拒否されたため、harness の
`perf_counter` / `wait4` の代替を使った。この入力での経路の確認であり、他の書庫や GUI の性能を表さない。

| `sha --sink` | base best / median（s） | 修正後 best / median（s） | best 比 | peak RSS best（MB、base → 修正後） |
|---|---:|---:|---:|---:|
| 1組目 | 0.3339 / 0.3357 | 0.2700 / 0.2722 | 0.8086 | 342.0 → 189.5 |
| 再計測 | 0.3268 / 0.3314 | 0.2643 / 0.2662 | 0.8087 | 342.5 → 189.5 |

base 対 base の `sha --sink` の各 round の比は0.9734〜1.0119、best 比は0.9881。
この入力では速く読み切る経路の性能低下は見られず、window の上限による保持量の減少も確認できた。

実行した harness のコマンド（出力は `<tmp>/kaitokit-0141-perf` に保存）:

```sh
python3 Tests/Measurement/decode-ab/ab.py \
  --base /tmp/kaitokit-0141-base/.build/release/kaito --same --base-rev fd0741d \
  --rounds 5 --manifest /tmp/kaitokit-0141-perf/manifest.json \
  --out /tmp/kaitokit-0141-perf/noise.jsonl
python3 Tests/Measurement/decode-ab/ab.py \
  --base /tmp/kaitokit-0141-base/.build/release/kaito --branch .build/release/kaito \
  --base-rev fd0741d --branch-rev fix/rar5-prefetch-window-working-tree \
  --rounds 5 --manifest /tmp/kaitokit-0141-perf/manifest.json \
  --out /tmp/kaitokit-0141-perf/ab.jsonl
# 同じ引数で --out だけ ab-repeat.jsonl に変えて再計測した。
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaitokit-0141-perf/noise.jsonl
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaitokit-0141-perf/ab.jsonl
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaitokit-0141-perf/ab.jsonl --metric max_rss
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaitokit-0141-perf/ab-repeat.jsonl
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaitokit-0141-perf/ab-repeat.jsonl --metric max_rss
```
