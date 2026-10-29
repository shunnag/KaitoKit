# LZMA wave-2 instruction experiments

See [the verification report](../../../Documentation/verification/2026-10-29-lzma-wave2.md)
for the decision, assembly counts, provenance, commands, and test results.

`attempts/*.patch` are independent experimental patches against HEAD
`14c25651ba07bddfe483225521fa6e5b15f98b65`. They are retained for reproduction;
their presence does not mean they are applied to the production decoder.

Generate the corpus in a fresh temporary directory:

```sh
bash Tests/Measurement/decode-ab/make-corpus.sh "$W/corpus" --scale 0.25
python3 Tests/Measurement/lzma-wave2/prepare.py "$W/corpus"
```

`prepare.py` uses decode-ab's three BMP pages, converts them with `sips`, and
invokes `7zz a` as a black-box writer for JPEG/color × LZMA/LZMA2 with `-mmt=1`.
It writes `corpus/lzma-cases.json`; the original decode-ab manifest remains intact.

Save a clean HEAD release binary and one separately built binary per patch.
Use the same source path, toolchain, cache, and release options for every build:

```sh
CLANG_MODULE_CACHE_PATH="$W/cache" swift build --disable-sandbox \
  -c release --product kaito -debug-info-format none
```

Run a HEAD-versus-HEAD control, then each independent candidate:

```sh
python3 Tests/Measurement/lzma-wave2/bench.py \
  "$W/bin/head" "$W/bin/head" "$W/corpus/lzma-cases.json" \
  "$W/timings-AA.jsonl" --rounds 7 --reps 9
python3 Tests/Measurement/lzma-wave2/bench.py \
  "$W/bin/head" "$W/bin/N" "$W/corpus/lzma-cases.json" \
  "$W/timings-N.jsonl" --rounds 7 --reps 9
```

Each pair warms the archive, alternates process order by round, and invokes
`kaito bench --threads 1 ARCHIVE 9`. The driver asserts exit status and decoded
byte count. It reports the median of the seven process medians and the median
of the seven paired B/A ratios; those two ratios need not be equal. Output files
must be new, preventing accidental mixing of sessions. Run with builds, tests,
and corpus generation finished.

Byte/error comparisons reuse `../lzma-wave1/Outcomes.swift`, linked independently
against each build's `KaitoKit.o`. The retained JSONL timing samples and
`verification.json` describe the actual run, including binary/input hashes.
