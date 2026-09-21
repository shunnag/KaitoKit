# brotli fixtures

Project-owned text / structured binary / random / empty / one-byte / USTAR inputs compressed by
the brotli CLI 1.2.0 (Google, MIT) at `-q 1` / `-q 5` / `-q 11`, `-w 10` / `-w 16` / `-w 17`
and `--large_window=30` (RFC 9841 header). `generate.py` decodes every fixture with the same CLI
before storing it and records archive / payload SHA-256 values and the first header byte in
`manifest.json`. KaitoKit decodes brotli with Apple Compression, so the CLI is the independent
writer / reader oracle. A 300,000-byte stream that spans the 64 KiB detection probe is generated
at test time (`BrotliTests`) because it does not fit the fixture size convention.

```sh
python3 Tests/Fixtures/brotli/generate.py
swift test --filter BrotliTests
```
