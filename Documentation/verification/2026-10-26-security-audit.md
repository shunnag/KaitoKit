# 2026-10-26 セキュリティ・性能監査の検証と対応

この記録は検証記録の例外で、design.md の数値の裏付けではなく、外部の AI エージェントが置いた監査報告
（本文書の旧版、下記「監査報告の主張」の列がその内容）を**独立に検証した結果**と、その対応をまとめたものである。
検証時点の HEAD は `143003a`（v0.16.0）で、監査報告が引用した行番号もこの HEAD のものだった。

## 検証の方法

- 監査報告の全 34 指摘（セキュリティ 26、性能 8）を 16 群に分け、各群に 1 エージェントを割り当てて
  **コードを直接読み直し**、到達可能性と実リスクを判定した（判定: 正しい / 部分的に正しい / 誤り）。
- 「正しい」「部分的に正しい」と判定された各件に、独立した**敵対的反証**を 2 観点
  （(a) 機構そのものを否定できるか、(b) 重大度と提案された修正を否定できるか）で当てた。
- 可能なものは**実物で再現**した（自作の細工書庫、`/usr/bin/time -l` の実測、7-Zip / bsdtar / unzip /
  ditto との既定挙動比較）。再現できたものだけを「実証済み」として扱う。
- 合計 81 エージェント。オーケストレータ自身も E1 / E2 / C1 / C3 / C4 を独立に再現し、
  性能値は release build で測り直した（監査と triage の一部の秒数は debug build の値だった）。

## 総括

- 監査が**最重要（高）としていた 2 件は、いずれも重大度が誤り**だった（C1 は低、T1 は低）。
- 実際に深刻だったのは、監査が「中」としていた **C3 と C4 の 2 件**（いずれも実証済みの CPU 枯渇）。
- 監査が**見落としていた、より直接的な欠陥が 1 件**あった（resource fork の entry が、自分が作っていない
  既存 file の mode と mtime を書き換える。`overwriteExisting: false` でも起きる）。
- 34 件のうち **誤り 3 件**（P5 / T3 / Q8）、**到達不能または既に文書化済み 7 件**、
  **対応不要（設計判断・POSIX 標準の挙動）5 件**。
- 修正したのは 10 件、文書のみ 8 件、対応不要 15 件、裁定待ち 1 件。

## 指摘ごとの判定と対応

