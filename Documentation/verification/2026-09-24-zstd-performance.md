# M10: Swift zstd decoder performance

Measured in `KaitoKit-m10` on branch `feature/2026-09-24-review-m10`, with baseline
`d412a021d6c7241ce7a9712ea6c8c505c6391cac`. No public API changes or commits.
The tools were Apple Swift 6.4 (Swift 6 language mode), arm64, and zstd 1.5.7.

The benchmark uses 256 MiB of generated text: the sorted Swift source files,
followed by the sorted Markdown documentation at the baseline revision, repeated
and truncated to 268,435,456 bytes. The seed contains 272 files / 5,453,414 bytes.
The text SHA-256 is
`d4cf7b60689a9f44517fb226da2b3a468a1f87d70751972ea3abfe924227961c`.
`bsdtar -cf - text | zstd -3 -T0` produced an 80,899,715-byte archive.

Final measurements ran after all builds and tests finished. Each Kaito number is
the median reported by `kaito bench FILE 3`, using the retained baseline binary
and the final Release binary on the same files.

| Archive | Before open (ms) | After open (ms) | Before extract (ms) | After extract (ms) |
|---|---:|---:|---:|---:|
| 256 MiB `text.tar.zst` | 1,449.075 | **513.479** | 21.072 | 21.277 |
| Existing `zstd-l1.7z` fixture | 0.134 | 0.096 | 0.588 | **0.041** |
| Existing `zstd-l19.7z` fixture | 0.108 | 0.111 | 0.647 | **0.043** |

The tar.zst open is **2.82× faster**, meeting the **600 ms** target. Its open phase
includes full decompression to staging and tar parsing; extraction reads the staged
file. The 7z fixtures each produce 263,430 bytes and exercise long matches; their
extraction improvements are 14.34× and 15.05×. Their sub-millisecond timings should
be interpreted as small-fixture measurements.

| Reference command / sink | Median of 3 (ms) |
|---|---:|
| `zstd -q -dc text.tar.zst > /dev/null` | 210.021 |
| `zstd -q -dc text.tar.zst > reference.tar` | 209.192 |

The remaining ratio to the reference CLI is **2.45×** on this generated corpus.
Reference timings include process startup; Kaito's reported open interval excludes
CLI startup. All 268,435,456 extracted bytes matched both the original text and the
reference `zstd` + `bsdtar` output using `cmp`. Raw results are in
`.build/m10/benchmark.json` and `.build/m10/final-benchmark.log`.

| Validation | Result |
|---|---|
| `swift build` (Debug) | Passed |
| `swift build -c release --product kaito` | Passed; final rebuild 61.58 seconds |
| `swift test` (complete package) | 1,458 tests, 49 skipped, 0 failures; 402.891 seconds |
| Address Sanitizer, all zstd/7z-zstd tests | 29 tests, 0 skipped, 0 failures; 20.013 seconds; no sanitizer reports |
| Existing CLI-generated matrix | 80 cases, all bytes matched |
| 256 MiB extraction vs original and reference tools | Both byte-for-byte comparisons passed |
| `git diff --check` | Passed |

The skips are existing optional corpus/tool conditions, including an Info-ZIP build
without bzip2 support. The new zstd tests all ran. Source hashes in
`.build/m10/tested-source.sha256` identify the implementation and tests used by both
the full suite and sanitizer run.

The implementation now uses a reusable contiguous history/block buffer, with
occasional compaction. Matches use bulk copies and doubling for overlap; short
copies use explicitly reserved slack. Backward bit reading uses bounded unaligned
64-bit refills. Sequence tables carry decoded bases and extra-bit widths, cache
the predefined distributions, and validate all FSE transitions at construction.
Huffman tables decode up to two symbols per lookup and interleave four streams.
XXH64 reads complete words while retaining its original incremental tail handling.

The emitted block array still has independent ownership. The internal scratch
buffer grows with actual output and is capped at `2 * retainedWindowSize +
maximumBlockSize + 16` bytes (saturating for enormous caller-supplied limits).
This provides room between compactions. `allocatedWindowBytes` continues to report
retained history; the new internal `allocatedBufferBytes` exposes the actual scratch
allocation for tests. Empty huge-window frames and the rejected empty huge-size
frame still allocate zero bytes. A one-byte block with an `Int.max` window and
explicitly enlarged limits allocates only 17 bytes.

The unsafe access invariants are documented next to the code:

- History occupies the initialized range immediately before the current block.
  The existing window-distance and reachable-history checks precede every match.
