# RAR5 / PPMd performance and verification — 2026-09-08

Start: clean `7a1d210bf1140e4133830d43558eef0c3746d75b`. Changes remain uncommitted.
Implementation inputs were KaitoKit's own decoders, its format/design notes and the supplied
specification. No third-party decoder implementation sources were consulted. XADMaster and
RAR 7.23 were used only as black-box executables.

## Files changed

- `<repo>/Sources/KaitoKit/Codecs/RAR/RAR5Decoder.swift`
- `<repo>/Sources/KaitoKit/Codecs/PPMd/PPMd7Model.swift`
- `<repo>/Tests/KaitoKitTests/RAR5DecoderTests.swift`
- `<repo>/Documentation/design.md`
- `<repo>/CHANGELOG.md`
- `<repo>/Documentation/performance-rar5-ppmd-2026-09-08.md`

## Changes and safety boundaries

- RAR5 stages the first match period in caller output, doubles it, and mirrors at most one
  ring turn using the existing `lhaCopyMatch`. Distance one uses its existing memset path.
  Window pointer/mask/cursor, history and produced count stay local throughout `read(into:)`;
  `defer` publishes the counters on both success and error. Tokens retain distance/history,
  output-budget and logical input checks. Read/filter boundaries clip pending matches.
- A 10-bit primary Huffman table reuses RAR29's in-repository pattern, with the existing
  15-bit table as fallback. The bit-reader and lookup helpers are inlined. Both tables are
  allocated once, zeroed on rebuild and populated only after canonical-range validation.
  The logical bit limit is still checked after the sentinel-safe physical peek.
- PPMd's 8192 binary probabilities and 256-byte character mask use fixed raw allocations.
  The mask is cleared in place at generation wrap and model restart. State-array spans are
  validated before borrowing a byte pointer; model updates occur after the scan has finished.
  Probability indices, frequencies, arena references, range intervals and suffix-chain
  progress checks remain in place. Public APIs are unchanged.
- Regression tests exercise full-ring and wrapped matches at distances 1, 3, 257, window-1
  and window; pending reads of 1, 7, 4096, 65537 and window+19 bytes; Huffman lengths 10, 11
  and 15; primary-table rebuilds; and a logically truncated code next to physical sentinels.

## Measurement method and environment

All performance tables use Swift 6.3.3 release and alternating XADMaster `extract archive 3`
then KaitoKit `bench archive 3` calls. Each number is the median of three extractions.
Builds, tests, fuzzing and profiling were not run concurrently with benchmarks. The reference
JSON `bytes` field sums three repetitions, whereas KaitoKit reports one extraction's bytes.
The local baseline differs from the approximate supplied baseline; both binaries were
measured on this host. Paired ratios, not the supplied approximate milliseconds, decide targets.

Toolchains observed:

```text
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1)
Target: arm64-apple-macosx27.0.0
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx28.0
```

The managed sandbox denies writes to the default Clang module cache and denies SwiftPM's
nested `sandbox-exec`. Builds/tests were rerun with repository-local caches and SwiftPM's
`--disable-sandbox` option. The outer managed sandbox was not disabled. No project build
settings were changed. Environment for successful verification:

```sh
export CLANG_MODULE_CACHE_PATH=<repo>/.build/batch11/module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=<repo>/.build/batch11/module-cache
S=<corpus>
A=$S/bench-work/corpus/archives
X=$S/bench-work/bin/xadbench
K=<repo>/.build/arm64-apple-macosx/release/kaito
cd <repo>
```

## Per-step measurements

The tiny-match experiment is included for auditability and was removed. PPMd was unchanged
between baseline and step 1; RAR5 was unchanged between steps 1 and 2.

| Step | Archive | Before KaitoKit ms | After KaitoKit ms | After XADMaster ms | After ratio | Decision |
|---|---|---:|---:|---:|---:|---|
| 1: bulk overlap copy + read-local state | book-tiff-rar5.cbr | 518.768 | 461.134 | 305.57 | 1.509 | Retained; target still marginal |
| 2: fixed PPMd buffers + validated raw scan | ppmd-s-m5-mctp.rar | 1913.278 | 1709.306 | 1243.90 | 1.374 | Retained |
| 2: same PPMd change | pp-jpg-mctp.rar | 870.669 | 830.456 | 596.48 | 1.392 | Retained |
| 3: RAR29-style tiny-match loop | book-tiff-rar5.cbr | 478.932 | 483.026 | 307.91 | 1.569 | Rejected; no improvement |
| 4: remove step 3; small Huffman primary + inline bit helpers | book-tiff-rar5.cbr | 483.026 | 391.625 | 313.59 | 1.249 | Retained |

Step 4 is also 478.932 → 391.625 ms against the step-2 RAR5 implementation with no tiny-match
experiment. The final verification benchmark below follows removal of an unused history
helper and does not add another optimization.

## Final paired benchmark table

| Archive | Baseline KaitoKit ms | Final KaitoKit ms | Final XADMaster ms | Final ratio | KaitoKit change |
|---|---:|---:|---:|---:|---:|
| book-tiff-rar5.cbr | 518.768 | 390.867 | 309.14 | 1.264 | -24.65% |
| book-rar5.cbr | 33.056 | 33.350 | 34.54 | 0.966 | +0.89% |
| book-tiff-rar4.cbr | 377.035 | 375.105 | 326.51 | 1.149 | -0.51% |
| book-rar4.cbr | 30.953 | 30.756 | 34.92 | 0.881 | -0.64% |
| book-solid.7z | 9841.389 | 9610.231 | 6910.35 | 1.391 | -2.35% |
| book-tiff.7z | 529.342 | 522.426 | 401.09 | 1.303 | -1.31% |
| book-lh5.lzh | 2089.463 | 2103.338 | 2680.12 | 0.785 | +0.66% |
| book-tiff-lh7.lzh | 343.316 | 335.192 | 824.50 | 0.407 | -2.37% |
| book-deflate.cbz | 678.218 | 683.972 | 679.34 | 1.007 | +0.85% |
| book-stored.cbz | 30.374 | 31.698 | 26.16 | 1.212 | +4.36% |
| ppmd-s-m5-mctp.rar | 2010.998 | 1702.270 | 1260.47 | 1.351 | -15.35% |
| pp-jpg-mctp.rar | 862.399 | 828.599 | 601.71 | 1.377 | -3.92% |

The separate PPMd command requested by the spec returned 1882.584 ms. It does not contain
its own reference pair; the final paired PPMd row above is from the immediately alternating
reference/KaitoKit follow-up. Both outputs are retained below. No samples were discarded.

LZMA source was left unchanged. The host profile and local samples identify the already
optimized literal-run and match-batch helpers. Local SIGPROF samples also attribute substantial
work to `pread`; this differs from the supplied host `sample` profile and is not treated as
proof that changing LZMA's hot loop or I/O would be safe. Final solid 7z (1.391×) and TIFF 7z
(1.303×) do not meet the optional 1.3× stretch goal. Their own extraction times did not regress.

## Profiling evidence and limitation

`sample <pid> 4 -file ...` was attempted before and after. The OS denied inspection of the
child process (exit 255), even though `kaito sha` itself exited successfully. Therefore the
spec's literal requirement for successful before/after **native `sample` captures is unmet**
in this environment; no such capture is claimed. The supplied host profile was retained as
initial corroborating evidence.

A temporary in-process diagnostic dylib samples the interrupted program counter using
SIGPROF at a requested 1 ms CPU interval. Its handler only records the PC into fixed storage;
address symbolization happens after the timer is disabled. Earlier diagnostic runs also
unwound stacks to identify callers, including PPMd model updates and the RAR5 copy site.
The final low-overhead PC runs below use the same sampler for all stages. These are sample
counts, not benchmark timings, and include startup, I/O and CLI SHA work. RAR5 filters do not
appear near the top. PPMd samples show escaped-symbol scans and model updates, without
prominent solid-group replay plumbing. The post-copy RAR5 samples still showed Huffman/
bit-reader work, motivating step 4.

The sampler, symbol maps, raw PCs, intermediate executables and complete logs are preserved
under `.build/batch11/` for local review; they are not product code. The source and command
outputs used for verification are included below.

### baseline-cpu: book-tiff-rar5.cbr

```text
load 0x1022f8000 samples 294
   83 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:)
   59 /usr/lib/system/libsystem_kernel.dylib pread
   53 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   46 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   15 RAR5Decoder.decodeDistance(slot:bits:)
    9 RAR5RawBitReader.read(_:)
    6 RAR5HuffmanTable.decode(from:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    3 RAR5Decoder.rotateDistanceToFront(_:)
    3 RAR5RawBitReader.peekPadded(_:)
    2 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/swift/libswiftCore.dylib _swift_stdlib_getUnsafeArgvArgc
    1 /usr/lib/dyld dyld-internal
    1 specialized Data.init<A>(_:)
    1 /usr/lib/system/libsystem_kernel.dylib __ioctl
    1 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    1 RAR5HuffmanTable.build(lengths:count:requireSymbol:)
    1 DYLD-STUB$$memmove
    1 /usr/lib/swift/libswiftCore.dylib swift_allocObject
    1 /usr/lib/system/libsystem_kernel.dylib mach_absolute_time
    1 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_free_tc
```

### baseline-cpu: ppmd-s-m5-mctp.rar

