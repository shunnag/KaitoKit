# Clean-room AArch64 LZMA hot-loop experiment — 2026-10-30

**Round 1 rejected. Round 2 below is also rejected.** The primary four cases improve
by **0.708%** in the geometric mean of native/Swift best times, below the requested
8% gate. Every individual case is below 8%; text regresses. This candidate does
not close the gap to 7zz. Production sources, Package.swift and fuzz scripts were
restored to baseline; the unapplied experiment is retained as
[`native.patch`](../../Tests/Measurement/lzma-native/native.patch). No commit was made.

## Measurements

Baseline commit: `e350e99b271bac6b40299c978fbe27d9349b89e4`. arm64 macOS 27.2
(26B118), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Apple Clang 2100.3.34.1.
Both backends use **the same release executable**, SHA-256
`b7d998e6daac670c7eacf71ff223490e0bdb2a6ab108b74d174c746216cda036`.

Each cell is the **best of five separate processes**, measured with Python's
monotonic wall clock, in milliseconds. No in-process repetitions are used.
Commands are `kaito bench --threads 1 ARCHIVE 1`, with
`KAITOKIT_LZMA_BACKEND=swift` or `native`, and
`7zz x -so -mmt=1 -bd -bb0 ARCHIVE` with stdout redirected to `/dev/null`.
The three process orders rotate each round. Archives are warmed in the page
cache. This task's builds, tests, corpus generation and equivalence runs finished
before timed runs began; machine-wide idleness is not asserted.

The decision uses JPEG/text × LZMA2 7z/xz, equally weighted geometrically. This
rule was stated before observing timings. LZMA1 is supplemental. Reduction is
`100 * (1 - native / Swift)`; positive is faster. Native/7zz above 1 is slower.

| Input / container | Swift ms | Native ms | 7zz ms | Reduction | Native/7zz |
|---|---:|---:|---:|---:|---:|
| JPEG / LZMA2 7z | 1511.904 | 1460.480 | 1307.340 | +3.40% | 1.117 |
| JPEG / xz (LZMA2) | 1518.864 | 1470.058 | 1331.060 | +3.21% | 1.104 |
| Text / LZMA2 7z | 167.011 | 169.562 | 145.156 | -1.53% | 1.168 |
| Text / xz (LZMA2) | 167.257 | 171.264 | 165.193 | -2.40% | 1.037 |
| JPEG / LZMA1 7z | 1502.057 | 1462.065 | 1301.745 | +2.66% | 1.123 |
| Text / LZMA1 7z | 169.441 | 170.999 | 145.729 | -0.92% | 1.173 |

All 90 timed processes exit zero; all KaitoKit runs report the expected byte
count. Before timing each archive, both backends' SHA-256 match the original
input (12 successful comparisons). The complete samples, commands and CLI output
are in [`timings.jsonl`](../../Tests/Measurement/lzma-native/timings.jsonl).

Observed min–max ranges (all five samples retained, no outlier removal):

| Input / container | Swift ms | Native ms | 7zz ms |
|---|---:|---:|---:|
| JPEG / LZMA2 7z | 1511.904–1529.563 | 1460.480–1470.768 | 1307.340–1320.654 |
| JPEG / xz (LZMA2) | 1518.864–1533.652 | 1470.058–1483.750 | 1331.060–1341.160 |
| Text / LZMA2 7z | 167.011–177.940 | 169.562–174.680 | 145.156–150.277 |
| Text / xz (LZMA2) | 167.257–178.901 | 171.264–175.833 | 165.193–173.065 |
| JPEG / LZMA1 7z | 1502.057–1523.000 | 1462.065–1468.229 | 1301.745–1326.291 |
| Text / LZMA1 7z | 169.441–177.257 | 170.999–172.835 | 145.729–150.681 |

