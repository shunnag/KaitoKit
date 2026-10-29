# 2026-10-29: container BZip2 parallelism and sized compressed-tar staging

Branch: `perf/wave2-ke2`. Baseline: `914d64a41e7eeb2e813723c587e200b59c1d44b5`.
Environment: arm64, macOS 27.2 (26B118), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, clang 2100.3.34.1). All reported decode measurements
explicitly request eight threads; input latency is automatic on local files.

## Implementation

- `SevenZipFolderPipeline.swift`: a single BZip2 coder uses a `BoundedByteSource`
  over its packed range. Multi-coder folders, including BZip2 with filters and
  AES -> BZip2, retain serial decoding and the existing materialization / integrity
  verification order. Header decoders retain their existing serial configuration.
- `ZipReader.swift`: methods 12 (BZip2), 95 (XZ), and 93 / legacy 20 (zstd) use
  bounded packed ranges and the existing parallel decoders. Open and shared
  reopen resolve execution options independently. Explicit single-thread and
  high-latency input retain the original serial decoders without parallel scans.
- `Bzip2BlockScanner.swift` and `ParallelBzip2Decompressor.swift`: an explicit
  `concatenatedStreams: false` mode preserves container decoding's first-stream
  termination, including ignored trailing data. The default single-file mode
  remains concatenating. Serial replay uses the same setting.
- `ZstdDecompressor.swift`: the parallel factory accepts an optional expected size.
  Inconsistent declared sizes retain the original serial decoder and errors.
  Parallelism requires multiple independent frames with known content sizes;
  a normal single-frame ZIP zstd payload stays serial.
- `ParallelXZDecompressor.swift`, `SingleFileReader.swift`, and
  `FormatReaderFactory.swift`: pass an optional XZ storage-size hint from the
  already validated layout, without an extra scan or a new length assertion.
  Gzip's final ISIZE is only a capped memory-reservation hint: concatenated members
  and modulo-2^32 sizes continue to use the actual streaming output length.
- `SingleFileMaterializer.swift`: reserve the declared size for in-memory streams;
  spool known-large streams directly to an unlinked file. Existing zstd FCS,
  lzip member totals, and pbzx sizes flow through the entry stream's remaining
  length. Unknown-size streams retain incremental growth / spilling. Keep the
  initial free-space reserve check, 256 MiB write checks, cancellation, and
  descriptor cleanup. The follow-up below coalesces direct-spool output in a
  bounded synchronous write buffer. If early spooling fails, defer that error until the original
  spill point so a prefix decoding / checksum / cancellation error wins first.

All parallel jobs use the existing memory-budget calculations and process-wide
`LeafDecodePool`; no new execution pool or unsafe codec implementation was added.
No writer thread was added: the storage changes remove the avoidable memory
prefix / copy without adding asynchronous I/O ordering and lifetime machinery.

## Reproduction and validation

