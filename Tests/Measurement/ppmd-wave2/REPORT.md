# PPMd decode performance, wave 2 — 2026-10-29

The changes narrow the decode gap; they do **not** establish parity with 7zz.
Final measurements and verification results are recorded below. Work starts at
`7b1e5837718f6e4f11a36cd427a857c6851b8814` on `perf/wave2-kd`.

## Provenance and scope

I did not open 7-Zip, p7zip, unrar, XADMaster, libarchive, pyppmd, or any other
third-party PPMd implementation. No external implementation or web reference was
opened. Implementation inputs were KaitoKit's own PPMd source, its frozen Swift
baseline and fixtures, `Documentation/design.md` (the required provenance
sections), the `be1dec1` own-code commit record and CHANGELOG 0.13.0 arena-accessor
entry, and the 2026-10-10/11 decode-performance records. The original source
provenance headers remain intact. The allowed SDK/Shkarin references named by
those headers were not newly consulted.

The profiling method came from the explicitly requested section 1 of the
2026-10-29 LZMA wave-1 record. Its locally generated text/BMP/JPEG inputs and
self-sampling diagnostic were reused; none is third-party decoder source.
7zz 26.05 was used only as a black box to create/test archives and measure time.

Only PPMd sources, PPMd tests, and this measurement directory changed.
`RAR29Decoder.swift` and `CHANGELOG.md` were not edited. No `bd`, git checkout,
reset, add, commit, or other git mutation command was run. Read-only git status, show,
diff, diff-check and rev-parse were used; the repository metadata is not writable
in this sandbox. No previously rejected decoder algorithm was reintroduced.
Existing arena validation, buffered input and 256 KiB output batching were
already present at HEAD and are not presented as new work.

## Environment and timing method

The host is arm64, macOS 27.2 (26B118), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, clang 2100.3.34.1). `7zz` reports 26.05 arm64 and
16 available threads. Hardware sysctl queries were denied, so this is not a
claim to reproduce the supplied Mac mini M4 absolute timings.

`W` below is `/tmp/kaitokit-wave2-kd` (also `/private/tmp/...`). Both binaries use
release optimization and `-debug-info-format none`; the latter follows the
same sandbox's documented dsymutil denial in the wave-1 record. The unchanged
HEAD PPMd sources were copied to `W/PPMd-before`, and the initial executable and
public-API harness were saved before edits.

The six benchmark archives were generated from the wave-1 synthetic inputs:
16,777,216 bytes of fixed-seed word text, three 2048-square BMPs totaling
37,748,898 bytes, and their three JPEG conversions totaling 3,848,833 bytes.
The commands used `7zz a -t7z -m0=PPMd -mmt=1` and
`7zz a -tzip -mm=PPMd -mmt=1`, with `-bso0 -bsp0`, the output pathname, and the
respective input filenames, from `/tmp/kaitokit-wave1-kc/bench-inputs`.
All six archive creations exited 0. These are new
archives, not the smaller corpus fixtures.

Final timing uses five alternating A/B rounds, warm archives, separate processes,
and one requested decode thread: `kaito sha --sink --threads 1 ARCHIVE` versus
`7zz t -mmt=1 ARCHIVE`. Wall time is Python `perf_counter`; startup, metadata,
reading and CRC checking are included. Kaito's SHA-256 calculation is disabled.
The final timing series runs after mutation, full-suite and ASan verification. Earlier diagnostic runs overlapped builds/tests and are not the
final evidence. Input/archive/binary digests and raw samples accompany this file.

| Archive | HEAD ms | Final ms | Time saved | 7zz ms | Final / 7zz |
|---|---:|---:|---:|---:|---:|
| text.7z | 254.431 | 235.123 | 7.6% | 216.524 | 1.086x |
| text.zip | 304.192 | 293.113 | 3.6% | 249.448 | 1.175x |
| color.7z | 7295.810 | 6553.165 | 10.2% | 3698.456 | 1.772x |
| color.zip | 7111.722 | 5721.242 | 19.6% | 3697.252 | 1.547x |
| jpeg.7z | 1430.871 | 1073.404 | 25.0% | 795.337 | 1.350x |
| jpeg.zip | 1539.483 | 927.812 | 39.7% | 773.561 | 1.199x |

