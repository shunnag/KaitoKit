# 7z Swap2 / Swap4 — 2026-09-18

## 実装と根拠

- `SevenZipMethod` に公式 `Methods.txt` の ID `02 03 02` / `02 03 04` を追加。
- `SwapFilterDecompressor` は2／4 byte単位の並びを反転する。最終単位の端数は保持する。
  この規則は 7zz 26.03 の `SwapN + Copy` の packed bytes と入力長0〜9で照合した。
- coder graph は単入力・単出力、propertiesなし、入力／出力の同じ長さを要求する。
  256 KiBの入力と出力、最大3 byteの未完成単位を保持し、宣言サイズ分のメモリは確保しない。
  上流の終端確認まで完了させ、切り詰め・余分な末尾・進捗なしを拒否する。
- 独立生成の4書庫は `Tests/Fixtures/sevenzip-swap`。plain／AESヘッダー暗号化×2方式。
  262,403 byte + 1,027 byteのsolid groupで、内部256 KiB境界とmember途中の単位を検査する。
  生成コマンド・全entryのSHA・書庫SHAはmanifestに保存する。

参照は [7-Zip Methods.txt](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt)、
プロジェクト内の既存 Decompressor 契約、および7zz実行ファイルの入出力。
第三者の Swap 実装は読んでいない。

## 検証

macOS 27.2 / Apple Silicon / Xcode 27.0。macOS 26・Intelは未実行。

- `swift test --filter SevenZipSwapTests`: **8件、失敗0、skip0**（7.528秒）。
  入力1〜9／出力1〜7 byte、空入力、最終端数、上流終端、巨大な宣言長、
  coder properties・arity・size不整合、solid逆順、AES、誤ったpassword、truncate、
  entry／aggregate／in-memory上限、分割巻、unlink後のreopen。
- solid coordinator の既存契約では、同じ reader で新しい stream を作ると古い stream は無効になる。
  この拒否と、`reopen()` した独立reader同士の交互読み出しを別々に検証した。
- KaitoFinder `CompressionCapabilityTests`: **12件、失敗0、skip0**（15.747秒）。
  新フィルターのプレビュー用ファイルを原本SHAで照合。全4書庫で複数ファイルを一度に追加し、
  元entryと追加entryの内容・暗号化、1回のundoによる書庫全byte復元、redo、7zz検査が一致。
- KaitoKit全件: **1,176件、失敗0、既知skip43**（374.667秒）。互換層も **24件、失敗0**。
- GyoshukuKit全件: **202件、失敗0、skip0**（523.278秒）。4 GiB超tar.xz／tar.bz2も再確認。
- ASan/UBSan: 正常4書庫の全entry SHA-256一致。
  圧縮payloadを含む4seedから160件の変異入力で、crash／hang／sanitizer所見はすべて0。
- KaitoFinderの全UIは、圧縮tarのネイティブ保存名の不一致を修正・検証中。

ログ:

- `/private/tmp/kaitofinder-sevenzip-swap-tests.log`
- `/private/tmp/kaitofinder-sevenzip-swap-finder.log`
- `/private/tmp/kaitofinder-sevenzip-swap-kaitokit-full.log`
- `/private/tmp/kaitofinder-sevenzip-swap-gyoshuku-full.log`
- `/private/tmp/kaitofinder-sevenzip-swap-sanitizer.log`
- `/private/tmp/kaitofinder-sevenzip-swap-sanitizer-valid.log`

## RISC-V の扱い

RISC-V は今回追加していない。公式method一覧とXZの公開仕様・API文書ではIDや
alignmentを確認できるが、変換の全規則を確定するには不足する。
従来どおり未対応方式として明示的に拒否する。

調査中のWeb検索結果がXZ/LinuxのRISC-V実装断片を自動表示した。
該当実装ページ自体は開いていないが、断片の表示は参照範囲の逸脱として
`design.md` のincident記録に開示した。その後RISC-V decoderを作らず、
表示内容はSwapの実装入力にも使用していない。
