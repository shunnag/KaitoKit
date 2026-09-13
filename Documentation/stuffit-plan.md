# StuffIt 対応の判断と計画（2026-09-13、bd `cooViewer-gu28`）

## 結論

**KaitoKit で StuffIt を Swift 6 で扱える状況は作れる。** 根拠は `~/GitHub/StuffitAnalyze`
の形式再構築レポート（58 章、7,148 行）で、classic StuffIt・StuffIt 5・StuffIt X の
容器と主要 codec が実装可能な精度（byte offset、bit 順、model の初期値と更新規則、
終端条件）で散文化されている。同レポートは「既存デコーダを翻訳するのではなく記述から
reader を実装する人向け」に書かれ、ソース引用を含まない。

| 段階 | 対象 | 判断 |
|---|---|---|
| Tier 1 | classic `.sit`（1.x〜4.x）と StuffIt 5、wrapper（MacBinary / AppleSingle・Double / BinHex 4）、method 0/1/2/3/5/8/13/14/15、SIT5 RC4、classic 改変 DES | **実装する**（XADMaster と同等） |
| Tier 2 | StuffIt X 容器（P2 整数・要素文法・framed block・catalog・solid slot）、bytewise range coder、Deflate / Blend / RC4-stored / Darkhorse / Cyanide / Iron（BWT+ST4）/ Brimstone、x86 前処理 | **実装する**（XADMaster と同等） |
| Tier 3 | (a) 性能で XADMaster を上回る、(b) XADMaster が開けない StuffIt 7 Mac `.sitx`（catalog key-10 整列）、(c) SITX パスワード暗号（RC4 / AES-CFB は CryptoKit、Blowfish / DES-CFB は自前実装）、(d) classic method 6、(e) Deflate window 10〜25、(f) `.exe` SFX stub、(g) wrapper の内側へ降りる | **すべて実装する** |
| Tier 4 | SITX JPEG 再圧縮（method 7、Ch.25–34、利用者自身の Python 参照実装 `tools/stuffitx_jpeg*.py` から移植） | **計画 slice 7**（コア slice の後） |
| 見送り | 画像・数値系 codec（値 8〜34）、recovery、segment、base-N transport、sidecar | 見送り（cooViewer の用途に当たらない） |

**方針（2026-09-13 利用者指示）: XADMaster への依存は排除し、フォールバックに頼らない。**
したがって「XADMaster も開けないから同じ失敗で揃える」という判断は取らない。cooViewer が開く宣言を
している範囲は KaitoKit 単独で実用に足る対応を目指す。cooViewer 側の依存排除は bd `cooViewer-6lrc`。

**method 7（JPEG 再圧縮）について。** Windows 版 StuffIt Deluxe 2009 / 2010 の既定設定は JPEG を
method 7 で再圧縮する。cooViewer の用途（画像書庫）に最も当たりうる欠落で、XADMaster も未対応
（実測でサイズ 0。CC0 コーパスの `testfile.stuffit_deluxe_2009.win.sitx`）。レポートの JPEG 章は
10 章・数千プロセスの検証を要した領域だが、利用者自身の独立 Python 実装が揃っているので、それを
Swift へ移植する slice 7 として計画に含める（出自は clean-room のまま）。数値表は vendor バイナリ
からの測定値で、`THIRD_PARTY_DATA.md` に出自がある。

## 進捗（2026-09-13 時点）

| slice | 内容 | 状態 | 記録 |
|---|---|---|---|
| 1 | wrapper（MacBinary / AppleSingle / BinHex 4）+ classic + StuffIt 5 + method 0/1/2/3/13/15 | 完了（PR #12） | [slice 1](verification/2026-09-13-stuffit-slice1.md) |
| 2 | method 5/8/14/6 + SIT5 RC4 + classic 改変 DES（MKey） | 完了（PR #13） | [slice 2](verification/2026-09-13-stuffit-slice2.md) |
| 3 | StuffIt X 容器 + range coder + Deflate / Blend / RC4-stored / Darkhorse / Cyanide | 完了（PR #14） | [slice 3](verification/2026-09-13-stuffit-slice3.md) |
| 4 | Brimstone + Iron + x86 + English（辞書組み込み） | 完了（PR #14） | [slice 4](verification/2026-09-13-stuffit-slice4.md) |
| 5 | 性能ラウンド（method 13 の table Huffman、Arsenic、XADMaster との A/B） | 完了（PR #15） | [slice 5](verification/2026-09-13-stuffit-slice5.md) |
| 6 | SITX 暗号（AES / Blowfish / DES-CFB、RC4、continuing-MD5 KDF、層状）+ `.exe` SFX | 完了（PR #16） | [slice 6](verification/2026-09-13-stuffit-slice6.md) |
| 7 | SITX JPEG 再圧縮（method 7、mode 0/1/2） | 完了（PR #17） | [slice 7](verification/2026-09-13-stuffit-slice7.md) |
| 8 | resource fork の展開（`<name>/..namedfork/rsrc` を実 fork へ）+ classic / SIT5 の `name` を完全パスに + MacJapanese 名の再試行（bd `cooViewer-gu28.8`） | 完了（PR #18） | [slice 8](verification/2026-09-13-stuffit-slice8.md) |

