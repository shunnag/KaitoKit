# ISO 9660 fixtures

`joliet.iso.gz.b64` is written by macOS `hdiutil makehybrid -iso -joliet`.
`rr-joliet.iso.gz.b64` is written by `xorriso -as mkisofs -R -J -no-pad`.
Both tools are used only as black-box writers; their implementation sources were not read.

Project-owned input files:

- `a.txt`: UTF-8 `hello iso 9660 test payload` followed by LF.
- `data.bin`: 4096 bytes, byte i = `(i * 13) % 251`.
- `日本語ファイル.txt`: UTF-8 `日本語の内容` followed by LF.
- `sub/nested.txt`: UTF-8 `nested payload` followed by LF.
- RR image only: symbolic link `link` → `sub/nested.txt`.

Generate Joliet before adding the symlink, then generate RR + Joliet.
Trim each image to the PVD Volume Space Size (LE32 at 32848) times the logical
block size (LE16 at 32896), gzip with `mtime=0`, and base64 encode with 76-column
wrapping. Image timestamps make writer output non-reproducible byte for byte.
SHA-256 values are recorded in `../NOTICE`. The two encoded fixtures total 3,730 bytes.

The tests decode the gzip through KaitoKit's existing gzip reader; no new runtime
or test dependency is required. `ISOImageBuilder` creates structural edge cases
from the published specification field tables in memory.

## zisofs fixtures (2026-09-20)

`zisofs-32k.iso.gz.b64` and `zisofs-128k.iso.gz.b64` are written by
`xorriso -outdev … -padding 0 -zisofs level=9:block_size=32k|128k -map src / -set_filter_r --zisofs /`
(GNU xorriso 1.5.8, black-box writer) from `generate-zisofs.py`. Inputs are project-owned:
`text.txt` (84,000 bytes of repeated lines), `zeros.bin` (70,000 zero bytes, every block becomes a
zero pointer), `mixed.bin` (40,000 zeros + 8,000 seeded random bytes + 30,000 zeros), `small.txt`
(`tiny`), `empty`, `sub/deep.txt` (`deep ` × 3,000). SHA-256 values are printed by the generator and
fixed in `ISOZisofsTests`. Each image is 133,120 bytes before gzip. libarchive's `--options zisofs`
writer was not used: its 3.7.4 / 3.8.9 output for `text.txt` fails to decode in libarchive itself
(`zisofs decompression failed (-3)`), so it is neither a writer nor a reader oracle here.
