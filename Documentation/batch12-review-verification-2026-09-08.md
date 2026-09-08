# Batch 12 review fixes: verification (2026-09-08)

Base: the uncommitted working tree at `a8c76f3`. Earlier changes were preserved. No commit or `bd` command was run. All added code, fixtures, benchmark archives, and persistent verification artifacts are inside KaitoKit.

## 1. Files changed by this fix batch

- `CHANGELOG.md`
- `Documentation/design.md`
- `Documentation/migration-from-xadmaster.md`
- `Documentation/batch12-review-verification-2026-09-08.md`
- `Sources/KaitoKit/Reader/Extractor.swift`
- `Sources/KaitoKit/Text/EncodingDetector.swift`
- `Sources/KaitoKit/Formats/RAR/RAR4Reader.swift`
- `Sources/kaito/main.swift`
- `Tests/KaitoKitTests/SymbolicLinkExtractionTests.swift`
- `Tests/KaitoKitTests/RealToolRegressionTests.swift`
- `Tests/KaitoKitTests/RARPasswordCompatibilityTests.swift`
- `Tests/KaitoKitTests/CLISmokeTests.swift`
- `Tests/Fixtures/rar4/kaito-password-nonbmp-retry-limit.rar.b64`
- `Tests/Fixtures/NOTICE`

## 2. Extraction blocker

`validateSymbolicLinkTarget` now opens every component through the last `..` in `parentComponents + targetComponents` as an existing directory with `O_NOFOLLOW`. ENOENT in that prefix is a malformed escaping target. After that prefix, missing parent directories remain allowed for forward references; the final `fstatat(AT_SYMLINK_NOFOLLOW)` check still rejects a symlink leaf. Since the extractor cannot replace an existing real directory with a symlink, a later entry or another archive cannot change the meaning of a validated `a/..`.

New tests in `SymbolicLinkExtractionTests` cover both TAR and ZIP, both pivot orders, the deeper pivot, separate archive readers and reopened readers, an existing symlink leaf, in-root parent links, forward directory references, and attempts to overwrite a validated directory.

## 3. RAR5 password decision

Preserve the existing RAR5 KDF and document its deliberate difference from RAR3. RAR5 continues to use the complete UTF-8 password. Unix rar truncates at 127 scalars, so such writer-created archives require the truncated password. This avoids breaking archives already readable with full-length passwords while Windows UTF-16 and Unix scalar boundary fixtures are still needed for a compatible candidate-probe extension. The decision is recorded in `design.md`; the RAR3 127-character rule remains there and is integrated into migration §10 in です・ます style, with the duplicate removed from §11.

## 4. RAR4 measurements

RAR 6.24 `a -ma4 -m5 -s`, deterministic 1 MiB/member payload (seeded random bytes mapped to 64 ASCII values); all members use compression method 0x35 and N−1 solid continuations. Swift 6.3.3 release, one warm-up and five alternating timed runs, median wall-clock milliseconds. BMP password: `keyA`; non-BMP password: `key🔑`. Baseline non-BMP times are single runs of the preserved pre-fix working-tree build. No build, test, or fuzz jobs ran concurrently with the measured runs.

### `-p`

| N | BMP ms | Non-BMP ms | Non-BMP/BMP | Non-BMP doubling | Baseline non-BMP ms |
|---:|---:|---:|---:|---:|---:|
| 5 | 47.397 | 58.924 | 1.243× | — | 268.941 |
| 10 | 84.732 | 95.885 | 1.132× | 1.627× | 893.681 |
| 20 | 166.174 | 177.480 | 1.068× | 1.851× | 3285.993 |
| 40 | 322.524 | 336.424 | 1.043× | 1.896× | 12700.601 |

### `-hp`

| N | BMP ms | Non-BMP ms | Non-BMP/BMP | Non-BMP doubling | Baseline non-BMP ms |
|---:|---:|---:|---:|---:|---:|
| 5 | 47.543 | 49.553 | 1.042× | — | 274.470 |
| 10 | 87.373 | 89.713 | 1.027× | 1.810× | 922.070 |
| 20 | 164.460 | 166.766 | 1.014× | 1.859× | 3292.899 |
| 40 | 330.401 | 334.986 | 1.014× | 2.009× | 12868.174 |

PASS: every member digest in all 16 archives matches both the generated source and the baseline; all five measured runs agree byte-for-byte. The fixed overhead is one initial candidate probe for `-p`; doubling converges to 2×, while the baseline approaches 4×. Header-CRC selection removes the data probe for `-hp`. Empty encrypted members cannot choose an encoding, and per-group probe indices are precomputed to avoid repeated prefix searches.

