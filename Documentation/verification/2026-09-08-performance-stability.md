# 実ツール互換性と PPMd 性能検証 — 2026-09-08

今回の作業は既存の未コミット CRC16 / RAR29 / LHA 最適化を含む作業ツリーを出発点にした。
それらの変更を保持し、実ツールレビューの不具合と PPMd を修正した。外部 decoder source は
参照せず、提供された挙動の所見、既存 KaitoKit 実装、RAR 6.24 / 7zz / XADMaster の実行結果を使った。
Windows metadata を持つ password fixture は独立して再暗号化した合成データであり、Windows 実機検証ではない。

## 修正内容

- RAR3 Audio の program fingerprint 長を 158 から実際の 216 bytes に修正。
- 長い RAR3 password に固有の SHA-1 入力 buffer 更新を再現。writer の最大127文字と、
  UTF-16 優先 / Unix scalar 下位16bit fallback を扱う。候補は CRC 検証前に公開しない。
- 結合文字に接する `/` を grapheme ではなく UTF-8 byte として分離。
  正常な名前の誤拒否と、通常 API / 互換 API hard-link relocation の symlink 経由の root 逸脱を修正。
- root 内に留まる親相対 symlink を許容し、途中で root 外へ出る target と既存 symlink の経由は拒否。
- LHA level 0〜3 の 0xFF / decoded backslash、level-0 Unix mtime / mode / uid / gid を処理。
  CP932 の 0x8E と EUC-JP の半角カナの判定を修正。
- CLI は entry ごとに失敗を報告して続行。`sha` の ERROR 行と partial digest、非ゼロ終了で部分成功を表す。
- ZipCrypto の一バイト password hint が偶然一致する既存テストを、最終 CRC 検証へ修正。
- directory sticky / setgid の属性保持は変更せず、rar 6/7 との違いを文書化。

## 性能

macOS 27.0 / Apple Silicon、Swift 6.3.3 release。ビルド済み CLI の `bench <archive> N` の
process 内 median で、起動・SHA-256・出力を含めない。測定時にはビルドとテストを重ねない。
同じ入力の展開 bytes と CRC を維持し、別途 SHA-256 を oracle と比較した。

PPMd JPEG (`pp-jpg-mctp.rar`, 2,017,217 bytes) の段階別測定:

| 段階 | 展開 median ms |
|---|---:|
| 開始時 | 16,803.559 |
| symbol ごとの重複構造走査を除去 | 8,914.492 |
| generic range coder / 検証済み state span / 平坦 probability | 2,584.134 |
| state 検索と checked accessor の inline 化 | 1,240.004 |
| mask 頻度集計の分岐削減 | 1,054.733 |
| 記号選択と rescale の state 参照を改善 | 832.749 |
| rescale 内の移動をまとめる | 826.442 |

最後の移動最適化の差は測定揺らぎの範囲である。最終の独立再測定は **822.206 ms**、
開始時に対して **20.4倍**。これを絶対的な性能上限や、全形式で最速という意味にはしない。
この入力では残る時間の大部分が適応モデルの頻度集計・記号選択・更新である。

| 最終入力 | bytes | KaitoKit ms | 同時期 XADMaster ms |
|---|---:|---:|---:|
| pp-jpg-mctp.rar | 2,017,217 | 822.206 | 571.550 |
| mixed-nopcm-s-mctp.rar | 39,080,942 | 9,988.671 | entry 41 で失敗 |
| pp-zero-mctp.rar | 5,000,000 | 1.794 | 0.600 |
| ppmd-s-m5-mctp.rar | 13,127,317 | 1,825.784 | 1,172.040 |
| book-rar4.cbr | 403,014,550 | 29.269 | 34.500 |
| book-tiff-rar4.cbr | 384,498,400 | 373.701 | 314.930 |
| book-lh5.lzh | 403,014,550 | 2,088.114 | 2,690.310 |
| book-tiff-lh7.lzh | 384,498,400 | 334.918 | 829.670 |
| book-rar5.cbr | 403,014,550 | 29.431 | 34.770 |
| book-tiff.7z | 384,498,400 | 513.201 | 401.850 |

