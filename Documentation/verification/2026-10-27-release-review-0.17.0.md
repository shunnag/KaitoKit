# 0.17.0 のリリース前レビュー（2026-10-27）

`main`（`143003a` / v0.16.0 相当）から branch `fix/security-audit-2026-10-26` までの 3 commit
（`d2fa536` / `32205fc` / `50a886e`、53 files / +2,710 / -98）を、タグを打つ前に敵対的レビューにかけた。
0.8.0 はこの手順を省いて翌日 0.8.1 を出す結果になり、0.9.0 は実施して実際の回帰を 1 件捕まえている。

**体制**: 6 観点に 1 エージェントずつ（予算 reset の不変条件 / キャンセル検査 / 公開 API と文書の一致 /
展開の意味論 / テストの質 / 既存挙動への回帰）、所見ごとに敵対的反証 2 観点（`mechanism` と `already-handled`）、
最後に見落とし critic 1 本。計 37 エージェント。エージェントはビルドとテストの実行を禁止し、読解と
`git diff` / `grep` のみ。実測は orchestrator が実行した。

**結果: blocker 0 件。** 生存した所見を R1〜R5 として直した。

## R1. resource fork だけの entry が、同じ展開で作った data file の mtime を失わせる

### 再現

`d2fa536` の時点の実装で、AppleDouble の対（data fork の entry → resource fork の entry）を**正規の順**で
同じ展開 root へ展開する。data file の mtime が書庫の値ではなく展開時刻になる。

### 原因

`Sources/KaitoKit/Reader/Extractor.swift:341` の `if createsDataInode {` が、**この展開でこの reader が作った
inode** まで「既存ファイル」として扱っていた。`d2fa536` は「resource fork だけの entry が、自分が作っていない
既存ファイルの mode と mtime を書き換える」ことを塞いだが、その guard が data fork を先に展開した正規の経路まで
巻き込んでいた。`Tests/KaitoKitTests/Core/ResourceForkExtractionTests.swift:36-46` が固定していたのは
「既存 inode に書庫 metadata を適用しない」側だけで、この側は誰も固定していなかった。

### 修正

`trustedTargets`（= `ArchiveReader.extractedFiles`。この reader がこの展開 root で作った inode の identity）を
resource fork の経路へ渡し、`ownsDataInode = createsDataInode || trustedTargets.values.contains(extractedIdentity)`
で判定して、自分が作った inode にだけ書庫の mode / mtime を復元する。**自分が作っていない既存 inode には
一切適用しない**という security 性質は保つ。さらに、既存 inode の場合は identity を返さず `nil` にして、
後続の展開で trusted target に昇格しないようにした。

### 回帰テスト

`ResourceForkExtractionTests` に、data fork → resource fork の正規順で展開したとき data file の mtime が
書庫の値になることを固定する 1 本を追加。既存の「既存 inode には適用しない」テストは維持。
修正前に新テストが失敗することを確認した。

## R2. 7z の password 変更判定だけが正準等価比較で、正しい password が恒久的に通らない

### 再現

NFD の `"e\u{301}x"` を設定して暗号化 entry を読む（`.wrongPassword`）。次に**正しい綴り**の NFC `"\u{E9}x"` を
設定して同じ entry を読む。同じ reader では以後ずっと `.wrongPassword` になり、予算も戻らない。

### 原因

`Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift:180` の `guard self.password != password` は Swift String の
**正準等価**比較なので NFD と NFC を同じと判定して早期 return する。一方、鍵は password の**厳密な UTF-16
code unit** から導く（`SevenZipAES.swift` の `passwordBytes`、cache key の `passwordUTF16LE`）。結果として
`password` / `keyCache` / `coordinators` / `entryKDFBudget` が前の綴りのまま残る。
`ReadLimits` と `embedding.md` の「別の password を設定すると予算が全額戻る」という約束にも反する。
この罠は `StuffItXStreamCoordinator.swift:29` のコメントが明記しており、StuffIt X 側は byte 比較に直してあった。
7z だけが取り残されていた。

### 修正