## 5. Verification commands and real output

Environment adjustments: the literal release command was attempted and failed because the outer workspace sandbox disallows the user Clang cache; with a local cache, nested `sandbox-exec` also failed. Build/test invocations therefore use a repository-local `CLANG_MODULE_CACHE_PATH` and SwiftPM `--disable-sandbox`, retaining the outer workspace sandbox. The supplied REPRO.sh exists but writes beside itself and defaults to an older binary: an unchanged workspace copy was run with the rebuilt binary as its argument. Oracle TSV outputs were placed under `.build/batch12-verification/` instead of `/tmp` to keep generated artifacts in this repository. No verification step or corpus was omitted. Full unabridged logs are retained there.

Command variables used below:

```bash
cd <repo>
S=<corpus>
W=$PWD/.build/batch12-verification
export CLANG_MODULE_CACHE_PATH=$W/module-cache
# The Swift 6.4 and sanitizer runs use $W/module-cache64.
```

### Initial literal release command: environment failure

```bash
DEVELOPER_DIR=/Applications/Xcode.app swift build -c release --product kaito
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.IN5O4t/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.2XEL7j/kaitokit-manifest"])
<unknown>:0: error: error opening '<clang module cache>/Swift-1IEYM950OGIQC.swiftmodule' for output: <clang module cache>: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.IypLmY/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.QeX3GW/kaitokit-manifest"])
<unknown>:0: error: error opening '<clang module cache>/Swift-1IEYM950OGIQC.swiftmodule' for output: <clang module cache>: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
error: ExitCode(rawValue: 1)
[0/1] Planning build
```

FAIL (environment): the sandbox blocks the user module-cache directory. The adjusted final build below passed; this initial failure is not counted as a successful check.

### Release build

```bash
DEVELOPER_DIR=/Applications/Xcode.app swift build --disable-sandbox -c release --product kaito
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
[0/1] Planning build
Building for production...
[0/3] Write sources
[1/3] Write swift-version--58304C5D6DBC2206.txt
[3/4] Compiling KaitoKit Bzip2Decompressor.swift
[4/6] Compiling kaito main.swift
[4/6] Write Objects.LinkFileList
[5/6] Linking kaito
Build of product 'kaito' complete! (28.97s)
```

PASS: final Swift 6.3.3 release binary built.

### Binary path

```bash
K=$(DEVELOPER_DIR=/Applications/Xcode.app swift build --disable-sandbox -c release --product kaito --show-bin-path)/kaito
```

No output.

PASS: K resolves to `<repo>/.build/arm64-apple-macosx/release/kaito`. The assignment produces no stdout.

### Supplied pivot reproduction

```bash
bash .build/batch12-verification/path-repro/REPRO.sh "$K"
```

```text
== NEW ==
error: failed entry 0 (x/link): Malformed archive: symbolic-link target escapes the extraction directory
error: 1 archive entries failed
rc=1
realpath: <repo>/.build/batch12-verification/path-repro/sb/out/x/link
cat: sb/out/x/link: No such file or directory
read through link: 
== OLD (a8c76f3) ==
error: Malformed archive: link target contains an unsafe component
rc=1
```

PASS: extraction fails with rc=1, and no x/link is created. The missing-file diagnostic is expected.

### Expanded pivot matrix

```bash
python3 .build/batch12-verification/pivot-matrix.py
```

```text
tar-1-link-first: rc=1, no escaping symlink
tar-1-pivot-first: rc=1, no escaping symlink
tar-2-link-first: rc=1, no escaping symlink
tar-2-pivot-first: rc=1, no escaping symlink
zip-1-link-first: rc=1, no escaping symlink
zip-1-pivot-first: rc=1, no escaping symlink
zip-2-link-first: rc=1, no escaping symlink
zip-2-pivot-first: rc=1, no escaping symlink
PASS: all eight TAR/ZIP order/depth combinations rejected.
```

PASS: both formats, both orders, and both depths reject the escaping link.

### EUC-JP regression

```bash
"$K" list "$S/realtool/verify-lha-names-encodings/bis/arc/one-12.lzh"
```

```text
0	3000	file	-lh5-	plain	ｶﾀｶﾅ半角.txt	level=2
```

PASS: the filename is ｶﾀｶﾅ半角.txt.

### Oracle comparisons

