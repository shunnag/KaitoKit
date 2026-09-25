# S6 / P1b: KaitoKit ZIP payload SPI

Base: `feature/2026-09-24-review`, `ba42ed8b1e56b410465f2737ee769fec8071af5c`.
Only KaitoKit was edited. GyoshukuKit and KaitoFinder were not edited or tested. No commit, tag, or release was created.
Apple Swift 6.4, Swift 6 language mode, arm64, macOS 27.2 host / macOS 26 deployment target.

The additions are confined to `@_spi(ZipRawLayout)`: `ZipRawEncryption`, the three new layout fields,
`ZipAESKeyMaterial`, `zipStoredPayloadStream(at:aesKey:)`, and `zipStream(at:aesKey:)`.
The normal reader shares its existing decoding, CRC, verifier, and HMAC paths with the SPI.
Supplied material bypasses password derivation/provider/cache; stored streams bypass decompression and XZ staging.

## Final results

| Check | Result |
| --- | --- |
| Configured `swift build` | Passed, 14.45 s |
| Configured `swift build -c release` | Passed, 64.89 s |
| Full `swift test` | 1,492 tests, 47 skips, 0 failures, 518.519 s |
| A1 classes in the full suite | 16 tests, 0 skips, 0 failures: stored SPI 9, key material 2, layout 4, SPI import 1 |
| Final focused A1 + UTC golden + differential fuzz | 18 tests, 0 skips, 0 failures, 18.301 s |
| Frozen P1-K golden | Unchanged test/inputs/expectations; 266 archives × 6 modes matched, including UTC |
| Differential fuzz | 1,500 mutations, 0 differences |
| ASan / UBSan CLI fuzz | 200 + 100 mutants, 0 crashes, 0 hangs, 0 findings |
| arm64 framework / release SPI consumer | Passed; both public interfaces hide all queried SPI names; ordinary import rejected |

The full suite includes the final encryption-key-only limitation test. No A1 tests skip. The 47 full-suite
skips are the same count as P1-K; optional performance/large-fixture and unavailable-oracle tests remain gated.

## Verification commands and environment

Logs and temporary build/consumer artifacts are in `/private/tmp/kaitokit-p1b`.
The initial, unmodified `swift build` failed because the sandbox cannot write the default
`/Users/nagash/.cache/clang/ModuleCache`. The existing P1-K cache/backend workaround was reused.
`/private/tmp/kaitokit-p1b/swift.sh` contains exactly:

```sh
#!/bin/bash
set -euo pipefail
exec env CLANG_MODULE_CACHE_PATH=/private/tmp/p1k-module-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/p1k-module-cache \
    /usr/bin/swift "$@" --disable-sandbox --cache-path /private/tmp/p1k-spm-cache \
    --build-system native --scratch-path /private/tmp/kaitokit-p1b/build --jobs 2 -debug-info-format none
```

The debug/release optimization settings and Swift language mode were not changed. Debug info was disabled,
as in P1-K, to avoid sandbox-dependent dSYM generation. The native backend emits a deprecation warning.

Commands run from the KaitoKit repository:

```sh
swift build
bash /private/tmp/kaitokit-p1b/swift.sh build
bash /private/tmp/kaitokit-p1b/swift.sh test --filter 'ZipStoredPayloadSPITests|ZipAESKeyMaterialTests|ZipRawRecordLayoutTests|ZipRawLayoutSPIImportTests'
TZ=UTC bash /private/tmp/kaitokit-p1b/swift.sh test --filter 'ZipStoredPayloadSPITests|ZipAESKeyMaterialTests|ZipRawRecordLayoutTests|ZipRawLayoutSPIImportTests|ZipPublicValueGoldenTests|RawEntryRecordTests|ZipEncryptionPrimitiveTests|ZipModernMethodTests|ZipDifferentialTests|AppleDoubleSidecarTests|ZipRawLayoutDifferentialFuzzTests'
bash /private/tmp/kaitokit-p1b/swift.sh test
TZ=UTC bash /private/tmp/kaitokit-p1b/swift.sh test --filter 'ZipStoredPayloadSPITests|ZipAESKeyMaterialTests|ZipRawRecordLayoutTests|ZipRawLayoutSPIImportTests|ZipPublicValueGoldenTests|ZipRawLayoutDifferentialFuzzTests'
KAITOKIT_ARCHS=arm64 Scripts/build-framework.sh
KAITOKIT_ARCHS=arm64 bash /private/tmp/kaitokit-p1b/build-framework.sh
PATH=/private/tmp/kaitokit-p1b/bin:$PATH Scripts/fuzz/run-mutants.sh --count 200 --timeout 5 /private/tmp/kaitokit-p1b/fuzz-seeds
PATH=/private/tmp/kaitokit-p1b/bin:$PATH Scripts/fuzz/run-mutants.sh --count 100 --timeout 5 --password raw-password /private/tmp/kaitokit-p1b/fuzz-seeds
/private/tmp/kaitokit-p1b/bin/swift build --disable-sandbox --scratch-path /private/tmp/kaitokit-p1b/release -c release
```

The first configured build found a `[UInt8]`/`Data` conversion error in the new shared derivation helper;
after fixing that conversion, the same build passed. The first A1 run had two assertions with an
overbroad expectation about encryption-key-only corruption, described below. No existing test expectations changed.
The subsequent broad run passed 80 tests, with one existing skip, in 24.971 seconds.

