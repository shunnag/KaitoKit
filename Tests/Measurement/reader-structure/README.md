# Reader の構成変更の比較 / Reader structure comparison

`measure-readers.py` は metadata が多い LHA level 0 (ASCII / CP932)・level 2、tar・gzip tar と、
200 entry の stored / deflate ZIP を作る。書庫を commit せず、指定したディレクトリへ生成する。
LHA は stored 64 byte × 10,000 member、tar も同じ件数と本文、ZIP は 64 KiB × 200 member。
生成器は Python 標準ライブラリと独立した stored LHA header の組み立てだけを使う。

The script generates deterministic stored LHA, tar, compressed tar and ZIP inputs with Python's standard
library. It first compares complete `kaito sha` output, then alternates the two release executables in
six rounds, reversing their order each round. Each call to `kaito bench` uses five repetitions. The JSON
report retains all samples and median ratios. No archive contents are written to an extraction directory.

```sh
python3 /path/to/KaitoKit/Tests/Measurement/reader-structure/measure-readers.py generate /tmp/reader-inputs
python3 /path/to/KaitoKit/Tests/Measurement/reader-structure/measure-readers.py compare /tmp/reader-inputs \
  --before /path/to/before/kaito --after /path/to/after/kaito --output /tmp/reader-results.json
```

両 binary は同一 toolchain の release 構成で作り、計測中は build / test を止める。
`kaito` は static に KaitoKit を組み込むため、framework の探索パスには依存しない。
比較先が違う source から作られたことを build log と git revision で確認する。

This measures the changed metadata/open paths and stored/deflate reads, not the complete codec corpus
or GUI performance. Preserve the normal public-value, raw-layout, recovery, volume and reopen tests.
See [2026-09-30 verification](../../../Documentation/verification/2026-09-30-reader-responsibilities.md).