All 90 final-series processes exited 0. Columns are medians of five process
wall times; time saved is calculated from those medians. Paired B/A medians
are also retained in `timing-summary.json`; all raw commands, outputs and exits
are in `timings-final.jsonl`. The remaining gap is input-dependent: approximately
1.35x / 1.20x on these JPEG H/I cases and 1.77x / 1.55x on color.
These local synthetic cases do not certify the supplied Mac mini M4 corpus.

## Profile findings

`sample PID 3 -file W/sample.txt` could not examine the existing process (exit
255); its 15-repetition wrapper completed successfully. No Instruments trace is
claimed. The fallback dylib sets `ITIMER_PROF` to 1 ms, saves interrupted PCs,
then uses `dladdr`, `nm -n`, and Swift demangling after execution. Disassembly
inspection was restricted to our own generated executable.

Baseline color profiles used 12 repetitions each:

| Baseline function / group | H, 24,661 samples | I, 25,711 samples |
|---|---:|---:|
| decodeSymbol2 | 18.3% | 27.2% |
| indexOfSymbol / findState | 12.3% | 12.3% |
| outer decode loop | 11.5% | 14.0% |
| updateModel | 9.2% | 11.2% |
| decodeSymbol1 | 6.2% | 5.8% |
| createSuccessors | 1.9% + 1.7% materialization | 4.5% |
| binary symbol | 1.5% | 2.0% |
| rescale | 1.0% | 0.8% |
| Swift runtime | 7.3% | 2.4% |

H's escapeEstimator was separately visible at 1.6%. Allocator operations were
usually around or below 1% individually; they were not the main target.
Normalization and field accessors are substantially inlined into the symbol
loops, so this profile cannot isolate their individual cost. Kernel samples
(about 11%) include the sampling mechanism and are not an I/O estimate.

The first cursor/span candidate reduced the H runtime share to 3.1%, but its I
image timings did not show a win. Its profile moved much of the selection work
into the outer loop through inlining. Own-binary assembly still showed overflow
branches inside bounded frequency scans, motivating the final bounded-arithmetic
pass. The final code also groups four state-search comparisons per loop.
Function percentages across differently inlined builds are not direct speedups.
The diagnostic PC sampler also clusters many samples at the output-byte store;
no memory-latency conclusion is drawn from that instruction attribution.

The accepted implementation's two-repetition profiles contain 4,857 H and
4,129 I samples. H attributes 37.6% to the inlined outer loop, 12.0% to
`decodeSymbol2`, 7.8% to search, 7.5% to `updateModel` and 3.4% to Swift runtime.
I attributes 45.3% to its outer loop, 10.7% to `decodeSymbol2`, 7.0% to search,
9.1% to `updateModel` and 1.7% to Swift runtime. `profile-final.txt` retains the
full top-function lists. These diagnostic profiles overlap verification work;
the final performance table uses the separate quiet timing series.

## Changes by function

- `PPMd7Model.decode` and `decodeByte` borrow an owned, noncopyable value cursor
  containing H's model scalars. One class access covers an output batch;
  exceptions preserve partial progress. RAR's one-symbol entry point remains.
  I retains its class model: the value-cursor trial was rejected after a ZIP
  color regression, rather than assuming the H representation suits both.
- `SevenZipPPMdRangeDecoder.withCursor` borrows value registers/input positions
  for that batch. Initialization and cleanup remain owned by the facade.
  `PPMd7RangeDecoding` permits a mutating, noncopyable cursor while the existing
  RAR class still conforms. I retains its original range-decoder implementation.
  Coder math, validation messages, refill limits and normalization positions
  are unchanged.
- H's SEE estimator becomes a fixed row-major allocation of 400 value records,
  replacing nested arrays of classes. Its validated row/column produces an
  integer index; the root uses a non-dereferenced sentinel. Estimator mean,
  update, and 16-bit summary behavior are unchanged. I's already-flat SEE table
  and dummy-estimator semantics are retained.
- `decodeSymbol1/2` advance pointers inside checked state spans, avoiding repeated
  indexed offset construction and I's per-state optional arena-base loads.
  Both variants call `PPMdStateScan.unmasked` for H's existing branch-free
  available-count/frequency calculation. I drops its scratch offset list;
  selection scans the same live state block, and escape marks all states
  (already-masked symbols receive the same value again). The actual unmasked
  count, threshold and subrange checks remain in their original order.
- Successful symbol updates use `updateDecodedFrequency` only after the context
  and selected state have been validated by the enclosing scan. Frequency and
  summary value checks, write order, swapping, and rescale calls remain.