The unmodified framework script hit the same default module-cache restriction. Its temporary copy fixes
`ROOT_DIR` to this checkout, adds the same cache/native/backend/debug-info flags to Swift build calls,
and places both build and framework output under `/private/tmp/kaitokit-p1b`.
An initial temporary wrapper invocation exited before compilation because Bash 3.2 treats the empty
optional-arguments array as unset under `set -u`; the corrected wrapper uses positional arguments.
The corrected arm64 framework build passed.

The `bin/swift` wrapper used by the fuzz scripts and standalone release build appends
`--cache-path /private/tmp/p1k-spm-cache --build-system native --jobs 2 -debug-info-format none` to
`swift build`, exports the same two module-cache variables, and executes `/usr/bin/swift`.
The repository scripts themselves are unchanged. `run-mutants.sh` invokes `Scripts/fuzz/build-asan.sh`
with its original `-sanitize=address,undefined` flags. The first sanitizer build passed in 21.39 seconds.
Both mutant runs passed: 200 without a password and 100 with `raw-password`, zero crashes/hangs/sanitizer findings.
The seed pool is the 261 single-file base64 ZIP inputs in the unchanged frozen manifest; the two split sets
and three generated large inputs are excluded. Counts are total mutants per run, not per seed.
The standalone `swift build -c release` passed in 64.89 seconds.

Both generated public `.swiftinterface` files were checked for
`ZipAESKeyMaterial|zipStoredPayloadStream|zipStream\(at|ZipRawEncryption|storedCRC32|ZipRawRecordLayout`:
zero matches. A release framework consumer using separate `public import KaitoKit` and
`@_spi(ZipRawLayout) internal import KaitoKit` files typechecks with Swift 6 and without `@testable`
or `-enable-testing`. Removing the SPI import rejects the stored-stream call as inaccessible.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/p1k-module-cache xcrun swiftc -typecheck -swift-version 6 \
  -module-name P1bConsumer -F /private/tmp/kaitokit-p1b/Frameworks -I Sources/CBzip2 \
  /private/tmp/kaitokit-p1b/ConsumerPublic.swift /private/tmp/kaitokit-p1b/ConsumerSPI.swift
CLANG_MODULE_CACHE_PATH=/private/tmp/p1k-module-cache xcrun swiftc -typecheck -swift-version 6 \
  -module-name P1bNoSPI -F /private/tmp/kaitokit-p1b/Frameworks -I Sources/CBzip2 \
  /private/tmp/kaitokit-p1b/ConsumerNoSPI.swift
git diff --exit-code -- Tests/KaitoKitTests/ZipPublicValueGoldenTests.swift Tests/Fixtures/zip-golden
git diff --check
```

The positive consumer exits 0; the negative consumer exits 1 with `inaccessible due to '@_spi' protection level`.
The frozen-golden diff and whitespace check exit 0. The UTC golden compared all 266 inputs across six modes;
the deterministic differential fuzz compared 1,500 mutations with zero differences (0.818 seconds in the final focused run).
The broad run's one skip is the existing Info-ZIP bzip2 test because the system Info-ZIP lacks bzip2 support.

## A1 coverage and key-material contract

- Plain stored/deflate, Info-ZIP ZipCrypto with bit 3, 7zz ZipCrypto without bit 3, and 7zz AES-128/192/256.
  Stored bytes match plaintext; raw deflate is independently inflated with zlib and compared with the normal stream.
- XZ-AES, XZ-ZipCrypto, Zstandard AES methods 20/93. Returned XZ has the expected magic, and 7zz independently
  expands the decrypted compressed payload. Dictionary limits still apply to keyed decompression.
  Damaged modern-method HMACs are deferred in stored streams, confirming that XZ staging is bypassed.
- Supplied material works without a password and never calls the forbidden provider. Invalid strength/salt/length
  and material supplied to a non-AES entry are rejected. Existing password-provider fallback remains usable.
- Verifier corruption and authentication-key corruption reject with `wrongPassword`; corrupted HMAC rejects
  before the final chunk is returned, including repeated reads after failure. AE-1 CRC corruption rejects with
  `checksumMismatch`. Supplied-key streams leave both empty and already-populated password caches unchanged.
- Derivation agrees with existing derived keys for every strength, empty/non-ASCII/arbitrary password bytes,
  and distinct NFC/NFD byte sequences. Existing fixed PBKDF2 vectors also remain in the regression suite.
- A real brute-force ZipCrypto verifier collision succeeds through the stored SPI and is rejected by the
  expanded stream as `wrongPassword`. Stored-stream callers must perform the specified CRC validation.
- Out-of-range, incomplete, `.001`, non-ZIP and merged resource-fork rejection; native ZIP splits and
  AppleDouble passthrough; stored payloads for an unsupported compression method.
- New layout fields agree with the public encryption, CRC and method values across all usable frozen-golden
  entries and all six opening modes. Malformed inputs retain the existing errors.

A1's phrase “wrong bytes produce `wrongPassword`” cannot apply to every isolated byte of arbitrary supplied
material: the encryption key, authentication key and verifier occupy independent parts of the material.
Changing only the encryption key does not change the verifier or the ciphertext HMAC. A stored stream
therefore returns different decrypted bytes; the stored-method AE-1 fixture's expanded stream rejects them
with its existing CRC error, whereas AE-2 has no CRC. `testEncryptionKeyAloneCannotBeAuthenticatedByVerifierOrHMAC`
records this explicitly.
The SPI preserves the specified authentication checks; callers must supply intact derivation output and retain
P1b's independent output validation. No additional password derivation is performed to try to validate supplied keys.

## Scope handoff

The cross-repository plan's P1b row must include KaitoKit, as required by P1-ORDER. That plan is outside this
repository's authorized scope and was not edited. S7/GyoshukuKit and S8/KaitoFinder remain separate work.