7z を UTF-16、RAR5 を UTF-8 の厳密比較に揃えた（鍵導出で使う綴りと同じ単位）。
ZIP は `setPassword` に guard が無く無条件に代入し、`WinZipAESKeyCacheKey` が `Data(password.utf8)` を含むので
同症状は成立せず、変更していない。

### 回帰テスト

NFD → NFC の順に設定して 2 回目で読めることを固定。修正前に失敗することを確認した。

## R3. RAR5 の entry 鍵導出が無課金・中断不能

### 再現

entry ごとに独立した 16 byte salt と `kdfCount = 24` を持つ暗号化 .rar を、全 entry を読む host に渡す。
entry 数に比例して PBKDF2-HMAC-SHA256(2^24) が走り、予算にも課金されず取消しも効かない。

### 原因

`Sources/KaitoKit/Formats/RAR/RAR5Crypto.swift:187` の `RAR5KeyCache.checkedKey` の課金引数が既定 no-op で、
entry 経路の呼出（`RAR5Reader.swift:855`）が `charge:` を渡していなかった。RAR5 の file encryption record は
entry ごとに salt と kdfCount を持ち（`RAR5VolumeParser.swift:792-799`）、`RAR5KeyDerivation.derive` の
HMAC loop に取消し検査が無かった。**7z について「読取 library として受け入れられない」と判定した条件と同型**で、
main にも存在する（回帰ではない）。文書は RAR5 の予算を header 限定と明記していたので文書との食い違いは無い。

### 修正

0.17.0 は entry の鍵導出を有界にする release なので、同じ穴を残さない。
`ReadLimits.maxRAR5EntryKDFWork`（既定 `16 * ((1 << 24) + 32)` = 268,435,968、最大コストの 16 導出分で
header 既定の 4 倍）を追加し、通常・solid の cache miss を reader と password の組ごとに課金し、
4,096 HMAC ごとに取消しを検査する。header の既定予算は変えない。`init` の引数は末尾に追加した。
prefetch 候補の経路は `record.encryption == nil` と `password: nil` で導出に到達しないので、
予算 0 を渡して到達したら失敗する形にした。

### 回帰テスト

`Tests/KaitoKitTests/RAR/RAR5EntryKDFTests.swift` を新規追加（6 本）。distinct salt の entry を順に読むと
`limitExceeded` になる / 別 password で戻る / 同じ password では戻らない。修正前に 6 本すべて失敗することを確認した。

## R4. 取消しで課金だけが残り、再試行が二重課金になる

### 再現

鍵導出中に Task を取消し、同じ reader・同じ password で読み直す。StuffIt X で約 4 KiB の鍵長を宣言する書庫では、
**1 回の取消しでその (reader, password) が恒久的に `limitExceeded`** になる。

### 原因

課金は導出の**前**に行う（`SevenZipAES.swift` の `chargeKDFWork` → `derive`、
`StuffItXCrypto.swift:104` → `:106`）。導出中に取消しで抜けると、課金は残って鍵は得られない。

### 修正

`KDFWorkBudget.refund`（`remaining += min(work, limit - remaining)`）を追加し、**`CancellationError` の
ときだけ**返金する。7z / RAR5 / StuffIt X の 3 形式。取消しは呼出側しか起こせず書庫からは誘発できないので、
DoS の上限は弱まらない。誤 password などの失敗は従来どおり返金しない。

### 回帰テスト

取消し後に同じ reader・同じ password で導出できることを 3 形式で固定。返金だけを外すと 3 本とも失敗する
ことを確認した。

## R5. 文書と記録が実装と食い違っていた

### 再現

`README.md` が `maxSevenZipEntryKDFWork` の既定を実装の 1/4（`4 * (1 << 24)`）、scope を旧「reader 内」と
記していた（**6 観点のうち 4 つが独立に指摘**）。`CHANGELOG` は追加項目まで「修正」節に入れていた。
`embedding.md` の英語の field 列挙に新 field が無かった。`2026-10-26-audit-kdf-fixes.md` の「最終既定値」が
追補前の値のままだった。

### 原因