- `indexOfSymbol` / `findState` use the shared four-state `PPMdStateScan`. It
  returns the first matching symbol and handles all three tail lengths. Missing
  symbols still reach the original errors.
- I's suballocator adds a checked span view and 16-bit field helpers. Allocation,
  free lists, glue, model restoration and arena-release rules are unchanged.
- `rescale`, `createSuccessors`, `updateModel` and restoration algorithms are
  unchanged apart from H's value-cursor mutation plumbing; they benefit from
  the shared lookup and successful-symbol paths.

## Unsafe bounds and arithmetic arguments

1. Both allocators own fixed arenas. H retains `requireContext` (12 bytes,
   unit-area membership and alignment), `requireStateBlock` (2...256 six-byte
   states), and `checkedBytes`. I retains `requireUnit`/`checkedInt`, including
   the released-arena guard, and validates `(n + 1) * 6`, with `n` a byte.
   Spans are never retained across a model update, allocator reuse, or release.
2. State cursors read symbol at +0 and frequency at +1, then advance six bytes
   for at most the validated count. They end at most one past that span. The
   four-state helper reads +0/+6/+12/+18 only when at least 24 bytes remain;
   its scalar tail reads the remaining members. UInt8 symbols index 256-byte
   masks, which occupy separate live allocations. No scratch offsets survive
   the scan. I's escape mask writes are idempotent for already-masked symbols.
3. Selected-state writes are at state +1; summary writes occupy context +2..<+4.
   Both lie inside already-validated live allocations. Multi-state arrays and
   their context occupy separate live allocator units; the frequency write
   cannot invalidate NumStats. No allocation occurs before these writes. A
   preceding state is read only after selecting index > 0. The successful-symbol
   helpers do not serve binary inline states. Value checks and subsequent
   successor validation/rescale remain.
4. Each scan sums at most 256 UInt8 frequencies, hence at most 65,280. A masked
   term is multiplied by exactly 0 or 1, and an available-state count is at most
   256. Wrapping arithmetic cannot overflow Int for any compressed input,
   including corrupt input. Frequency-total/subrange validation is still
   performed by the unchanged range coder; these bounds do not assume that the
   encoded threshold is valid.
5. H's SEE allocation has exactly 25 * 16 initialized entries. Both coordinates
   are checked before calculating their row-major index. The root sentinel 400
   is tested before every dereference. Reset overwrites initialized values;
   cursor destruction deinitializes/deallocates the allocation once.
6. Range input ownership and its 64 KiB allocation are unchanged. A load follows
   refill and has `0 <= byteOffset < byteCount <= 65536`. Refill validates short
   reads and the compressed end offset. No speculative input, sentinel overread,
   deferred corruption check, or changed normalization boundary is introduced.
   H's noncopyable cursors prevent duplicated ownership of its buffers and
   tables; I's original class ownership is retained.

## Identity and corruption equivalence

`make-corpus.sh W/corpus --scale 0.0078125` produced 71 archives. Its current
manifest includes RAR4 PPMd but omits H/I archives; `prepare-corpus.py` generated
`text-ppmd.7z` and `text-ppmd.zip` and added them to that temporary manifest (73
archives total). Every PPMd archive in the resulting manifest was tested.

`Outcomes.swift` links independently against the saved HEAD and candidate
libraries. It tests all seven ZIP PPMd fixtures, the frozen 7z PPMd fixture, both
RAR4 PPMd fixtures (including R0 solid), the three manifest PPMd archives, and all
six larger benchmark archives: 19 successful original archives. For frozen and
corpus fixtures it adds 208 truncation/bit-flip variants, read at buffer sizes
1, 4,099 and 262,144 (624 mutation outcomes). It records each entry's returned
byte count, SHA-256, exact reflected error and archive-open errors.

Final HEAD and accepted-candidate runs each exited 0 with **643 rows**. `cmp`
exited 0: the files are byte-identical, including exact errors and all returned
prefix hashes/counts. There are 123 outcomes with returned bytes followed by an
entry error. The retained `outcomes.jsonl` SHA-256 is
`4e553c8f024611634fd8a58d9e17c20652902fc8267a8cc25ac32eeb9a40d198`;
`outcome-comparison.json` records both independently computed digests.