The synthetic JPEG input concatenates 136 independently encoded, complete
1024×1024 JPEG pages, 67,231,113 bytes (64.117 MiB). Pages have changing paper
colors, stripes and independent grain, encoded by macOS `sips` at quality 85.
Text is 67,108,864 bytes (64 MiB) from a fixed vocabulary and deterministic RNG.
Each 7z has one file; xz contains the exact same payload and opens through the
single-file reader, without compressed-tar staging. Both use an 8 MiB dictionary
and preset 6. `prepare.py` uses Python's standard `lzma` API only as a black-box
encoder, and constructs 7z framing from KaitoKit's own header tests. No 7zz writer
or correctness oracle was used. Input/archive hashes and sizes are in
[`corpus.json`](../../Tests/Measurement/lzma-native/corpus.json).

## Design and bounds

The experimental internal `CLZMAHot` C target borrows the existing UInt16
probability allocation with the exact Swift offsets (literal models start at
1846). Three calls process literal runs, new-match runs and rep symbols. Scalar
range/code/state/rep cursors cross the C interface; there is no probability or
dictionary duplication. Range/code stay 32-bit, and probabilities remain 16-bit.

The hand-written AArch64 `tree_step` keeps the comparison's carry for `adc` to
form `2 * symbol + bit` and for conditional selection of the preloaded child
probability. This avoids materializing a bit and comparing it again in that
step. Other binary/direct/reverse decoding, matched literals and state transitions
are C translations of KaitoKit's own Swift code. The kernel is C plus inline
AArch64 assembly, rather than an entire decoder written in a separate .S file.

Swift retains headers, allocation/reset/ownership of dictionary and input,
refills, match copying, limits, cancellation, error creation, and commits of the
public decoder state. C literals write only the contiguous span bounded by Swift.
Matched literals validate history before reading it. New matches are decoded
into at most 256 packed length/distance entries, validated in Swift, and copied
with the existing group helper. The scratch match array grows from 32 to 256
entries (an additional 1,792 bytes per decoder).

The existing 64-byte input sentinel and per-symbol overrun checks remain.
A new match uses at most 48 normalizations; literal/rep symbols use fewer.
No further symbol starts after overrun. The EOF sentinel is used to detect
truncation, never to accept missing input. All probability-tree child preloads
stay inside the existing allocation. Output spans, reference distances and
match lengths are checked before dictionary/output access. New-match runs drain
to the same 256-symbol/output-budget/refill boundary after a validation failure,
preserving the existing precedence of truncated input over distance/size errors.
As already documented on LZMADecoder, a throwing decoder must be discarded.

Both C assembly and function definitions are guarded by `__aarch64__`; all Swift
calls are guarded by `#if arch(arm64)`. Intel retains the Swift path even when
`KAITOKIT_LZMA_BACKEND=native` is set. A complete x86_64 release slice built and
ran a frozen LZMA1 fixture under Rosetta, returning 98,280 bytes and SHA-256
`0e9c8f51af5c1dc3253c320ef2266341d548b325a0f037a07b2060c0a5fa003e`.
The final C source, including inline assembly, also compiled directly for x86_64
with its guard excluding the assembly.

## Correctness and tests

- Thirteen frozen LZMA-family seeds: 7z LZMA1/LZMA2, ZIP LZMA, LZMA_Alone,
  xz CRC32/CRC64 and lzip. The exact source paths and hashes are in
  [`verification.json`](../../Tests/Measurement/lzma-native/verification.json).
- Existing `Scripts/fuzz/mutate.py --count 400`, seed 20260906, provides flips,
  overwrites, payload mutations, truncations, insertions and max-length mutations.
  The thirteen originals plus 400 mutants are read with buffers 1/4,099/65,536:
  **1,239 rows per backend**, including returned byte counts, SHA-256 and reflected
  open/stream errors. Swift, the C prototype, and the final assembly candidate
  match byte-for-byte, SHA-256
  `c17b863cd2823c884b21cf5830c1f49995651f2c830b2ac856f74c7e055a1da1`.
  The rows contain 540 open errors, 663 entry-stream errors (including 441 invalid
  LZMA distances and 51 truncations), and 262 entry rows returning nonempty data.
  One shared result is retained as [`outcomes.jsonl`](../../Tests/Measurement/lzma-native/outcomes.jsonl).