| ID | 監査 | 判定 | 実リスク（検証後） | 対応 |
| --- | --- | --- | --- | --- |
| C3 | 中 | **正しい（高へ引き上げ）** | salt が異なる folder ごとに entry 時の鍵導出が無課金。最大コスト（cyclesPower 24）で 1 folder ≈ 0.42 秒（release）。鍵 cache は folder 数の上限なし。20 MB 級の書庫で数十時間規模。`list` は無害で、password を渡した時だけ（誤った password でも）発生 | **修正**: `maxSevenZipEntryKDFWork`（既定 `4 * 2^24` rounds）を reader 単位で課金し、cache miss のみ減算。鍵 cache は 64 件 FIFO。32 salt の細工書庫は 13.55 秒 → 1.69 秒で `limitExceeded` |
| C4 | 中 | **正しい** | 鍵導出が二次（MD5 入力 ≈ `16 × rounded²`）。225 byte の書庫が **425 秒**（release 実測）、71 byte で 6.5 秒。暗号化 catalog なら `list` で、entry ごとに倍増。cancellation も効かない | **修正**: `maxStuffItXKDFWork`（既定 `2^22` MD5 圧縮回数）を reader 単位で課金し、取消し検査を追加。225 byte の書庫は 425.74 秒 → 即時 `limitExceeded`。受理境界は宣言鍵長 4,032 byte（1.59 秒） |
| E1 | 中 | 正しい（低） | 書庫宣言の setuid / setgid を既定で復元。bsdtar / unzip / ditto / 7-Zip はいずれも既定で落とす（実測）。非 root 単独利用では権限昇格にならないが、root 展開・権限付き複写・共有 destination で危険 | **修正**: 非 directory の entry から `0o6000` を除去し、`ExtractionOptions.preserveSetUserIDBits`（既定 `false`）で従来の挙動を opt-in に。directory の特殊 bit は文書化済みの既定どおり維持 |
| （新） | — | **監査の見落とし** | resource fork だけの entry が、既存 file の mode を 0644 → 06755 に、mtime を 1970 に書き換えた（内容はそのまま）。`overwriteExisting: false` でも発生 | **修正**: 既存の data fork には書庫の metadata を適用しない |
| E4 | 低 | 部分的に正しい | 上記と同根。反証 lens も「コード修正に値する」と判定 | **修正**（同上） |
| C1 | 高 | 部分的に正しい（低） | CLI の `-p` が argv のみ。同一利用者の `ps` と shell 履歴に露出。開発者向け CLI で、他者アカウントからは argv を読めない。監査は 4 箇所のうち 2 箇所しか挙げていない | **修正**: 4 コマンドすべてに `--password-stdin` を追加（`-p` との併用・空入力は usage error）。`-p` の露出も文書化 |
| C6 | 低 | 正しい（実リスクなし） | 5 byte の verifier だけ早期脱出比較。監査自身の「安全確認」節の「ConstantTime で統一」という記述と矛盾する | **修正**: `ConstantTime.equals` に統一 |
| P6 | 低 | 部分的に正しい（低） | bidi 制御文字が未 escape で端末表示を偽装できる。**design.md:1406 に既知の制限として記録済み**で、監査はその行を「根拠」として引用していた | **修正**: `U+202A〜202E` / `U+2066〜2069` を escape（`safe\u{202e}txt.exe` と表示）。design.md:1406 の既知事項を解消 |
| T1 | 高 | 部分的に正しい（低） | brew の oracle が未固定。ただし差分テストの基準は fixture の期待値で、oracle は生成器。Homebrew bottle の版固定は非現実的 | **修正**: CI の既存の版表示 step に oracle 4 つの版を記録（版の固定はしない） |
| Q4 | — | 部分的に正しい | folder digest が無い書庫でも folder CRC を計算していた（7-Zip も libarchive も folder digest を書かない）。読取 CPU の約 23%、0.056 秒/GiB | **修正**: folder digest がある書庫だけ CRC を計算 |
| Q2 | — | 部分的に正しい | tar checksum が 512 byte を throwing 加算。10 万 header の open で wall 276 → 245 ms | **修正**: `validateChecksum` のみ固定範囲の和に変更（unsigned / signed 両方式の受理は不変）。10 万 header の open は 276 → 245 ms |
| E2 | 中 | 部分的に正しい（リスクなし） | `renameat` は無条件だが、**KaitoKitCompat は `ExtractionOptions` を一切参照しない**ので「option に従わない」という指摘は到達不能。CLI は compat を link しない。中核の上書き分岐と同じ挙動 | 文書のみ |
| C2 | 中 | 部分的に正しい（低） | 鍵材料を zero 化しない。ただし**監査の提案は無効**: Swift の `Data` は copy-on-write なので in-place zero 化は別 buffer を消すだけ（実測で確認） | 文書のみ |
| C5 | 低 | 部分的に正しい（リスクなし） | 空 IV の zero 埋めは形式準拠 | 文書のみ |
| C7 | 低 | 部分的に正しい（リスクなし） | reader が cipher を選べるわけではない（書庫が決める）。監査の引用行は選択箇所ではなく鍵 schedule。RC4/DES/Blowfish は ZIP ではなく StuffIt 系 | 文書のみ |
| C9 | 低 | 部分的に正しい（低） | 「検出が遅延」は派生鍵では誤り。`RAR5DerivedKeys.verify` の doc に記載済み | 文書のみ |
| P1 | 中 | 部分的に正しい（低） | Xar の text 連結は二次だが TOC が 16 MiB で上限付き（監査は上限の行を誤引用）。最大 TOC で 0.8 秒 / 110 MB | 文書のみ |
| P2 | 低 | 部分的に正しい（低） | 契約は `ByteSource.swift:14-15` に既記。limit 付き variant は約 200 箇所と公開 API 追加が必要で、新たな保証は無い | 文書のみ |
| Q6 | — | 部分的に正しい（リスクなし） | 小 buffer は高遅延入力のための意図的な選択。監査の提案は NAS で悪化する | 文書のみ |
| E3 | 中 | 部分的に正しい（リスクなし） | **design.md:1605-1609 に設計判断として記録済み**。per-component `O_NOFOLLOW` により、植えた symlink は展開経路で辿られない。監査自身の「安全確認」節と矛盾 | 対応不要 |
| E5 | 低 | 部分的に正しい（リスクなし） | 呼出側が渡した root path の中間 symlink を辿るのは POSIX 標準の挙動。監査の提案（root 全体 nofollow）は macOS の temp directory を壊す | 対応不要 |
| C8 | 低 | 正しい（リスクなし） | 形式の仕様どおり。`formats.md:336` / `:350-352`、`design.md:2106`、`README.md:118` に既記 | 対応不要 |
| C10 | 低 | 部分的に正しい（低） | `ReaderOptions.swift:96-111` に既記 | 対応不要 |
| P3 | 低 | 正しい（到達不能） | 呼出元すべてが上限付き。監査自身も「到達不能」と記載 | 対応不要 |
| P4 | 低 | 正しい（到達不能） | 細工 header でも count が上限内 | 対応不要 |
| P5 | 低 | **誤り** | 読み違い。順序 guard が既にある | 対応不要 |
| T3 | 中 | **誤り** | 同一 workflow run の中間 artifact を外部由来として扱っていた。workflow 権限は read-only | 対応不要 |
| T4 | 中 | 部分的に正しい（リスクなし） | 攻撃者が存在しない（inbox への書込権は既に開発者のシェル掌握を意味する） | 対応不要 |
| T5 | 低 | 部分的に正しい（リスクなし） | fuzz の固定文字列で秘密ではない | 対応不要 |
| Q1 | — | 部分的に正しい | 中央 directory の二度走査は事実。反証 2 lens は「文書のみでは弱い」と判定したが、single-pass 化は回帰リスクのある再構成なので今回は見送り | 見送り（候補） |
| Q3 | — | 部分的に正しい | 一覧 CPU の約 2%。String 復号と entry 構築が支配的 | 対応不要 |
| Q5 | — | 部分的に正しい（リスクなし） | lock の第二保持者が存在しない。1 MiB は既定ではない | 対応不要 |
| Q7 | — | 部分的に正しい（低） | 二重 validate は `read()` のみ（`stream()` / 展開経路は 1 回）。5 万 entry で約 2.4 ms | 見送り |
| Q8 | — | **誤り** | broadcast は既に実装済み | 対応不要 |
| T2 | 中 | 正しい（低） | action が tag pin。SHA pin は有効だが、dependabot 無しでは pin が腐る。月次 PR と CI 時間の費用対効果は利用者判断 | **裁定待ち** |

