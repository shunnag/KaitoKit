# ZIP legacy-method fixtures

PKZIP 1.x archives using Shrink (method 1), Reduce (methods 2-5) and Implode (method 6), built from
project-owned payloads (`manifest.json` lists every payload file's size and SHA-256, and each
archive's size, SHA-256 and the readers that verified it).

| Archive | Method | Coverage | Verified by |
| --- | --- | --- | --- |
| `shrink.zip` | 1 | dynamic LZW growing from 9 to 13 bits, KwKwK codes, no partial clear | unzip, 7zz, deark |
| `shrink-clear.zip` | 1 | 70 KB word salad that fills the 8192-entry table three times: partial clears (`256,2`) and re-use of freed codes | unzip, 7zz, deark |
| `reduce1.zip` … `reduce4.zip` | 2-5 | follower sets of every size 1-32 (a one-element set is indexed with 1 bit), DLE (0x90) escapes, copies with the extra length byte, factor-dependent distance bits | deark |
| `reduce-empty-sets.zip` | 2 | every follower set empty (each byte read as 8 raw bits) | deark |
| `implode-4k-2trees.zip`, `implode-8k-3trees.zip`, `implode-4k-3trees.zip`, `implode-8k-2trees.zip` | 6 | both window sizes × with / without a literal tree, extra 8-bit lengths, Shannon-Fano trees rebuilt per APPNOTE §5.3.8 | unzip, 7zz, deark |

The payload set is text.txt (31,680 bytes of repetitive lines), dle.bin (runs of 0x90 and all byte
values), runs.bin (long single-byte runs), mixed.bin (20,000 semi-random bytes), empty.txt and one.txt.

`generate.py` contains the encoders, written from PKWARE APPNOTE.TXT 6.3.10 §5.1-5.3 prose only, and
extracts every archive with the readers named above before writing the base64 files. Reduce is checked
by deark alone because macOS's unzip is built without UNREDUCE and 7-Zip has no Reduce decoder; deark
also refuses overlapping Reduce copies, so those fixtures contain none. `experiments/` holds the
black-box scripts that settled the Shrink partial-clear convention and a large-payload sweep
(Documentation/verification/2026-09-21-zip-legacy.md). No third-party Shrink / Reduce / Implode
implementation source was consulted.

```sh
python3 Tests/Fixtures/zip-legacy/generate.py   # needs unzip, 7zz and deark on PATH
swift test --filter ZipLegacyMethodTests
```