```text
load 0x10418c000 samples 1134
  382 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  194 specialized PPMd7Model.decodeSymbol2<A>(in:using:)
   98 RAR29Decoder.read(into:)
   84 PPMd7Model.storeState(_:at:)
   55 PPMd7Suballocator.appendText(_:)
   53 specialized PPMd7Model.decodeSymbol1<A>(in:using:)
   35 specialized PPMd7Model.decodeByte<A>(using:)
   28 PPMd7Model.setNumberOfStats(_:in:)
   20 PPMd7Model.indexOfSymbol(_:in:)
   16 /usr/lib/swift/libswiftCore.dylib swift_beginAccess
   16 specialized PPMd7Model.decodeBinarySymbol<A>(in:using:)
   12 PPMd7Model.updateModel(minimumContext:)
   12 /usr/lib/swift/libswiftCore.dylib swift_release
   11 PPMd7Model.stateRef(in:index:)
    8 /usr/lib/swift/libswiftCore.dylib swift_isUniquelyReferenced_nonNull_native
    8 /usr/lib/swift/libswiftCore.dylib swift_endAccess
    6 RARPPMdRangeDecoder.remove(start:size:)
    6 specialized static PPMd7Suballocator.bytes(forClass:)
    6 PPMd7Model.appendState(_:summaryFrequency:to:)
    6 PPMd7Model.setSummaryFrequency(_:of:)
    6 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    5 RAR29Decoder.nextPPMdToken(outputPosition:)
    4 PPMd7Model.escapeEstimator(for:)
    4 PPMd7Model.loadState(at:)
    4 PPMd7Model.setStateFrequency(_:at:)
    4 RARPPMdRangeDecoder.threshold(total:)
    4 /usr/lib/swift/libswiftCore.dylib swift_retain
    3 PPMd7Suballocator.glueFreeBlocks()
    3 PPMd7Model.update2(context:state:)
    2 PPMd7Model.createSuccessors(skipFoundState:suffixState:minimumContext:)
    2 PPMd7Suballocator.removeNode(classIndex:)
    2 specialized PPMd7Model.materializeSuccessors(_:baseContext:upBranch:symbol:)
    2 /usr/lib/system/libsystem_malloc.dylib xzm_malloc_zone_size
    2 PPMd7Model.validate(_:)
    2 /usr/lib/swift/libswiftCore.dylib _swift_setExclusivityTLS
    2 PPMd7Suballocator.allocateUnits(_:)
    2 DYLD-STUB$$swift_retain
    2 /usr/lib/swift/libswiftCore.dylib _swift_getExclusivityTLS
    2 PPMd7Model.update1(context:stateIndex:)
    2 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    1 /usr/lib/swift/libswiftCore.dylib _ZL28getExistentialValueWitnessesN5swift23ProtocolClassConstraintEPKNS_14TargetMetadataINS_9InProcessEEEjNS_15SpecialProtocolEb
    1 lazy protocol witness table accessor for type [String] and conformance [A]
    1 /usr/lib/swift/libswiftCore.dylib swift_allocObject
    1 PPMd7Suballocator.insertNode(_:classIndex:)
    1 /usr/lib/swift/libswiftCore.dylib _ZN5swift20swift_slowAllocTypedEmmy
    1 PPMd7Model.setStateSuccessor(_:at:)
    1 PPMd7ArenaSEEContext.mean()
    1 DYLD-STUB$$swift_release
    1 PPMd7Suballocator.requireFrontierOrder()
    1 /usr/lib/swift/libswiftCore.dylib $ss23_ContiguousArrayStorageCfD
    1 PPMd7Suballocator.checkedOffset(_:byteCount:)
    1 PPMd7Model.rescale(_:)
    1 /usr/lib/system/libsystem_malloc.dylib _free
    1 specialized static RARStandardFilters.audio(_:channels:)
    1 RAR29HuffmanTable.build(_:requireSymbol:)
    1 RARPPMdRangeDecoder.decodeBinary(probability:)
    1 /usr/lib/system/libsystem_kernel.dylib pread
    1 DYLD-STUB$$swift_endAccess
    1 DYLD-STUB$$swift_beginAccess
```

### baseline-cpu: book-solid.7z

```text
load 0x100dd0000 samples 7634
 6168 /usr/lib/system/libsystem_kernel.dylib pread
 1191 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
  132 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  101 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   21 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   10 LZMADecoder.read(into:)
    5 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    2 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    1 specialized Data.init<A>(_:)
    1 /usr/lib/swift/libswiftCore.dylib swift_release
```

### baseline-cpu: book-tiff.7z

```text
load 0x1026cc000 samples 361
  181 /usr/lib/system/libsystem_kernel.dylib pread
   96 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   22 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   22 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   14 LZMADecoder.read(into:)
    8 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    8 /usr/lib/libz.1.dylib inflateSetDictionary
    8 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
```

### step1-cpu: book-tiff-rar5.cbr

```text
load 0x100660000 samples 261
   66 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:window:windowMask:windowPosition:historySize:produced:)
   65 /usr/lib/system/libsystem_kernel.dylib pread
   41 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   38 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   17 RAR5HuffmanTable.decode(from:)
    7 RAR5Decoder.decodeDistance(slot:bits:)
    5 RAR5RawBitReader.read(_:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    4 RAR5RawBitReader.peekPadded(_:)
    3 /usr/lib/libz.1.dylib inflateSetDictionary
    3 /usr/lib/system/libsystem_platform.dylib _platform_memset
    3 RAR5HuffmanTable.build(lengths:count:requireSymbol:)
    2 /usr/lib/system/libsystem_platform.dylib __bzero
    1 specialized Data.init<A>(_:)
    1 /usr/lib/system/libsystem_malloc.dylib __xzm_xzone_free_to_freelist_chunk
    1 /usr/lib/libobjc.A.dylib deallocating_retain
```

### step1-cpu: ppmd-s-m5-mctp.rar

```text
load 0x100570000 samples 1082
  399 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  153 specialized PPMd7Model.decodeSymbol2<A>(in:using:)
  106 RAR29Decoder.read(into:)
   70 PPMd7Model.storeState(_:at:)
   62 PPMd7Suballocator.appendText(_:)
   59 specialized PPMd7Model.decodeSymbol1<A>(in:using:)
   29 PPMd7Model.setNumberOfStats(_:in:)
   24 specialized PPMd7Model.decodeByte<A>(using:)
   17 /usr/lib/swift/libswiftCore.dylib swift_beginAccess
   15 specialized PPMd7Model.decodeBinarySymbol<A>(in:using:)
   12 PPMd7Model.updateModel(minimumContext:)
   11 PPMd7Model.indexOfSymbol(_:in:)
    9 PPMd7Model.stateRef(in:index:)
    8 PPMd7Model.setStateFrequency(_:at:)
    7 PPMd7Model.escapeEstimator(for:)
    7 PPMd7Model.loadState(at:)
    7 RAR29Decoder.nextPPMdToken(outputPosition:)
    6 PPMd7Model.setSummaryFrequency(_:of:)
    6 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    5 /usr/lib/swift/libswiftCore.dylib swift_isUniquelyReferenced_nonNull_native
    5 /usr/lib/swift/libswiftCore.dylib _swift_setExclusivityTLS
    5 RARPPMdRangeDecoder.decodeBinary(probability:)
    4 PPMd7Model.appendState(_:summaryFrequency:to:)
    4 /usr/lib/swift/libswiftCore.dylib swift_endAccess
    4 /usr/lib/swift/libswiftCore.dylib swift_retain
    4 /usr/lib/swift/libswiftCore.dylib swift_release
    3 specialized static RARStandardFilters.audio(_:channels:)
    3 /usr/lib/system/libsystem_kernel.dylib pread
    2 specialized PPMd7Model.materializeSuccessors(_:baseContext:upBranch:symbol:)
    2 PPMd7Suballocator.removeNode(classIndex:)
    2 PPMd7Model.rescale(_:)
    2 PPMd7Model.update1(context:stateIndex:)
    2 PPMd7Model.validate(_:)
    2 DYLD-STUB$$swift_isUniquelyReferenced_nonNull_native
    2 PPMd7Suballocator.requireFrontierOrder()
    2 RARPPMdRangeDecoder.threshold(total:)
    2 RARPPMdRangeDecoder.remove(start:size:)
    1 /usr/lib/system/libsystem_kernel.dylib stat
    1 __swift_instantiateConcreteTypeFromMangledNameV2
    1 /usr/lib/swift/libswiftCore.dylib _ZN5swift38StableAddressConcurrentReadableHashMapINS_17GenericCacheEntryENS_23TaggedMetadataAllocatorILt14EEENS_5MutexEE11getOrInsertINS_16MetadataCacheKeyEJRNS_17MetadataWaitQueue6WorkerERNS_15MetadataRequestERPKNS_27TargetTypeContextDescriptorINS_9InProcessEEERPKPKvEEENSt3__14pairIPS1_bEET_DpOT0_
    1 /usr/lib/swift/libswiftCore.dylib _ZL25_swift_getGenericMetadataN5swift15MetadataRequestEPKPKvPKNS_27TargetTypeContextDescriptorINS_9InProcessEEE
    1 lazy protocol witness table accessor for type [String] and conformance [A]
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_free_tc
    1 /usr/lib/system/libsystem_malloc.dylib xzm_malloc_zone_size
    1 PPMd7Suballocator.allocateUnitsRare(classIndex:)
    1 /usr/lib/swift/libswiftCore.dylib _swift_getExclusivityTLS
    1 DYLD-STUB$$swift_endAccess
    1 PPMd7Suballocator.checkedOffset(_:byteCount:)
    1 PPMd7Model.setSuffix(_:of:)
    1 /usr/lib/system/libsystem_malloc.dylib malloc_size
    1 PPMd7Model.update2(context:state:)
    1 PPMd7Model.setStatsRef(_:of:stateCount:)
    1 PPMd7ArenaSEEContext.update()
    1 /usr/lib/system/libsystem_malloc.dylib __xzm_xzone_free_to_freelist_chunk
    1 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    1 /usr/lib/swift/libswiftCore.dylib _ZL8getCacheRKN5swift27TargetTypeContextDescriptorINS_9InProcessEEE
    1 DYLD-STUB$$swift_beginAccess
```