N=3（段階測定の後半は N=5）。XADMaster は同じ入力の `xadbench extract ... 3`。
39 MB mixed PPMd は既報の約219秒に対し約9.99秒だが、既報は今回の同条件 baseline ではない。
JPEG ≤1.5秒、mixed ≤15秒という実ツールレビューの目標を満たす。
以前の RAR29 / LHA 最適化の比較は `2026-09-08-performance-rar-lha.md` に残している。

同じ2,017,217-byte JPEGを7zzのPPMdで圧縮した7zでも、同条件のN=3 medianは
**17,104.904 → 845.760 ms（20.2倍）**。元JPEGと展開後SHA-256が一致した。

## 検証と制限

- RAR4 corpus 20書庫: regular file 47件と symlink 5件が一致。既知 password で oracle を得られない1件は留保。
- 既存 benchmark corpus 18書庫・6,400 entry の名前 / byte count / SHA-256 が既存 oracle と一致。
- 実ツールの暗号化・音声フィルタ46ケース・387 entry が作成ツールの展開結果と一致。
- LHA 名前71ケース: 60ケース完全一致、24ケース改善、新たに悪化したケースなし。
  残る11ケースは既存の writer 変換・特殊名・表記差を含み、すべての曖昧な legacy 名の復元を保証しない。
  結合文字・level-0 directory・CP932 trail byte の6ケースは実ファイルの展開ツリーも一致。
- 最終 PPMd / Audio / LHA lh5 / lh7 の圧縮範囲600変異を ASan/UBSan で検査し、
  crash / timeout / sanitizer finding はすべて0。初期段階の追加400変異も0。
- 境界検査、range / frequency 検査、model 更新時の整合検査、進捗と出力サイズの上限を保持する。
  model の固定 arena span は再配置を伴う更新前までしか借用しない。
- RAR3 の非BMP候補検証は追加の展開を伴う。solid では先行 entry の replay が必要で、
 多数の暗号化 member では追加 CPU コストが累積する。CRC は暗号学的な認証ではない。
- 旧 RAR 圧縮 version、custom VM、未対応 LHA method 等の既存対応範囲は変わらない。

## 反映後の最終確認

修正を `<repo>` へ反映し、既存の未コミット変更を維持した。
全53対象パスが検証した作業コピーと一致し、`git diff --check` は成功した。

- Swift 6.3.3: **617 tests / 5 skipped / 0 failures**（183.408秒）。
- Swift 6.4: **617 tests / 5 skipped / 0 failures**（main 602 + compat 15）。
- `KAITOKIT_RAR4_CORPUS` / `KAITOKIT_LHA_CORPUS` に加えて、実 `st1200-pts.rar` を
  filter archive に指定した。19 file の展開が RAR 7.23 と一致した。
- 互換 API の結合文字 hard-link relocation は、修正前4 assertion失敗、修正後は両Swiftで成功。
- 非BMP暗号化solidは前方順次・後方・再読・誤password後の再設定を検証。
  後から確定したentryの方式は保持済みcoordinatorにも共有し、後続を誤った方式で開かない。
- リリース・タグ作成・commit・push・cooViewer再統合は行っていない。

Release成果物を反映先で再測定したN=5 medianは **933.590 ms**、続けて検証用コピーを
同条件で測ると **913.887 ms** だった。先の822.206 msから両者とも増えており、実行時点による
変動がある。本体の最終確認値では開始時比 **18.0倍**、今回の測定範囲では概ね **18〜20倍**。
初回の本体確認970.830 msはタスク記録処理と重なったため、比較値には採用しない。
本体のRelease CLIで非BMP暗号化solidの全3件と200文字passwordの書庫も正常に読み出した。