The default module cache was unwritable. Commands use
`CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules` and `--disable-sandbox`.
The default Xcode build linked the baseline CLI but failed in `dsymutil` with
`Operation not permitted`; SwiftPM's `--build-system native` builds successfully.
The initial native release attempt overlapped source edits and was discarded.
Final performance comparisons use successful native release builds on both sides.
The baseline package under `/tmp/kaito-ke2-baseline` contains KaitoKit's own
Sources and Package.swift, with each changed source restored using read-only
`git show HEAD:<path>`; the worktree and its git metadata were not reverted.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native -c release --product kaito
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native --package-path /tmp/kaito-ke2-baseline -c release --product kaito
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --filter 'ContainerParallelCodecTests|SingleFileStagingSizeTests|ParallelBzip2DecompressorTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --scratch-path /tmp/kaito-ke2-asan --sanitize address --filter 'ContainerParallelCodecTests|SingleFileStagingSizeTests|ParallelBzip2DecompressorTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
KAITO_EXECUTABLE=/tmp/kaito-ke2/kaito-after CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native
GIT_OPTIONAL_LOCKS=0 git diff --check
```

Targeted: **46 tests, zero failures**, 56.569 s. ASan: **46 tests, zero failures**,
89.164 s, no sanitizer findings. The original full-suite attempt was interrupted
after it stopped progressing during CLI smoke coverage; the isolated ARJ smoke
case passed (3.921 s). The successful full rerun explicitly selects the release CLI using the
existing `KAITO_EXECUTABLE` test override: **1,995 tests, 55 skipped, zero
failures**, 1,274.372 s; exit status 0. Skips are the suite's optional external
corpora / opt-in probes / unavailable oracle features; targeted and ASan runs
have no skips. The subsequent Swift Testing runner reports zero additional tests.
Debug and both native release builds pass. `git diff --check` passes.

The new `ContainerParallelCodecTests.swift` exercises black-box-generated 7z
BZip2 (`7zz a -m0=BZip2 -mmt={off,on} -ms={off,on} -mhc=off`) and ZIP BZip2
(`7zz a -tzip -mm=BZip2 -mmt=off`), with a 10 MiB multi-block member and a
second 1 MiB member. It compares bytes across 1 / 2 / 8 / automatic threads,
solid entry boundaries, backwards reads and reopen. Packed-data bit flips,
removed suffixes, zeroed trailers and truncated archives compare errors with
serial decoding; corrupt partial output must be the same prefix (allowing the
existing parallel decoder's different chunk boundary / prefix length).
Additional checks cover first-stream termination, filter-chain serial fallback,
low-memory / power / high-latency policies, identical serial-policy source-byte
counts, actual parallel submissions, bounded ZIP XZ and multi-frame zstd, and
cancellation. The pre-existing decoder tests cover abandonment, worker-memory
bounds, serial replay and process pool behavior. A separate release CLI matrix
(`/tmp/kaito-ke2/modern-mutations.py`) constructs method 95 / 93 / 20 ZIPs using
the same public header layout, with a following stored entry, and compares
`sha --threads 1` against `sha --threads 8`: all **18 cases** match exit status,
stdout and stderr exactly. Each method includes valid data, three packed-stream
truncations and two bit flips. The following entry remains readable. XZ is a
36 MiB, nine-block black-box `xz -T2 --block-size=4MiB` stream; zstd uses two
small independent raw frames.

`SingleFileStagingSizeTests.swift` covers storage selection at the threshold,
prefix decode-error precedence over an early space failure, the historical spill
error point, XZ hints without length assertions, gzip concatenation, and
identical tar contents / listing metadata / reopen for gzip, XZ, zstd, lzip and
BZip2 on both sides of an adjustable threshold. Existing staging tests cover the
256 MiB reserve recheck, descriptor cleanup and cancellation.

A separate release matrix uses expanded tar lengths **67,108,352 / 67,108,864 /
67,109,376 bytes**, each compressed as `.tar.{gz,xz,zst,lz,bz2}`. Both release
CLIs produce identical `list` and `sha` output for all **15 archives**. Tar files
contain a single `payload.bin`, a standard USTAR header, deterministic repeated
text and two terminating zero records. The SHA-256 values also match the independently generated tar payloads.
Generation and result logs are under
`/tmp/kaito-ke2/threshold*`; fixtures are not added to the repository.

## Release measurements

Benchmark corpus (`/tmp/kaito-ke2/make-corpus.py`, seed 2929): a 32 MiB
synthetic RGB-like tiled gradient / variation payload and 32 MiB of deterministic
varying log-style text. The image tile is 1 MiB; byte `x` is
`(x // 3 + (x % 3) * 37 + rng.randrange(16)) % 256`. Text comprises repeated
100,000-row batches with row numbers and seeded values. Each BZip2 archive has
one member. The USTAR benchmark bundle contains both files: **67,112,960 bytes**,
just over the 64 MiB staging threshold. Compressed archive sizes:

| Archive | Bytes |
|---|---:|
| image.7z | 22,185,070 |
| text.7z | 1,908,388 |
| image.zip | 22,185,100 |
| text.zip | 1,908,416 |
| bundle.tar.gz | 35,985,902 |
| bundle.tar.zst | 5,931,206 |
| bundle.tar.xz | 4,726,104 |

Generation uses `7zz a -t7z -m0=BZip2 -mmt=off`,
`7zz a -tzip -mm=BZip2 -mmt=off`, `gzip -n -c`, `zstd -q -T1 -c`,
and `xz -T4 --block-size=8MiB -c`. The final zstd command receives the tar
filename, so its frame declares the full content size; `zstd --list` confirms
one frame and 64.0 MiB uncompressed. An earlier stdin-generated frame omitted
FCS and appropriately kept incremental staging; its preliminary timings are
excluded from the final table. All seven benchmark archives also have
identical baseline / patched `sha` output and match the original input SHA-256.

Commands run after the full suite and both builds exited, alternating baseline
then patched for each archive:

```sh
/tmp/kaito-ke2/kaito-before bench /tmp/kaito-ke2/corpus/<archive> 5 --threads 8
/tmp/kaito-ke2/kaito-after bench /tmp/kaito-ke2/corpus/<archive> 5 --threads 8
/usr/bin/time -l /tmp/kaito-ke2/kaito-after bench /tmp/kaito-ke2/corpus/image.7z 1 --threads 8
```

Each timing is the CLI's median of five repetitions (warm local-file cache).
Tar `open` includes complete decompression / staging and tar parsing, i.e. the
work of listing without formatting the rows. `extract` is `kaito bench` reading
all entries into Data and retaining the results until that repetition ends.
Peak RSS is the maximum for the same five-repetition process, including staging,
decoder workers and retained extracted entries.

`/usr/bin/time -l` was attempted on both binaries and exits 1 after successfully
running the benchmark: `time: sysctl kern.clockrate: Operation not permitted`.
It supplies no RSS here. The table therefore uses Python
`resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss` around each isolated
CLI process, in bytes on macOS, converted to MiB. This is also the repository's
existing restricted-runner fallback in `Tests/KaitoKitTests/Support/KaitoCLI.swift`.
No unavailable time(1) RSS values are claimed. The wrapper is:

```python
completed = subprocess.run(command, capture_output=True, text=True)
peak_rss_bytes = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
```

| Archive | Open / list ms, before → after | Extract ms, before → after | Peak RSS MiB, before → after |
|---|---:|---:|---:|
| image.7z | 0.142 → 0.168 | 968.637 → 277.124 | 51.7 → 211.3 |
| text.7z | 0.160 → 0.172 | 360.015 → 93.483 | 51.7 → 174.5 |
| image.zip | 0.254 → 0.265 | 972.305 → 278.996 | 52.1 → 211.9 |
| text.zip | 0.236 → 0.305 | 367.643 → 107.847 | 51.8 → 175.1 |
| bundle.tar.gz | 87.335 → 81.638 | 3.803 → 3.747 | 393.9 → 136.4 |
| bundle.tar.zst | 29.893 → 45.359 | 3.603 → 3.591 | 402.4 → 80.7 |
| bundle.tar.xz | 74.355 → 70.617 | 3.752 → 4.141 | 509.6 → 188.0 |

BZip2 extraction improves **3.41–3.85x**, at the expected cost of retained
parallel inputs / outputs and worker state. The existing parallel memory budget
and process pool remain in control. Gzip / XZ open improves modestly and their
five-repetition peak RSS drops substantially.

**Initial K-E2 known-FCS zstd tradeoff (superseded by the follow-up below):** direct staging cuts peak RSS from 402.4 to 80.7 MiB,
but its first five-run open median rises from 29.893 to 45.359 ms. Two reverse-
order / forward-order rechecks confirm the direction: baseline 29.253 / 29.995 ms,
patched 37.289 / 39.874 ms. The likely cost is writing each small native zstd
output chunk synchronously instead of one large in-memory prefix write. No
writer thread or batching change was added: preserving decode / I/O failure
ordering beyond the old spill point would require more machinery than this
narrow storage-selection change. Unknown-FCS streams continue the original
incremental path. The slowdown is a measured limitation, not a claimed speedup.

Raw final results: `/tmp/kaito-ke2/final-bench-known-size.jsonl` (14 successful
processes); rechecks: `/tmp/kaito-ke2/zstd-staging-recheck.json`. Fixture generation,
SHA comparisons and boundary / mutation matrices are retained under
`/tmp/kaito-ke2/`. No benchmark fixtures or binaries are added to the worktree.


## Follow-up: diagnose and remove the tar.zst open regression

### Controlled timing instrumentation

No external implementation source was consulted. A copy of KaitoKit's current
Sources and Package.swift was made at `/tmp/kaito-ke2-profile`, with only its
own materializer instrumented. `DispatchTime.now().uptimeNanoseconds` times
`EntryStream.read`, `Data.append`, and staged writes; counters record read and
`writeAll` invocations and decoded chunk lengths. The main worktree contains
no profiler switches or timing hooks. `KAITO_PROFILE_GROW=1` in the temporary
copy emulates the old incremental memory-prefix strategy while keeping the
same decoder; `KAITO_PROFILE_LIMIT=134217728` tests exact reservation in memory.

Median component times from five-repetition release runs on the same known-FCS
67,112,960-byte zstd tar (instrumentation changes timing slightly):

| Strategy | Stream reads | Nonempty writeAll calls | Read/decode ms | Append ms | Write ms | Materialize ms |
|---|---:|---:|---:|---:|---:|---:|
| Old memory-prefix strategy | 3,079 | 2 | 13.608 | 4.379 | 9.444 | 28.119 |
| K-E2 direct spool | 3,079 | 3,078 | 14.349 | 0 | 22.881 | 37.356 |
| Fixed 4 MiB coalescing, representative five-run round | 3,079 | 17 | 14.099 | 0 | 7.952 | 23.750 |

There are **2,731 decoded chunks of 8 KiB**, 285 of 128 KiB, 59 of 120 KiB,
and three other nonempty chunks. K-E2 wrote every decoded chunk. Each nonempty
`writeAll` requires at least one `write(2)` syscall. Decoder work and read counts
are unchanged; the extra cost is writing thousands of short chunks. The fix
writes the same bytes in 17 batches, with no second accumulation copy.

Why zstd was affected most:

- Gzip's modulo-2^32 hint is capped at the memory limit, so it retains the exactly
  reserved memory prefix and makes only **two** writes for this tar.
- XZ and lzip each return mostly 256 KiB chunks: K-E2 makes **257** writes, versus
  zstd's 3,078. Their measured read/decode work is about 60 / 105 ms, so write
  overhead is a smaller fraction of their open time.
- BZip2 has no size hint and retains the previous memory-prefix path, with two
  writes. Its decode scheduling and storage policy are unchanged.

The corpus exceeds 64 MiB by 4,096 bytes, so **both the original and K-E2
strategies return FileByteSource**. A memory-to-file versus memory-only return
cannot explain the regression. No one-shot zstd path was removed: both staging
strategies use the same EntryStream reads and decoder. The ZIP expected-size
factory extension does not change single-file zstd staging. Content-size / frame
structure preflight is the same on both sides; no new validation pass is involved.

### Fix and measured buffer choice

`SingleFileMaterializer.swift` now coalesces output **only for streams selected
for direct spooling**. Decoders write into the available tail of a bounded
4 MiB buffer, with the original **256 KiB maximum per read**. Full batches, the
historical spill crossing and the final tail are flushed synchronously. The
memory-prefix path, public limits, known-size storage threshold and codecs are
unchanged. There is no writer thread, new decoder pass, or extra output copy.

If a later read / checksum / cancellation fails after the old spill point,
earlier acknowledged buffered bytes are flushed first: an earlier I/O failure
still wins. Before that point a prefix decoding error retains precedence, and
an early I/O error stays deferred as in K-E2. Failed writes are not retried by
the error handler. Space is still checked initially and every 256 MiB written;
the descriptor is closed on every failure path.

The instrumented zstd sweep used three processes of five repetitions per size:

| Write buffer | Open medians ms | Nonempty writes |
|---|---:|---:|
| 256 KiB | 32.468 / 28.628 / 43.738 | 257 |
| 1 MiB | 36.398 / 31.748 / 30.813 | 65 |
| **4 MiB** | **25.953 / 25.267 / 25.439** | **17** |
| 8 MiB | 24.046 / 23.936 / 23.919 | 9 |

4 MiB is the smallest tested buffer that consistently meets the 30 ms goal;
8 MiB saves roughly another 1–2 ms at twice the buffer memory. The exact-memory
128 MiB threshold experiment opened in 15.587 ms, but is unnecessary: bounded
spooling already meets the time and RSS goals while respecting existing caller
limits. No new size threshold was introduced.

### Uninstrumented release comparison

All three binaries use native SwiftPM release builds. `original` is HEAD before
K-E2, `ke2` is the prior result, and `fixed` is the synchronous coalescing fix.
All use the same corpus and `--threads 8`. The previously missing `.tar.lz` and
`.tar.bz2` measurements use `lzip -c bundle.tar` and `bzip2 -c bundle.tar` as
black-box writers. Results are **the median of three five-repetition process
medians**; peak RSS is the **maximum** across those processes. Binary order
alternates between rounds. All measurements were taken before the verification
jobs started, with no competing build/test process.

| Tar format | Original → K-E2 → fixed open/list ms | Original → K-E2 → fixed peak RSS MiB |
|---|---:|---:|
| .tar.zst | 28.684 → 43.432 → 26.027 | 404.1 → 82.4 → 85.9 |
| .tar.gz | 85.910 → 82.914 → 82.356 | 393.9 → 137.0 → 137.0 |
| .tar.xz | 72.754 → 70.959 → 70.759 | 511.8 → 188.0 → 192.5 |
| .tar.lz | 119.530 → 121.304 → 117.337 | 405.0 → 81.1 → 84.6 |
| .tar.bz2 | 302.946 → 308.936 → 305.962 | 627.9 → 628.5 → 631.6 |

Fixed zstd five-run open medians are **24.515 / 26.027 / 29.030 ms**; every
round meets the 30 ms target. Peak RSS is at most **85.9 MiB**, versus 404.1 MiB
for the original strategy (the earlier record measured 402.4 MiB). Gzip / XZ /
lzip are stable or faster. BZip2's fixed 302.046–312.385 ms range overlaps both
original and K-E2 ranges; its median is 1% faster than K-E2 and 1% above the
original, within the observed run-to-run variation. The additional direct-spool
workspace costs at most 4 MiB; BZip2's unknown-size path retains its old buffer.

Raw measurements and scripts: `/tmp/kaito-ke2-followup/profile-before.jsonl`,
`buffer-sweep.jsonl`, `bench-all.jsonl`, `bench-recheck.jsonl`, `make-profile.py`,
`make-profile-fixed.py`, `profile-run.py`, `buffer-sweep.py`, `bench-all.py`,
`bench-recheck.py`. None is a reference implementation or external source.

### Follow-up commands and verification

```sh
python3 /tmp/kaito-ke2-followup/make-profile.py
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native --package-path /tmp/kaito-ke2-profile -c release --product kaito
python3 /tmp/kaito-ke2-followup/profile-run.py
python3 /tmp/kaito-ke2-followup/make-profile-fixed.py
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native --package-path /tmp/kaito-ke2-profile -c release --product kaito
python3 /tmp/kaito-ke2-followup/buffer-sweep.py
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native -c release --product kaito
python3 /tmp/kaito-ke2-followup/bench-all.py
python3 /tmp/kaito-ke2-followup/bench-recheck.py
python3 /tmp/kaito-ke2-followup/verify-content.py
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --filter 'ContainerParallelCodecTests|SingleFileStagingSizeTests|ParallelBzip2DecompressorTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --scratch-path /tmp/kaito-ke2-asan --sanitize address --filter 'ContainerParallelCodecTests|SingleFileStagingSizeTests|ParallelBzip2DecompressorTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
KAITO_EXECUTABLE=/tmp/kaito-ke2-followup/kaito-4m CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native -c release
GIT_OPTIONAL_LOCKS=0 git diff --check
```

Debug / release builds pass. Instrumented builds pass; 15 controlled before
profile cases and all 12 buffer-sweep cases exit 0. All **45** uninstrumented
benchmark processes exit 0. Targeted debug tests: **49 tests, zero skipped,
zero failures**, 60.323 s. The three added staging tests exercise uneven short
chunks across buffer boundaries with CRC validation, error precedence at the
256 MiB space-check boundary on both sides of the old spill point, and mid-stream
cancellation / descriptor cleanup.

ASan: **49 tests, zero skipped, zero failures**, 92.611 s, no sanitizer
findings; exit 0. Content checks: all **20 archives** (the five main tar formats
and 15 real 64 MiB threshold fixtures) have identical prior-K-E2 / fixed `list`
and `sha` output, and their content SHA-256 values match the independent tar
inputs. All 80 CLI comparisons exit successfully. Results are in
`/tmp/kaito-ke2-followup/content-verification.jsonl`.

Full release suite (`swift test -c release`, no test filter): **1,998 tests,
55 skipped, zero failures**, 302.242 s; exit 0. Its release test build completes
in 213.97 s. The Swift Testing runner adds zero tests. The same optional-corpus /
probe / unavailable-oracle skips remain as before; all touched tests run.
The debug build takes 4.03 s and the release CLI build 67.66 s. Final
`git diff --check` passes. Logs are retained as `build.log`, `release-build.log`,
`targeted.log`, `asan.log`, and `full-release.log` under
`/tmp/kaito-ke2-followup/`.

The follow-up edits only `Sources/KaitoKit/Reader/SingleFileMaterializer.swift`,
`Tests/KaitoKitTests/SingleFile/SingleFileStagingSizeTests.swift`, and this record.
The earlier container routing changes remain as previously verified. No `.git`
write, `bd`, commit, changelog edit, or protected-source edit was performed.
Provenance remains KaitoKit-owned code / records and black-box CLI fixtures only.

## Adversarial hardening: encrypted ZIP routing and output allocation bounds

The independent review found two confirmed K-E2 defects: parallel readers could
rewind decrypting ZIP sources repeatedly, and ZIP XZ jobs could allocate from a
large decoded Index before EntryStream enforced the ZIP declaration / entry
limit. This follow-up corrects both and audits the related output-size hints.
No crypto implementation or excluded source was edited.

### Changes

- `ZipReader.swift`: pass the parsed `ZipEntryEncryption` into codec selection.
  BZip2, XZ, and zstd (including legacy method 20) now require `.none` before
  parallel decoding. Both traditional and AES entries retain the original serial
  codecs and error normalization. Existing authenticated compressed AES-XZ
  staging remains unchanged; no additional encrypted staging route was added.
- `ParallelXZDecompressor.swift`: accept the container's optional `expectedSize`.
  The validated layout total must pass `Checked.size(total, limit: maxEntrySize)`
  and match that declaration before native selection, job planning, reservations,
  submission or output-buffer allocation. ZIP requires a known declared size.
  Otherwise the wrapper selects the original `XZDecompressor`, preserving its
  declared-size error and partial output. An over-limit layout exports no storage
  hint. Single-file XZ therefore also avoids header-driven parallel output
  allocations above the entry limit.
- `ParallelBzip2Decompressor.swift`: cap each worker output buffer by
  `limits.maxEntrySize`, as well as the existing interval / caller caps. The
  existing one-byte minimum end-marker probe remains. A read-only internal
  `outputBufferLimit` exposes that allocation bound to tests.
- `SevenZipFolderPipeline.swift`: additionally pass the declared folder output
  as the BZip2 worker cap. Solid folders can legitimately exceed one entry's
  limit; each worker remains capped by both values and the existing memory budget.
  Small speculative output that cannot contain a real block replays serially.
  ZIP BZip2 similarly passes its declared entry size as the worker cap.
- `SingleFileMaterializer.swift`: discard storage hints above `maxEntrySize`.
  A bogus hint can no longer select direct spooling or size its working buffer;
  the streaming entry limit supplies the error. Known EntryStream lengths are
  already validated by EntryStream initialization. Exact memory reservation is
  still clamped to the entry / memory limits. The 4 MiB coalescing fix remains.

The other known-size inputs were checked in KaitoKit's own code: zstd frame
content sizes and parallel-unit totals are checked against `maxEntrySize`;
lzip checks each member and the total; pbzx checks total output during framing.
Gzip ISIZE remains only a hint and now also passes the central hint filter.
Codec dictionaries / fixed scanner workspace retain their independent existing
limits and parallel budget; this change bounds decoded-output allocations.

### Regression fixtures and observations

Read the supplied clean-room probe scripts
`/private/tmp/ke2probe/scripts/mk.py`, `ZZProbeEncryptedParallelTests.swift`, and
`/private/tmp/claude-501/-Users-nagash-Github-cooViewer/f5d31b04-ea4a-4009-9969-c5c1029f63fe/scratchpad/gen/mkbomb.py`.
The former probe's `fx` directory was absent, so portable fixtures are generated
inside `ZipParallelSafetyTests.swift`, using public APPNOTE / WinZip AES framing
and the existing OS PBKDF2, AES-ECB, and HMAC primitive wrappers. Production
ZipCrypto / WinZip AES implementations are not used to construct the fixture
state machines. The supplied 313 KiB ZIP / 2 GiB decoded XZ bomb is also tested
when `KAITO_KE2_XZ_BOMB` is set (as in all runs below).

The six new tests cover:

1. Traditional ZipCrypto and AES-256, each with BZip2 / eight-frame zstd /
   multi-block XZ: decoded bytes match the generated plaintext, t=8 and t=1 read
   exactly the same source bytes, and neither submits any parallel job.
2. Twelve authenticated-but-invalid compressed variants (truncation and invalid
   block / CRC / footer bits): t=8 matches t=1 in exact partial bytes, typed
   error, read count and zero submissions. Zstd's invalid final block follows
   seven valid frames to guarantee meaningful partial output; AES HMAC is valid,
   so this exercises codec-error routing rather than an early authentication fail.
3. A tiny (<64 KiB) XZ payload expanding to 34 MiB, stored in ZIP as a 1 MiB
   entry, tested with entry limits of 2 MiB and 64 MiB. These separately exercise
   the entry-limit and declaration-match gates. Both t=1 and t=8 fail with
   `malformed("entry output exceeds its declared size")`, with identical partial
   output. There are zero job submissions; XZ diagnostics report zero held job
   bytes / peak workers and serial fallback. This scaled fixture fails safely
   if a guard regresses, rather than needing multi-gigabyte allocations in CI.
4. The actual reviewer 2 GiB bomb: the same declared-size error and partial output
   at t=1 / t=8, **zero jobs**. Ciphertext is not involved in this unencrypted
   case; t=8 performs an additional bounded layout preflight before choosing the
   serial codec (525,324 versus 788,465 source bytes), with no job-sized output.
5. Single-file XZ with a 34 MiB decoded layout and 2 MiB entry limit: no parallel
   work or oversized hint, then the original streaming `limitExceeded("entry size")`.
   An explicit `UInt64.max` storage hint on a valid 128-byte unknown-length stream
   is ignored: it stays in memory and never queries temporary space.
6. BZip2 worker buffer capped at a 1 KiB entry limit, including an actual failed
   speculative decode / serial replay below 40 MiB of diagnostic reservation
   (the fixed scanner workspace is included). A 7z folder declaring 512 bytes
   caps the BZip2 worker at 512 bytes even with a 1 KiB entry limit.

Encrypted read counts reset after opening the central directory, then include
stream setup / payload decoding / completion. For the same archive and read
buffer at t=1 / t=8:

| Encryption | Codec | Source bytes t=1 | Source bytes t=8 | Jobs t=8 |
|---|---|---:|---:|---:|
| ZipCrypto | BZip2 | 467,827 | 467,827 | 0 |
| AES-256 | BZip2 | 467,854 | 467,854 | 0 |
| ZipCrypto | zstd, eight frames | 524,437 | 524,437 | 0 |
| AES-256 | zstd, eight frames | 524,464 | 524,464 | 0 |
| ZipCrypto | XZ, nine blocks / 34 MiB | 12,501 | 12,501 | 0 |
| AES-256 | XZ, nine blocks / 34 MiB | 6,304 | 6,304 | 0 |

The zstd / BZip2 fixtures decode to 512 KiB of deterministic data. The XZ fixture
uses repeated bytes so it exercises multiple large decoded jobs while staying
small on disk. Unencrypted valid parallel paths remain covered by the existing
container / decoder tests. Metadata limits, thread and power policies, process
slots and cancellation remain unchanged.

### Commands and results

Commands use the same temporary module cache and native build system as the
previous verification. The external probe environment variable is set for the
actual reviewer bomb, not merely the scaled fixture:

```sh
export KAITO_KE2_XZ_BOMB=/private/tmp/claude-501/-Users-nagash-Github-cooViewer/f5d31b04-ea4a-4009-9969-c5c1029f63fe/scratchpad/fx/bomb-xz.zip
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native
KAITO_KE2_XZ_BOMB="$KAITO_KE2_XZ_BOMB" CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --filter ZipParallelSafetyTests
KAITO_KE2_XZ_BOMB="$KAITO_KE2_XZ_BOMB" CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --filter 'ZipParallelSafetyTests|ContainerParallelCodecTests|ParallelBzip2DecompressorTests|ParallelXZDecompressorTests|XZResourceLimitTests|SingleFileStagingSizeTests|SingleFileParallelDecodeTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
KAITO_KE2_XZ_BOMB="$KAITO_KE2_XZ_BOMB" CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native --scratch-path /tmp/kaito-ke2-asan --sanitize address --filter 'ZipParallelSafetyTests|ContainerParallelCodecTests|ParallelBzip2DecompressorTests|ParallelXZDecompressorTests|XZResourceLimitTests|SingleFileStagingSizeTests|SingleFileParallelDecodeTests|ZipModernMethodTests|SingleFileArchiveReaderIntegrationTests'
CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift build --disable-sandbox --build-system native -c release --product kaito
NSUnbufferedIO=YES KAITO_KE2_XZ_BOMB="$KAITO_KE2_XZ_BOMB" KAITO_EXECUTABLE=/tmp/kaito-ke2-hardening/kaito CLANG_MODULE_CACHE_PATH=/tmp/kaito-ke2-modules swift test --disable-sandbox --build-system native -c release
GIT_OPTIONAL_LOCKS=0 git diff --check
```

Debug build: pass (3.61 s). Safety-only tests: **6 tests, zero failures**,
2.381 s. Broader targeted debug run: **84 tests, zero skips / failures**,
65.439 s. All six encrypted combinations read exactly 1.00x the t=1 byte count.

ASan targeted run: **84 tests, zero skips / failures**, 106.258 s; exit 0,
no sanitizer findings. Release CLI build passes (66.17 s). The actual reviewer
bomb and all six encrypted combinations run under ASan as well.

The first full release attempt stopped progressing in CLI smoke coverage and
was interrupted (exit 130). The existing password-stdin smoke case passes in
isolation (0.917 s) with:

```sh
KAITO_EXECUTABLE=/tmp/kaito-ke2-hardening/kaito xcrun xctest -XCTest KaitoKitTests.CLISmokeTests/testPasswordStdinDecryptsForAllCommands .build/release/KaitoKitPackageTests.xctest
```

The full unfiltered rerun used `NSUnbufferedIO=YES`. It exposed one existing
optimized-build test race: `ParallelXZDecompressorTests.testCancellationAbandonsWorkersWithinTwoSeconds`
missed its very short live-worker interval between 1 ms polls, then requested
cancellation after the decode had finished. That attempt has two assertion
failures in that one case; all other cases pass. The test now wraps its immutable
source in an NSCondition gate: initialization reads pass normally, worker reads
wait until the test has observed live workers and requested cancellation, and
then the gate is released. All original assertions and the 2 s abandonment
bound remain. A defer cancels / releases on every exit. No production decoder
behavior is changed to slow the test down.

After this test-only correction, broader debug and ASan runs are repeated:
**84 tests, zero skips / failures**, 66.423 s (debug) and 105.905 s (ASan), both
exit 0, with no sanitizer findings. Logs: `targeted-final.log`, `asan-final.log`.
The interrupted and timing-race attempts are retained in
`full-release-interrupted.log` and `full-release-timing-race.log`.

Final unfiltered release suite after the deterministic test correction:
**2,004 tests, 55 skipped, zero failures**, 298.427 s; exit 0. All six new safety
tests run, including the external 2 GiB probe. The existing optional-corpus /
probe / unavailable-oracle skips remain. The final `git diff --check` and
whitespace checks for the new test / verification files pass. No required
verification remains pending.

Logs: `/tmp/kaito-ke2-hardening/{build,safety-tests,targeted,asan,release-build,full-release}.log`.
The only additional source edits in this follow-up are the five files listed
above, `ZipParallelSafetyTests.swift`, and the deterministic cancellation test
in `ParallelXZDecompressorTests.swift`; this record is updated. No excluded
code, changelog or git metadata was written. No `bd` or commit was run.

## Provenance and scope

Implementation input was exclusively KaitoKit's own source, tests and existing
verification records, including the clean-room policy in `Documentation/design.md`.
No unrar, 7-Zip/p7zip, XADMaster, The Unarchiver, libarchive, bzip2/libbz2,
zstd reference, or xz/liblzma implementation source was opened. Installed CLIs
were used only as black boxes: 7zz 26.05 arm64, zstd 1.5.7, xz 5.8.4,
bzip2 1.0.8, gzip and lzip. Hand-framed ZIP and zstd tests use the project's
existing format-test conventions. No external implementation snippets or web
searches were used.

No `.git` files, `CHANGELOG.md`, LZ4 sources, `Deflate64Decompressor.swift`,
PPMd sources, or crypto sources were edited. No `bd` command or commit was run.
