# 検証記録

設計書（[`../design.md`](../design.md)）の各追補が主張する数値の裏付けとなる、実行コマンドと
その出力をそのまま残した記録。ファイル名は `YYYY-MM-DD-<主題>.md` で、日付順に並ぶ。

本文中の絶対パスは `<repo>` / `<corpus>` / `<home>` に置換してある。コーパスや大きな実書庫は
リポジトリに含めないため、記録の再現には同じ書庫を用意する必要がある。

| 記録 | 日付 | 主題 | 対応するコミット |
| --- | --- | --- | --- |
| [2026-09-08-performance-rar-lha.md](2026-09-08-performance-rar-lha.md) | 2026-09-08 | RAR29 と LHA の高速化（CRC16 の slice-by-eight 化、重複一致の周期コピー、静的 Huffman の一次 lookup） | `7a1d210` |
| [2026-09-08-performance-stability.md](2026-09-08-performance-stability.md) | 2026-09-08 | PPMd の毎シンボル検査除去と安定性の再確認 | `7a1d210` |
| [2026-09-08-review-fixes-verification.md](2026-09-08-review-fixes-verification.md) | 2026-09-08 | 敵対レビュー指摘（展開先を脱出する symbolic link を含む）の修正検証 | `7a1d210` |
| [2026-09-08-performance-rar5-ppmd.md](2026-09-08-performance-rar5-ppmd.md) | 2026-09-08 | RAR5 の周期コピーと 10bit Huffman lookup、PPMd の固定確率表 | `a70bd9d` |
| [2026-09-09-xadmaster-feature-gap.md](2026-09-09-xadmaster-feature-gap.md) | 2026-09-09 | XADMaster との機能差分の black-box 調査(86 書庫 + 破損 27 書庫) | `4f6c138` |
| [2026-09-09-sevenzip-singlefile-gaps.md](2026-09-09-sevenzip-singlefile-gaps.md) | 2026-09-09 | 7z coder 連鎖・LZMA_Alone・`.tar.Z` の実装と検証 | `fc8146e` |
| [2026-09-09-branch-filter-derivation.md](2026-09-09-branch-filter-derivation.md) | 2026-09-09 | SPARC / IA-64 branch filter の black-box 導出とオラクル固定ベクタ | `b18f11b` |
| [2026-09-09-iso9660.md](2026-09-09-iso9660.md) | 2026-09-09 | ISO 9660 reader(ECMA-119 / Joliet / Rock Ridge)の実装と XADMaster 比較 | `a1a2753` |
| [2026-09-09-ar.md](2026-09-09-ar.md) | 2026-09-09 | ar reader(BSD `#1/` / SysV `//` / symbol table / thin)の実装と XADMaster 比較 | (本コミット) |
| [2026-09-09-cpio-binary-recovery.md](2026-09-09-cpio-binary-recovery.md) | 2026-09-09 | 切り詰めた binary cpio の救済対応 | `94bc3f5` |
| [2026-09-09-cpio.md](2026-09-09-cpio.md) | 2026-09-09 | cpio reader(bin / odc / newc / crc / hpbin / hpodc)の実装と XADMaster 比較 | (本コミット) |
| [2026-09-09-format-gap-queue.md](2026-09-09-format-gap-queue.md) | 2026-09-09 | XADMaster が対応し KaitoKit が未対応の形式の洗い出しと実装キュー | `0b38a37` |
| [2026-09-09-recovery-mode.md](2026-09-09-recovery-mode.md) | 2026-09-09 | 破損書庫の救済モードの実測(XADMaster 比較・健全書庫と暗号化書庫の不変性・tar 検出の修正)、追補で RAR5 の切り詰め救済 | `4969b34` / `7aba9ae` / `5e83353` / `c00dd09` |

これらは 2026-09-08 に `Documentation/` 直下から本ディレクトリへ移した。記録本文に埋め込まれた
`git status` などの出力には移動前のパスが残っているが、当時の実行結果として意図的に手を入れて
いない。旧名との対応は次のとおり。

| 旧名 | 現在 |
| --- | --- |
| `performance-rar-lha-2026-09-08.md` | `verification/2026-09-08-performance-rar-lha.md` |
| `performance-stability-2026-09-08.md` | `verification/2026-09-08-performance-stability.md` |
| `batch12-review-verification-2026-09-08.md` | `verification/2026-09-08-review-fixes-verification.md` |
| `performance-rar5-ppmd-2026-09-08.md` | `verification/2026-09-08-performance-rar5-ppmd.md` |
