# 2026-11-02 RAR の分割 SFX と他形式の SFX 検証

## 対象

RAR4 / RAR5 の SFX 先頭巻を含む multi-volume を開けるようにする。RAR 以外の実 SFX も、実行せずに形式を検出して読めることを確認する。RAR5 compression version 1、RAR4 の旧 unpack version / custom VM は今回の対象外。

## 実書庫と再現

RAR 7.23 で RAR5、RAR 6.24 で RAR4 の stored 書庫を作り、先頭に 4,096 byte の PE prefix を付けた。
この Mac の RAR / 7zz パッケージには SFX module がないため、実際の書庫に既存の SFX 試験と同じ bounded prefix を使う。
各書庫は 700 byte の `A` と `B` の 2 file、巻サイズ 1 KiB。

- RAR5: `five.part1.exe` + `five.part2.rar`
- RAR4 new numbering: `four.part1.exe` + `four.part2.rar`
- RAR4 old numbering: `four.exe` + `four.r00`

修正前の KaitoKit は、3形式とも `Unsupported archive method: multi-volume from Data` で第 2 file を読めなかった。
`unrar t` は 3形式とも成功した。追加した `RARMultiVolumeSFXTests` は修正前に 18 件の assertion failure を出した。

RAR 以外の実 SFX も確認した。

- `explz1001_arm64.exe` / `explz1001_x64.exe`: CAB（LZX）、39 entries の全 byte と SHA-256 を読み取れた。
- `arj286.exe`: ARJ、35 entries の全 byte と SHA-256 を読み取れた。
- `testfile.stuffit651_dlx.macx1.exe`: StuffIt、data / resource fork を読み取れた。
- `/bin/ls`: 通常の Mach-O 実行ファイルで、`Unsupported archive format` を返した。SFX stub はいずれも実行していない。

## 実装

- `FormatReaderFactory` は SFX prefix がある先頭巻でも `sourceURL` と directory anchor を保持する。
- `RARVolumeLocator` は先頭巻の署名 offset と元 source の identity を検証する。続巻は offset 0 の署名を従来どおり検証する。
- `.partN.exe` の先頭巻は、次巻を `.part(N+1).rar` として解決する。RAR4 old numbering の先頭 `.exe` も `.r00` へ進める。
- RAR5 の rebased source でも、元の file descriptor による identity 検査を行う。
- Data / 任意 `ByteSource` の multi-volume 拒否、決定的な兄弟名だけを開く規則、symlink 拒否、128 巻上限は変更しない。
- 欠巻は URL では `truncated`、Data では従来どおり `unsupportedMethod("multi-volume from Data")`。

## 検証

- `RARMultiVolumeSFXTests`: 3形式とも全 byte、reopen、RAR5 Quick Open、`unrar` も成功。
- RAR 系全体: **339 tests / 11 skipped / 0 failures**。
- `RAR5RecoveryTests`: 12件、失敗 0。単独書庫を前提とする fixture 検査から、分割用の 2 fixture だけを除いた。
- `RAR5SFXTests`: 5件、失敗 0。
- `SevenZipSFXIntegrationTests`、`ZipIntegrationTests`: 失敗 0。
- KaitoFinder `ArchiveReaderAdoptionTests`: 15件、失敗 0。

`Documentation/formats.md`、`Documentation/limitations.md`、`Documentation/migration-from-xadmaster.md` と CHANGELOG を実装に合わせた。
fixture は `Tests/Fixtures/rar4/README.md` に生成版と入力を記録し、test 実行時に RAR / unrar / SFX module は不要。
