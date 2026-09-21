# UDF fixtures

Nine small disc images (gzip + base64, 4.9–18 KB each) that share one project-owned payload:
a 2,880-byte text file, a 2,304-byte binary, an empty file, a 1-byte file, a Japanese file name,
two symbolic links, a file with a resource fork and an xattr, and a directory three levels deep.
`generate.py` builds them on macOS with the system tools as black boxes; `manifest.json` records
the payload digests, each image's raw size and SHA-256, and the writer used.

| Image | Writer | What it exercises |
| --- | --- | --- |
| `hybrid102.iso` | `hdiutil makehybrid -iso -joliet -udf -udf-version 1.02` | ISO 9660 / Joliet / UDF hybrid; detected as `.iso`, listed from the UDF tree |
| `pure150.iso` | `hdiutil makehybrid -udf -udf-version 1.50` | UDF only, 2048-byte blocks, file entries, raw symlink bodies |
| `udf201-512.img` | `hdiutil create -fs UDF` (newfs_udf 2.01) | 512-byte blocks, extended file entries, inline data, named streams (resource fork, xattr) |
| `udf260-meta.img` | `newfs_udf -b 2048 -r 2.60` on an attached raw image | metadata partition with a mirror file |
| `sparable150-relocated.iso` | synthetic, from `pure150.iso` | sparable partition map; partition packet 0 relocated through the sparing table, original wiped |
| `vat150.iso` | synthetic, from `pure150.iso` | virtual partition map; UDF 1.50 style VAT (trailer with `*UDF Virtual Alloc Tbl`, ICB file type 0) |
| `vat2x.iso` | synthetic, from `pure150.iso` | virtual partition map; UDF 2.x style VAT (152-byte header, ICB file type 248) |
| `icb-two-entries.iso` | synthetic, from `pure150.iso` | readme.txt's ICB is two blocks: direct entry + Terminal Entry (strategy 4); macOS reads it |
| `icb-chain-4096.iso` | synthetic, from `pure150.iso` | strategy 4096 chain (stale DE + Indirect Entry → current DE + TE); **macOS rejects strategy 4096**, so this pins spec-derived behaviour only |

The synthetic images exist because `newfs_udf -m fix-packet` / `-m var-packet -t wo` do not produce
mountable structures on a plain image. Their descriptors follow ECMA-167 3rd edition and OSTA UDF
2.60 §2.2.9 / §2.2.12 (sparing) and §2.2.8 / §2.2.11 plus UDF 1.50 §2.2.10 (VAT). All images except
`icb-chain-4096.iso` were mounted read-only with `hdiutil attach` and returned the payload digests before being checked in
(Documentation/verification/2026-09-21-udf.md). No third-party UDF implementation source was consulted.

```sh
python3 Tests/Fixtures/udf/generate.py   # macOS only; mounts images, needs no elevated rights
swift test --filter UDFReaderTests
```