- Exact copies read initialized bytes. Overlapping matches grow the initialized
  prefix with disjoint copies. Short copies can write at most 15 extra bytes into
  the reserved 16-byte slack; checksum and returned output exclude this slack.
- A refill loads eight bytes only when all eight lie inside that bitstream's
  declared range. Short tails use bounded byte reads.
- Initial FSE states fit the accuracy log, and every constructed transition stays
  inside the table. Grouped reads check their bit budget before unchecked reads.
- Huffman lookup indices are masked to the table width; pair decoding requires
  enough input bits and two output bytes. Each of the four streams checks its own
  end marker, bounds, and trailing bits.
- XXH64 word reads occur only after checking the complete stripe/tail length.

The new differential tests use the reference CLI as a black box and compare every
byte for levels 1, 3, 9, 19, `--long=27 --no-content-size`, and `--ultra -22`.
They cover text, long runs, random bytes, tiny frames, 160 concatenated frames,
all 16 skippable magic values, and small windows that compact repeatedly.
They explicitly check that generated samples contain raw/RLE blocks and that the
large-window descriptor is 128 MiB. Additional cases cover short-copy boundaries,
history-to-current-block overlap, `Int.max` window arithmetic, and backward-reader
widths 1...31 at unaligned starts and byte tails. Generated-frame mutation tests
perform 768 bit flips plus sampled truncations; errors must be `KaitoError`.
The existing fixture, mutation, limit, dictionary, checksum, repeat-offset,
treeless, and FSE-mode tests remain in place.

Reproduction uses local caches because the environment restricts filesystem
writes. The default Swift 6.4 build engine failed at dSYM generation with
`Operation not permitted`; the native SwiftPM engine successfully builds the same
package and emits only its deprecation notice. Retain the baseline Release binary
before changing the decoder.

```sh
mkdir -p .build/m10/{tmp,cache,config,security,module-cache}
export TMPDIR="$PWD/.build/m10/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/m10/module-cache"
swift_options=(--build-system native --disable-sandbox
  --cache-path "$PWD/.build/m10/cache"
  --config-path "$PWD/.build/m10/config"
  --security-path "$PWD/.build/m10/security")

swift build "${swift_options[@]}" -c release --product kaito
cp .build/release/kaito .build/m10/kaito-before
```

```sh
python3 - <<'PY'
import base64, io, subprocess, tarfile
from pathlib import Path
out = Path('.build/m10')
archive = tarfile.open(fileobj=io.BytesIO(subprocess.check_output(
    ['git', 'archive', 'd412a02', 'Sources', 'Documentation'])))
names = sorted(m.name for m in archive if m.isfile()
               and m.name.startswith('Sources/') and m.name.endswith('.swift'))
names += sorted(m.name for m in archive if m.isfile()
                and m.name.startswith('Documentation/') and m.name.endswith('.md'))
corpus = b''.join(archive.extractfile(name).read() for name in names)
with (out / 'text').open('wb') as stream:
    remaining = 256 * 1024 * 1024
    while remaining:
        part = corpus[:remaining]
        stream.write(part)
        remaining -= len(part)
for name in ['zstd-l1.7z', 'zstd-l19.7z']:
    (out / name).write_bytes(base64.b64decode(
        Path('Tests/Fixtures/sevenzip-zstd', name + '.b64').read_bytes()))
PY
bsdtar -cf - -C .build/m10 text | zstd -q -3 -T0 -f -o .build/m10/text.tar.zst

swift build "${swift_options[@]}"
swift test "${swift_options[@]}"
swift test "${swift_options[@]}" --scratch-path .build/m10/asan \
  --sanitize address --filter 'ZstdTests|ZstdDifferentialTests|SevenZipZstdTests'
swift build "${swift_options[@]}" -c release --product kaito

.build/m10/kaito-before bench .build/m10/text.tar.zst 3
.build/release/kaito bench .build/m10/text.tar.zst 3
.build/m10/kaito-before bench .build/m10/zstd-l1.7z 3
.build/release/kaito bench .build/m10/zstd-l1.7z 3
.build/m10/kaito-before bench .build/m10/zstd-l19.7z 3
.build/release/kaito bench .build/m10/zstd-l19.7z 3
zstd -q -dc .build/m10/text.tar.zst > /dev/null
zstd -q -dc .build/m10/text.tar.zst > .build/m10/reference.tar
.build/release/kaito extract .build/m10/text.tar.zst -o .build/m10/extracted
cmp .build/m10/text .build/m10/extracted/text
bsdtar -xOf .build/m10/reference.tar text | cmp .build/m10/extracted/text -
git diff --check
```

Build, test, sanitizer, and benchmark logs are retained in `.build/m10/`.