## 修正の詳細

- C3 / C4 / C6: [2026-10-26-audit-kdf-fixes.md](2026-10-26-audit-kdf-fixes.md)
- E1 / 見落とし分 / E4 / C1 / P6 / T1 / Q4 / Q2: [2026-10-26-audit-extract-fixes.md](2026-10-26-audit-extract-fixes.md)

## 監査報告そのものの誤り

後続の監査で同じ誤りを繰り返さないために記録する。

1. 規模の誤り: 「`Sources/KaitoKit` 601 ファイル / 約 75,000 行」。実際は `Sources` 全体で 321 ファイル。
2. 件数の自己不一致: 冒頭の「高 2・中 9・低 13」が、自身の表（高 2・中 10・低 14）と合わない。
3. 既存の設計判断を新規指摘として提示: E3 は `design.md:1605-1609`、P6 は `design.md:1406`（しかも
   その行を「根拠」として引用）、C8 / C9 / C10 は既に複数箇所で文書化済み。
4. 自己矛盾: 第 2 節の「安全確認: 検証 byte の比較は `ConstantTime.equals` で統一」は C6 と矛盾する。
5. 上限の誤引用: Xar TOC の上限は `XarReader.swift:199-213` ではなく `XarReader.swift:20`。
6. 無効な改善提案: C2 の「`Data` を in-place で zero 化」は copy-on-write のため効果がない。
   E5 の「root 全体を nofollow で開く」は macOS の `/private/tmp` 経由の destination を壊す。