**XADMaster を上回る点（実測）:** (1) wrapper（`.bin` / `.as` / `.hqx`）の内側へ降りる、(2) classic method 6、
(3) 8 文字パスワードの classic（StuffIt 4.5 実書庫）、(4) StuffIt 7 Mac の `.sitx`（catalog key-10 整列）、
(5) MacBinary で包まれた実 `.sitx`、(6) SITX パスワード暗号（4 cipher + 層状 + 暗号化 catalog）、(7) `.exe` SFX、
(8) JPEG method 7（XADMaster はサイズ 0）、(9) 速度: method 13 が 2.55 倍、SMSSenderPro3osx.sitx が 1.6 倍、
Arsenic +12.5%、Cyanide 同等（A/A 床の範囲）。

**利用側で決めたこと（cooViewer-40b6、2026-09-13）:** cooViewer は `.sit` に加えて `.sitx` / `.sea` / `.hqx` を宣言し、
KaitoKit main（slice 1〜8）の framework を取り込んだ。スナップショット CLI で classic / StuffIt X（JPEG method 7）/
BinHex 内 StuffIt X / 日本語名フォルダ付き classic が表示される。header 暗号化書庫（SITX 暗号化 catalog、RAR5 `-hp`）は
両エンジンでパスワードを求めずに開けない既存の欠陥があり（`KaitoArchive(file:)` が `passwordRequired` を nil に潰す）、
cooViewer 側の bd `cooViewer-p2r1` で扱う。

**既知の未対応（見送りのまま）:** SITX recovery / redundancy（Root algorithm 5、CC0 の `recoverability` / `redundancy` 10 本）、
segment、base-N transport、画像・数値系 codec、JPEG の「単一成分に 1×1 以外の sampling」（参照 Python と同じ拒否、
コーパス 292 本中 12 本。cjpeg でグレースケール元画像に `-sample 2x2` を指定した人工的な profile）、
classic の暗号化 fork を書庫の resource fork なしで開くこと（MKey が無い。XADMaster も不可）。

## 実測: XADMaster の現状（cooViewer 同梱の XADMaster.framework、`Scripts/bench/xadsha`）

CC0 コーパス（ssokolow/stuffit-test-files、216 書庫）に対し、パスワード `password` を与えて実行:

| ケース | XADMaster の挙動 | 件数 | レポートの根拠 |
|---|---|---:|---|
| classic `.sit` / SIT5 `.sit` / `.sea`（平文） | 展開できる | 多数 | — |
| StuffIt 7 Mac `.sitx` | **開けない**（`unknown tag 63`。catalog key-10 の整列を欠く） | 8 | Ch.3 §「Key 10 aligns…」で修正確立 |
| SITX パスワード（RC4 / AES / Blowfish / DES） | 一覧は出るが**中身は空** | 8 | Ch.13–14 で 4 暗号を独立再構築・検証済み |
| SITX JPEG（method 7） | **サイズ 0** | 4 | Ch.25–34（見送り） |
| `.exe` SFX（Mac / Windows） | 開けない | 19 | Ch.2 は特定 stub のみ |
| `.bin` / `.as` / `.hqx` wrapper | 内側へ降りず 1 entry として提示 | 134 | Ch.6 |
| SIT5 パスワード `.sit` | 開けない | 1 | Ch.2 RC4 |
| SITX recovery（`redundancy` / `recoverability`） | 開けない | 4 | Ch.16–17（見送り） |

「XADMaster を上回る」は、性能だけでなく **上の表の開けないケースを開ける**ことでも達成できる。

## 出自（プロベナンス）の方針

- 実装入力は `inbox/stuffit/`（git 管理外）に固定した **StuffitAnalyze レポートの散文と表のみ**:
  Ch.00–13、`report/tables/*`、`research/{archive-verification,core-vectors,stuffitx-vectors}.json`。
  全 22 ファイルの SHA-256 を `inbox/stuffit/SHA256SUMS` に記録した。
- **XADMaster、The Unarchiver、stuffit-go（いずれも LGPL 2.1）のソースは開かない。**
  利用者は 2026-09-13 に他実装の解析を許可したが、レポートが「読んだ側」と「実装する側」を
  分ける clean-room の形を既に取っているため、それより少ない参照で足りる。レポートが曖昧な点は
  fixture か Python 参照ツールの**観測可能な挙動**で決め、検証記録に残す。
- XADMaster は `Scripts/bench/xadsha` を通じた **黒箱オラクル**（展開結果の SHA-256）としてのみ使う。
  レポート同梱の Python ツール（`tools/stuffitx_restore.py` 等、利用者の独自実装）は
  XADMaster が扱えない経路の第二オラクル。
- 表の扱い: `method13.json`（method 13 固定表）、`arsenic-randomization.json`（256 段の間隔）、
  `classic-key-substitution.json`（改変 DES の置換表）は形式が定める **定数** であり、
  XADMaster から転記された旨を `research/THIRD_PARTY_DATA.md` が記録している。これらは
  形式仕様の一部として実装に取り込み、出自を source header と design.md §10 に記す。
