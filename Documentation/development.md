# 開発と検証

ビルドには Xcode 27 / Swift 6.4 以上を使います。製品は macOS 26 以上の Apple Silicon / Intel で動作します。
[README](../README.md#開発)、[テスト構成](../Tests/README.md)、[検証記録一覧](verification/README.md) も参照してください。

## 開発

テストの構成（対象ごとのフォルダ、Support/ の共有 helper、環境変数の一覧、外部ツール、計測 harness）は
[Tests/README.md](../Tests/README.md) にまとめてある。

```console
swift build
swift test
swift test --filter 'Documentation|ReleaseReview|MigrationGuide'
swift build -c release
bash -n Scripts/build-framework.sh Scripts/fuzz/*.sh
python3 -m py_compile Scripts/fuzz/mutate.py
```

7zz / xz を使う差分テストは、`KAITO_7ZZ` / `KAITO_XZ`、`PATH`、既知の Homebrew path
の順で executable を探します。通常は tool が無ければ該当テストを skip します。CI と同じく
不足を failure にする場合は次のように実行します。

```console
brew install sevenzip xz
KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 swift test
```

圧縮 payload を含む ZIP / 7z seed を実際の 7zz で作り、malformed / unusual archive の
robustness mutant を ASan/UBSan build で走らせる手順は次のとおりです。AES seed の password は
`KaitoFuzz` で、`--password` は暗号化されていない seed と同じ directory に対しても指定できます。

```console
Scripts/fuzz/make-compressed-seeds.sh /tmp/kaito-compressed-seeds
Scripts/fuzz/run-mutants.sh --count 200 --password KaitoFuzz \
  --require-payload-ranges /tmp/kaito-compressed-seeds
```

`Scripts/build-framework.sh` は Apple Silicon / Intel 両対応のユニバーサル `KaitoKit.framework` を生成します。SwiftPM を介さず利用する場合は、ネストされた `KaitoKitCompat` モジュールを見つけられるよう `-I Frameworks/KaitoKit.framework/Modules` も指定してください。

設計判断、堅牢性規則、参照可能な仕様は [Documentation/design.md](design.md)、
XADMaster からの移行状況は
[Documentation/migration-from-xadmaster.md](migration-from-xadmaster.md) を参照してください。
設計書が引く性能・安定性の実測ログは
[Documentation/verification/](verification/README.md) にあります。

- [0.10.0 分割巻の公開 API の検証（2026-09-23）](verification/2026-09-23-archive-volume-set.md): 巻名生成・保持 fd の同一性・reopen の引き継ぎ・回帰テスト・全件検証。
- [0.9.0 リリースレビューの検証（2026-09-22）](verification/2026-09-22-release-review-0.9.0.md): R1〜R11 の再現・修正・回帰テスト・全件検証。
- [0.8.1 リリースレビューの検証（2026-09-22）](verification/2026-09-22-release-review-0.8.1.md): R1〜R14 の修正前の失敗・回帰テスト・全件検証。

> **Development**
>
> Differential tests that use 7zz and xz look for the executables in the order `KAITO_7ZZ` and
> `KAITO_XZ`, then `PATH`, then the known Homebrew paths. By default the affected tests are skipped
> when a tool is absent. To make a missing tool a failure, as CI does, run the commands shown above
> after installing them.
>
> The commands above also show how to build ZIP and 7z seeds containing compressed payloads with a
> real 7zz, then run malformed and unusual archive robustness mutants against an ASan/UBSan build.
> The password for AES seeds is `KaitoFuzz`, and `--password` may also be given for a directory of
> seeds that are not encrypted.
>
> `Scripts/build-framework.sh` produces a universal `KaitoKit.framework` for both Apple Silicon and
> Intel. When using it without SwiftPM, also pass `-I Frameworks/KaitoKit.framework/Modules` so that
> the nested `KaitoKitCompat` module can be found.
>
> For design decisions, robustness rules and the specifications that may be consulted, see
> [Documentation/design.md](design.md); for the state of migration from XADMaster, see
> [Documentation/migration-from-xadmaster.md](migration-from-xadmaster.md).
> The measured performance and stability logs cited by the design document are in
> [Documentation/verification/](verification/README.md).

## CI

[CI workflow](../.github/workflows/ci.yml) は Xcode 27 / Swift 6.4 で build / 全テストを実行し、
7zz / xz / brotli / zstd の外部ツール不足を failure とします。Asia/Tokyo の LHA golden も明示的に実行します。
Xcode 27 で universal build した test bundle・`kaito`・xctest と依存 framework / dylib を運び、
`macos-26`（arm64）と `macos-26-intel`（x86_64）でコンパイルせず全 suite と LHA golden を検査します。
ユニバーサル framework と両 Swift module の検査、圧縮 payload を含む 63 mutant の
ASan/UBSan fuzz smoke（timeout 5 秒、password `KaitoFuzz`）も行います。

Swift 6.3.3 の `-O` による `TaskLocal<function?>` の誤コンパイルを避けるため、CI の build は Xcode 27 のみです。
cooViewer が Xcode 26 で使う framework script の旧 module 配置の分岐は残しています。
背景は [設計書](design.md#ci-と-toolchain2026-10-08) と [CHANGELOG](../CHANGELOG.md#unreleased) を参照してください。

## 参照ツールとの照合と過去の計測

cooViewer の `book.lzh` は level 2 の `-lh0-` 4 member をすべて lhasa の black-box
出力と SHA-256 比較しています。`-lh5-` の literal / match / preset-window vector も、
hand-built archive を lhasa と KaitoKit の双方で展開して一致を確認しています。release の
`kaito bench book.lzh 9` は open 0.049 ms、合計 33,104 bytes の extract 0.189 ms でした。

RAR4 の `st1200-pts.rar` は 19 file 全件が RAR 7.23 の black-box 出力と一致し、
PPMd↔LZ 変換の 241,647,978-byte entry も一致しました。さらに RAR4 corpus 20 書庫では
47 regular file の byte count / SHA-256 と 5 symlink の名前 / target bytes が一致しました。
既知 password 集合では oracle を得られない暗号化 entry が 1 件あり、破損した
`seek_data_cursor0` 書庫は RAR 7.23 と KaitoKit の双方が拒否します。

> **Differential testing against reference tools**
>
> All four level-2 `-lh0-` members of cooViewer's `book.lzh` are compared by SHA-256 against the
> black-box output of lhasa. The `-lh5-` literal, match and preset-window vectors are also confirmed
> by extracting a hand-built archive with both lhasa and KaitoKit. A release build of
> `kaito bench book.lzh 9` measured an open of 0.049 ms and an extract of 33,104 bytes in 0.189 ms.
>
> For RAR4, all 19 files of `st1200-pts.rar` match the black-box output of RAR 7.23, including the
> 241,647,978-byte entry that exercises the PPMd/LZ transition. Across a 20-archive RAR4 corpus, the
> byte counts and SHA-256 of 47 regular files and the names and target bytes of 5 symlinks all match.
> One encrypted entry has no oracle under the known password set, and the damaged
> `seek_data_cursor0` archive is rejected by both RAR 7.23 and KaitoKit.