- Existing `Scripts/fuzz/run-mutants.sh --count 400 --timeout 5` on these seeds,
  final assembly candidate: **400 mutants, 0 crashes, 0 hangs, 0 ASan/UBSan findings**.
  C and Swift are both instrumented; the inline assembly probability store itself
  is not instrumented by ASan. Its address is bounded by the tree-index invariant,
  and surrounding C probability loads are instrumented. The experimental script patch permits a
  scratch build directory and adds `-Xcc -fsanitize=address,undefined`.
- Full `swift test`: **2,080 tests, 116 skipped, 2 failures**, 1,231.933 seconds.
  This run uses the C prototype before the tree_step assembly addition, with
  the same Swift bridge, model/state machine, validation and dictionary code.
  Both failures are existing `ZipStoredPayloadSPITests` methods that throw
  `required A1 oracle is unavailable: /private/tmp/kk-lzasm/no-7zz`:
  `testModernMethodsReturnCompressedBytesWithoutXZStaging` and
  `testPlainInfoZIPAndSevenZipStoredAndDeflate`.
  SevenZip fixture generation/output comparison was deliberately disabled to
  obey the timing-only restriction. These methods do not skip on missing tools.
  A Swift-backend rerun of this nine-test class has the identical two failures.
  No unrelated test was changed to hide these failures.
- Final assembly candidate `swift test --filter LZMA`: **95 tests, 12 skipped,
  0 failures**, 12.832 seconds. It includes ring-wrap, tiny reads, exact packed
  consumption, resets, corrupted input and output limits.

Logs are retained alongside the artifacts: `swift-test.log`, `lzma-test.log`,
`fuzz.log` and `swift-oracle-test.log`. An earlier full-run attempt was interrupted
after unrelated URL assertions compared `/private/tmp` against `/tmp` spelling;
the reported full run uses `TMPDIR=/tmp/kk-lzasm/tmp` (the same physical directory).
Initial default swiftbuild-engine builds were interrupted; all reported builds
use SwiftPM's native engine. The 8% decision did not trigger a full-suite rerun
of the final assembly candidate or implementation polishing.

## Reproduction

Apply the retained patch to the baseline checkout. Use a fresh scratch area;
all corpus, builds and runtime temporary files belong under `/private/tmp/kk-lzasm`.
The actual principal commands were:

```sh
W=/private/tmp/kk-lzasm
mkdir -p "$W/tmp"
export CLANG_MODULE_CACHE_PATH="$W/cache" TMPDIR=/tmp/kk-lzasm/tmp
patch -p1 < Tests/Measurement/lzma-native/native.patch
swift build --build-system native --disable-sandbox --scratch-path "$W/build" \
  -c release --product kaito -debug-info-format none
python3 Tests/Measurement/lzma-native/prepare.py "$W/corpus"
KAITO_7ZZ="$W/no-7zz" KAITOKIT_LZMA_BACKEND=native \
  swift test --build-system native --disable-sandbox --scratch-path "$W/tests"
KAITO_7ZZ="$W/no-7zz" KAITOKIT_LZMA_BACKEND=native \
  swift test --build-system native --disable-sandbox --scratch-path "$W/tests" --filter LZMA
python3 Tests/Measurement/lzma-native/bench.py \
  "$W/build/release/kaito" "$W/corpus" "$W/timings.jsonl"
swift build --build-system native --disable-sandbox --scratch-path "$W/intel" \
  --arch x86_64 -c release --product kaito -debug-info-format none
```

The original full run created `.build` as a temporary symlink to `$W/tests` for
CLI tests; no existing .build directory was overwritten. This symlink is removed
at cleanup. To reconstruct the small seeds, base64-decode each `source` listed
in verification.json into `$W/seeds/decoded_name`, then run the existing mutator:

