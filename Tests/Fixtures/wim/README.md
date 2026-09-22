# WIM fixtures

Windows Imaging archives built from a project-owned payload (`manifest.json` lists every payload
file's size and SHA-256, and each archive's size and SHA-256).

| Archive | Writer | Coverage |
| --- | --- | --- |
| `stored.wim` | `generate.py` (own writer) | uncompressed resources, an alternate data stream (`readme.txt:Zone.Identifier`), a hard-link pair, an empty file (zero hash, no resource), a relative symbolic-link reparse point, a Japanese name, nested directories |
| `xpress.wim` | `generate.py` (own [MS-XCA] LZ77+Huffman encoder) | XPRESS chunks, multi-chunk files, an incompressible chunk stored raw, E8-heavy data |
| `xpress-4k.wim` | `generate-chunk-sizes.py` → 自作 encoder | 4 KiB chunk、複数 chunk、70,001 byte file、SHA-1 / SHA-256 |
| `xpress-64k.wim` | 同上 | 64 KiB chunk、64 KiB を超える file、SHA-1 / SHA-256 |
| `lzx.wim` | `generate.py` (own WIM-variant LZX encoder) | verbatim and aligned-offset blocks, E8 translation, multi-chunk files, a stored chunk |
| `lzx-raw.wim` | `generate.py` | as above plus an odd-length uncompressed block at the end of a chunk (no trailing pad byte) |
| `two-images.wim` | `generate.py` | two metadata resources sharing file resources; listed below `1/` and `2/` like 7-Zip |
| `sevenzip-copy.wim` | 7-Zip 26.03 `7zz a -twim` | an independent stored writer |

`lzx-raw.wim.b64` is 50 KB, above the usual ~40 KB fixture budget, because the odd-length raw block
variant keeps part of each multi-chunk file uncompressed; the other archives stay under 41 KB.

`generate.py` extracts every archive with 7-Zip (`7zz x` / `7zz t`) and compares the payload before
writing the base64 files, so the compressed samples are validated by an independent decoder. The
container follows Microsoft's public "Windows Imaging File Format (WIM)" whitepaper; the WIM-specific
LZX details (no E8 header bit, translation size 12,000,000, the block-size flag, stored chunks, no pad
byte at a chunk end) and the 102-byte DIRENTRY fixed part were pinned black-box against a
Microsoft-written `boot.wim` (Documentation/verification/2026-09-21-wim.md). No third-party WIM, LZX
or XPRESS implementation source was consulted.

```sh
python3 Tests/Fixtures/wim/generate.py   # needs 7zz on PATH
python3 Tests/Fixtures/wim/generate-chunk-sizes.py   # 追加した 2 本だけ再生成
swift test --filter WIMReaderTests
```