`50a886e` で既定値と意味論を変えたとき、`ReadLimits` の doc comment・`design.md`・`embedding.md`（日本語側）は
更新したが、README と CHANGELOG の節構成、英語側の列挙、KDF 記録の該当行が取り残された。

### 修正

README を `16 * (1 << 24)`（268,435,456）と「reader と password の組ごと」に直し、別 password で全額戻ること
（＝試行回数を縛るのは host の責務）を明記。CHANGELOG を `[0.16.0]` と同じ節構成（追加 / 変更 / 修正）に直した。
`embedding.md` の英語の列挙に新 field 3 件を追加。KDF 記録には追補への参照を 1 行入れた（時系列記録なので
本文は書き換えない）。併せて「7zz の出力は saltSize 0」という安心材料の根拠の範囲を
「7zz と GyoshukuKit で実測。第三者 writer の corpus は無い」と限定した。

### 回帰テスト

文書のみの変更なので回帰テストは追加していない。

## critic が見つけた未検査領域と、所見にしなかった点

6 観点のどれにも当たらなかった差分（`.github/workflows/ci.yml` の SHA pin、`dependabot.yml`、
`CLISmokeTests` / `ReaderOptionsTests` / `StuffItSlice2CryptoTests`、fixture 一式、`Documentation/verification/`
1,495 行）は critic が読み、R3 と R4 を新規に見つけた。fixture は `manifest.json` の sha256 3 件が
b64 復号後の payload と一致することを確認済み。

所見にしなかった点（根拠つき）: `makeDecoder(restartingAt:)` は単一 LZMA2 coder の gate があるので暗号化 folder は
到達しない。`SevenZipFolderDecoderFactory` の構築 5 箇所のうち fallback 予算に落ちるのは prefetch（password nil）と
header（明示 closure）だけ。秘密値比較の掃き残しは無い（`ConstantTime` 以外で verifier を `==` するのは
書庫由来の公開値 2 つの比較だけ）。CI の新しい 2 行は `|| true` が pipeline 全体に掛かるので
`set -euo pipefail` 下でも job を落とさない。

## 出荷前の実測（orchestrator が実行）

- 全 suite: `swift test` で **1,874 tests / 51 skipped / 0 failures**（レビュー前 1,862、main 1,828）。
  compat suite は 34 / 0 failures。
- **pin した action の SHA 4 件が upstream に実在すること**を `gh api repos/<owner>/<repo>/commits/<sha>` で確認:
  `actions/checkout@fbc6f399…`（v5、2026-07-16）、`actions/checkout@11d5960a…`（v4、2026-07-16）、
  `actions/upload-artifact@ea165f8d…`（2025-03-19）、`actions/download-artifact@d3f86a10…`（2025-04-24）。
  間違っていれば全 job が checkout で即死する。
- GyoshukuKit が新しい `ReadLimits` に対してビルドできること（公開 API の追加は `init` の末尾引数のみ）。
- 予算の意味論の実測（cyclesPower 19 で 512 entry 打ち止め / 同じ password では戻らない / 別 password で戻る /
  cyclesPower 24 で 8/8）は [2026-10-26-audit-kdf-fixes.md](2026-10-26-audit-kdf-fixes.md) の追補にある。

## 下流 3 プロジェクトの検査（リリース判定の前提）

0.17.0 候補に対して 3 プロジェクトの全 suite が通っている。判定表と実測は各 repo の
`Documentation/verification/2026-10-26-security-audit.md` にある。

| プロジェクト | テスト | この候補に起因する対応 |
| --- | --- | --- |
| KaitoFinder | 1,790 / 33 skipped / 0 failures | 予算の意味論を文書化（実効倍率は reader 21〜33 個）。`.sitx` は open 時に prompt へ到達するので StuffIt X の予算も影響する |
| GyoshukuKit | 921 / 49 skipped / 0 failures | 自傷なし（saltSize 0 で導出 1 回）。敵対的 distinct-salt 入力の編集が失敗し得ることを文書化 |
| cooViewer | 1,241 / 2 skipped / 0 failures | 自動 password 試行に上限を入れ、`limitExceeded` の誤表示（「パスワードが違います」）を直した |