```sh
python3 Scripts/fuzz/mutate.py --count 400 -o "$W/equivalence" "$W"/seeds/*
KAITO_FUZZ_BUILD_DIR="$W/asan" KAITOKIT_LZMA_BACKEND=native \
  bash Scripts/fuzz/run-mutants.sh --count 400 --timeout 5 "$W/seeds"
```

`Outcomes.swift` accepts an output JSONL path followed by directories of inputs.
It was compiled with `swiftc -O`, the debug build's KaitoKit objects/modules,
CBzip2 module map, and the final release `LZMAHot.c.o`, linked with `-lz -lbz2`.
Run the same harness in separate Swift/native processes and compare JSONL with
`cmp`. The final assembly harness deliberately links the new C object rather
than the earlier full-test binary's object.

## Provenance, limits and final state

Only KaitoKit's own Swift decoder, tests and existing verification records were
used to design this code. No external LZMA specification or implementation was
needed or opened. No 7-Zip, LZMA SDK, xz/liblzma or other implementation source or
assembly was opened or derived from; no foreign binary was disassembled. 7zz was
invoked only for the timed extraction commands. Python's compression API and
sips were used only to encode test input.

This is a result for this kernel, synthetic corpus, host and toolchain. The full
CLI comparison includes process startup, allocation, container and checksum
costs; it does not attribute the remaining gap specifically to 7zz assembly.
Other assembly designs and other arm64 CPUs remain unmeasured. Duplicated model
offsets in the experimental C code would require maintenance if adopted.
Intel's compile guard and fallback have direct build/runtime evidence, but no
Intel performance improvement is proposed.

No Japanese CHANGELOG entry or production tests were added because the requested
8% gate was not met. The only retained changes are this report, reproducible
measurement scripts, raw results/logs, hashes and the rejected patch. Allocated
scratch usage observed with `du` peaked at about 1.6 GiB; the lowest observed Data
volume free space was 62 GiB, above the 25 GiB stop threshold. Swift's initial
build engine used large sparse cache files; disk accounting here is allocated
blocks, not their logical extents. All scratch is deleted at final cleanup.


## Round 2 — counters and whole-chunk native loop (2026-10-30)

**Rejected again.** This round requires at least 8% single-thread reduction on
both JPEG and text, in both requested containers. The whole-chunk candidate
improves JPEG by 4.45% / 2.77%, text by 11.13% / 6.06%, and fails that gate.
No implementation polishing or further performance variants were attempted after
these results. The production decoder, Package.swift, fuzz scripts and CHANGELOG
are byte-identical to the original baseline. The rejected patch is retained as
[`round2/chunk-native.patch`](../../Tests/Measurement/lzma-native/round2/chunk-native.patch).
No commit was made.

### Counter collection

The exact same corpus was regenerated: its manifest is byte-identical to the
round-1 corpus.json. Only the four LZMA2 7z/xz cases are measured in this round.
Each row below is the fastest of five separate processes; instructions, cycles,
IPC and peak RSS come from that **same process**, rather than independently
choosing each counter's minimum. Commands remain `kaito bench --threads 1 ARCHIVE 1`
and `7zz x -so -mmt=1 -bd -bb0 ARCHIVE`, with 7zz stdout sent to `/dev/null`.
Orders alternate for the initial two-way comparison. All target processes exit 0.

`/usr/bin/time -l` was actually invoked for every sample, but this sandbox denies
its `sysctl kern.clockrate` call. It prints real/user/sys time and then
`time: sysctl kern.clockrate: Operation not permitted`, without the extended
counter/RSS lines. The wrapper exits 1 despite the target's successful exit.
These errors are retained verbatim in every sample.

