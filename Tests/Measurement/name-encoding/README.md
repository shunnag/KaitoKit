# ファイル名の文字コード判定の測定

`Sources/KaitoKit/Text/` の判定器（EncodingDetector・NameEncodingCandidates・NameEncodingScorer ほか）の
正解率・規則の発火・関数別の時間を、`swift test` とは別に測る道具。CI では実行しない。リポジトリの root で実行する。

| ファイル | 入力 | 出力 |
|---|---|---|
| make-name-corpus.py | `inbox/name-corpus/raw/<lang>.txt` | `.build/name-corpus/{names.tsv,archives.tsv,summary.json}`（`--split tune/eval`） |
| measure-name-detection.py | kaito CLI、任意の `inbox/bench/udet`、`--corpus` | `--out-dir` の report.md / report.json。`--self-check` は入力なしで codec 表を検査 |
| name-rule-firing.swift | names.tsv（Text/ の判定器のソースと一緒に `swiftc` でコンパイル） | 規則の発火の TSV |
| report-name-rule-firing.py | names.tsv・`inbox/name-corpus/raw`・発火の TSV | 発火率の Markdown |
| report-name-encoding-c.py | `.build` に残した report / runs | 検証記録の比較表 |
| compare-name-scoring-sharing.py | 共有 ON の report.json と共有 OFF の kaito | 固定の 8 コマンドの stdout が byte 一致するか |
| profile-name-scoring.py | Text/ の 8 ファイル（計測用のコピーをコンパイル） | `--out-dir/profile`（関数別の時間） |
| make-name-encoding-fuzz-seeds.py | `Tests/Fixtures/encoding/names-multilingual.tsv` | `Scripts/fuzz/run-mutants.sh` へ渡す seed の ZIP |
| test-name-corpus.py・test-name-measurement.py | 上の生成器と測定器 | unittest（手で実行する） |

`inbox/` は .gitignore の対象で clean checkout には無い。make-name-corpus.py と report-name-rule-firing.py、
test-name-corpus.py の RFC 1456 の検査は、`inbox/` がある環境でだけ動く。
`LanguageExemplars.swift` を作る make-exemplars.py は Sources/ へ書く生成器なので `Scripts/generate/` にあり、
test-name-corpus.py はそこから import する。

検証記録: `Documentation/verification/2026-09-14-name-encoding-{baseline,baseline-c,multilingual,languages,thai-rule}.md`。
