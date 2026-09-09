# cpio binary 切り詰め検出の救済（2026-09-09）

## 修正

変更は `CpioHeader.swift`、`CpioReader.swift`、`FormatDetector.swift`、
`CpioReaderTests.swift` とこの記録だけ。前回の作業ツリーを保持し、commit / bd / xcodebuild は
実行していない。禁止対象の実装sourceは参照せず、XADMasterは既存の `gap/bin/xadsha`
実行ファイルをblack-box oracleとしてだけ使用した。

- detectorのData / ByteSource / URL / ArchiveReader用入口から救済フラグを渡す。
- strictの既存probeをそのまま試し、truncatedの場合のみ
  `if recoverDamagedArchives && index >= 2` で別の検証を許可する。
  先行する最低2 recordは、名前・数値・全data/padding範囲まで完全に検証済みである。
- 末尾にもbinary magic 2 bytesを要求する。存在するheader fieldを検査し、
  mode不正、確定済みnamesizeの0/1、負のfilesize、空名、未終端の完全な名前、
  NUL後の非NUL byteは拒否する。実際に物理EOFでheader/name/padding/dataが欠けた場合だけ受理する。
  headerの未到着byteの0埋めは検証用であり、完全recordとしてcountしたり公開したりしない。
- strict時は救済検証を呼ばない。既存検出の順序、ASCII probe、4 recordまでの走査上限は不変。
- 不完全entryは既存の残量clampとisIncompleteを使い、CopyDecompressorを
  RecoveryDecompressorで包んだ `length: nil` / `expectedCRC32: nil` のstreamを返す。
  完全entryのstreamは従来のまま。救済でもReadLimitsを維持する。

## 受け入れ実測

指定の `hostile/bin-t60.cpio`（30,412 bytes）と、既存 `gnu-hpbin.cpio` を
`bytes.prefix(bytes.count * 60 / 100)` で切った入力（同じ30,412 bytes）を使用した。
大きいfixtureは追加せず、外部受け入れtest内でHP版を作る。

| 入力 | strict | 救済entry数 | サイズ順 | 総合SHA-256 |
|---|---|---:|---|---|
| bin-t60 | unsupportedFormat | 4 | 0 / 6 / 14 / 30258 | dd08768ab0db5e521363a12eddc486a6e4cf923b432fb7234c4f0a2a8908407a |
| hpbin-t60 | unsupportedFormat | 4 | 0 / 6 / 14 / 30264 | 9c973ba687a794e3e7e5c428d0fbc517382014742c1e79ecf82565ec09cbbef6 |

両方ともXADMasterのentry順・サイズ・内容SHA-256と一致し、原本の該当prefixともbyte単位で一致。
HP版は格納名の `./` がない分data開始offsetが6 bytes早いため、救済されるdataも6 bytes多い。
名前は `. / a.txt / b.txt / data.bin` の順。KaitoKitは従来どおり格納名を保持するため、
BSD binの公開名には `./` が残る。XADMasterの表示名はそれを除去するので、名前比較ではこの
既存の表記差だけを正規化した。今回の修正では既存の名前の扱いを変更していない。
最終entryだけ `isIncomplete == true`。各内容SHAは以下のとおり。

| entry | SHA-256 |
|---|---|
| . | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| a.txt | b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060 |
| b.txt | 1e6f53bf8c3e3704ca99c5e692d8745b54ed7ec0d83064484a5fb1ce6c7355a8 |
| data.bin（bin） | a9fc7a97c4f2d9b3364984696550a7e155046ea422b0c3820fd59fb674a1e6c1 |
| data.bin（hpbin） | 7ae0c5738aeb36e83a5e82b1a7e01d0f230190c909341824bd7c7d4099b9558a |

健全10 fixtureはstrictと救済の両モードで、前回の総合digest・12 entry・名前・内容を維持。
検出コーパスは前回修正後の `/tmp/kk-cpio-detect-release.json` をbaselineとし、95通常書庫と
6暗号化書庫の計101件すべてでstrict/救済とも判定不変。新たなcpio誤検出は0件。

## テストと実行結果

両byte orderで完全record数0/1/2、末尾のheader/name/data/padding切断位置、
magic欠損・未知のごみ・不正mode・名前NUL・負のfilesize・最初のrecordの破損を検証した。
Data / ByteSource / URLの配線、reopen、unknown-length stream、各size/count制限も固定した。
外部fixtureとcorpusは以下の環境変数が指定されたときに実行する。

指定引数での実行結果は **BUILD=1 / TEST=1**。ログは `/tmp/kk-cb2.log` / `/tmp/kk-ct2.log`。
SDKROOTは明示したが、既定のsandbox外module cacheへの書込みが拒否されmanifestで停止した。
以下の環境調整で検証を完了した（依存やPackage.swiftは変更なし）。

```sh
export SDKROOT=/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cpio-work/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cpio-work/cache"
export TMPDIR="$PWD/.build/cpio-work/tmp"
export KAITO_EXECUTABLE="$PWD/.build/cpio-work/native/release/kaito"
export KAITOKIT_CPIO_ORACLE=/private/tmp/claude-501/-Users-nagash-cooViewer/37ef55f3-9116-4440-88b8-9a15060856ad/scratchpad/gap/cpio
export KAITOKIT_CPIO_DETECTION_BASELINE=/tmp/kk-cpio-detect-release.json
swift build --disable-sandbox --build-system native --scratch-path .build/cpio-work/native -c release > /tmp/kk-cb2-adjusted.log 2>&1; echo "BUILD_ADJUSTED=$?"
swift test --disable-sandbox --build-system native --scratch-path .build/cpio-work/native > /tmp/kk-ct2-adjusted.log 2>&1; echo "TEST_ADJUSTED=$?"
```

- **BUILD_ADJUSTED=0 / TEST_ADJUSTED=0**。
- 全727 tests、33 skip、失敗0。cpio本体の16 testsはすべて実行・成功。
- 健全10 fixtureのstrict/救済、bin/hpbin切り詰め2件、検出corpus101件の照合も全テスト内で実行した。
- `git diff --check` 成功。テストログのerror/failed抽出にあるのは既存manifest cache warningと
  fixture生成toolの `Compression method bzip2 not enabled` のみで、テスト失敗はない。
