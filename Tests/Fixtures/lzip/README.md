# lzip fixtures

Project-owned inputs framed by `generate.py` per draft-diaz-lzip-14 §2 around a raw LZMA1
stream from Python's standard `lzma` module (lc=3, lp=0, pb=2, end marker). `bundle.tar.lz`
is written by the OS `bsdtar --lzip` instead. Every fixture is decoded by XZ Utils
(`xz -d --format=lzip`, an independent reader) and compared with the original bytes
before it is stored. `manifest.json` records archive and payload SHA-256 values, member
layouts and dictionary sizes. No lzip / plzip / lzlib / libarchive / XZ Utils source was read.

```sh
python3 Tests/Fixtures/lzip/generate.py
swift test --filter LzipTests
```
