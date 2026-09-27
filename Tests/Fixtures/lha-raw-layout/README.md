# P4-K frozen LHA fixtures

The 31 base64 inputs, 31 `*.golden.json` files and `manifest.json` are unchanged
copies of the orchestrator's P4 Step 0 freeze (`scratchpad/p4/fixtures`, 2026-09-26).
The goldens were produced by `p4/tools/lhadump` against KaitoKit `d35f2da` with
`TZ=Asia/Tokyo`. The manifest records each input's construction, decoded SHA-256,
stored size and logical size. Do not regenerate goldens from the implementation
under test.

`LHAFrozenFixtures` verifies each decoded input's size and SHA-256. The
`level1-large-packed.header.b64` input contains only its 62-byte header; the test
materializer extends a temporary file to 4,294,967,359 bytes as a sparse file.
It does not allocate or read a 4 GiB buffer. The three `lh{4,6,7}-small` goldens
also cover the byte-identical archives in `Tests/Fixtures/lha`.

Run the public-value comparison with:

```sh
TZ=Asia/Tokyo swift test --filter 'LHARawLayout|LHAPublicValueGolden'
```

The dump compares all reader/entry metadata and streams every entry, including
directories, to SHA-256. Errors are frozen values: `tl-S8b` fails to open with
`LHA header CRC mismatch`; `lhark-lh7` fails content reading as truncated;
`level1-large-packed` fails content reading because output exceeds its declared
size. `tl-S11` intentionally retains the original four-entry view.