```bash
A=$S/bench-work/corpus/archives
for f in sjis2000.zip ascii2000.zip book-deflate.cbz book-tiff.7z book-solid.7z book-rar5.cbr book-tiff-rar5.cbr book-rar4.cbr book-tiff-rar4.cbr book-lh5.lzh book-lh6.lzh book-lh7.lzh book-tiff-lh5.lzh book-tiff-lh6.lzh book-tiff-lh7.lzh; do
  "$K" sha "$A/$f" > "$W/k-$f.tsv" && python3 "$S/compare-sha.py" "$S/oracle/$f.sha.tsv" "$W/k-$f.tsv" | grep RESULT
done
```

```text
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
RESULT: OK
```

PASS: all 15 comparisons returned RESULT: OK, in the order above.

### Corpus and real-tool parity

```bash
python3 .build/batch12-verification/corpus-parity.py
```

```text
Real-tool name parity: 234 archives, 233 identical, 1 changed
Name change: realtool/verify-lha-names-encodings/bis/arc/one-12.lzh
LHA corpus: 227 archives; extraction/tree identical=227, changed=0; failures before=17, after=17; digest changes=0
Real-tool path regression: 40 archives; extraction/tree identical=40, changed=0; failures before=16, after=16; digest changes=0
rar6 -ma4 -ol and lha-unix symlinks: 2 archives; extraction/tree identical=2, changed=0; failures before=0, after=0; digest changes=0
PASS: corpus parity and failure counts unchanged.
```

PASS: 234 name listings have only the intended one-name correction; the 227-archive LHA extraction/digest results and failure counts are unchanged. The 40 path-regression archives and fresh rar6 -ma4 -ol / lha-unix symlink archives are identical. Tree comparison includes names, bytes, link targets, modes, and recorded file mtimes; current creation times for archives without valid timestamps are excluded.

### Swift 6.3.3 tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app swift test --disable-sandbox 2>&1 | tail -3
```

```text
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

PASS: process and pipeline exit status 0.

XCTest summary (627 tests total; Swift 6.4 runs the 612 library and 15 compatibility tests separately; the trailing Swift Testing summary above has no Swift Testing cases):

```text
Test Suite 'All tests' passed at 2026-09-08 17:01:31.678.
	 Executed 627 tests, with 33 tests skipped and 0 failures (0 unexpected) in 156.237 (156.284) seconds
```

### Swift 6.4 tests

```bash
swift test --disable-sandbox 2>&1 | tail -3
```

```text
↳ Testing Library Version: 2078
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

PASS: process and pipeline exit status 0.

XCTest summary (627 tests total; Swift 6.4 runs the 612 library and 15 compatibility tests separately; the trailing Swift Testing summary above has no Swift Testing cases):

```text
Test Suite 'All tests' passed at 2026-09-08 17:04:11.225.
	 Executed 612 tests, with 33 tests skipped and 0 failures (0 unexpected) in 154.996 (155.041) seconds
Test Suite 'All tests' passed at 2026-09-08 17:04:12.167.
	 Executed 15 tests, with 0 failures (0 unexpected) in 0.805 (0.808) seconds
