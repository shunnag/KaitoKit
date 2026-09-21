# MacBinary / AppleSingle / BinHex fixtures

Six wrappers around a plain 823-byte text payload (with `0x90` bytes and a long run so BinHex's
RLE90 is exercised) and a 416-byte resource fork, written by `generate.py` from the same public
descriptions the reader uses. Before they are stored, The Unarchiver's `lsar` and `unar` list each
file and extract both forks byte for byte (`manifest.json` records the result per file, plus the
payload SHA-256 values).

| File | Wrapper | Notes |
| --- | --- | --- |
| `readme.txt.bin` | MacBinary II (with the `mBIN` MacBinary III signature) | data + resource fork |
| `kanji.bin` | MacBinary II | Shift_JIS file name `テスト.txt` |
| `noresource.bin` | MacBinary II | no resource fork |
| `readme.txt.as` | AppleSingle v2, big-endian | Real Name, File Dates Info, Finder Info entries |
| `readme-le.txt.as` | AppleSingle v2, little-endian magic `00160500` | same entries |
| `readme.txt.hqx` | BinHex 4.0 | RLE90 + 6-bit transport, header / fork CRCs |

```sh
python3 Tests/Fixtures/macwrappers/generate.py   # needs lsar / unar
swift test --filter MacWrapperTests
```
