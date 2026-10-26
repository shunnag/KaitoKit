# 0.17.0 のタグ前レビュー（2026-10-27）

`main`（`143003a` / v0.16.0 相当）から branch `fix/security-audit-2026-10-26` までの 3 commit
（`d2fa536` / `32205fc` / `50a886e`、53 files / +2,710 / -98）を、タグを打つ前に敵対的レビューにかけた。
この repository は「リリース前に必ずタグ前レビューを通す」規律を持つ（v0.9.0 のレビューでは実際の回帰が 1 件出た）。

**体制**: 6 観点に 1 エージェントずつ（予算 reset の不変条件 / キャンセル検査 / 公開 API と文書の一致 /
展開の意味論 / テストの質 / 既存挙動への回帰）、所見ごとに敵対的反証 2 観点（`mechanism` と `already-handled`）、
最後に見落とし critic 1 本。計 37 エージェント。エージェントはビルドとテストの実行を禁止され、
読解と `git diff` / `grep` のみ。実測は orchestrator が行った。

**結果: blocker 0 件。** 生存した所見と、critic が見つけた未検査領域を次のとおり処置した。

## 1. 自分たちの修正による回帰（最重要）

**resource fork の mtime**（`Sources/KaitoKit/Reader/Extractor.swift:341`、反証 2/2 で生存）。

`d2fa536` で「resource fork だけの entry は既存 data fork の metadata を書き換えない」ようにしたが、
`if createsDataInode` の guard が**この展開でこの reader が作った inode** まで「既存ファイル」として扱っていた。
したがって AppleDouble の対（data fork の entry → resource fork の entry）を**正規の順**で展開すると、
data file の mtime が書庫の値ではなく展開時刻になる。

`Tests/KaitoKitTests/Core/ResourceForkExtractionTests.swift:36-46` が固定していたのは
「既存 inode に書庫 metadata を適用しない」側だけで、この側は誰も固定していなかった（critic の N5）。

処置: `trustedTargets`（= `ArchiveReader.extractedFiles`。この reader がこの展開 root で作った inode の identity）を
resource fork の経路へ渡し、「この展開で作った inode」なら従来どおり書庫の mtime を復元する。
security 性質（この reader が作っていない既存 inode には書庫 metadata を一切適用しない）は保つ。
正規順で mtime が保たれることを固定する回帰テストを追加した。

## 2. 同じ罠の取り残し

**7z の `setPassword` guard だけが String の正準等価比較**（`Formats/SevenZip/SevenZipReader.swift:180`、反証 2/2 で生存）。

7z の鍵は password の厳密な UTF-16 code unit から導く（`SevenZipAES.swift:124-133`、cache key は `passwordUTF16LE`）が、
guard は Swift String の正準等価比較なので NFD と NFC を同じと判定する。NFD で一度失敗した reader に
**正しい綴りの NFC を設定しても guard が早期 return** し、`password` / `keyCache` / `coordinators` /
`entryKDFBudget` が NFD のまま残る。以後その reader では正しい password が恒久的に通らず、予算も戻らないため
`ReadLimits.swift:72-73` と `embedding.md:79` の「別の password を設定すると全額戻る」という約束に反する。
編集 SPI（`ArchiveReader.swift:341`）経由では `expectedCRC32: nil` なので、呼出側は前の綴りの鍵で復号した平文を
黙って受け取る。

**この罠は repository 自身が `StuffItXStreamCoordinator.swift:29` のコメントで明記し、StuffItX 側は byte 比較に
直してある。7z だけが取り残されていた。** ZIP（`ZipReader.swift:161`）と RAR5（`RAR5Reader.swift:140`）の
同じ guard も併せて確認した。

処置: 7z の guard を byte 綴りの比較にして StuffItX と揃え、NFD → NFC の回帰テストを追加した。

## 3. critic が見つけた未検査領域

**N1: RAR5 の entry 鍵導出が無課金・中断不能**（`Formats/RAR/RAR5Crypto.swift:187`、`RAR5Reader.swift:855`）。
`RAR5KeyCache.checkedKey` の課金引数は既定 no-op で、entry 経路は `charge:` を渡さない。RAR5 の file encryption
record は entry ごとに独立した 16 byte salt と kdfCount を持ち（`RAR5VolumeParser.swift:792-799`）、
`RAR5KeyDerivation.derive` の `2^kdfCount + 32` 回 HMAC loop に取消し検査が無い。
salt を entry ごとに乱択し `kdfCount = 24` を付けた暗号化 .rar を全 entry 読む host に渡すと、
entry 数に比例して PBKDF2-HMAC-SHA256(2^24) が無課金・中断不能に走る。**7z について「読取 library として
受け入れられない」と判定した条件と同型**である（main にも在るので回帰ではなく、文書は RAR5 の予算を
header 限定と明記しているので文書との食い違いも無い）。