### step1-cpu: book-solid.7z

```text
load 0x1042e0000 samples 7632
 6598 /usr/lib/system/libsystem_kernel.dylib pread
  826 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
   87 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   81 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   17 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   11 LZMADecoder.read(into:)
    3 /usr/lib/libz.1.dylib inflateSetDictionary
    2 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/system/libsystem_kernel.dylib fstat
    1 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_chunk_batch_list_push
    1 LZMA2Decoder.beginCompressedChunk(control:controlOffset:)
    1 /usr/lib/system/libsystem_malloc.dylib xzm_malloc_zone_size
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation _CFExecutableLinkedOnOrAfter
```

### step1-cpu: book-tiff.7z

```text
load 0x104c60000 samples 343
  211 /usr/lib/system/libsystem_kernel.dylib pread
   62 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   31 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   10 LZMADecoder.read(into:)
    9 /usr/lib/system/libsystem_platform.dylib _platform_memmove
    8 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    2 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __CFStringAppendFormatCore
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation -[NSTaggedPointerString getCharacters:range:]
    1 /usr/lib/system/libsystem_platform.dylib _platform_memset
    1 /usr/lib/system/libsystem_malloc.dylib __xzm_xzone_free_to_freelist_chunk
    1 outlined destroy of ByteReader
```

### step2-cpu: book-tiff-rar5.cbr

```text
load 0x102f30000 samples 261
   62 /usr/lib/system/libsystem_kernel.dylib pread
   58 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   53 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:window:windowMask:windowPosition:historySize:produced:)
   46 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   13 RAR5Decoder.decodeDistance(slot:bits:)
    6 RAR5HuffmanTable.decode(from:)
    4 RAR5RawBitReader.read(_:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    2 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __NSDictionaryM_new
    1 /System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight _ZL21QuartzCoreLibraryCorePPc.31398
    1 /usr/lib/swift/libswiftCore.dylib _ZNK5swift35TargetProtocolConformanceDescriptorINS_9InProcessEE15getWitnessTableEPKNS_14TargetMetadataIS1_EERNS_27ConformanceExecutionContextE
    1 specialized Array.init<A>(_:)
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __CFStringAppendFormatCore
    1 /System/Library/Frameworks/CryptoKit.framework/Versions/A/CryptoKit __swift_memcpy16_8
    1 /usr/lib/system/libsystem_kernel.dylib fstat
    1 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    1 RAR5RawBitReader.peekPadded(_:)
    1 RAR5HuffmanTable.build(lengths:count:requireSymbol:)
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 0x19aa0037c
    1 /usr/lib/system/libsystem_kernel.dylib close
```

### step2-cpu: ppmd-s-m5-mctp.rar

```text
load 0x10283c000 samples 1018
  376 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  185 specialized PPMd7Model.decodeSymbol2<A>(in:using:)
  112 RAR29Decoder.read(into:)
   71 PPMd7Model.storeState(_:at:)
   54 PPMd7Suballocator.appendText(_:)
   29 PPMd7Model.setNumberOfStats(_:in:)
   27 specialized PPMd7Model.decodeSymbol1<A>(in:using:)
   20 specialized PPMd7Model.decodeByte<A>(using:)
   14 PPMd7Model.indexOfSymbol(_:in:)
   13 specialized PPMd7Model.decodeBinarySymbol<A>(in:using:)
   12 PPMd7Model.loadState(at:)
    8 PPMd7Model.updateModel(minimumContext:)
    7 /usr/lib/swift/libswiftCore.dylib swift_retain
    7 PPMd7Model.stateRef(in:index:)
    7 /usr/lib/swift/libswiftCore.dylib swift_beginAccess
    7 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    6 PPMd7Model.setSummaryFrequency(_:of:)
    5 PPMd7Model.appendState(_:summaryFrequency:to:)
    4 RARPPMdRangeDecoder.remove(start:size:)
    4 RAR29Decoder.nextPPMdToken(outputPosition:)
    4 /usr/lib/swift/libswiftCore.dylib swift_release
    3 specialized PPMd7Model.materializeSuccessors(_:baseContext:upBranch:symbol:)
    3 PPMd7Model.update2(context:state:)
    3 PPMd7Model.rescale(_:)
    3 /usr/lib/swift/libswiftCore.dylib swift_endAccess
    2 PPMd7Suballocator.checkedOffset(_:byteCount:)
    2 PPMd7Suballocator.insertNode(_:classIndex:)
    2 PPMd7Model.validate(_:)
    2 PPMd7Suballocator.glueFreeBlocks()
    2 PPMd7Model.escapeEstimator(for:)
    2 PPMd7Model.update1(context:stateIndex:)
    2 RAR29Decoder.copyMatchToFilter(window:windowMask:windowPosition:distance:remaining:maximumCount:outputPosition:)
    1 /usr/lib/system/libsystem_kernel.dylib __open
    1 PPMd7Model.setSuffix(_:of:)
    1 __swift_instantiateConcreteTypeFromMangledNameV2
    1 lazy protocol witness table accessor for type [String] and conformance [A]
    1 /usr/lib/swift/libswiftCore.dylib swift_isUniquelyReferenced_nonNull_native
    1 PPMd7Model.createSuccessors(skipFoundState:suffixState:minimumContext:)
    1 PPMd7Model.setStatsRef(_:of:stateCount:)
    1 PPMd7Suballocator.allocateUnitsRare(classIndex:)
    1 PPMd7Suballocator.allocateContext()
    1 specialized static PPMd7Model.add(_:_:)
    1 /usr/lib/swift/libswiftCore.dylib _swift_setExclusivityTLS
    1 /usr/lib/swift/libswiftCore.dylib _swift_getExclusivityTLS
    1 /usr/lib/swift/libswiftCore.dylib swift_bridgeObjectRelease
    1 PPMd7Suballocator.allocateUnits(_:)
    1 specialized static PPMd7Suballocator.bytes(forClass:)
    1 specialized static RARStandardFilters.audio(_:channels:)
    1 RAR29HuffmanTable.build(_:requireSymbol:)
    1 /usr/lib/system/libsystem_kernel.dylib pread
    1 PPMd7Model.setStateFrequency(_:at:)
    1 EntryStream.read(into:)
```

### step2-cpu: book-solid.7z

```text
load 0x1020c8000 samples 7632
 6513 /usr/lib/system/libsystem_kernel.dylib pread
  879 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
  104 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   94 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   21 LZMADecoder.read(into:)
    7 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    6 /usr/lib/libz.1.dylib inflateSetDictionary
    5 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    1 specialized Data.init<A>(_:)
```

### step2-cpu: book-tiff.7z

```text
load 0x1002f4000 samples 335
  209 /usr/lib/system/libsystem_kernel.dylib pread
   66 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   23 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   10 LZMADecoder.read(into:)
    9 /usr/lib/system/libsystem_platform.dylib _platform_memmove
    5 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    3 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __CFStringAppendFormatCore
    1 /usr/lib/swift/libswiftCore.dylib $sSKsSS7ElementRtzrlE6joined9separatorS2S_tFSaySSG_Tg5
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation CFStringGetCharacters
    1 outlined destroy of ByteReader
```

### step3-cpu: book-tiff-rar5.cbr

```text
load 0x100054000 samples 271
   66 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:window:windowMask:windowPosition:historySize:produced:)
   65 /usr/lib/system/libsystem_kernel.dylib pread
   51 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   42 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   16 RAR5Decoder.decodeDistance(slot:bits:)
    6 RAR5RawBitReader.read(_:)
    4 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    4 RAR5HuffmanTable.decode(from:)
    4 /usr/lib/libz.1.dylib inflateSetDictionary
    2 /usr/lib/system/libsystem_platform.dylib __bzero
    2 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    2 RAR5RawBitReader.peekPadded(_:)
    2 RAR5Decoder.rotateDistanceToFront(_:)
    1 /usr/lib/system/libdispatch.dylib dispatch_once
    1 type metadata completion function for ReaderOptions
    1 specialized Array.init<A>(_:)
    1 /usr/lib/system/libsystem_kernel.dylib fstat
    1 DYLD-STUB$$memmove
```

### step3-cpu: ppmd-s-m5-mctp.rar

