# ZIP AES PBKDF2 and sequential key look-ahead

Task `cooViewer-y9eq.11`, branch `perf/zip-aes-pbkdf2` from `origin/main`.
Completed 2026-10-29 on arm64 macOS 27.2, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, clang 2100.3.34.1). The host reports 16 logical CPUs;
7zz is 26.05 arm64. Generated artifacts are under `.build/zip-aes-verification`,
builds under `.build/zip-aes-{final,asan,intel}`, and detailed build/test logs in `/tmp`.

## Result and per-file changes

PBKDF2-HMAC-SHA1 is **3.80× faster** for the WinZip AES-256 parameters.
Alternating archive measurements show **27.65× faster** extraction for 2,000
small AES-256 entries. Four large AES-256 entries show a 3.4% reduction in
extraction time; 7zz remains faster for this large-entry workload.

| File | Change |
|---|---|
| `Sources/CBzip2/PBKDF2SHA1.h` | Clean-room ARM SHA-1 final-block compression, reusable HMAC pad states, generic PBKDF2 setup, and CommonCrypto fallback. |
| `Sources/CBzip2/shim.h` | Exposes the new header through the existing C bridge. |
| `Sources/KaitoKit/Core/CommonCryptoPrimitives.swift` | Routes SHA-1 PBKDF2 through the bridge, preserving pointer lifetimes and failure handling. |
| `Sources/KaitoKit/Formats/Zip/ZipAESKeyLookAhead.swift` | Bounded reader-owned key jobs on the existing leaf pool, memory accounting, cancellation-aware waits and reset handling. |
| `Sources/KaitoKit/Formats/Zip/ZipReader.swift` | Detects sequential reads, schedules salt-only look-ahead, consumes matching keys, and caches them only after authentication. |
| `Tests/KaitoKitTests/Zip/ZipPBKDF2SHA1Tests.swift` | Independent CommonCrypto oracle for the required matrix, 10,000 random cases and extra boundaries. |
| `Tests/KaitoKitTests/Zip/ZipAESKeyLookAheadTests.swift` | Thread/memory/power policy, byte identity, error ordering, password/seek/reopen, changed-salt and authentication-cache regressions. |
| `Tests/Measurement/zip-aes/KDFBench.c` | Compares CommonCrypto, copied contexts, ARM kernel and compression-only reference. |
| `Tests/Measurement/zip-aes/KDFVerify.c` | Standalone C oracle with unaligned buffers, null empty inputs, output guards and parameter checks. |
| `Tests/Measurement/zip-aes/ArchiveBench.py` | Reproducible alternating small/large archive measurements and deterministic large fixture creation. |
| `Documentation/verification/2026-10-29-zip-aes-kdf.md` | This evidence, commands, results and limitations. |

No `.git` writes, `bd`, `CHANGELOG.md` changes, package platform changes or
unrelated refactors were performed. No external implementation source was opened.
7zz was used only as a black-box executable for requested fixtures and timing.

## Clean-room derivation and minimum work