7. 到達可能性の未検証: E2 は該当 module が `ExtractionOptions` を参照しないため、指摘された乖離が起きない。
   T3 は同一 run の artifact を外部入力と誤認。
8. 重大度の系統的な過大評価: 「高」2 件はいずれも低。逆に、実際に深刻な C3 を「中」に置いていた。

## 過程の注記

- 検証中に triage エージェントの 1 つが、repository root に StuffIt X の試験書庫 6 個
  （`1024` `4096` `8192` `16384` `32768` `65536`）を書き残した。内容を確認して削除した。
- 性能値は release build で測り直した。監査と初回 triage の一部の秒数は debug build のもので、
  7z の鍵導出では約 50 倍の差があった（2^24 で debug 24 秒 / release 0.42 秒）。
- 第三者の書庫実装 source は参照していない（design.md §10）。brew install も行っていない。

## 下流プロジェクトでの検証（リリース判定の前提）

本修正を含む 0.17.0 は、KaitoKit を利用する 3 プロジェクトの同じ観点での検査が終わるまでリリースしない
（利用者の指示、2026-10-26）。各プロジェクトに検査の指示書を置いた。

| プロジェクト | 指示書 | 依存の形 | 0.17.0 の影響 |
| --- | --- | --- | --- |
| KaitoFinder | `../KaitoFinder/Documentation/2026-10-26-audit-instructions.md` | `../KaitoKit` への path 参照（版の pin なし）。CI は `main` を浅く clone | KDF 予算のみ。展開 API は未使用 |
| GyoshukuKit | `../GyoshukuKit/Documentation/2026-10-26-audit-instructions.md` | 隣に checkout があれば path、無ければ `.upToNextMinor(from: "0.16.0")`（= 0.17.0 未満） | KDF 予算のみ。自分が書いた書庫を読み戻せるかの自傷確認が要る |
| cooViewer | `../cooViewer/Documentation/2026-10-26-audit-instructions.md` | ビルド時に `../KaitoKit` から framework を再ビルド（版の記録なし） | KDF 予算。`.sitx` 対応なので現行出荷版（2.0b49、v0.16.0 ビルド）が敵対的 `.sitx` で固まる可能性 |

### 下流の調査で判明した本修正の限界（0.17.0 で判断が必要）

3 プロジェクトの範囲調査（2026-10-26）で、**R2 / C3 の予算は reader 単位であり `reopened()` で引き継がれない**
ことが、下流では実効的な弱点になると判明した（`Core/KDFWorkBudget.swift`、
`Formats/SevenZip/SevenZipReader.swift` の `reopened`）。

- KaitoFinder は password 検証で worker ごとに `reopen()` し、誤った password ごとに `open` し直す
  （prompt loop に試行上限が無い）。
- cooViewer は 1 冊につき primary 1 + extractor 最大 6 の reader を開き、nested で更に増える。
- いずれも**予算が reader の数だけ倍になる**。

逆方向の懸念もある: cyclesPower 24 の正規の暗号化 7z では既定予算（`4 × 2^24`）で約 4 回しか導出できないため、
**password を 4 回以上試した利用者が `limitExceeded` で弾かれる**可能性がある。cooViewer の
`classifyProbeFailure` は `limitExceeded` を「password 違い」に分類するので、**誤った案内**になる恐れもある。

判断の選択肢（下流の実測が出てから決める）:

1. 現状維持（reader 単位）＋ 意味論を `ReadLimits` の doc と embedding.md に明記し、reader を多数開く呼出側は
   上限を下げるか reader を共有するよう案内する。