```text
load 0x102180000 samples 1012
  393 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  143 specialized PPMd7Model.decodeSymbol2<A>(in:using:)
  113 RAR29Decoder.read(into:)
   63 PPMd7Suballocator.appendText(_:)
   56 specialized PPMd7Model.decodeSymbol1<A>(in:using:)
   54 PPMd7Model.storeState(_:at:)
   25 PPMd7Model.setNumberOfStats(_:in:)
   24 specialized PPMd7Model.decodeByte<A>(using:)
   13 PPMd7Model.loadState(at:)
   10 PPMd7Model.indexOfSymbol(_:in:)
    9 PPMd7Model.setSummaryFrequency(_:of:)
    8 PPMd7Model.stateRef(in:index:)
    8 PPMd7Suballocator.glueFreeBlocks()
    7 /usr/lib/swift/libswiftCore.dylib swift_release
    7 /usr/lib/swift/libswiftCore.dylib swift_retain
    7 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    6 specialized PPMd7Model.decodeBinarySymbol<A>(in:using:)
    5 /usr/lib/swift/libswiftCore.dylib swift_beginAccess
    5 PPMd7Model.rescale(_:)
    5 PPMd7Model.update1(context:stateIndex:)
    4 PPMd7Model.updateModel(minimumContext:)
    4 RARPPMdRangeDecoder.remove(start:size:)
    3 PPMd7Model.appendState(_:summaryFrequency:to:)
    3 PPMd7Model.setStateFrequency(_:at:)
    3 RAR29Decoder.nextPPMdToken(outputPosition:)
    2 PPMd7Model.update2(context:state:)
    2 specialized static PPMd7Suballocator.bytes(forClass:)
    2 PPMd7Suballocator.removeNode(classIndex:)
    2 PPMd7Suballocator.allocateUnits(_:)
    2 specialized static RARStandardFilters.audio(_:channels:)
    2 DYLD-STUB$$swift_retain
    2 RARPPMdRangeDecoder.decodeBinary(probability:)
    1 /usr/lib/system/libsystem_kernel.dylib __open
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_thread_cache_fill_and_malloc
    1 PPMd7Suballocator.checkedOffset(_:byteCount:)
    1 specialized PPMd7Model.materializeSuccessors(_:baseContext:upBranch:symbol:)
    1 lazy protocol witness table accessor for type [String] and conformance [A]
    1 RARPPMdRangeDecoder.threshold(total:)
    1 PPMd7Model.setStatsRef(_:of:stateCount:)
    1 PPMd7Suballocator.requireAllocatedUnitBlock(_:classIndex:)
    1 PPMd7Model.validate(_:)
    1 PPMd7Suballocator.requireFrontierOrder()
    1 PPMd7Suballocator.allocateUnitsRare(classIndex:)
    1 /usr/lib/swift/libswiftCore.dylib _swift_setExclusivityTLS
    1 /usr/lib/system/libsystem_malloc.dylib malloc_type_malloc
    1 PPMd7Model.escapeEstimator(for:)
    1 RAR29Decoder.copyMatchToFilter(window:windowMask:windowPosition:distance:remaining:maximumCount:outputPosition:)
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 PPMd7Model.createSuccessors(skipFoundState:suffixState:minimumContext:)
    1 /usr/lib/system/libsystem_kernel.dylib pread
    1 DYLD-STUB$$swift_release
    1 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
```

### step3-cpu: book-solid.7z

```text
load 0x10069c000 samples 7651
 6069 /usr/lib/system/libsystem_kernel.dylib pread
 1261 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
  142 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
  128 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   20 LZMADecoder.read(into:)
   17 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    7 /usr/lib/libz.1.dylib inflateSetDictionary
    2 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __CFStringAppendFormatCore
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    1 specialized Data.init<A>(_:)
    1 /usr/lib/system/libsystem_malloc.dylib Malloc_Facility
```

### step3-cpu: book-tiff.7z

```text
load 0x102bcc000 samples 347
  179 /usr/lib/system/libsystem_kernel.dylib pread
   89 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   29 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   13 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   12 LZMADecoder.read(into:)
    9 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    6 /usr/lib/libz.1.dylib inflateSetDictionary
    3 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    3 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
    1 /usr/lib/system/libsystem_kernel.dylib close
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/system/libsystem_malloc.dylib malloc_type_malloc
    1 outlined destroy of ByteReader
```

### step4-cpu: book-tiff-rar5.cbr

```text
load 0x1028ec000 samples 221
   70 /usr/lib/system/libsystem_kernel.dylib pread
   42 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   39 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   32 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:window:windowMask:windowPosition:historySize:produced:)
   10 RAR5Decoder.decodeDistance(slot:bits:)
    7 specialized RAR5Decoder.decodeLengthSlot(_:bits:)
    3 /usr/lib/libz.1.dylib inflateSetDictionary
    2 /usr/lib/system/libsystem_platform.dylib __bzero
    2 RAR5HuffmanTable.build(lengths:count:requireSymbol:)
    2 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    1 /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation $sSTsSQ7ElementRpzrlE6starts4withSbqd___tSTRd__AAQyd__ABRSlFSS8UTF8ViewV_Says5UInt8VGTg5
    1 kaito_main
    1 /usr/lib/system/libsystem_kernel.dylib __openat
    1 /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation $ss22_ContiguousArrayBufferV20_consumeAndCreateNew14bufferIsUnique15minimumCapacity13growForAppendAByxGSb_SiSbtFSS_Tg5
    1 specialized Data.init<A>(_:)
    1 /usr/lib/swift/libswiftCore.dylib _ZL52swift_conformsToProtocolMaybeInstantiateSuperclassesPKN5swift14TargetMetadataINS_9InProcessEEEPKNS_24TargetProtocolDescriptorIS1_EEb
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation CFAllocatorDeallocate
    1 specialized RAR5Decoder.decodeLength(using:bits:)
    1 /usr/lib/system/libsystem_platform.dylib _platform_memset
    1 RAR5Decoder.rotateDistanceToFront(_:)
    1 DYLD-STUB$$memmove
    1 /usr/lib/system/libsystem_kernel.dylib close
```

### final-cpu: book-tiff-rar5.cbr

```text
load 0x104cb8000 samples 245
   62 /usr/lib/system/libsystem_kernel.dylib pread
   58 RAR5Decoder.decodeRaw(into:capacity:stopAtFilter:window:windowMask:windowPosition:historySize:produced:)
   45 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   29 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   16 RAR5Decoder.decodeDistance(slot:bits:)
   11 specialized RAR5Decoder.decodeLengthSlot(_:bits:)
    5 /usr/lib/libz.1.dylib inflateSetDictionary
    4 specialized RAR5Decoder.decodeLength(using:bits:)
    4 RAR5HuffmanTable.build(lengths:count:requireSymbol:)
    3 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    3 /usr/lib/system/libsystem_platform.dylib _platform_memset
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __CFStringAppendFormatCore
    1 /usr/lib/swift/libswiftCore.dylib swift_arrayDestroy
    1 RAR5Decoder.rotateDistanceToFront(_:)
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_tiny
    1 /usr/lib/system/libsystem_kernel.dylib close
```

### final-cpu: ppmd-s-m5-mctp.rar

```text
load 0x100ee4000 samples 1042
  351 /usr/lib/system/libsystem_platform.dylib _platform_memmove
  169 specialized PPMd7Model.decodeSymbol2<A>(in:using:)
  112 RAR29Decoder.read(into:)
   64 PPMd7Suballocator.appendText(_:)
   61 PPMd7Model.storeState(_:at:)
   40 specialized PPMd7Model.decodeSymbol1<A>(in:using:)
   31 specialized PPMd7Model.decodeByte<A>(using:)
   25 PPMd7Model.setNumberOfStats(_:in:)
   23 PPMd7Model.indexOfSymbol(_:in:)
   16 /usr/lib/swift/libswiftCore.dylib swift_release
   14 PPMd7Model.stateRef(in:index:)
   13 PPMd7Model.updateModel(minimumContext:)
   10 PPMd7Model.loadState(at:)
    7 RARPPMdRangeDecoder.remove(start:size:)
    7 /usr/lib/swift/libswiftCore.dylib swift_beginAccess
    6 PPMd7Suballocator.insertNode(_:classIndex:)
    6 PPMd7Model.setSummaryFrequency(_:of:)
    6 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    6 PPMd7Model.update1(context:stateIndex:)
    6 PPMd7Model.setStateFrequency(_:at:)
    6 RAR29Decoder.nextPPMdToken(outputPosition:)
    5 PPMd7Model.appendState(_:summaryFrequency:to:)
    5 /usr/lib/swift/libswiftCore.dylib swift_retain
    4 PPMd7Model.update2(context:state:)
    4 specialized PPMd7Model.materializeSuccessors(_:baseContext:upBranch:symbol:)
    4 PPMd7Model.escapeEstimator(for:)
    3 /usr/lib/system/libsystem_kernel.dylib pread
    3 specialized PPMd7Model.decodeBinarySymbol<A>(in:using:)
    3 PPMd7Suballocator.glueFreeBlocks()
    3 PPMd7Model.rescale(_:)
    3 specialized static RARStandardFilters.audio(_:channels:)
    2 PPMd7Suballocator.requireFrontierOrder()
    2 __swift_instantiateConcreteTypeFromMangledNameV2
    2 PPMd7Model.setStateSuccessor(_:at:)
    2 RARPPMdRangeDecoder.threshold(total:)
    2 DYLD-STUB$$swift_beginAccess
    2 PPMd7Suballocator.splitBlock(_:oldClass:newClass:)
    2 /usr/lib/swift/libswiftCore.dylib _swift_setExclusivityTLS
    1 /usr/lib/system/libsystem_malloc.dylib xzm_malloc_zone_size
    1 PPMd7Suballocator.checkedOffset(_:byteCount:)
    1 /usr/lib/swift/libswiftCore.dylib swift_deallocClassInstance
    1 PPMd7Suballocator.requireAllocatedUnitBlock(_:classIndex:)
    1 PPMd7Model.setStatsRef(_:of:stateCount:)
    1 PPMd7Suballocator.removeNode(classIndex:)
    1 /usr/lib/swift/libswiftCore.dylib _swift_getExclusivityTLS
    1 specialized static PPMd7Suballocator.bytes(forClass:)
    1 /usr/lib/system/libsystem_malloc.dylib _xzm_free_tc
    1 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    1 RAR29Decoder.copyMatchToFilter(window:windowMask:windowPosition:distance:remaining:maximumCount:outputPosition:)
    1 /usr/lib/system/libsystem_malloc.dylib malloc_size
```

