# AppleDouble sidecar fixtures

`finder.zip.b64` is a ZIP written by macOS `ditto -c -k --sequesterRsrc --keepParent`, the same
call Finder's "Compress" uses, so it carries `__MACOSX/…/._name` AppleDouble sidecars. `mac.tar.b64`
is the same tree written by macOS `tar` (bsdtar), which stores the sidecars as `._name` next to each
file. The payload is `folder/plain.txt` (an xattr but no resource fork), `folder/rsrc.txt`
(resource fork `RSRC-DATA-1234\n`) and `folder/sub/deep.txt` (resource fork `DEEP-RSRC`).
`generate.sh` rebuilds both; `SHA256SUMS` pins the archives. The AppleDouble layout
(magic 00051607, version 2, entry table, resource fork = entry 2) follows Apple's public
"AppleSingle/AppleDouble Formats for Foreign Files" developer note; no third-party source was used.

```sh
Tests/Fixtures/appledouble/generate.sh
swift test --filter AppleDoubleSidecarTests
```