A small, clean-room launcher provides **real OS counters**, not estimates:
`waitid(WEXITED | WNOWAIT)` retains the exited child; `proc_pid_rusage` with
`RUSAGE_INFO_V6` reads `ri_instructions` and `ri_cycles`; `wait4` then obtains
`ru_maxrss` and reaps it. This API succeeds under the same sandbox. It measures
the target process, excluding the collector's instructions, cycles and RSS.
The launcher uses only public macOS API declarations. `/usr/bin/time -l`
wraps this launcher, and its failure is kept separate from target status.
Wall time uses CLOCK_MONOTONIC around target launch/exit. RSS is Darwin bytes,
converted to MiB below. Instruction/byte and cycle/byte divide by the known
67,231,113 JPEG or 67,108,864 text output bytes. IPC is instructions/cycles.

| Input | Decoder | Best ms | Instructions/byte | Cycles/byte | IPC | Peak RSS MiB |
|---|---|---:|---:|---:|---:|---:|
| JPEG / 7z | swift | 1510.524 | 256.768 | 88.136 | 2.913 | 80.141 |
| JPEG / 7z | 7zz | 1298.828 | 159.028 | 75.973 | 2.093 | 12.484 |
| JPEG / xz | swift | 1506.911 | 256.759 | 87.945 | 2.920 | 83.078 |
| JPEG / xz | 7zz | 1328.487 | 162.880 | 77.526 | 2.101 | 12.703 |
| Text / 7z | swift | 165.148 | 31.798 | 9.557 | 3.327 | 79.984 |
| Text / 7z | 7zz | 142.623 | 23.265 | 8.294 | 2.805 | 12.469 |
| Text / xz | swift | 168.180 | 31.852 | 9.723 | 3.276 | 82.984 |
| Text / xz | 7zz | 163.802 | 27.133 | 9.622 | 2.820 | 12.719 |

Raw values and all 40 samples are in
[`round2/baseline-counters.jsonl`](../../Tests/Measurement/lzma-native/round2/baseline-counters.jsonl).
Kaito retires about 58–61% more instructions than 7zz on JPEG, 37% more on 7z
text, and 17% more on xz text. Its IPC is higher, so the instruction difference
is much larger than the elapsed-time difference. Counters alone do not establish
which operations 7zz implements differently.

The RSS comparison includes the CLI's output policy: `kaito bench` retains a
complete ~64 MiB Data while 7zz streams to `/dev/null`. This is not a claim that
the decoder core intrinsically requires six times as much memory.

### Profile and attribution

The requested profiler paths were attempted on Kaito itself:

- `sample PID 1 1 -file ...` cannot examine the owned Kaito process and suggests
  sudo. No privilege escalation or sandbox bypass was used.
- `xctrace record --template 'CPU Counters' ... --launch -- kaito ...` initially
  fails writing its default cache. Redirecting CoreFoundation's cache with
  CFFIXED_USER_HOME into scratch allows initialization, but recording still
  fails with `Error connecting to DTServiceHub`. Its nominal exit 0 does not
  mean recording succeeded. Logs are retained as `sample-error.log` and
  `xctrace-error.log`; no percentages are derived from those failed traces.

Instead, our own measurement-only dylib samples **Kaito's main thread** in
process. A helper thread sends SIGPROF at pseudo-random 0.3–1.7 ms intervals;
the handler records PC, LR and a bounded, monotonically increasing frame-pointer
chain within the active main stack. Symbol lookup and output happen after
sampling stops. This helper is never loaded into 7zz. A preliminary periodic
ITIMER_PROF version showed severe phase locking to memcpy/pread and was discarded;
the retained results use jitter. Decoder worker count stays 1; the extra thread
only collects samples. These are approximate main-thread wall-stack shares,
not xctrace hardware-event samples or a process-wide CPU-time decomposition.

A separate `-O` release profiling build carries DWARF, with the same Swift 6.4
compiler. Its text differs by 428 bytes from the no-debug timing build; it is
not used for timing/counters. `atos` resolves **only our executable's addresses**,
including inline frames, against our own DWARF. System-function names from
`dladdr` help recognize CRC/copy calls, but no foreign code is disassembled.
`symbolize.py` and `classify.py` retain the exact classification rules. Leaf and
inline frames take precedence; source lines distinguish literal dictionary
stores from the bit kernel. Parent frames assign libc copy/input calls.