### final-cpu: book-solid.7z

```text
load 0x1002cc000 samples 7641
 6553 /usr/lib/system/libsystem_kernel.dylib pread
  864 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
  106 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   72 /usr/lib/system/libsystem_platform.dylib _platform_memmove
   17 LZMADecoder.read(into:)
   14 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
    3 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    2 /usr/lib/system/libsystem_kernel.dylib _kernelrpc_mach_vm_map_trap
    2 /usr/lib/libz.1.dylib inflateSetDictionary
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 specialized Data.init<A>(_:)
    1 LZMA2Decoder.read(into:)
    1 /usr/lib/swift/libswiftCore.dylib swift_isUniquelyReferenced_nonNull_native
    1 /usr/lib/swift/libswiftCore.dylib _swift_getExclusivityTLS
    1 /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation _CFRuntimeCreateInstance
    1 DYLD-STUB$$memmove
    1 /usr/lib/swift/libswiftCore.dylib $ss7_StdoutVs16TextOutputStreamssACP5writeyySSFTW
```

### final-cpu: book-tiff.7z

```text
load 0x10002c000 samples 326
  229 /usr/lib/system/libsystem_kernel.dylib pread
   48 decodeLZMANewMatchBatch(probabilities:positionStateMask:processedPosition:state:decoder:output:outputCapacity:outputBudget:refillLimit:firstMatchPending:)
   18 /usr/lib/system/libcorecrypto.dylib AccelerateCrypto_SHA256_compress
   11 /usr/lib/system/libsystem_platform.dylib _platform_memmove
    6 decodeLZMARepeatedMatchSymbol(probabilities:positionState:statePositionIndex:state:rep0:rep1:rep2:rep3:decoder:)
    4 /usr/lib/libz.1.dylib inflateSetDictionary
    3 /usr/lib/system/libsystem_malloc.dylib _xzm_xzone_malloc_freelist_outlined
    3 LZMADecoder.read(into:)
    1 /usr/lib/system/libsystem_kernel.dylib close
    1 /usr/lib/system/libsystem_platform.dylib __bzero
    1 /usr/lib/libobjc.A.dylib _ZN11objc_object9changeIsaEP10objc_class
    1 decodeLZMALiteralRun(probabilities:dictionary:dictionaryCount:literalContextShift:literalPreviousShift:literalPositionMask:positionStateMask:rep0:dictionaryPosition:dictionaryBytesAvailable:previousByte:processedPosition:outputPosition:state:decoder:maximumCount:refillLimit:)
```

### Native `sample` command results

`before: book-tiff-rar5.cbr`

```text
sample[65711]: sample cannot examine process 65710 (kaito-before) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`before: ppmd-s-m5-mctp.rar`

```text
sample[65713]: sample cannot examine process 65712 (kaito-before) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`before: book-solid.7z`

```text
sample[65717]: sample cannot examine process 65716 (kaito-before) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`before: book-tiff.7z`

```text
sample[65731]: sample cannot examine process 65730 (kaito-before) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`after: book-tiff-rar5.cbr`

```text
sample[70135]: sample cannot examine process 70134 (kaito-final) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`after: ppmd-s-m5-mctp.rar`

```text
sample[70137]: sample cannot examine process 70136 (kaito-final) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`after: book-solid.7z`

```text
sample[70141]: sample cannot examine process 70140 (kaito-final) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

`after: book-tiff.7z`

```text
sample[70150]: sample cannot examine process 70149 (kaito-final) for unknown reasons, even though it appears to exist; try running with `sudo`.

exit: 255
```

## Acceptance criteria

1. **Met:** `book-tiff-rar5.cbr` ≤ 1.5× paired reference: 390.867 / 309.14 = 1.264×.
2. **Met:** `ppmd-s-m5-mctp.rar` ≤ 1.5× paired reference: 1702.270 / 1260.47 = 1.351×.
3. **Met:** no >5% regression in the nine named cases. Largest increase: `book-stored.cbz`, +4.36%.
4. **Met:** all 14 archives in the SHA loop plus `st1200-pts.rar` returned `RESULT: OK`; all `kaito sha` invocations exited 0. The two changed PPMd cases also match baseline output and an independent black-box oracle.
5. **Met with documented environment adaptation:** full `swift test` passes under both Swift 6.3.3 and 6.4; 400 mutants over the specified corpus (41 seeds) report 0 crashes, 0 hangs and 0 sanitizer findings. Successful builds/tests use the local cache and `--disable-sandbox` as explained above.
6. **Met:** this dated record is linked from design.md §11; CHANGELOG.md has exactly one new bullet.

Additional constraints: no public API change; boundary validation and §11's hot-loop policy
are retained; no `bd`, commit or push was run. The optional LZMA 1.3× stretch goal and successful
native `sample` inspection remain unmet, explicitly distinguished from the six acceptance criteria.

## Full verification command output

Outputs below are unabridged for each displayed command. For the spec's `tail -3` and `tail -2`
commands, the displayed output is exactly that tail; the complete underlying stream is also
preserved at the linked local log. Exit status records the underlying process/pipeline rather
than silently accepting `tail` success. SHA TSV outputs are the files explicitly redirected
by the spec; all result lines are reproduced here.

### 01-build-exact

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift build -c release --product kaito
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.RbRLOm/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "-module-cache-path", "<repo>/.build/batch11/module-cache", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.ek7n00/kaitokit-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.EN1d1u/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "-module-cache-path", "<repo>/.build/batch11/module-cache", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.xk7uAb/kaitokit-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
error: ExitCode(rawValue: 1)
[0/1] Planning build
```

Exit status: 1. [Complete underlying log](../.build/batch11/verification/01-build-exact.log).

### 02-build-local

```sh
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
Build of product 'kaito' complete! (28.64s)
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/02-build-local.log).

### 03-bin-path

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift build -c release --product kaito --show-bin-path
```

```text
<repo>/.build/arm64-apple-macosx/release
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/03-bin-path.log).

### 04-paired-bench

```sh
for f in book-tiff-rar5.cbr book-rar5.cbr book-tiff-rar4.cbr book-rar4.cbr book-solid.7z book-tiff.7z book-lh5.lzh book-tiff-lh7.lzh book-deflate.cbz; do
  "$X" extract "$A/$f" 3 | tail -1; "$K" bench "$A/$f" 3 | grep extract-median || exit; done