`PPMdDifferentialTests` additionally exercises packed-range corruption against
KaitoKit's older frozen Swift implementation. A new batch-size test checks exact
errors and returned prefixes at 1/37/4,096/262,145 bytes, including partial writes
that the throwing read must not publish. Existing generated order/memory tests
cover 38 H/I archives and short-reading sources. `PPMdStateScanTests` checks
all counts 1...256 and all 256 symbols in exact unaligned spans, plus first-match
behavior. A second test checks all/none/sparse masks, escape values 0/1/255 and
maximum-frequency sums in exact spans; ASan covers both helpers. Existing ZIP restoration/release tests
and the R0 solid-fixture SHA test remain in the verification set.

## RAR4 call-site work left out of scope

The shared H model/SEE/search changes already apply to RAR4. `RAR29Decoder` still
calls `model.decodeByte` for every raw model byte through `decodePPMdByte`.
To use a whole-run cursor it would need to borrow both model and RAR range state
across its PPMd token loop, emit consecutive literals until the escape marker,
and commit input/output state at the same token/error boundaries. Escape action
bytes, matches, filters and block transitions must stay in token order. Simply
bulk-decoding model bytes into the final output buffer would mistake control
bytes for output. This needs a scoped model/coder cursor API as well as the
call-site change, with the same range byteOffset and persistent solid-model
commit boundaries. No such call-site or RAR range-cursor change is included.

## Commands and actual results

All Swift package commands set `CLANG_MODULE_CACHE_PATH=W/cache` and use
`--disable-sandbox`. Logs live under W. Commands that are scripts retain their
individual subprocess commands, stdout and exit codes in the accompanying raw
JSONL. Exploratory `rg`, `sed`, `cat`, `ls`, `find`, `wc`, read-only git and
source-edit operations completed as shown in the session; absent-file probes
and no-match `rg` searches sometimes returned 1 and are not verification failures.