| Input | Samples | Range/tree decoding | Match/dictionary writes | Input refill | Output/CRC/handoff | State/call bookkeeping | Other |
|---|---:|---:|---:|---:|---:|---:|---:|
| JPEG / 7z | 3869 | 89.09% | 0.88% | 0.34% | 0.49% | 9.15% | 0.05% |
| JPEG / xz | 3885 | 87.82% | 0.93% | 0.51% | 0.93% | 9.78% | 0.03% |
| Text / 7z | 4306 | 76.87% | 14.31% | 0.42% | 3.02% | 5.27% | 0.12% |
| Text / xz | 4465 | 74.00% | 15.21% | 0.52% | 5.08% | 5.13% | 0.07% |

The bookkeeping column includes per-symbol state changes, cursor commits,
prologue/epilogue and unresolved line-0 instructions. It is an upper bound on
pure per-call overhead, not evidence that 9% is removable call overhead.
Percentages are sampling estimates; narrow categories and optimized line
attribution should not be overinterpreted. Raw stacks and resolved own-code
frames are retained as `round2/*.profile.json.gz`; aggregate details are in
[`round2/profile-summary.json`](../../Tests/Measurement/lzma-native/round2/profile-summary.json).

The attribution supports a whole-loop experiment: JPEG is about 88–89% in
range/tree decoding; text is 74–77%, plus 14–15% in match/dictionary work.
Refills account for only about 0.3–0.5%, and output/CRC/handoff for 0.5–5.1%.
Optimizing only output delivery or refill cannot reasonably provide 8% on both
inputs in this measurement. The large black-box instruction-count difference
therefore motivates combining the decode and dictionary state machines.

### Whole-chunk candidate and decision

The internal `CLZMAChunk` target borrows the same dictionary, input storage and
UInt16 probability layout. Its C/AArch64 chunk loop owns literals, new matches,
reps, pending match copies, dictionary ring writes, output-window flushes and
range input-pointer advances. The earlier hand-written carry-based tree kernel
is reused. New matches are copied inside the native run, preserving the original
one/32-match grouping instead of staging an entire 256-match run for Swift.
Direct and short copies have the same bounded head/tail and forward-overlap
semantics as KaitoKit's Swift copy helpers.

Swift retains setup, header/properties validation, allocation, size/cancellation
checks and error creation. The native loop returns only at output capacity/end,
error, or an exhausted input window. LZMA2's packed payload is already resident;
raw LZMA1 returns for ByteSource refill only at the existing input-window boundary.
A consumed match-head flag survives such a refill. Scalar state crosses the FFI
at these boundaries, not per literal/match/rep run. The existing 64-byte sentinel,
symbol overrun checks, distance/output bounds and 256-symbol failure-drain
boundary are retained. C statuses map to the same Swift error strings and order.
The default experiment path is Swift; `KAITOKIT_LZMA_BACKEND=native` selects the
candidate. C definitions/assembly use `__aarch64__`, and Swift calls use
`#if arch(arm64)`.

The final comparison uses the same patched executable for Swift/native and
rotates Swift/native/7zz process order. All four original payload SHA-256 values
match in both Kaito backends before timing. All task builds, profiling runs,
comparisons and fuzz/tests finish before these timings. Machine-wide idleness
is not asserted. Every elapsed-time cell is best-of-five, milliseconds:

| Input | Swift | Whole native | 7zz | Native time reduction |
|---|---:|---:|---:|---:|
| JPEG / 7z | 1503.655 | 1436.728 | 1300.220 | +4.45% |
| JPEG / xz | 1495.398 | 1453.941 | 1324.554 | +2.77% |
| Text / 7z | 176.088 | 156.496 | 144.309 | +11.13% |
| Text / xz | 171.110 | 160.736 | 165.035 | +6.06% |

Counters for those same fastest Swift/native samples:

| Input | Instructions/byte Swift / native | Cycles/byte Swift / native | IPC Swift / native |
|---|---:|---:|---:|
| JPEG / 7z | 256.697 / 240.515 | 87.287 / 83.577 | 2.941 / 2.878 |
| JPEG / xz | 256.715 / 240.629 | 87.016 / 84.222 | 2.950 / 2.857 |
| Text / 7z | 31.906 / 30.437 | 10.110 / 9.099 | 3.156 / 3.345 |
| Text / xz | 31.832 / 30.423 | 9.894 / 9.285 | 3.217 / 3.277 |

All 60 target processes exit 0; all samples and failed time-l formatting output
are retained in `round2/chunk-counters.jsonl`. Native JPEG instructions fall
about 6.3%, but cycles and elapsed time improve less. Text 7z's 11.13% is not a
pass for the requested gate: text xz is only 6.06%, and both JPEG cases are below
8%. The earlier and later Swift text timings also vary, so the isolated 7z text
percentage should not be treated as a confirmed general speedup. No extra trial
or tuning was performed after rejection.

### Validation and retained state

- The existing 13 seeds plus the same 400 mutants, at 1/4,099/65,536-byte reads:
  **1,239 rows per backend**, byte-for-byte equal to each other and to the
  round-1 reference. SHA-256 remains
  `c17b863cd2823c884b21cf5830c1f49995651f2c830b2ac856f74c7e055a1da1`.
- Existing fuzz runner: **600 mutants, 0 crashes, 0 hangs, 0 ASan/UBSan findings**.
  C and Swift are instrumented. As before, the inline assembly probability store
  itself is outside ASan instrumentation; its tree-index bounds are preserved.
- `swift test --filter LZMA`: **95 tests, 12 skipped, 0 failures**, 13.396 seconds.
  The 7zz-dependent tests remain disabled to preserve timing/counter-only usage.
  No full 2,080-test rerun was made for this rejected candidate; round 1's full
  suite and its two mandatory-oracle failures remain documented above.
- Complete Intel release build succeeded. With the native environment switch,
  the x86_64 executable ran the frozen LZMA1 fixture under Rosetta via Swift:
  98,280 bytes, SHA-256
  `0e9c8f51af5c1dc3253c320ef2266341d548b325a0f037a07b2060c0a5fa003e`.
- Patch dry-run succeeds against the restored baseline; production source,
  Package.swift, fuzz scripts and CHANGELOG have no diff. No commit was made.

Counter launchers, sampler, symbolizer/classifier, both rejected patches and
measurement records are retained under `Tests/Measurement/lzma-native/`.
Round-2 binary/patch hashes and every selected counter are in
[`round2/verification.json`](../../Tests/Measurement/lzma-native/round2/verification.json).
All implementation inputs remain KaitoKit's own Swift and the previous clean-room
candidate; macOS public API headers were used for counter/profile collection.
No forbidden codec source, assembly or binary disassembly was inspected.

Reproduction starts with the restored baseline: regenerate the same corpus,
build the no-debug release binary, compile `round2/counters.c`, and run
`round2/counters.py BINARY COLLECTOR CORPUS OUTPUT.jsonl`. It invokes time-l and
records the OS fallback counters. For the profile, build a separate release with
DWARF **before applying the candidate**, copy it to `W/bin/profile`, compile
`round2/self-sample.c` as a dylib, and run it only on Kaito with
`DYLD_INSERT_LIBRARIES` and `KK_PROFILE_OUT=W/CASE.sample.tsv`. Use 3 JPEG or
30 text bench repetitions. Then `symbolize.py W` and `classify.py W` reproduce
the baseline-source-line classification. Apply `round2/chunk-native.patch`, build
the candidate, and add `--candidate` to the counter driver to measure all three
backends. Set TMPDIR=/tmp/kk-lzasm/tmp and CLANG_MODULE_CACHE_PATH under W throughout.

Observed allocated scratch peak is about 1.4 GiB and minimum observed Data free
space is 65 GiB. Scratch is deleted at cleanup. The 8% gate was not met, so no
Japanese CHANGELOG entry or production-test polishing is performed.
