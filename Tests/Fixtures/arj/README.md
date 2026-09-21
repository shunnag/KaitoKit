# ARJ fixtures

Archives written by `generate.py`'s own ARJ writer around project-owned payloads. Method 1 members are
compressed by the generator's own LZ77 + static-Huffman encoder, written from the public description of
the LHA lh5/lh6 bit stream, because the CC0 Archive Team wiki documents ARJ methods 1–3 as that stream
with a 26 KB window; the container follows the ARJ TECHNOTE.TXT of the ARJ 2.86 distribution (see
Documentation/verification/2026-09-21-arj.md for both). `manifest.json` records every payload file's
size and SHA-256 and each archive's size, SHA-256 and the readers that verified it.

| Archive | Coverage | Verified by |
| --- | --- | --- |
| `basic.arj` | format version 11, PATHSYM (`/`) names, two directories, method 1 (26 KB and 30 KB members, the latter crossing the window), stored, an empty member, a CP932 name | 7zz, deark, unar |
| `backslash.arj` | the same members with DOS `\` separators (no PATHSYM flag) | 7zz, deark, unar |
| `sfx.exe` | an MZ stub (containing a decoy header id whose CRC does not match) followed by the archive, as in a DOS self-extractor | 7zz, unar |
| `nodata.arj` | adds a method 9 (no data) member, which 7-Zip lists but cannot extract | 7zz listing |
| `garbled.arj` | README.TXT flagged GARBLED with its bytes xor 0x5A; readers must refuse it | — |

7-Zip writes the CP932 name as raw bytes and unar decodes it as CP1252, so that member is matched by
content. No ARJ writer is installed here; every stored archive was extracted with the readers named
above and compared with the payload first. No third-party ARJ or LHA implementation source was consulted.

```sh
python3 Tests/Fixtures/arj/generate.py   # needs 7zz, deark and unar on PATH
swift test --filter ARJReaderTests
```
