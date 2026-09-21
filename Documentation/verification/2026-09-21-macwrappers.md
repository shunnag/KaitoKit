# MacBinary / AppleSingle / BinHex 4 の単体公開（2026-09-21）

環境: macOS 27.2 / Apple Silicon / The Unarchiver 1.10.8 `lsar` / `unar`（Homebrew、黒箱 reader）。

## 実装と範囲

- 公開 `ArchiveFormat` に `.macBinary`（`"macbinary"`）、`.appleSingle`（`"applesingle"`）、`.binHex`（`"binhex"`）を
  追加。`FormatDetector.stuffItInput` が剥がした wrapper の payload が StuffIt（classic / 5 / X の署名）でない
  とき、従来の `unsupportedFormat` でなく wrapper 自身を 1 file の書庫として公開する（`envelopeFormat`）。
  payload が StuffIt なら従来どおり `.stuffIt` / `.stuffItX`。
- `StuffItEnvelope` に `MacWrapperInfo`（名前の生 byte、type、creator、Finder flags、作成 / 更新日時、comment）を
  加え、各 parser が埋める: MacBinary II（名前 @1、type @65、creator @69、flags @73 / @101、日時 @91 / @95 =
  1904 起点の秒）、AppleSingle（Real Name 3、Comment 4、File Dates Info 8 = 2000-01-01 起点の符号付き秒、
  Finder Info 9。type / creator は 4 文字コードなので little-endian 変種でも byte 順のまま）、
  BinHex（header の名前・type・creator・flags。日時は無い）。
- `MacWrapperReader`: entry 0 = data fork（`fork=data`）、resource fork があれば entry 1 =
  `name/..namedfork/rsrc`（`fork=resource`）。`formatSpecific` に `wrapper`、`macType`、`macCreator`、
  `finderFlags`、`created`、`comment`。名前は StuffIt と同じ書庫名判定（UTF-8 / CP932 / EUC-JP、MacJapanese
  fallback）に掛け、`/` は `:` に写す。名前を持たない AppleSingle は file 名から `.as` / `.applesingle`
  （MacBinary は `.bin` / `.macbin` / `.mb`、BinHex は `.hqx`）を外して名付け、Data からは `data`。
- 一段だけ剥がす（MacBinary の中の MacBinary / ZIP は file として公開）。AppleDouble（magic `00051607`）の
  単体は従来どおり `unsupportedFormat`（sidecar 統合は ZIP / tar の方針で扱う）。
- 既存テスト `StuffItWrapperTests.testRejectedWrappersAndMemoryLimit` の「StuffIt でない payload は拒否」を
  「`.macBinary` として開ける」に反転した。

## 出自

新しい形式入力は無い。wrapper parser は既存（利用者所有の再構築レポート Ch.00 / 06 の散文）。fixture の writer は
同じ散文から Python で書き、The Unarchiver の `lsar` / `unar` が名前を一覧し data fork と resource fork を
byte 単位で同じに展開することを生成時に確認した（`generate.py` の `verify_with_unar`）。

## 独立した検証データ

`Tests/Fixtures/macwrappers/`（`generate.py`、`manifest.json`）: 823 byte の text（RLE90 の対象になる `0x90` と
長い同一 byte 列を含む）と 416 byte の resource fork を、MacBinary III 署名付き MacBinary II（ASCII 名 /
Shift_JIS 名 / resource fork 無し）、AppleSingle v2（big-endian / little-endian）、BinHex 4.0 に包んだ 6 本。
すべて unar が同じ fork を展開した。

## 通過した検証

- `MacWrapperTests` 4 件、失敗 0: 6 fixture の検出・形式・entry 数・名前（Shift_JIS 復元と `nameEncoding`）・
  サイズ・method 名・fork・type / creator・日時・SHA-256・`reopen()`、展開で resource fork が復元されること、
  既存 StuffIt corpus の wrapper が `.stuffIt` のままであること、名前の無い AppleSingle の fallback 名、
  MacBinary の CRC 破損、AppleSingle の descriptor 範囲外、BinHex の fork CRC、`maxEntrySize`。
- 既存 StuffIt / LHA / FormatDetector suite（182 件）が通過。

## 残る制約

- MacBinary I（CRC 無し）は既存の零検査 fallback でだけ受理する。MacBinary の secondary header は読み飛ばす。
- AppleSingle の Finder Info の Finder flags は little-endian 変種で数値として swap するが、実物の little-endian
  AppleSingle は手元に無い。
- 名前の日時（BinHex）や comment（MacBinary の Get Info comment は本文に無い）は無い。
