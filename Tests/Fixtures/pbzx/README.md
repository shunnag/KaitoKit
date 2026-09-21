# pbzx fixtures

`payload-xz.pbzx.b64` is the `Payload` of a flat package written by macOS `pkgbuild`
(`--compression latest --min-os-version 10.10`) and extracted with `xar`. The layout
(`pbzx` + BE64 chunk size, then BE64 unpacked size / BE64 stored length / xz-or-raw chunk) was
measured black-box from that output (Documentation/verification/2026-09-20-pbzx.md); no Apple
documentation or third-party pbzx source was used. `generate.py` decodes each chunk with the
`xz` CLI, checks the concatenation is an odc cpio that `bsdtar` lists and extracts to the
project-owned inputs, and re-wraps the same cpio as `payload-raw-xz.pbzx.b64` (one stored chunk +
one xz chunk) and the text file as `text.pbzx.b64` (two xz chunks, not a cpio). SHA-256 values
and chunk layouts are in `manifest.json`.

```sh
python3 Tests/Fixtures/pbzx/generate.py
swift test --filter PbzxTests
```
