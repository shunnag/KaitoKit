# テスト

`swift test` は二つの target を実行する。

- `KaitoKitTests`: 本体の試験。形式ごとのディレクトリ（Core・Codecs・Zip・SevenZip・RAR・LHA・Tar・StuffIt・
  Containers・SingleFile・Text・CLI・Documentation）に分け、共有の helper は `Support/`（型名とファイル名が同じ。
  `#filePath` から場所を求めるのは `Support/TestFixtures.swift` だけ）、環境変数で有効にする計測は `Probes/` に置く。
- `KaitoKitCompatTests`: `KaitoKitCompat` の API を `@testable` なしで使えることを確かめる別 module（`CompatFixtures.swift`）。

1 ファイルに 1 クラスで、クラス名とファイル名は同じ。`--filter` はクラス名で指定する。名前を変えたクラスは
本体の先頭に `// 旧名: …` を残す（過去の検証記録の `--filter` を読み替えるため）。

## クラス名の接尾辞

| 接尾辞 | 意味 |
|---|---|
| Hardening | 壊れた・敵対的な入力と上限。skip しない |
| Corpus | 実データの集まり。外部の corpus は環境変数か `inbox/` で渡し、無ければ skip（EncodingDetectorCorpusTests は checked-in） |
| Differential | 別の実装（7zz・xz・rar など）や別の読み方との比較 |
| PublicValueGolden | 公開 API の値を `Tests/Fixtures` の凍結した JSON と比べる |
| SPIImport | `@_spi(...) internal import` だけで（`@testable` なしで）使えることの確認 |
| Compatibility | 実ツールで作った checked-in の fixture との相互運用（RARPasswordCompatibilityTests など） |
| ScaleProbe | `Probes/` の計測。環境変数が無ければ skip |

## 外部ツール

`Support/ExternalTools.swift` が環境変数 → `PATH` → `/opt/homebrew/bin` → `/usr/local/bin` の順に探す。無ければ skip、
`KAITO_REQUIRE_<名前>=1` なら失敗にする（CI は `brew install sevenzip xz brotli zstd` のうえで 7ZZ・XZ・BROTLI・ZSTD を立てる）。

| ツール（Homebrew） | 場所の指定 |
|---|---|
| 7zz（sevenzip）・xz・brotli・zstd | `KAITO_7ZZ`・`KAITO_XZ`・`KAITO_BROTLI`・`KAITO_ZSTD`（ZstdDifferentialTests は `KAITO_ZSTD` を見ず PATH と既定の場所だけを探す） |
| rar（cask rar）・lha（lhasa） | `KAITOKIT_RAR_EXECUTABLE`・`KAITOKIT_LHA_EXECUTABLE` |
| lz4・cabextract | なし（LZ4LegacyTests は Homebrew と /usr/bin の固定の場所、CabLZXTests はそれに加えて PATH を探す） |

macOS 同梱の `/usr/bin/{bsdtar,gzip,bzip2,compress,ditto,zip,unzip,hdiutil,python3}` も fixture の生成と比較に使う。
`kaito` CLI は `KAITO_EXECUTABLE`、無ければ build の成果物を探す（`Support/KaitoCLI.swift`）。

## CI と toolchain

build は Xcode 27 / Swift 6.4 のみ。`build-and-test` は `xcode-27` で既定の全 suite と
Asia/Tokyo の LHA golden を実行し、framework と圧縮 payload の sanitizer smoke も同じ toolchain で検査する。
Swift 6.3.3 の `-O` による `TaskLocal<function?>` の誤コンパイル（2026-10-08 確認）のため、
Xcode 26 / Swift 6.3 での build は CI でサポートしない。

`build-for-macos-26` は Xcode 27 で arm64 / x86_64 の universal test を build し、
`KaitoKitTests.xctest`・`KaitoKitCompatTests.xctest` と `kaito`、両 arch の `otool` で調べた
非 system の依存 framework / dylib、Xcode 27 の xctest を tar で運ぶ。
同じ install name の `Testing.framework` は universal な platform copy を使い、
必要な arch のない weak dependency は同梱しない。strong dependency は両 arch を必須にする。
`macos-26-runtime` は `macos-26` / `macos-26-intel` の同じ checkout path に展開し、
コンパイルせず同梱 runner と `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH` で二つの bundle と LHA golden を実行する。
fixture、README / CHANGELOG / 検証記録、生成器は checkout から読み、作業 file は `.build` に置く。
Xcode 26 の system xctest は XCTestCore の interop symbol が不足し、Xcode 27 の test bundle を load できない。
制限 umask の子 process も現在の xctest を再利用し、SIP で消える `DYLD_*` は別名で渡して shell 内で復元する。
両実行 job は同じ必須 oracle を使い、macOS 26 の製品コードは OS Swift runtime 上で動かす。
実際の test failure、bundle ごとの実行件数0、LHA golden の二つの marker の欠如は失敗にする。

## 環境変数（CI と過去の記録が使う名前なので変えない）