```

```text
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[420.30,308.47,309.14],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
extract-median-ms	390.867
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[151.48,34.19,34.54],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
extract-median-ms	33.350
{"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[436.24,326.51,326.19],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
extract-median-ms	375.105
{"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[151.21,34.67,34.92],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
extract-median-ms	30.756
{"mode":"extract","archive":"book-solid.7z","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[7127.91,6910.35,6856.71],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
extract-median-ms	9610.231
{"mode":"extract","archive":"book-tiff.7z","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[511.91,400.24,401.09],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
extract-median-ms	522.426
{"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2823.36,2680.12,2661.67],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
extract-median-ms	2103.338
{"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[933.29,824.50,823.79],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
extract-median-ms	335.192
{"mode":"extract","archive":"book-deflate.cbz","entries":200,"bytes":1209043650,"diskread":0,"pageins":1,"rep_ms":[795.14,679.34,673.37],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
extract-median-ms	683.972
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/04-paired-bench.log).

### 05-ppmd-bench

```sh
"$K" bench "$S/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar" 3
```

```text
reps	3
open-median-ms	0.281
extract-median-ms	1882.584
bytes	13127317
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/05-ppmd-bench.log).

### 06-sha-list

```sh
for f in sjis2000.zip book-deflate.cbz book-tiff.7z book-solid.7z book-rar5.cbr book-tiff-rar5.cbr book-rar4.cbr book-tiff-rar4.cbr book-lh5.lzh book-lh6.lzh book-lh7.lzh book-tiff-lh5.lzh book-tiff-lh6.lzh book-tiff-lh7.lzh; do
  "$K" sha "$A/$f" > /tmp/k-$f.tsv && python3 "$S/compare-sha.py" "$S/oracle/$f.sha.tsv" /tmp/k-$f.tsv | grep RESULT || exit; done
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
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/06-sha-list.log).

### 07-sha-st

```sh
"$K" sha <external RAR4 archive> > /tmp/k-st.tsv && python3 "$S/compare-sha.py" "$S/oracle/st1200.tsv" /tmp/k-st.tsv | grep RESULT
```

```text
RESULT: OK
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/07-sha-st.log).

### 08-ppmd-parity

```sh
for f in ppmd-s-m5-mctp.rar pp-jpg-mctp.rar; do
  .build/batch11/kaito-before sha "$S/realtool/rar4-solid-random-access/arc/$f" > ".build/batch11/verification/before-$f.tsv" &&
  "$K" sha "$S/realtool/rar4-solid-random-access/arc/$f" > ".build/batch11/verification/after-$f.tsv" &&
  cmp ".build/batch11/verification/before-$f.tsv" ".build/batch11/verification/after-$f.tsv" || exit; done
```

```text
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/08-ppmd-parity.log).

### 09-test633-exact

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift test 2>&1 | tail -3
```

```text
sandbox-exec: sandbox_apply: Operation not permitted
error: ExitCode(rawValue: 1)
[0/1] Planning build
```

Exit status: 1. [Complete underlying log](../.build/batch11/verification/09-test633-exact.log).

### 10-test633-local

```sh
DEVELOPER_DIR=/Applications/Xcode.app swift test --disable-sandbox 2>&1 | tail -3
```

```text
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/10-test633-local.log).

XCTest suite total (the separate Swift Testing footer reports zero tests):

```text
	 Executed 629 tests, with 33 tests skipped and 0 failures (0 unexpected) in 155.812 (155.859) seconds
```

### 11-test64-exact

```sh
swift test 2>&1 | tail -3
```

```text
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.fOczMD/vfs.yaml", "-L", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "6.0.0", "-module-cache-path", "<repo>/.build/batch11/module-cache", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.Zso1hc/kaitokit-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
```

Exit status: 1. [Complete underlying log](../.build/batch11/verification/11-test64-exact.log).

### 12-test64-local

```sh
swift test --disable-sandbox 2>&1 | tail -3
```

```text
↳ Testing Library Version: 2078
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/12-test64-local.log).

XCTest suite total (the separate Swift Testing footer reports zero tests):

```text
	 Executed 614 tests, with 33 tests skipped and 0 failures (0 unexpected) in 154.483 (154.527) seconds
	 Executed 15 tests, with 0 failures (0 unexpected) in 0.741 (0.744) seconds
```

### 13-build-asan

```sh
Scripts/fuzz/build-asan.sh
```

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for debugging...
[2 / 14] KaitoKit
[5 / 17] KaitoKit
[13 / 26] KaitoKit
[17 / 29] kaito-product
[24 / 33] kaito-product
[25 / 33] KaitoKit
[32 / 34] kaito-product
Build complete! (2.03秒)
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/13-build-asan.log).

### 14-mutants

```sh
Scripts/fuzz/run-mutants.sh --count 400 --timeout 8 "$S"/fuzz-seeds/*/* 2>&1 | tail -2
```

```text
generated 400 mutants from 41 seed(s)
mutants: 400, crashes: 0, hangs: 0, sanitizer findings: 0
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/14-mutants.log).

### 15-diff-status

```sh
git diff --check; git status --porcelain
```

```text
 M CHANGELOG.md
 M Documentation/design.md
 M Sources/KaitoKit/Codecs/PPMd/PPMd7Model.swift
 M Sources/KaitoKit/Codecs/RAR/RAR5Decoder.swift
 M Tests/KaitoKitTests/RAR5DecoderTests.swift
?? Documentation/performance-rar5-ppmd-2026-09-08.md
```

Exit status: 0. [Complete underlying log](../.build/batch11/verification/15-diff-status.log).

### Additional final pairs (stored and both PPMd cases)

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-stored.cbz 3
{"mode":"extract","archive":"book-stored.cbz","entries":200,"bytes":1209043650,"diskread":0,"pageins":1,"rep_ms":[143.00,26.05,26.16],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-final bench <corpus>/bench-work/corpus/archives/book-stored.cbz 3
reps	3
open-median-ms	0.735
extract-median-ms	31.698
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
{"mode":"extract","archive":"ppmd-s-m5-mctp.rar","entries":9,"bytes":39381951,"diskread":0,"pageins":2,"rep_ms":[1260.47,1307.13,1246.31],"sha256":"35f487fa884d054584eefe7b4d3d72cfff8bf4e398b02923a888282af2433407"}
exit: 0
$ .build/batch11/kaito-final bench <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
reps	3
open-median-ms	0.287
extract-median-ms	1702.270
bytes	13127317
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
{"mode":"extract","archive":"pp-jpg-mctp.rar","entries":1,"bytes":6051651,"diskread":0,"pageins":2,"rep_ms":[601.71,599.51,632.03],"sha256":"74b90234a6b15aaed8de35e39801a0f0dcb108a28a068e4e559d28e71af84cc9"}
exit: 0
$ .build/batch11/kaito-final bench <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
reps	3
open-median-ms	0.207
extract-median-ms	828.599
bytes	2017217
exit: 0
```

The supplementary oracle script initially tried aggregate hashes of raw output, first over
three repetitions and then over one. Per-member checks already passed. Black-box comparison
identified the reference field as SHA-256 of the concatenated binary member digests from one
extraction. The corrected script verifies that aggregate as well as every member against rar.
Both diagnostic failures and the successful rerun are retained; they were not decoder mismatches.

### ppmd-blackbox-initial

```text
$ /opt/homebrew/bin/rar p -inul <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar
Traceback (most recent call last):
  File "<repo>/.build/batch11/ppmd-oracle.py", line 16, in <module>
    assert hashlib.sha256(result.stdout*3).hexdigest()==x[name]['sha256']
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
AssertionError
```

### ppmd-blackbox-second

```text
$ /opt/homebrew/bin/rar p -inul <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar
Traceback (most recent call last):
  File "<repo>/.build/batch11/ppmd-oracle.py", line 16, in <module>
    assert hashlib.sha256(result.stdout).hexdigest()==x[name]['sha256']
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
AssertionError
```

### ppmd-blackbox

```text
$ /opt/homebrew/bin/rar p -inul <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar
ppmd-s-m5-mctp.rar: 9 member SHA-256 digests match rar; aggregate of binary member digests matches XADMaster; exit 0
$ /opt/homebrew/bin/rar p -inul <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar
pp-jpg-mctp.rar: 1 member SHA-256 digests match rar; aggregate of binary member digests matches XADMaster; exit 0
```

## Complete per-step benchmark outputs

### before

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":884736,"pageins":47,"rep_ms":[416.40,307.61,304.91],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
reps	3
open-median-ms	1.718
extract-median-ms	518.768
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[152.54,34.57,34.98],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
reps	3
open-median-ms	3.507
extract-median-ms	33.056
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar4.cbr 3
{"mode":"extract","archive":"book-tiff-rar4.cbr","entries":100,"bytes":1153495200,"diskread":32768,"pageins":5,"rep_ms":[424.51,313.71,313.71],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-tiff-rar4.cbr 3
reps	3
open-median-ms	0.840
extract-median-ms	377.035
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar4.cbr 3
{"mode":"extract","archive":"book-rar4.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[153.00,34.72,34.75],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-rar4.cbr 3
reps	3
open-median-ms	1.319
extract-median-ms	30.953
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-solid.7z 3
{"mode":"extract","archive":"book-solid.7z","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[6931.76,6716.64,6773.77],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-solid.7z 3
reps	3
open-median-ms	0.582
extract-median-ms	9841.389
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff.7z 3
{"mode":"extract","archive":"book-tiff.7z","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[533.44,415.04,424.91],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-tiff.7z 3
reps	3
open-median-ms	0.398
extract-median-ms	529.342
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-lh5.lzh 3
{"mode":"extract","archive":"book-lh5.lzh","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[2880.06,2751.19,2700.48],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-lh5.lzh 3
reps	3
open-median-ms	3.495
extract-median-ms	2089.463
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-lh7.lzh 3
{"mode":"extract","archive":"book-tiff-lh7.lzh","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[944.29,831.97,829.80],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-tiff-lh7.lzh 3
reps	3
open-median-ms	1.238
extract-median-ms	343.316
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-deflate.cbz 3
{"mode":"extract","archive":"book-deflate.cbz","entries":200,"bytes":1209043650,"diskread":0,"pageins":1,"rep_ms":[798.77,670.03,659.15],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-deflate.cbz 3
reps	3
open-median-ms	0.676
extract-median-ms	678.218
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-stored.cbz 3
{"mode":"extract","archive":"book-stored.cbz","entries":200,"bytes":1209043650,"diskread":0,"pageins":1,"rep_ms":[144.36,26.18,26.62],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/bench-work/corpus/archives/book-stored.cbz 3
reps	3
open-median-ms	0.675
extract-median-ms	30.374
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
{"mode":"extract","archive":"ppmd-s-m5-mctp.rar","entries":9,"bytes":39381951,"diskread":49152,"pageins":6,"rep_ms":[1272.01,1240.97,1235.29],"sha256":"35f487fa884d054584eefe7b4d3d72cfff8bf4e398b02923a888282af2433407"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
reps	3
open-median-ms	0.252
extract-median-ms	2010.998
bytes	13127317
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
{"mode":"extract","archive":"pp-jpg-mctp.rar","entries":1,"bytes":6051651,"diskread":1978368,"pageins":2,"rep_ms":[615.20,614.72,612.68],"sha256":"74b90234a6b15aaed8de35e39801a0f0dcb108a28a068e4e559d28e71af84cc9"}
exit: 0
$ .build/batch11/kaito-before bench <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
reps	3
open-median-ms	0.212
extract-median-ms	862.399
bytes	2017217
exit: 0
```

### step1

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[417.72,305.57,305.39],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-step1 bench <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
reps	3
open-median-ms	1.692
extract-median-ms	461.134
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[151.64,34.18,34.43],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-step1 bench <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
reps	3
open-median-ms	3.516
extract-median-ms	29.318
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
{"mode":"extract","archive":"ppmd-s-m5-mctp.rar","entries":9,"bytes":39381951,"diskread":0,"pageins":2,"rep_ms":[1214.02,1162.76,1169.06],"sha256":"35f487fa884d054584eefe7b4d3d72cfff8bf4e398b02923a888282af2433407"}
exit: 0
$ .build/batch11/kaito-step1 bench <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
reps	3
open-median-ms	0.306
extract-median-ms	1913.278
bytes	13127317
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
{"mode":"extract","archive":"pp-jpg-mctp.rar","entries":1,"bytes":6051651,"diskread":0,"pageins":2,"rep_ms":[591.39,587.00,584.94],"sha256":"74b90234a6b15aaed8de35e39801a0f0dcb108a28a068e4e559d28e71af84cc9"}
exit: 0
$ .build/batch11/kaito-step1 bench <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
reps	3
open-median-ms	0.235
extract-median-ms	870.669
bytes	2017217
exit: 0
```

### step2

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[445.31,329.00,328.50],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-step2 bench <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
reps	3
open-median-ms	1.703
extract-median-ms	478.932
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[151.50,34.92,35.22],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-step2 bench <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
reps	3
open-median-ms	3.504
extract-median-ms	29.494
bytes	403014550
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
{"mode":"extract","archive":"ppmd-s-m5-mctp.rar","entries":9,"bytes":39381951,"diskread":0,"pageins":2,"rep_ms":[1232.50,1243.90,1247.97],"sha256":"35f487fa884d054584eefe7b4d3d72cfff8bf4e398b02923a888282af2433407"}
exit: 0
$ .build/batch11/kaito-step2 bench <corpus>/realtool/rar4-solid-random-access/arc/ppmd-s-m5-mctp.rar 3
reps	3
open-median-ms	0.273
extract-median-ms	1709.306
bytes	13127317
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
{"mode":"extract","archive":"pp-jpg-mctp.rar","entries":1,"bytes":6051651,"diskread":0,"pageins":2,"rep_ms":[596.48,595.87,621.03],"sha256":"74b90234a6b15aaed8de35e39801a0f0dcb108a28a068e4e559d28e71af84cc9"}
exit: 0
$ .build/batch11/kaito-step2 bench <corpus>/realtool/rar4-solid-random-access/arc/pp-jpg-mctp.rar 3
reps	3
open-median-ms	0.201
extract-median-ms	830.456
bytes	2017217
exit: 0
```

### step3

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[418.83,304.35,307.91],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-step3 bench <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
reps	3
open-median-ms	1.666
extract-median-ms	483.026
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[151.33,35.38,35.22],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-step3 bench <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
reps	3
open-median-ms	3.602
extract-median-ms	37.590
bytes	403014550
exit: 0
```

### step4

```text
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
{"mode":"extract","archive":"book-tiff-rar5.cbr","entries":100,"bytes":1153495200,"diskread":0,"pageins":2,"rep_ms":[409.24,303.88,313.59],"sha256":"1744a14943514316af3db63b53d73a12a141984ac90de1ef4f1a267954077c01"}
exit: 0
$ .build/batch11/kaito-step4 bench <corpus>/bench-work/corpus/archives/book-tiff-rar5.cbr 3
reps	3
open-median-ms	1.785
extract-median-ms	391.625
bytes	384498400
exit: 0
$ <corpus>/bench-work/bin/xadbench extract <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
{"mode":"extract","archive":"book-rar5.cbr","entries":200,"bytes":1209043650,"diskread":0,"pageins":2,"rep_ms":[153.96,34.27,34.44],"sha256":"733008d3fb445424a3fff55b14d5f843f3fc441a776fd86e241f7b8c5e149843"}
exit: 0
$ .build/batch11/kaito-step4 bench <corpus>/bench-work/corpus/archives/book-rar5.cbr 3
reps	3
open-median-ms	3.536
extract-median-ms	32.654
bytes	403014550
exit: 0
```

## Supplementary focused tests and build diagnostics

### build-baseline.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.0TfEkk/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.Yn3zOz/kaitokit-manifest"])
<unknown>:0: error: error opening '<clang module cache>/Swift-1IEYM950OGIQC.swiftmodule' for output: <clang module cache>: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.YooXSJ/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.6ctxYL/kaitokit-manifest"])
<unknown>:0: error: error opening '<clang module cache>/Swift-1IEYM950OGIQC.swiftmodule' for output: <clang module cache>: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
error: ExitCode(rawValue: 1)
[0/1] Planning build
```

### build-baseline-retry.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.4q6YPV/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "-module-cache-path", "<repo>/.build/batch11/module-cache", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.FoEowc/kaitokit-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.8Cp2FV/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk", "-package-description-version", "6.0.0", "-module-cache-path", "<repo>/.build/batch11/module-cache", "<repo>/Package.swift", "-o", "/var/folders/vg/13nykq6d7nq3tnwcqwr1nfl40000gn/T/TemporaryDirectory.X9kbea/kaitokit-manifest"])
sandbox-exec: sandbox_apply: Operation not permitted
error: ExitCode(rawValue: 1)
[0/1] Planning build
```

### build-baseline-local.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
[0/1] Planning build
Building for production...
[0/2] Write swift-version--58304C5D6DBC2206.txt
[2/3] Compiling KaitoKit Bzip2Decompressor.swift
[3/4] Compiling kaito main.swift
Build of product 'kaito' complete! (28.68s)
```

### build-step1.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for production...
[0/3] Write sources
[1/3] Write swift-version--58304C5D6DBC2206.txt
[3/4] Compiling KaitoKit Bzip2Decompressor.swift
[4/6] Compiling kaito main.swift
[4/6] Write Objects.LinkFileList
[5/6] Linking kaito
Build of product 'kaito' complete! (28.88s)
```

### build-step2.log

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
Build of product 'kaito' complete! (29.14s)
```

### build-step3.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for production...
[0/3] Write sources
[1/3] Write swift-version--58304C5D6DBC2206.txt
[3/4] Compiling KaitoKit Bzip2Decompressor.swift
[3/5] Write Objects.LinkFileList
[4/5] Linking kaito
Build of product 'kaito' complete! (28.12s)
```

### build-step4.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
Building for production...
[0/3] Write sources
[1/3] Write swift-version--58304C5D6DBC2206.txt
[3/4] Compiling KaitoKit Bzip2Decompressor.swift
[4/6] Compiling kaito main.swift
[4/6] Write Objects.LinkFileList
[5/6] Linking kaito
Build of product 'kaito' complete! (28.89s)
```

### test-step1.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
[0/1] Planning build
Building for debugging...
[0/7] Write sources
[2/7] Write swift-version--58304C5D6DBC2206.txt
[4/9] Compiling KaitoKit RAR5Decoder.swift
[5/9] Emitting module KaitoKit
[6/10] Compiling KaitoKit RAR5Reader.swift
[7/15] Emitting module kaito
[8/17] Emitting module KaitoKitCompat
[8/17] Write Objects.LinkFileList
[11/18] Emitting module KaitoKitCompatTests
[11/18] Linking kaito
[11/18] Linking libKaitoKitDynamic.dylib
[13/18] Applying kaito
[15/18] Compiling KaitoKitTests RAR5DecoderTests.swift
[16/18] Emitting module KaitoKitTests
[16/18] Write Objects.LinkFileList
[17/18] Linking KaitoKitPackageTests
Build complete! (2.72s)
Test Suite 'Selected tests' started at 2026-09-08 17:32:12.700.
Test Suite 'KaitoKitPackageTests.xctest' started at 2026-09-08 17:32:12.701.
Test Suite 'RAR5DecoderTests' started at 2026-09-08 17:32:12.701.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeltaFilterOutputResumesAcrossArbitraryBufferSizes]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeltaFilterOutputResumesAcrossArbitraryBufferSizes]' passed (0.100 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeterministicFilterPayloadMutantsCompleteBoundedly]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeterministicFilterPayloadMutantsCompleteBoundedly]' passed (0.068 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testE8FilterOutputResumesAcrossArbitraryBufferSizes]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testE8FilterOutputResumesAcrossArbitraryBufferSizes]' passed (0.122 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testGeneratedMatchStreamHandlesShortSourceAndTinyOutputReads]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testGeneratedMatchStreamHandlesShortSourceAndTinyOutputReads]' passed (0.139 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testLiteralBlocksStreamThroughOneByteReadsAndReuseTables]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testLiteralBlocksStreamThroughOneByteReadsAndReuseTables]' passed (0.003 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedAndUnsupportedFilterParametersAreRejected]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedAndUnsupportedFilterParametersAreRejected]' passed (0.004 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedBlockHeadersAndTablesAreRejected]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedBlockHeadersAndTablesAreRejected]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testPendingMatchesWrapHistoryAndPreserveSolidContinuation]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testPendingMatchesWrapHistoryAndPreserveSolidContinuation]' passed (0.885 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testSolidStateCarriesDictionaryTablesDistancesAndLastLength]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testSolidStateCarriesDictionaryTablesDistancesAndLastLength]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testSourceFailuresAndInvalidCountsAreThrownWithoutAborting]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testSourceFailuresAndInvalidCountsAreThrownWithoutAborting]' passed (0.002 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testUnknownSizeFutureFilterFailsTruncatedAfterRawStreamEnds]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testUnknownSizeFutureFilterFailsTruncatedAfterRawStreamEnds]' passed (0.001 seconds).
Test Suite 'RAR5DecoderTests' passed at 2026-09-08 17:32:14.029.
	 Executed 11 tests, with 0 failures (0 unexpected) in 1.327 (1.328) seconds
Test Suite 'KaitoKitPackageTests.xctest' passed at 2026-09-08 17:32:14.029.
	 Executed 11 tests, with 0 failures (0 unexpected) in 1.327 (1.328) seconds
Test Suite 'Selected tests' passed at 2026-09-08 17:32:14.029.
	 Executed 11 tests, with 0 failures (0 unexpected) in 1.327 (1.329) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

### test-step4.log

```text
warning: <swiftpm state>/configuration is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm state>/security is not accessible or not writable, disabling user-level cache features.
warning: <swiftpm cache> is not accessible or not writable, disabling user-level cache features.
warning: 'kaitokit': failed storing manifest for 'kaitokit' in cache: attempt to write a readonly database
[0/1] Planning build
Building for debugging...
[0/7] Write sources
[2/7] Write swift-version--58304C5D6DBC2206.txt
[4/10] Emitting module KaitoKit
[5/10] Compiling KaitoKit PPMd7Model.swift
[6/10] Compiling KaitoKit RAR5Decoder.swift
[7/15] Compiling KaitoKit RAR5Reader.swift
[8/15] Compiling KaitoKit SevenZipFolderPipeline.swift
[9/15] Compiling KaitoKit RAR4Reader.swift
[10/15] Compiling KaitoKit RAR29Decoder.swift
[11/15] Compiling KaitoKit PPMd7Decoder.swift
[12/22] Emitting module kaito
[13/22] Emitting module KaitoKitCompat
[13/22] Write Objects.LinkFileList
[16/23] Emitting module KaitoKitCompatTests
[16/23] Linking kaito
[17/23] Linking libKaitoKitDynamic.dylib
[18/23] Applying kaito
[20/23] Emitting module KaitoKitTests
[21/23] Compiling KaitoKitTests RAR5DecoderTests.swift
[21/23] Write Objects.LinkFileList
[22/23] Linking KaitoKitPackageTests
Build complete! (3.15s)
Test Suite 'Selected tests' started at 2026-09-08 17:39:53.714.
Test Suite 'KaitoKitPackageTests.xctest' started at 2026-09-08 17:39:53.715.
Test Suite 'PPMd7DecoderTests' started at 2026-09-08 17:39:53.715.
Test Case '-[KaitoKitTests.PPMd7DecoderTests testCorruptPPMdStreamsThrowOrRemainOutputBounded]' started.
Test Case '-[KaitoKitTests.PPMd7DecoderTests testCorruptPPMdStreamsThrowOrRemainOutputBounded]' passed (0.103 seconds).
Test Case '-[KaitoKitTests.PPMd7DecoderTests testKnownPPMd7StreamsWithSingleByteReads]' started.
Test Case '-[KaitoKitTests.PPMd7DecoderTests testKnownPPMd7StreamsWithSingleByteReads]' passed (0.006 seconds).
Test Case '-[KaitoKitTests.PPMd7DecoderTests testPropertiesAreValidatedBeforeModelAllocation]' started.
Test Case '-[KaitoKitTests.PPMd7DecoderTests testPropertiesAreValidatedBeforeModelAllocation]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.PPMd7DecoderTests testSuballocatorUsesOnlyItsFixedArenaAndRecyclesUnits]' started.
Test Case '-[KaitoKitTests.PPMd7DecoderTests testSuballocatorUsesOnlyItsFixedArenaAndRecyclesUnits]' passed (0.000 seconds).
Test Suite 'PPMd7DecoderTests' passed at 2026-09-08 17:39:53.825.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.110 (0.110) seconds
Test Suite 'RAR5DecoderTests' started at 2026-09-08 17:39:53.825.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeltaFilterOutputResumesAcrossArbitraryBufferSizes]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeltaFilterOutputResumesAcrossArbitraryBufferSizes]' passed (0.100 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeterministicFilterPayloadMutantsCompleteBoundedly]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testDeterministicFilterPayloadMutantsCompleteBoundedly]' passed (0.069 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testE8FilterOutputResumesAcrossArbitraryBufferSizes]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testE8FilterOutputResumesAcrossArbitraryBufferSizes]' passed (0.123 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testGeneratedMatchStreamHandlesShortSourceAndTinyOutputReads]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testGeneratedMatchStreamHandlesShortSourceAndTinyOutputReads]' passed (0.141 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testHuffmanPrimaryRebuildAndLongCodeLogicalEnd]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testHuffmanPrimaryRebuildAndLongCodeLogicalEnd]' passed (0.005 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testLiteralBlocksStreamThroughOneByteReadsAndReuseTables]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testLiteralBlocksStreamThroughOneByteReadsAndReuseTables]' passed (0.003 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedAndUnsupportedFilterParametersAreRejected]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedAndUnsupportedFilterParametersAreRejected]' passed (0.004 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedBlockHeadersAndTablesAreRejected]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testMalformedBlockHeadersAndTablesAreRejected]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testPendingMatchesWrapAndPreserveSolidHistory]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testPendingMatchesWrapAndPreserveSolidHistory]' passed (0.884 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testSolidStateCarriesDictionaryTablesDistancesAndLastLength]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testSolidStateCarriesDictionaryTablesDistancesAndLastLength]' passed (0.001 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testSourceFailuresAndInvalidCountsAreThrownWithoutAborting]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testSourceFailuresAndInvalidCountsAreThrownWithoutAborting]' passed (0.002 seconds).
Test Case '-[KaitoKitTests.RAR5DecoderTests testUnknownSizeFutureFilterFailsTruncatedAfterRawStreamEnds]' started.
Test Case '-[KaitoKitTests.RAR5DecoderTests testUnknownSizeFutureFilterFailsTruncatedAfterRawStreamEnds]' passed (0.001 seconds).
Test Suite 'RAR5DecoderTests' passed at 2026-09-08 17:39:55.160.
	 Executed 12 tests, with 0 failures (0 unexpected) in 1.334 (1.335) seconds
Test Suite 'KaitoKitPackageTests.xctest' passed at 2026-09-08 17:39:55.160.
	 Executed 16 tests, with 0 failures (0 unexpected) in 1.444 (1.445) seconds
Test Suite 'Selected tests' passed at 2026-09-08 17:39:55.160.
	 Executed 16 tests, with 0 failures (0 unexpected) in 1.444 (1.446) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

## Temporary PC sampler source

```c
#include <execinfo.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <sys/time.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void *frames[100000][40];
static int depths[100000];
static volatile sig_atomic_t used;
static void tick(int signal, siginfo_t *info, void *context) {
    int i=used;
    if(i>=100000) return;
    frames[i][0]=(void *)__darwin_arm_thread_state64_get_pc(((ucontext_t *)context)->uc_mcontext->__ss);
    depths[i]=1;
    used=i+1;
}
__attribute__((constructor)) static void start(void) {
    struct sigaction action={0};
    action.sa_sigaction=tick;
    action.sa_flags=SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGPROF,&action,NULL);
    struct itimerval interval={{0,1000},{0,1000}};
    setitimer(ITIMER_PROF,&interval,NULL);
}
__attribute__((destructor)) static void finish(void) {
    struct itimerval interval={0};
    setitimer(ITIMER_PROF,&interval,NULL);
    const char *path=getenv("KAITO_PROFILE_PATH");
    if(!path) return;
    FILE *file=fopen(path,"w");
    if(!file) return;
    const struct mach_header *executable=NULL;
    for(uint32_t i=0;i<_dyld_image_count();i++) if(_dyld_get_image_header(i)->filetype==MH_EXECUTE) executable=_dyld_get_image_header(i);
    fprintf(file,"load %p samples %d\n",executable,used);
    for(int i=0;i<used;i++) {
        for(int j=0;j<depths[i];j++) fprintf(file,"%p ",frames[i][j]);
        fputc('\n',file);
    }
    fclose(file);
    char names[4096]; snprintf(names,sizeof(names),"%s.runtime",path);
    file=fopen(names,"w");
    if(!file) return;
    for(int i=0;i<used;i++) for(int j=0;j<depths[i];j++) {
        Dl_info info;
        if(dladdr(frames[i][j],&info)) fprintf(file,"%p %s %s\n",frames[i][j],info.dli_fname,info.dli_sname?info.dli_sname:"?");
    }
    fclose(file);
}
```

The earlier caller-unwinding diagnostic used the same handler with `backtrace` after recording
the interrupted PC; final PC-only runs omit that operation. Raw sampling files and symbol maps
are available in the local evidence directory.
