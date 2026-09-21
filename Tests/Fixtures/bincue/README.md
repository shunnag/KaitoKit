# Raw-sector CD image fixtures (BIN/CUE)

`generate.py` wraps two existing project-owned images — `../iso/rr-joliet.iso.gz.b64` (xorriso, Rock
Ridge + Joliet, 38 sectors) and `../udf/pure150.iso.gz.b64` (newfs_udf, UDF 1.50) — into raw CD sectors
laid out per ECMA-130 §14, and writes two cue sheets. `manifest.json` records each image's size and
SHA-256 and the source images' SHA-256.

| Fixture | Sector | User data | Notes |
| --- | --- | --- | --- |
| `mode1.bin` | 2352, Mode 1 | @16 | zero trailer |
| `mode1-garbage.bin` | 2352, Mode 1 | @16 | pseudo-random bytes in the EDC / ECC positions |
| `mode2-subheader.bin` | 2352, Mode 2 | @24 | opaque 8-byte sub-header (`00 00 08 00` ×2) |
| `mode2-plain.bin` | 2352, Mode 2 | @16 | no sub-header |
| `mode1-2448.bin` | 2448, Mode 1 | @16 | 96 pseudo-random sub-channel bytes after each sector |
| `mode2-2336.bin` | 2336 | @8 | sub-header + user data + trailer, no sync / header |
| `udf-mode1.bin` | 2352, Mode 1 | @16 | the pure UDF image; detected as `udf` |
| `mode1-truncated.bin` | 2352, Mode 1 | @16 | `mode1.bin` minus its last 100 bytes (trailer only) |
| `mode1.cue`, `multi.cue` | — | — | quoted LF sheet; CRLF sheet with an audio track first and a `C:\IMAGES\…` Windows path |

The EDC / ECC fields are **not** valid codes (KaitoKit never reads them), so these are fixtures for the
user-data mapping, not valid CD sectors. No installed tool reads raw-sector images; the generator
verifies each image by stripping the framing back and comparing with the source image, and the tests
compare entries and contents with the plain ISO / UDF readers. No third-party raw-sector implementation
source was consulted (Documentation/verification/2026-09-21-bincue.md).

```sh
python3 Tests/Fixtures/bincue/generate.py
swift test --filter RawSectorImageTests
```