| Command / run | Actual result |
|---|---|
| `swift build -c release --product kaito -debug-info-format none` | Baseline exit 0, 70.50 s; `build-before.log` |
| Initial cursor-only release build | Exit 1: Swift rejects conditional initialization/destruction of noncopyable values. Reset moved after owner initialization; `build-cursor.log` |
| Cursor/SEE release build | Exit 0, 67.42 s; `build-cursor-see.log` |
| Range/span release build | Exit 0, 65.49 s; `build-range-spans.log` |
| Advancing-scan release build | Exit 0, 62.14 s; `build-final.log` |
| Validated-update release build | Exit 0, 63.80 s; `build-validated-updates.log` |
| Four-state scan release build | Exit 0, 65.24 s; `build-scan.log` |
| Bounded-scan release build (I cursor trial) | Exit 0, 62.50 s; `build-final-bounded.log` |
| I class-model release build | Exit 0, 62.65 s; `build-I-class.log` |
| Shared branch-free mask release build | Exit 0, 61.98 s; `build-shared-mask.log` |
| Accepted final-source release build | Exit 0, 73.33 s; `build-accepted.log` |
| Accepted H/I PC profiles, 2 repetitions each | Both exit 0; `profile-{H,I}-accepted.log`; symbol summary exit 0 |
| Accepted harness compilation/run and HEAD comparison | Compile/run/`cmp` all exit 0; 643 identical rows; `harness-build-accepted.log`, `outcomes-accepted.log` |
| `otool -L W/asan/out/Products/Debug/KaitoKitTests.xctest/Contents/MacOS/KaitoKitTests` | Exit 0; confirms linkage to `libclang_rt.asan_osx_dynamic.dylib` |
| `bash Tests/Measurement/decode-ab/make-corpus.sh W/corpus --scale 0.0078125` | Exit 0; 71 archives; `corpus.log` |
| `python3 Tests/Measurement/ppmd-wave2/prepare-corpus.py W/corpus` | Exit 0; both 7zz invocations exit 0, resulting manifest 73 archives |
| Six `7zz a` benchmark archive commands described above | All exit 0 |
| `sample PID 3 -file W/sample.txt` / its bench wrapper | Sample exit 255 (cannot examine process); wrapper exit 0; `sample.log`, `sample-bench.log` |
| `clang -dynamiclib -O2 Tests/Measurement/ppmd-wave2/self-profile.c -o W/self-profile.dylib` | Exit 0 |
| `KAITO_PROFILE_OUT=... DYLD_INSERT_LIBRARIES=... kaito-before bench --threads 1 W/color.{7z,zip} 12` | Both exit 0; `profile-{H,I}-before.log` |
| Same PC profiles of first cursor/span candidate, 2 repetitions | Both exit 0; `profile-{H,I}-after.log` |
| `nm -n`, `swift demangle --compact`, `otool -tvV` on own binaries; `summarize-profile.py` | Exit 0; `profile-{before,after}.txt`, own-binary assembly under W |
| `swiftc -O -module-cache-path W/cache -I .build/release -I Sources/CBzip2 Tests/Measurement/ppmd-wave2/Outcomes.swift .build/release/KaitoKit.o -lz -lbz2 -o ...` | Baseline and all intermediate harness compilations exit 0 (six through shared-mask candidate) |
| Baseline outcomes before manifest extension | Exit 0, 545 rows; superseded by complete-manifest run |
| Complete-manifest HEAD and cursor/SEE, advancing-scan, four-state, bounded-scan and shared-mask candidates | All outcome runs exit 0, 643 rows; each `cmp` against HEAD exit 0 |
| Rejected I-cursor `bench.py ... --rounds 5 --sink` | Exit 0; 90 processes all exit 0; ZIP color paired median B/A 1.0354; `timings-cursor-I.jsonl` |
| `bench.py` I class trial, 3 rounds, ZIP only | Exit 0; 27 processes all exit 0; relative to I cursor: color 7,098.4 → 6,700.0 ms, JPEG 1,477.8 → 1,428.1 ms, text 287.7 → 297.2 ms; verification activity overlapped |
| `bench.py` shared-mask trial, 3 rounds, ZIP only | Exit 0; 27 processes all exit 0; relative to class/list candidate: color 6,832.7 → 5,704.6 ms, JPEG 1,454.9 → 956.7 ms, text 292.3 → 292.7 ms; verification activity overlapped |
| `swift test --scratch-path W/tests-final --filter PPMdStateScanTests` | Exit 0; 2 tests, no failures, 0.033 s; `test-scan.log` |
| Initial focused `swift test --scratch-path W/tests --filter 'PPMd\|RAR4FilterFixtureTests\|RAR4ReaderTests'` | Exit 0; 66 tests, 5 skipped, no failures, 229.79 s; pre-final cursor/SEE build; `test-targeted.log` |
| Initial `bench.py ... --rounds 3 --reps 3` | Exit 0; 54 processes, all exit 0. H image improvement, I image neutral/slower; superseded by final series; `timings-stage2.jsonl` |
| Six standalone `7zz t -mmt=1` timing probes | All exit 0; preliminary whole-process probes, not final medians |
| `kaito-before sha --sink --threads 1 W/text.7z` | Exit 0; 1 entry, 16,777,216 bytes |
| `sysctl -n machdep.cpu.brand_string hw.model hw.logicalcpu` | Exit 1, Operation not permitted |
| `pgrep -fl 'swift-test.*kaitokit-wave2-kd/tests'` | Exit 3, cannot get process list; no process was terminated |
| `sw_vers`, `swift --version`, `7zz` | Exit 0; versions recorded above |

| Final verification command | Actual result |
|---|---|
| Earlier full `swift test --scratch-path W/tests` (pre-final I cursor candidate) | Exit 0; 1,914 main tests (56 skipped), 34 compatibility tests, zero failures; 1,237.55 s + 2.09 s; `test-full.log`; final-source run is recorded separately below |
| `swift test --scratch-path W/asan --sanitize=address --filter PPMd` | Exit 0; 40 tests, 1 skipped, no failures, 566.83 s; ASan diagnostic search found no errors; `test-asan.log` |
| Final `swift test --scratch-path W/tests-final` | Exit 0; 1,915 main tests (56 skipped), 34 compatibility tests, zero failures; 1,239.90 s + 2.14 s; `test-full-final.log` |
| `python3 Tests/Measurement/ppmd-wave2/bench.py W W/kaito-before W/kaito-accepted --rounds 5 --sink --output W/timings-final.jsonl` | Exit 0; 90 processes, all exit 0; final table above; `bench-final.log` |
| `git diff --check` | Exit 0 |
| Python whitespace audit, including untracked source/tests/measurement files | Exit 0; no trailing whitespace or missing final newlines |

The ASan skip is the separately optional historical RAR3 solid fixture. The
required R0 `testSolidPPMdFixtureContinuesModelAndMatchesEveryInputSHA256` passed,
as did all 16 ZIP PPMd tests and both exact-span primitive tests.