| 変数 | 値 | 用途（無いときの扱い） |
|---|---|---|
| `KAITO_REQUIRE_LHA_GOLDEN` | 1 | TZ が Asia/Tokyo でない LHAPublicValueGoldenTests を skip でなく失敗にする（CI の Tokyo の step） |
| `KAITOKIT_LHA_CORPUS` | dir | LHAExternalCorpus・LHAMethodCorpus・LHASFX・LHAMacBinary の外部 corpus（skip） |
| `KAITOKIT_RAR4_CORPUS`・`_PPMD_SOLID_ARCHIVE`・`_FILTER_ARCHIVE` | dir・file | RAR4Reader・RAR4SFX・RAR4CorpusDifferential の外部書庫（skip） |
| `KAITOKIT_CAB_CORPUS`・`KAITOKIT_AR_ORACLE`・`KAITOKIT_CPIO_ORACLE`・`KAITOKIT_CPIO_DETECTION_BASELINE`・`KAITOKIT_BOOK_LHA` | dir・file | CabLZX・ArReader・CpioReader・LHAIntegration の外部 oracle（skip） |
| `STUFFITX_CORPUS`・`STUFFIT_SLICE6_CORPUS` | dir | StuffItXCorpus・StuffItXCrypto の外部 corpus（skip）。`STUFFITX_VERIFY_STREAMS=1`・`STUFFITX_INVENTORY`（.build 下の出力名）は補助 |
| `STUFFITX_JPEG_CORPUS`・`_BENCHMARK`・`_MUTATE` | 1 | StuffItXJPEGTests の外部 corpus・release の計測・敵対的入力（skip）。`_FILTER`（正規表現）・`_REPORT`（出力名）・`_SEED`・`_ROUNDS`（整数）はその設定 |
| `STUFFITX_LARGE_WINDOWS` | 1 | StuffItXDeflateTests の 32 MiB の距離の検証（skip） |
| `KAITOKIT_WRITE_ZIP_GOLDEN[_INPUTS]`・`KAITOKIT_WRITE_TAR_GOLDEN[_INPUTS]`・`KAITOKIT_WRITE_7Z_PUBLIC_GOLDEN` | 1 | PublicValueGolden の golden と入力を書き直す（意図した変更のときだけ） |
| `KAITOKIT_DUMP_ZIP_GOLDEN`・`KAITOKIT_DUMP_TAR_GOLDEN` | path | 実際の値をファイルへ書き出す（差の調査用） |
| `KAITOKIT_ZIP_SCALE_PROBE[_OPEN_ONLY]`・`KAITOKIT_7Z_SCALE_DIR`・`KAITOKIT_TAR_SPLICE_PROBE[_LARGE]` | file・dir・1 | Probes/ の計測（下記。skip） |
| `KAITOKIT_7Z_SCALE_CHILD`・`_RECORDING`・`KAITOKIT_COMPAT_RESTRICTIVE_UMASK_*`・`KAITO_CHILD_DYLD_*` | — | テストが子 process へ渡す内部の値。手で設定しない |

外部ツールの場所と `KAITO_REQUIRE_*`・`KAITO_EXECUTABLE` は前節のとおり。

## fixture

- `Tests/Fixtures/<形式>/`: checked-in の入力（多くは `.b64`）。作り方は各ディレクトリの README と生成器、第三者の出自は `Tests/Fixtures/NOTICE`。
- `Scripts/fixtures/`: テストが実行時に呼ぶ生成器（make-cp932-zip.py・make-zstd.py・make-cab-lzx.py・make-stuffit-english-dictionary.py）。
- 多くの書庫は `HandZipEntry`・`HandTarEntry`・`HandLHAEntry` からその場で作る（`Support/` の *TestSupport）。
- `inbox/`（.gitignore の対象）: 配布しない外部の corpus と oracle。読むテストは無ければ skip する。

## Probes（計測）

release で `-Xswiftc -enable-testing` を付けて実行し、`KAITOKIT-PROBE`・`7Z-LAYOUT` の行を読む。

```sh
KAITOKIT_ZIP_SCALE_PROBE=<zip500k.zip> swift test -c release -Xswiftc -enable-testing --filter ZipScaleProbe
KAITOKIT_7Z_SCALE_DIR=<scale> swift test -c release -Xswiftc -enable-testing --filter SevenZipEditLayoutScaleProbeTests
KAITOKIT_TAR_SPLICE_PROBE=<manifest.json> swift test -c release -Xswiftc -enable-testing --filter TarEditScaleProbeTests
```

manifest は [tar-splice](Measurement/tar-splice/README.md) で作る。`KAITOKIT_TAR_SPLICE_PROBE_LARGE=1` は 4 GiB + 1 MiB への追記
（一時領域に 12 GiB）。記録: `Documentation/verification/2026-09-25-zip-raw-layout.md`・`2026-09-26-sevenzip-edit-layout.md`・
`2026-09-25-tar-splice-verification.md`。

## テスト以外の道具の置き場所

- `Scripts/`: CI かテストが実行するもの（build-framework.sh・fuzz/・fixtures/）。
- `Scripts/generate/`: 出力を Sources/ に commit する生成器（make-exemplars.py・stuffitx-jpeg-tables.py）。
  `StuffItXEnglishDictionary.swift` を作る make-stuffit-english-dictionary.py は、テストが `--check` で呼ぶので `Scripts/fixtures/` に置く。
- `Tests/Fixtures/<形式>/`: 一度だけ走らせる fixture の生成器（出力の隣）。
- `Tests/Measurement/`: CI では実行しない測定と検証の道具。[name-encoding](Measurement/name-encoding/README.md)・
  [stuffitx-jpeg](Measurement/stuffitx-jpeg/README.md)・[crc16](Measurement/crc16/README.md)・[tar-splice](Measurement/tar-splice/README.md)・[reader-structure](Measurement/reader-structure/README.md)。
