# StuffIt X JPEG の差分検証

StuffIt X の JPEG 再圧縮（`Sources/KaitoKit/Codecs/StuffItX/JPEG/`）を、利用者から支給された独立の
Python 実装（`inbox/stuffit/tools/`）だけを oracle にして確かめる道具。CI では実行せず、`inbox/` がある
環境でリポジトリの root から実行する。

| ファイル | 入力 | 出力 |
|---|---|---|
| stuffitx-jpeg-vectors.py | `inbox/stuffit/tools/`・`inbox/stuffit-corpus/jpeg/` | checked-in の `Tests/Fixtures/stuffit/slice7-jpeg-vectors.json` |
| verify-stuffitx-jpeg.py | 同じ corpus と、StuffItXJPEGTests が書く `.build/jpeg-<名前>.json`（`--swift-report`） | `.build/jpeg-oracle.jsonl`・`.build/jpeg-oracle-expanded.json` と一致・不一致の集計 |
| stuffitx-jpeg-compare.patch | 外部の `inbox/stuffit-corpus/compare.py` | 二つの CC0 oracle に JPEG 行の期待値を補う差分（`patch -p1` で一度だけ当てる） |

Swift 側は `STUFFITX_JPEG_CORPUS=1 STUFFITX_JPEG_REPORT=release swift test -c release --filter StuffItXJPEGTests`
で `.build/jpeg-release.json` を書く。定数表 `StuffItXJPEGTables.swift` を作る stuffitx-jpeg-tables.py は
Sources/ へ書く生成器なので `Scripts/generate/` にある。

検証記録: `Documentation/verification/2026-09-13-stuffit-slice7.md`（「再現コマンド」）。