2. 複数 reader で共有できる予算 object を公開 API として追加する（`ReadLimits` に注入する形）。
3. 既定値を上げ下げする（下流の実測した倍率と、正規書庫の試行回数の両方を見てから）。

この 3 択は下流 3 件の検査結果が揃ってから決める。1 は最小、2 は呼出側の手当てが要るが本質的、
3 だけでは多重化を解けない。

### 下流 3 件の検査結果と、採った裁定（2026-10-27）

3 プロジェクトの検査を実施した（KaitoFinder 45 / GyoshukuKit 36 / cooViewer 78 エージェント。各 repo の
`Documentation/verification/2026-10-26-security-audit.md` に判定表・実測・限界を記録）。結論は次のとおり。

**実測で、既定 `4 × 2^24` は正規利用を壊すことが確定した**（計測の詳細は `2026-10-26-audit-kdf-fixes.md` の
「追補（2026-10-27）」）。

- cyclesPower 24 の書庫に**同一 reader** で password を試すと 4 回で打ち止めになり、5 回目は即 `limitExceeded`。
- cyclesPower 19 で salt が folder ごとに異なる書庫は、**正しい password でも entry 128 以降が読めない**。
- 7-Zip（`7zz`）と GyoshukuKit の出力は saltSize 0 なので導出 1 回で済み、無影響（200 folder で実測）。

**採った裁定: 上の選択肢 3（既定値の見直し）＋ 予算の意味論の変更。**

1. `maxSevenZipEntryKDFWork` の既定を `16 × 2^24`（268,435,456 rounds）にした。cyclesPower 19 なら distinct salt
   512 個、24 なら 16 回。最悪 ≈ 7.5 s/reader/password（M4 Max）で、修正前の**無制限**から有限になる性質は保つ。
2. 予算を **「reader と password の組ごと」** にした（`KDFWorkBudget.reset()` を
   `SevenZipReader.setPassword` と `StuffItXReader.setPassword` の変更検査の内側で呼ぶ）。
   `ArchiveReader.preparePassword` は `stream()` ごとに `setPassword` を呼ぶので、**reset が実際の変更時だけ
   発火すること**が不変条件であり、回帰テストで固定した（1 password で distinct salt の entry を順に読むと
   予算が積算されて止まる）。
3. 7z の KDF chunk loop に `Task.checkCancellation()` を入れた。上限そのものより中断可能性が GUI を守る。
4. 選択肢 2（共有予算の公開 API）は**採らなかった**。下流の実測で、多重化は「host が自動で何回試すか」で決まり
   （cooViewer は 1 回の password 入力の後、child ごとに vault と既知 password を自動で試す）、
   **試行回数を縛るのは host の責務**だと確定したため。`ReadLimits` の doc に露出が
   `試行回数 × reader 数` に比例することを明記し、下流にはそれぞれ上限を入れた。

**下流で確認された、この裁定に関わる事実**:

- cooViewer の `NestedUnlocker` は自動試行が `promptingDisabled` の判定より前にあり、利用者の操作ゼロで
  child ごとに鍵導出が走る（修正済み: 連続全敗に上限）。
- cooViewer の `classifyProbeFailure` は `limitExceeded` を「password が違う」と誤表示していた（修正済み）。
- KaitoFinder の実効倍率は「全選択 → 展開」1 回で reader `V + 1 + P` 個（既定で 21〜33 個）。
  `.limitExceeded` は再入力に化けないので自動増幅はしない。`.sitx` は open 時に prompt へ到達するので
  `maxStuffItXKDFWork` も影響する（指示書の「無関係」仮説を反証）。
- GyoshukuKit は saltSize 0 のため自傷なし。ただし**敵対的な distinct-salt 入力の編集**は予算超過で失敗し得る
  （仕様として文書化）。
- 併せて GyoshukuKit 側に、**自分が書けて KaitoKit が読めない名前**（path 要素 1,025 個）という相互運用の
  自傷が見つかり、書き込み側に `maxPathComponentCount` の guard を入れた（Mac mini で実証）。