Algorithm sources were limited to KaitoKit's own RAR5/ZIP/C-shim/leaf-pool code,
[RFC 8018 §5.2](https://www.rfc-editor.org/rfc/rfc8018.html#section-5.2),
[RFC 2104 §§2/4](https://www.rfc-editor.org/rfc/rfc2104.html#section-2),
[FIPS 180-4 §§4–6.1](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf),
and Apple's installed CommonCrypto headers and toolchain `arm_neon.h` declarations.
No 7-Zip, XADMaster, libarchive or other cryptographic/archive implementation
source was consulted.

For a password of at most 64 bytes, salt length 16, iteration count 1,000 and
output length 66, PBKDF2 needs `ceil(66/20) = 4` output blocks and 4,000 HMACs.
The compression-count minimum for this construction with reusable pads is
`2 + 4 * 1000 * 2 = 8,002` SHA-1 blocks, or 640,160 SHA-1 rounds.
The implementation attains that logical count. Longer passwords additionally
require their initial SHA-1 hash, as required by HMAC.

CommonCrypto handles long-key hashing, pad absorption, arbitrary-length salts
and each block's first HMAC. Later iterations use two ARM SHA-1 single-block
compressions. Their final blocks contain 20 digest bytes, `0x80`, zero padding
and the total bit length 672, including the 64-byte pad. Intermediate words stay
in host order; only the first input and final output require byte-order conversion.

Final KDF medians, five interleaved samples of 500 derivations per method:

| Method | µs/derivation |
|---|---:|
| `CCKeyDerivationPBKDF` | 694.892 |
| Copied `CC_SHA1_CTX` inner/outer states | 1,224.250 |
| Selected ARM kernel | 182.688 |
| Dependent 8,000-block compression-only reference | 186.352 |

The ARM kernel is 3.80× faster than CommonCrypto. Copied contexts were rejected
because their measured update/final-call cost was slower than the complete
CommonCrypto PBKDF2 call. The compression-only reference isolates compression
cost; it is not a universal lower bound on wall time because code generation,
scheduling and constants differ. The theoretical minimum above is a count of
hash compressions, not an asserted CPU-independent duration.

## Bit identity, portable fallback and Intel slices

The required **162-case Cartesian product** compares every derived byte directly
with Apple's `CCKeyDerivationPBKDF`:

| Parameter | Values |
|---|---|
| Password byte length | 0, 1, 63, 64, 65, 200 |
| Salt byte length | 8, 12, 16 |
| Iterations | 1, 2, 1,000 |
| Derived byte length | 34, 50, 66 |

Both Swift and standalone C also run **10,000 deterministic random cases**:
password lengths 0…256, salt lengths 0…160, iterations chosen from
1/2/3/17/1,000, and output lengths 1…101. Extra cases cover a 4,097-byte password,
1,024-byte salt, empty salt, NUL/high-bit bytes and output counters beyond 255
(5,141 output bytes). These exercise long-key prehashing, salt padding boundaries,
multi-block salts and partial output blocks. The C harness additionally checks
unaligned input/output, exact input allocation bounds, null pointers for empty
inputs, output sentinels, and invalid iteration/output sizes.

The ARM intrinsics are compiled only for `__aarch64__`. Intel and explicitly
forced portable builds delegate to `CCKeyDerivationPBKDF`. Supported Apple arm64
hardware supplies these SHA-1 instructions; Clang's target feature name is `sha2`.

Intel evidence is stronger than compilation alone:

- The **entire package and prebuilt test bundles** built with `--arch x86_64
  --build-tests`. `file` confirms x86_64 slices for the CLI, test bundle and
  `libKaitoKitDynamic.dylib`.
- `vtool` reports the test bundle's minimum macOS version as **26.0**.
- The standalone x86_64 C verifier ran under Rosetta and passed the full matrix,
  random cases, boundaries and parameter checks.
- The prebuilt x86_64 ZIP test bundle ran under Rosetta through universal
  `xctest`: **28 tests, zero failures**, including the Swift CommonCrypto matrix,
  random cases and all 6,000 small AES-128/192/256 fixture entries.

This verifies the slice and fallback used by `macos-26-intel` prebuilt-test CI.
Runtime verification here used Rosetta, not physical Intel hardware. The installed
SwiftPM discovery helper is arm64-only, so direct `swift test --arch x86_64
--skip-build` failed to load the x86_64 bundle. Explicitly selecting the x86_64
slice of universal `xctest` resolved that runner limitation without code changes.

## Why key look-ahead was justified, and its contract

After part 1, key derivation still costs about 183 µs versus the existing roughly
1 µs small-entry streaming/authentication work. It remains dominant, so the
contained ZIP-only look-ahead was implemented.

For password byte count `p`, memory budget `M` and resolved thread count `T`,
the job capacity is bounded by
`min(T - 1, 8, LeafDecodePool.capacity, floor(M / (4096 + 2*p)))`, with
nonpositive/overflowing capacities disabled. The reservation covers retained
password Data, its worker byte-array copy, contexts, result, tickets and overhead.
The existing authenticated key cache retains its previous semantics.

Automatic thread resolution already applies `DecodePowerPolicy`, including its
low-power/thermal policy and physical-memory clamp. Explicit `decodeThreads`
retains the existing override behavior. One thread, insufficient parallel memory
or high-latency input disables look-ahead. The reader scans only a fixed window
of upcoming entries and submits immutable password/salt/strength values to the
existing process-wide bounded leaf pool. No worker accesses mutable reader or
source state. Seeks, password changes and reopen discard or replace the window;
already-running jobs finish before its memory budget can be reused.

Future headers are read speculatively but neither validated nor cached. Future
read/parse errors are ignored and retried by the normal path in entry order.
Workers never check future verifiers. The normal entry path rereads the actual
salt, consumes only a matching speculative key, then checks the existing 2-byte
verifier and HMAC. The first wrong password therefore fails before any following
jobs are scheduled; later wrong-password errors occur at their original entry.
Speculative keys enter the reusable cache **only after successful HMAC**.
Changed salts discard speculation; worker failures fall back to normal derivation.

`ReadLimits` contains no ZIP KDF work budget. Existing 7z/RAR5/StuffIt X budgets
were left unchanged; the parallel memory budget is respected and no new public
ZIP budget API was added.

## Final alternating archive measurements

- Small: 2,000 distinct 127-byte files, **254,000 output bytes**, AES-256 ZIP
  **610,022 bytes**. Plaintext byte `j` of file `i` is `(j*29+i)&255`.
- Large: four distinct **16 MiB** files, **67,108,864 output bytes**, AES-256
  stored (`-mx=0`) ZIP **67,109,582 bytes**. Deterministic random plaintext avoids
  making decompression the benchmark variable.
- Password: `KaitoFuzz`. The saved `kaito-before` binary was captured from the
  unchanged worktree before the new KDF was connected. Both binaries are release.
- One warm-up per method/archive, then seven retained rounds. Method order rotates
  and reverses on alternating rounds, and small/large archive order alternates.
  All builds, sanitizers and test runs had finished before timing. Every command
  exited 0 and each Kaito sample reported the expected byte count.
- Each Kaito command is `bench <zip> 1 -p KaitoFuzz [--threads 1|4]`;
  automatic runs omit `--threads`. The reference is `7zz t -pKaitoFuzz <zip>`.
  `kaito bench` measures extraction separately; wall time also includes process
  startup and opening. These are warm-cache measurements.

Median milliseconds:

| Method | Small extract | Small wall | Large extract | Large wall |
|---|---:|---:|---:|---:|
| Before, automatic threads | 1431.868 | 1440.872 | 43.576 | 50.675 |
| After, 1 thread | 371.682 | 380.810 | 42.443 | 49.720 |
| After, 4 threads | 136.983 | 146.066 | 41.668 | 48.923 |
| After, automatic threads | 51.787 | 61.299 | 42.081 | 49.461 |
| 7zz t | — | 449.515 | — | 36.100 |

Small extraction improved **27.65×** with automatic look-ahead and **3.85×** with
one thread. Comparing process wall time, automatic Kaito is **7.33× faster** than
7zz on the small archive. The large archive is **3.4% faster** than baseline in
extraction time; 7zz is still **1.37× faster** than final Kaito by wall time there.
Large-entry AES/stream processing is outside this KDF change's scope.

Byte identity passed for all 6,000 small files across AES-128/192/256. Both saved
baseline and final CLIs also extracted all four large files byte-identically to
the generated inputs (67,108,864 bytes per extraction).
Raw samples, actual command arrays and round order are retained in
`.build/zip-aes-verification/alternating-timings.json`.

## Verification commands and results

Commands run from the worktree root. Shared settings below are literal values
used for the recorded invocations; all build paths stay inside the worktree.

```sh
export CLANG_MODULE_CACHE_PATH=/tmp/kaito-zipaes-module-cache
export KAITO_ZIP_AES_FIXTURE_DIR="$PWD/.build/zip-aes-verification"
FILTER='ZipPBKDF2SHA1Tests|ZipAESKeyLookAheadTests|ZipAESReuseTests|ZipEncryptionPrimitiveTests|ZipAESKeyMaterialTests'
```

| Command | Result |
|---|---|
| `swift build --scratch-path .build/zip-aes-final --disable-sandbox -debug-info-format none` | PASS, 1.15 s (completed before continuation). |
| `swift build --scratch-path .build/zip-aes-final -c release --disable-sandbox -debug-info-format none` | PASS; continuation rebuild completed in **73.13 s**. Previous isolated/default release builds also passed in 69.55/66.35 s. |
| `swift test --scratch-path .build/zip-aes-final --disable-sandbox -debug-info-format none --filter "$FILTER"` | PASS, **30 tests**, zero failures, 16.71 s; 6,000 small fixture files. Filter also includes two existing SevenZip AES reuse tests. |
| `swift test --disable-sandbox -debug-info-format none` | PASS, **2,044 tests, 57 skipped, zero failures**. KaitoKit: 2,010 tests in 1,209.47 s; compat: 34 in 2.11 s. This run preceded two added cache/salt regression methods. |
| `swift test --scratch-path .build/zip-aes-final --skip-build --disable-sandbox -debug-info-format none --parallel --num-workers 4 --xunit-output .build/zip-aes-verification/full-final.xml` | PASS, exit 0, **2,046 final-source cases, zero failures/errors**: 2,012 KaitoKit + 34 compat. The parallel xUnit writer does not preserve XCTest skip markers. |
| `ASAN_OPTIONS=detect_leaks=0 swift test --scratch-path .build/zip-aes-asan --sanitize address --disable-sandbox -debug-info-format none --filter "$FILTER"` | PASS, build 30.93 s; **30 tests**, zero failures, 18.81 s; **no sanitizer findings**. |
| `swift build --scratch-path .build/zip-aes-intel --arch x86_64 --build-tests --disable-sandbox -debug-info-format none` | PASS, **30.21 s**; package, CLI, dynamic library and prebuilt tests have x86_64 slices. |
| `swift test --scratch-path .build/zip-aes-intel --arch x86_64 --skip-build --disable-sandbox -debug-info-format none --filter "$FILTER"` | Runner failure: this Xcode's SwiftPM discovery helper is arm64-only. Resolved by explicit x86_64 `xctest` below. |
| `file .build/zip-aes-intel/out/Products/Debug/KaitoKitTests.xctest/Contents/MacOS/KaitoKitTests .build/zip-aes-intel/out/Products/Debug/kaito .build/zip-aes-intel/out/Products/Debug/libKaitoKitDynamic.dylib` | PASS: all **Mach-O x86_64**. |
| `xcrun vtool -show-build .build/zip-aes-intel/out/Products/Debug/KaitoKitTests.xctest/Contents/MacOS/KaitoKitTests` | PASS: platform MACOS, **minos 26.0**. |
| `python3 Tests/Measurement/zip-aes/ArchiveBench.py --prepare-only` | PASS: created the four-large-file AES-256 fixture using the 7zz command below. |
| `python3 Tests/Measurement/zip-aes/ArchiveBench.py --rounds 7` | PASS: all **80 commands** (10 warm-ups + 70 measured invocations) exited 0; final table above. |
| `GIT_OPTIONAL_LOCKS=0 git diff --check` | PASS, no output. New-file newline/trailing-whitespace checks also passed. |

Explicit prebuilt x86_64 test execution (exit 0, **28 tests, zero failures**, 11.07 s):

```sh
KAITO_ZIP_AES_FIXTURE_DIR="$PWD/.build/zip-aes-verification" \
  arch -x86_64 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest 'KaitoKitTests.ZipPBKDF2SHA1Tests,KaitoKitTests.ZipAESKeyLookAheadTests,KaitoKitTests.ZipAESReuseTests,KaitoKitTests.ZipEncryptionPrimitiveTests,KaitoKitTests.ZipAESKeyMaterialTests' \
  .build/zip-aes-intel/out/Products/Debug/KaitoKitTests.xctest
```

Standalone C sanitizer and Intel runtime checks (each compile exited 0 with
`-Wall -Wextra -Werror`; each verifier printed
`162 matrix + 10000 random + 2 boundary cases; parameter checks: PASS`):

```sh
xcrun clang -O1 -g -fsanitize=address -fno-omit-frame-pointer \
  -Wall -Wextra -Werror -I Sources/CBzip2 \
  Tests/Measurement/zip-aes/KDFVerify.c -o .build/zip-aes-verification/kdf-asan
ASAN_OPTIONS=detect_leaks=0 .build/zip-aes-verification/kdf-asan

xcrun clang -O1 -g -fsanitize=address -fno-omit-frame-pointer \
  -Wall -Wextra -Werror -DKK_PBKDF2_SHA1_FORCE_PORTABLE -I Sources/CBzip2 \
  Tests/Measurement/zip-aes/KDFVerify.c -o .build/zip-aes-verification/kdf-portable-asan
ASAN_OPTIONS=detect_leaks=0 .build/zip-aes-verification/kdf-portable-asan

xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
  -I Sources/CBzip2 Tests/Measurement/zip-aes/KDFVerify.c \
  -o .build/zip-aes-verification/kdf-intel
arch -x86_64 .build/zip-aes-verification/kdf-intel
```

Both ASan verifier runs had **zero findings**. `detect_leaks=0` is intentional:
this macOS ASan runtime rejects `detect_leaks=1` as unsupported; address and bounds
instrumentation remain enabled. The initial default Swift build also hit a
sandbox-only dSYM `Operation not permitted` failure; `-debug-info-format none`
avoids that step. No permissions were changed.

KDF timing command (exit 0; output is the four-row KDF table above):

```sh
xcrun clang -O3 -Wall -Wextra -Werror -I Sources/CBzip2 \
  Tests/Measurement/zip-aes/KDFBench.c -o .build/zip-aes-verification/kdf-arm
.build/zip-aes-verification/kdf-arm
```

The earlier compile-only Intel check also passed:

```sh
xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
  -I Sources/CBzip2 -c Tests/Measurement/zip-aes/KDFVerify.c \
  -o .build/zip-aes-verification/kdf-intel.o
```

The small fixtures were generated as follows (all three 7zz invocations exited 0):

```sh
python3 - <<'PYFIXTURE'
from pathlib import Path
import subprocess
root = Path('.build/zip-aes-verification').resolve()
files = root / 'input'
files.mkdir(parents=True, exist_ok=True)
for i in range(2000):
    (files / f'{i:04d}.bin').write_bytes(bytes((j*29+i)%256 for j in range(127)))
for bits in (128, 192, 256):
    subprocess.run(['/opt/homebrew/bin/7zz', 'a', '-tzip', f'-mem=AES{bits}',
                    '-pKaitoFuzz', str(root/f'aes{bits}.zip'), '.'], cwd=files, check=True)
PYFIXTURE
```

Large fixture command, executed by `ArchiveBench.py` from `large-input` (exit 0):

```sh
# cwd: .build/zip-aes-verification/large-input
/opt/homebrew/bin/7zz a -tzip -mx=0 -mem=AES256 -pKaitoFuzz \
  /Users/nagash/Github/KaitoKit-wt-zipaes/.build/zip-aes-verification/aes256-large.zip .
```

`ArchiveBench.py` resolves the archive path before setting the subprocess cwd,
records that absolute command, and uses four 16 MiB files
from Python's deterministic generator seeded with `0x801821041804`.

Extraction verification commands (all exited 0):

```sh
# The three invocations, expressed as a loop:
for bits in 128 192 256; do
  .build/zip-aes-final/out/Products/Release/kaito extract \
    ".build/zip-aes-verification/aes${bits}.zip" -p KaitoFuzz --threads 4 \
    -o ".build/zip-aes-verification/extracted${bits}"
done

.build/zip-aes-verification/kaito-before extract \
  .build/zip-aes-verification/aes256-large.zip -p KaitoFuzz --threads 4 \
  -o .build/zip-aes-verification/large-extracted-before
.build/zip-aes-final/out/Products/Release/kaito extract \
  .build/zip-aes-verification/aes256-large.zip -p KaitoFuzz --threads 4 \
  -o .build/zip-aes-verification/large-extracted-after
```

Python compared name-to-byte dictionaries from extracted directories with the
input directories: **2,000/2,000 files per small strength**, and **4/4 large files
for each binary**, all identical. Large command arrays and results are in
`.build/zip-aes-verification/large-byte-identity.json`.

Final byte comparison command (exit 0, `6000 small + 8 large extracted files: PASS`):

```sh
python3 - <<'PYIDENTITY'
from pathlib import Path
root = Path('.build/zip-aes-verification')
def contents(directory):
    return {p.name: p.read_bytes() for p in directory.iterdir()}
small = contents(root / 'input')
for bits in (128, 192, 256):
    assert contents(root / f'extracted{bits}') == small
large = contents(root / 'large-input')
for version in ('before', 'after'):
    assert contents(root / f'large-extracted-{version}') == large
print('6000 small + 8 large extracted files: PASS')
PYIDENTITY
```