```

### Default toolchain build

```bash
swift build --disable-sandbox
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for debugging...
[Planning deferred tasks]
Build complete! (0.36秒)
```

PASS: Swift 6.4 build.

### ASan/UBSan build

```bash
Scripts/fuzz/build-asan.sh
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for debugging...
[2 / 14] KaitoKit
[4 / 16] KaitoKit
[10 / 22] kaito-product
[16 / 25] KaitoKit
[18 / 26] KaitoKit
[24 / 26] KaitoKitDynamic-product
Build complete! (1.57秒)
```

PASS: sanitized binary built with Swift 6.4.

### ASan mutants

```bash
Scripts/fuzz/run-mutants.sh --count 400 --timeout 8 $S/fuzz-seeds/*/* 2>&1 | tail -2
```

```text
generated 400 mutants from 41 seed(s)
mutants: 400, crashes: 0, hangs: 0, sanitizer findings: 0
```

PASS: 400 mutants, 0 crashes, 0 hangs, 0 sanitizer findings.

### CLI source-member evidence

```bash
kaito sha bad-solid.rar; kaito extract bad-solid.rar -o out
```

```text
sha: exit 1
stdout:
0	ERROR	failed entry 0: Checksum mismatch (source member 0)	hello.txt
1	ERROR	failed entry 1: Checksum mismatch (source member 0)	tiny.txt
partial	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	
stderr:
error: failed entry 0 (hello.txt): Checksum mismatch (source member 0)
error: failed entry 1 (tiny.txt): Checksum mismatch (source member 0)
error: 2 archive entries failed
extract: exit 1
stdout:
stderr:
error: failed entry 0 (hello.txt): Checksum mismatch (source member 0)
error: failed entry 1 (tiny.txt): Checksum mismatch (source member 0)
error: 2 archive entries failed
```

PASS: testSolidCRCFailureLabelsFailedEntryAndSourceMember checks both stdout TSV and stderr, including extract.

### Non-final candidate error evidence

```bash
Baseline probe with maxDictionarySize=8 MiB, then 1024 MiB
```

```text
Fixture: candidate-5.rar archive bytes: 147
Baseline maxDictionarySize=8 MiB: ERROR Read limit exceeded: size 114294784 exceeds limit 8388608
Baseline maxDictionarySize=1024 MiB: OK 3840 8c95fa7da2949f1acfc1d611336a6d3c49df821947b757263dd0435bc573d495
Source SHA256: 8c95fa7da2949f1acfc1d611336a6d3c49df821947b757263dd0435bc573d495
```

PASS: testNonBMPCandidateRetriesAfterDictionaryLimitError verifies the new reader returns the 3,840 expected bytes at the 8 MiB limit. testEmptyEncryptedMemberDoesNotSelectPasswordEncoding covers empty-member ambiguity. resolvePasswordEncoding now catches every error and rethrows the first error if all candidates fail.

### Whitespace check

```bash
git diff --check
```

No output.

PASS: no whitespace errors.

## 6. Uncommitted working tree

HEAD remains `a8c76f3`; no commit was made. Earlier uncommitted files are intentionally included below.

```text
 M CHANGELOG.md
 M Documentation/design.md
 M Documentation/migration-from-xadmaster.md
 M README.md
 M Sources/KaitoKit/Codecs/LHA/LZSStaticHuffmanDecoder.swift
 M Sources/KaitoKit/Codecs/PPMd/PPMd7Decoder.swift
 M Sources/KaitoKit/Codecs/PPMd/PPMd7Model.swift
 M Sources/KaitoKit/Codecs/PPMd/PPMd7Suballocator.swift
 M Sources/KaitoKit/Codecs/RAR/RAR29Decoder.swift
 M Sources/KaitoKit/Codecs/RAR/RARStandardFilters.swift
 M Sources/KaitoKit/Core/CRC16.swift
 M Sources/KaitoKit/Formats/LHA/LHAHeaderParser.swift
 M Sources/KaitoKit/Formats/RAR/RAR4Reader.swift
 M Sources/KaitoKit/Formats/RAR/RAR5Reader.swift
 M Sources/KaitoKit/Formats/RAR/RARCrypto.swift
 M Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift
 M Sources/KaitoKit/Formats/SingleFile/SingleFileReader.swift
 M Sources/KaitoKit/Formats/Tar/TarReader.swift
 M Sources/KaitoKit/Formats/Zip/ZipReader.swift
 M Sources/KaitoKit/Reader/Extractor.swift
 M Sources/KaitoKit/Text/EncodingDetector.swift
 M Sources/KaitoKitCompat/KaitoArchive.swift
 M Sources/kaito/main.swift
 M Tests/Fixtures/NOTICE
 M Tests/KaitoKitCompatTests/KaitoArchiveCompatTests.swift
 M Tests/KaitoKitTests/CLISmokeTests.swift
 M Tests/KaitoKitTests/LHAIntegrationTests.swift
 M Tests/KaitoKitTests/LZSStaticHuffmanDecoderTests.swift
 M Tests/KaitoKitTests/RAR4ReaderTests.swift
 M Tests/KaitoKitTests/RARCommonPrimitiveTests.swift
 M Tests/KaitoKitTests/ZipEncryptionPrimitiveTests.swift
?? Documentation/batch12-review-verification-2026-09-08.md
?? Documentation/performance-rar-lha-2026-09-08.md
?? Documentation/performance-stability-2026-09-08.md
?? Tests/Fixtures/rar4/kaito-audio.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii100-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii100-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii128-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii128-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii200-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii200-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii28-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii28-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii29-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii29-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii64-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-ascii64-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-japanese29-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-japanese29-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-long-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-long-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-retry-limit.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-solid.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-unix-windows-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-utf16-hp.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-utf16-p.rar.b64
?? Tests/Fixtures/rar4/kaito-password-nonbmp-utf16-unix-p.rar.b64
?? Tests/KaitoKitTests/CRC16Tests.swift
?? Tests/KaitoKitTests/LHABoundedWindowTests.swift
?? Tests/KaitoKitTests/RARPasswordCompatibilityTests.swift
?? Tests/KaitoKitTests/RealToolRegressionTests.swift
?? Tests/KaitoKitTests/SymbolicLinkExtractionTests.swift
```