- **English 辞書（100,366 語、881,863 バイト）は KaitoKit に組み込む**（利用者決定 2026-09-13）。
  XADMaster 内蔵資産の展開物であり LGPL 由来と見なしうる点は `Tests/Fixtures/NOTICE` と design.md §10 に
  出自として明記する。圧縮した辞書を文字列リテラルで埋め込み、初回使用時に KaitoKit 自身のデコーダで
  展開して SHA-256 を照合する（SwiftPM の resource bundle は cooViewer の framework 組み立てと相性が悪い）。
- fixture: `stuffit-test-files` は CC0 → `Tests/Fixtures/stuffit/` に代表的な部分集合を base64 で
  収録し `NOTICE` に記す。stuffit-go の `samples/*.sit` は LGPL リポジトリ内の資料なので
  オラクル入力にのみ使い、収録しない。

## オラクルと検証

- 差分: CC0 コーパス 216 書庫 + stuffit-go 標本 17 本を `kaito sha` と `xadsha` の両方に流し、
  行単位で `cmp`。wrapper（`.bin/.as/.hqx`）は XADMaster が降りないので、内側の書庫を取り出した
  結果と比較する。XADMaster が失敗するケースはレポートの `archive-verification.json`
  （13 書庫・80 fork の CRC）と Python 参照ツールで担保する。
- 敵対的入力: 既存ハーネスと同じ形（切り詰め・bit 反転・header field 総当り・宣言サイズ改変・
  payload 乱数化）を ASan ビルドの `kaito` に流す。
- 単体: `core-vectors.json`（classic 17 vector）と `stuffitx-vectors.json`（SITX 32 vector）を
  固定期待値として XCTest 化する。

## 性能

- 基準は `Scripts/bench/xadbench`（XADMaster、`DYLD_FRAMEWORK_PATH` 必須）と `kaito bench`。
  同一書庫で A/A ノイズ床を取ってから交互 5 巡 × 3 回、各巡 B/A の中央値で判定する
  （`cooViewer-r897` / `2weq` と同じ規律）。
- 目標: 全書庫で XADMaster より遅くない。CPU 重心の method 15（Arsenic）・13・SITX Brimstone で
  明確に速い。
- コーパス: CC0 の標本は数 KB なので性能測定に使えない。classic は writer が現存しないため
  実書庫（archive.org の Info-Mac 等）を `inbox/stuffit-corpus/` に集め、出自と SHA-256 を
  記録する（収録しない）。SITX は研究ハーネスが vendor エンジン（x86_64、Rosetta）を writer として
  使えるので、任意の method・サイズで生成する。

## 実装の切り方（Codex への 1 task = 1 slice、各 slice 後に独立検証）

1. wrapper（MacBinary の LHA からの一般化、AppleSingle/Double、BinHex 4）+ classic 容器 + SIT5 容器
   + method 0/1/2/3/13/15。
2. method 5/8/14/6 + SIT5 RC4 + classic 改変 DES（`MKey` は書庫自身の resource fork。
   MacBinary / AppleSingle 経由でのみ到達できる）。
3. SITX 容器 + range coder + Deflate（window 10〜25）+ Blend + RC4-stored + Darkhorse + Cyanide。
   key-10 整列・type-9 comment catalog・kind-3 auxiliary 長の fixture 由来の修正を含む。
4. Brimstone + Iron（BWT / ST4）+ x86 + English（辞書は組み込み）。
5. 性能ラウンド（XADMaster との A/B）。
6. SITX 暗号（RC4 / AES-CFB は CryptoKit、Blowfish / DES-CFB は自前実装）+ `.exe` SFX stub。
7. SITX JPEG 再圧縮（method 7）を利用者の Python 参照実装から移植。

設計上の決め事:

- `ArchiveFormat` に `.stuffIt`（classic + SIT5）と `.stuffItX` を追加。wrapper は
  `FormatDetector` の透過的な unwrap 層で、形式ではない。署名は全て offset 0 / 10 にあるので
  SFX 走査は不要。BinHex は `(This file must be converted with BinHex` の前方走査を上限付きで行う。
- fork の公開は LHA / MacBinary の前例に従う: data fork が entry、resource fork は非空
  （classic）／descriptor あり（SIT5）のとき別 entry。
- SITX の solid stream は 1 本の復号出力の区間として fork を切る。7z の solid folder と同じ
  モデルにし、`EntryStream` は fork 境界でデコーダをリセットしない。
- 未対応 method は `KaitoError.unsupportedMethod` で失敗させ、部分出力を返さない。
  フォールバック前提の設計はしない（bd memory `no-xadmaster-fallback-policy`）。
- Brimstone の allocator（12 バイト単位、38 クラス、LIFO free list、分割規則）は既存の
  PPMd var.H / var.I と同じ形。枯渇 → restart は**意味論**であり資源方針ではない。
  hot loop は `cooViewer-2weq` の教訓（class 内 Swift Array を置かない、固定長ポインタ、
  `withUnsafeTemporaryAllocation`）を最初から適用する。