処置: 0.17.0 は「entry の鍵導出を有界にする」release なので、同じ穴を残して出さない。
`ReadLimits.maxRAR5EntryKDFWork` を足し、cache miss のみ課金し、derive loop に取消し検査を入れた。

**N2: 取消しで課金だけが残り、再試行が二重課金になる**。課金は導出の前に行うので、導出中に取消しで抜けると
課金が残って鍵が無い。StuffIt X は 1 導出が予算の大半を使い得る（約 4 KiB の鍵長を宣言する書庫なら 1 回で
使い切る）ため、**1 回の取消しでその (reader, password) が恒久的に `limitExceeded`** になる。

処置: `KDFWorkBudget.refund` を足し、**`CancellationError` のときだけ**返金する。取消しは呼出側しか
起こせず書庫から誘発できないので、DoS の上限は弱まらない。`wrongPassword` などは従来どおり返金しない。

**N3 / N4 / N6: 文書と記録の食い違い**。`README.md:154-155` が既定値を実装の 1/4（`4 * (1 << 24)`）と
旧 scope「reader 内」のまま書いていた（**4 観点が独立に指摘**）。`CHANGELOG` が追加項目まで `### 修正` に
入れていた。`2026-10-26-audit-kdf-fixes.md:53`・`:403` の「最終既定値」が追補前の値のまま。
テスト件数の基準が 1,854（推定値）になっていた（正しくは main の 1,828 → HEAD 1,862 で +34）。
いずれも処置済み。

**critic が所見にしなかった点**（根拠つきで確認済み）: `makeDecoder(restartingAt:)` は単一 LZMA2 coder の
gate があるので暗号化 folder は到達しない。`SevenZipFolderDecoderFactory` の構築 5 箇所のうち fallback 予算に
落ちるのは prefetch（password nil）と header（明示 closure）だけ。秘密値比較の掃き残しは無い
（`ConstantTime` 以外で verifier を `==` するのは書庫由来の公開値 2 つの比較だけ）。
fixture の manifest の sha256 3 件は b64 復号後の payload と一致。CI の新しい 2 行は `|| true` が
pipeline 全体に掛かるので `set -euo pipefail` 下でも job を落とさない。

## 4. 出荷前の実測（orchestrator が実行）

- **pin した action の SHA 4 件が upstream に実在すること**を確認した（`gh api repos/<owner>/<repo>/commits/<sha>`）:
  `actions/checkout@fbc6f399…`（v5、2026-07-16）、`actions/checkout@11d5960a…`（v4、2026-07-16）、
  `actions/upload-artifact@ea165f8d…`（2025-03-19）、`actions/download-artifact@d3f86a10…`（2025-04-24）。
  間違っていれば全 job が checkout で即死するので、tag 前に確かめる価値があった。
- **distinct salt を書く writer の範囲**: repository の暗号化 7z fixture は 7zz と GyoshukuKit 由来のみで、
  第三者 writer の暗号化 7z は corpus に無い（`Tests/Fixtures/NOTICE`）。「7zz の出力は saltSize 0」という
  安心材料の根拠を「7zz と GyoshukuKit で実測」と限定して文書に明記した。
- 予算の意味論の実測（cyclesPower 19 で 512 entry 打ち止め / 同じ password では戻らない / 別 password で戻る /
  cyclesPower 24 で 8/8）は `2026-10-26-audit-kdf-fixes.md` の追補に記録済み。

## 5. 下流 3 プロジェクトの検査（リリース判定の前提）

0.17.0 候補に対して 3 プロジェクトの全 suite が通っている。各 repo の
`Documentation/verification/2026-10-26-security-audit.md` に判定表と実測がある。

| プロジェクト | テスト | この候補に起因する修正 |
| --- | --- | --- |
| KaitoFinder | 1,790 / 33 skipped / 0 failures | 予算の意味論を文書化（実効倍率 21〜33 reader）。`.sitx` が prompt に到達するので StuffItX の予算も影響あり |
| GyoshukuKit | 921 / 49 skipped / 0 failures | 自傷なし（saltSize 0）。敵対的 distinct-salt 入力の編集が失敗し得ることを文書化 |
| cooViewer | 1,241 / 2 skipped / 0 failures | 自動 password 試行に上限を入れ、`limitExceeded` の誤表示（「パスワードが違います」）を直した |
