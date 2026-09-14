# 多言語ファイル名エンコーディング判定 — 設計メモと決定経緯

Task A / B(bd `cooViewer-6lrc.1`)の設計メモ。`inbox/`(git 外)で orchestrator が執筆し、advisor レビュー 5 回と追補の決定を変更履歴に残したものを、実装完了時にそのまま保存した。実装の最終値は検証記録 `verification/2026-09-14-name-encoding-multilingual.md` が正。


bd `cooViewer-6lrc.1`(2026-09-14)。利用者指示: UniversalDetector の移植はしない。KaitoKit 単独で、
MIT のまま、CJK・ベトナム語・タイ語・ウクライナ語・スペイン語(+ できるだけ多く)の書庫名を
フォールバックなしで判定する。KaitoKit を使う他アプリからも使えること。実書庫は後日。

## 現状

- `EncodingDetector`(995 行): 厳密 UTF-8 → CP932 / EUC-JP の構造検査 → Foundation
  `NSString.stringEncoding(for:)`(候補 5: Shift_JIS / EUC-JP / UTF-8 / ISO-2022-JP / CP1252、
  `likelyLanguage: "ja"`)→ Latin-1 fallback。書庫単位の投票は CP932 vs EUC-JP のみ。
- 入口は 2 つ(全 13 reader が使う): `detectArchiveEncoding(names:policy:fromWindows:maximumBatchByteCount:)`
  と `resolveUndeclaredName` / `detect(bytes:policy:fromWindows:)`。ここを差し替えれば全形式に効く。
- cooViewer の KaitoKit 既定経路は UniversalDetector を使っていない(delegate 未配線)。

## 方針(clean-room)

`UniversalDetector/universalchardet/*`、XADMaster のソースは**開かない**。使ってよい入力:
公開規格(JIS X 0208 / GB 2312 / Big5 / KS X 1001 の区点構造、各 code page の配置)、
Unicode CLDR の exemplar 文字集合(Unicode License、`inbox/cldr/`)、公知の言語事実(文字頻度・正書法)、
自作コーパス(`inbox/name-corpus/`)。cooViewer 同梱の `UniversalDetector.framework` は**黒箱ベンチマーク**
(`scratchpad/enc/bin/udet`)としてのみ使う。

## 候補 encoding(CoreFoundation で全て利用可能を確認済み。VISCII / mac-vietnamese は不可)

| 系統 | 候補(報告する `String.Encoding`) | 構造検査 | 言語集合 |
|---|---|---|---|
| Unicode | UTF-8(厳密、最優先。既存) | RFC 3629 | — |
| 日本語 | CP932(`.shiftJIS`)、EUC-JP | 既存の状態機械 + 区分類 | ja |
| 簡体字 | GB18030(GBK / GB2312 を包含) | lead 0x81–0xFE、trail 0x40–0x7E / 0x80–0xFE、4 byte 形 | zh |
| 繁体字 | CP950(Big5 + MS 拡張)、Big5-HKSCS(CP950 で復号できない時のみ) | lead 0x81–0xFE、trail 0x40–0x7E / 0xA1–0xFE | zh-Hant |
| 韓国語 | CP949(EUC-KR を包含) | lead 0x81–0xFE、trail 0x41–0x5A / 0x61–0x7A / 0x81–0xFE | ko |
| タイ語 | CP874(TIS-620 を包含) | 1 byte | th |
| ベトナム語 | CP1258 | 1 byte(結合記号 0xCC 0xD2 0xDE 0xF2 0xF3) | vi |
| キリル | CP1251、KOI8-U、KOI8-R、ISO-8859-5、CP866、MacCyrillic | 1 byte(8859-5 は 0x80–0x9F を拒否) | uk, ru |
| ラテン西 | CP1252、ISO-8859-15、MacRoman、CP850 | 1 byte(8859-15 は 0x80–0x9F を拒否) | es, pt, fr, de, it, en |
| ラテン中欧 | CP1250、ISO-8859-2、MacCE | 同上 | pl, cs, hu |
| その他 | CP1253(el)、CP1254(tr)、CP1255(he)、CP1256(ar)、CP1257(lt, lv, et) | 1 byte | 各 1 言語 |

`likelyLanguage` は候補の**絞り込みではなく事前確率**(僅差の時だけ効く)。API は変えない。

ISO-2022-JP は 7 bit なので `automaticallyDetect` の「全 ASCII → UTF-8」で常に到達不能(書庫形式で名前に使う例も
ない)。新判定器の候補・コーパスから外す。既存の Foundation 候補 5 は互換のため残す。

## 採点(名前 × 候補)

1. 復号: 1 byte 系は起動時に 256 表を CoreFoundation から一度作り、以後は表引き(Foundation を経由しない)。
   多 byte 系は自前の構造検査に通った候補だけ CoreFoundation で厳密復号(lossy 不可)。
2. 文字ごとの得点(先頭 256 scalar):
   - 言語集合: 候補に対応する言語の CLDR exemplar **main** に含まれる文字 +2、**auxiliary** +1、
     同じ文字種(スクリプト)だが集合外の文字 −2(例: ISO-8859-5 で CP1251 bytes を読むと出る Ђ Ѓ Ќ)、
     記号 −0.25、制御文字 / PUA / 未割当 −4、ASCII 英数 +0.25。候補に複数言語があれば **membership は言語集合の和集合**で判定し(スペイン語の題名にフランス語の
     人名が混ざって −2 にならないように)、bonus は**言語ごとに合計し最大**を採る。
   - 多 byte 系の区分類: JIS X 0208 第 1 水準(区 16–47)/ GB 2312 一級(0xB0–0xD7)/ Big5 常用(0xA440–0xC67E)/
     KS X 1001 完成型ハングル 2,350(0xB0–0xC8)は +2、第 2 水準・二級・次常用・拡張ハングル +0.75、
     記号区 +0.5、外字・PUA・未定義 −3、かな +2、ハングル字母 +0.5。
   - **ja / zh / ko の交差復号**: GB2312 bytes は EUC-JP として構造的に有効で JIS 第 1 水準に落ちる。CP932 の漢字 lead は
     GBK 3–4 区に落ちる。CP949 のハングル行は GBK / CP950 / EUC-JP として有効。対策: (i) 半角カナ(CP932 0xA1–0xDF)は
     既存 `isLikelyHalfWidthName` が成立しない限り +0 とし、GBK 0xB0–0xDF が半角カナに見えても日本語へ寄らないようにする。
     (ii) 復号結果が Han のみで ja と zh の候補が小差(< 0.3)なら `likelyLanguage` が**決定する**(加点ではない)。
     これが GBK を候補に加えても既存の日本語テスト 13 件を安定させる規則。
3. 大小文字の整合(Latin / Cyrillic / Greek): 単語内で「小文字→大文字」の遷移ごとに −1.5(`aBcD` 型の
   ゴミを罰する。`Título`、`ПРИВЕТ`、`Привет мир` は無罰)。
   - **スクリプト混在(単語内)**: 1 つの文字列(letter run)の中で Latin↔Cyrillic、Latin↔Greek、Latin↔Thai、
     Cyrillic↔Greek が隣接するごとに −2.5(`Título` を CP1251 で読むと `Tнtulo`、CP874 では `T` + タイ文字 + `tulo`)。
     Han / かな / ハングルは対象外(日本語名に英字が混ざるのは正常)。短名でスペイン語・ベトナム語をキリル・タイの
     全候補から切り離す最も鋭い規則。
   - **アルファベット系の音韻妥当性**(Latin / Cyrillic / Greek 共通、言語非依存): 母音比率が 25–65% の外 −1、
     子音連続 ≥ 4 で −1(連続ごと)、罫線・ブロック・幾何図形(U+2500–25FF)−3 / 文字。CP1251 の小文字を KOI8-R で
     読むと `ОПХБЕР`(全て正規の大文字で集合内)になり、大小文字規則が沈黙するため、これが KOI8-R / KOI8-U /
     ISO-8859-5 / CP866 の間を分ける唯一の信号。ウクライナ語の і ї є も KOI8-R では別の文字に化ける。
4. 正書法規則:
   - タイ語: 声調記号(U+0E48–0E4B)・上下母音(U+0E31、0E34–0E3A、0E47、0E4C–0E4E)は子音(U+0E01–0E2E)
     または上母音の直後にのみ、前置母音(U+0E40–0E44)の直後は子音、SARA AM(U+0E33)は子音か声調の後。
     違反 −2 / 適合 +0.5。**曖昧でない違反だけ**を罰する(実コーパスで違反 0 が受け入れ条件)。
   - ベトナム語: 結合記号(U+0300 0301 0303 0309 0323)は母音(aăâeêioôơuưy、大小)の直後にのみ、
     1 音節に 1 つ。違反 −3 / 適合 +1。同じく曖昧でない違反のみ。
   - 日本語: 既存の plausibility(かな・漢字・半角カナ・EUC の 8E/8F 規則)をそのまま。
5. 文字頻度(粗い): 言語ごとに上位 10 文字と識別文字(uk: і ї є ґ / ru: ы э ъ ё / es: ñ ¿ ¡ / pt: ã õ ç /
   fr: ç œ / de: ß)に +0.5。公知の事実の範囲(精密な頻度表は持たない)。
6. 事前確率は**同点の時だけ**効く段階順位(平坦な ±0.02 は 1 個の +0.5 で埋もれるため廃止):
   キリル CP1251 > KOI8-U > KOI8-R > CP866 > ISO-8859-5 > MacCyrillic、
   ラテン CP1252 > CP1250 > ISO-8859-15 > MacRoman > CP850 > CP1258。`likelyLanguage` の言語を持つ候補は
   同一スクリプト内の順位で最上位へ。`fromWindows` で Mac 系は最下位へ。Mac 系 reader(StuffIt)は既存の
   MacRoman 既定を維持。**CP1258 はベトナム語の正の証拠**(正しい位置の結合声調記号 ≥ 1、または đ ơ ư ă を
   含む音節)が無ければ候補から落とす(「São」が「Săo」に化けるのを防ぐ)。
7. 名前の得点 = **非 ASCII scalar** の文字得点の平均 + 規則の加減(ASCII は大小文字・スクリプト混在の規則を
   通してのみ効く。`Vol.01 - Título 03.jpg` の判別文字は 1 つで、30 文字で割ると事前確率が決めてしまう)。候補の順位は得点、confidence は 1 位と 2 位の差を
   [0, 1] に写像(差 0 → 0.5、差 ≥ 1.0 → 0.95)。

## 書庫単位

未宣言かつ非 UTF-8 の名前を重複除去し出現数で重み付け(既存)、候補ごとに名前得点の加重和を取り、
最大の候補を書庫 encoding にする。**1 つの候補で全名が復号できること**を優先条件にし、できない候補は
復号できた名前数で減点。既存の CP932 vs EUC-JP の決定規則(既存テスト 13 件 + ArchiveNameEncodingTests)は
維持する(日本語 2 候補の同点は CP932、Foundation hint は日本語 2 候補の間でのみ使う)。
書庫 encoding で復号できない名前だけ単名判定へ戻す(既存の `resolveUndeclaredName`)。

## 性能

名前 1 件あたり 20 候補の採点で ≤ 50 µs(M 系)、1,000 名の書庫で ≤ 50 ms を目標。1 byte 系は表引きのみ、
多 byte 系は構造検査で大半を早期除外。既存の 512 名 / 256 KiB の sample 上限は維持。

## 検証

- `inbox/name-corpus/`: Wikipedia ランダム記事名(18 言語 × 約 2,000)+ 合成のコレクション風パターン
  (`[作者] 題名 第01巻`、`v01`、`(2005)`、`- 03.jpg`、大小文字違い、1〜3 文字の短名)を、各 legacy encoding で
  符号化(Python codecs、表現できない名前は除外、厳密 UTF-8 になる bytes も除外)。正解つき TSV。
  擬似書庫(同じ (言語, encoding) の名前を 1 / 2 / 3 / 5 / 10 / 30 / 100 件、ASCII 名を混ぜたもの)。
- `kaito detect-encoding`(新 CLI): 単名 / 書庫モードで判定を出力。
- `udet`(UniversalDetector 黒箱)を同じ入力に流し、(言語, encoding, 名前長, 書庫サイズ)ごとの正解率を
  並べる。目標: **全群で UniversalDetector 以上**、CJK / タイ / ベトナム / ウクライナ / スペインの
  非 ASCII 4 文字以上の名前で ≥ 99%、書庫 10 名以上で ≥ 99.5%。
- 過学習の防止: 生成器は seed を取る。重みは seed 20260914 で調整し、受け入れは**別 seed** で報告。
  正解は復号文字列の一致(code page 一致は副次列)。言語ごとの混同対(ja→gb18030、cp1251→koi8-r …)を割合だけでなく列挙。
- 回帰: ja 行は Task A ベースライン以上、既存の日本語テスト 13 件は不変。
- udet は短名で弱い(`あい` → windows-1252 0.50)ため、公平な比較は書庫モード。両方報告するが「上回る」の主張は書庫モードで行う。
- 既存テスト全緑(日本語の挙動は不変)。ASan は既存の敵対的入力ハーネスで名前系を流す。
- 実書庫(利用者提供)は入手後に再検証し、差分は bd に記録。

## 記録

design.md §10(出自: CLDR = Unicode License、NOTICE)/ §11、README(対応言語表)、
`Documentation/verification/2026-09-14-name-encoding-*.md`。

## 変更履歴

- 2026-09-14 advisor レビュー: (a) 単語内スクリプト混在の罰則、(b) キリル code page 間の音韻妥当性(母音比率・子音連続・罫線)、
  (c) 平坦な事前確率を段階順位に置換し CP1258 は正の証拠を要求、(d) 平均の分母を非 ASCII scalar に、
  (e) ja/zh/ko 交差復号(半角カナの抑制・Han のみは likelyLanguage が決定)を採用。ISO-2022-JP を候補から除外。
  CLDR 実測: ja main 2,311 / zh 2,210 / zh_Hant 2,179 / **ko main 11,172(全音節、非判別)**→ 韓国語は KS X 1001 の
  区分類(完成型 2,350 = 0xB0–0xC8)が担う。th 73 / vi 89 / uk 34 / es 33。
- 2026-09-14 advisor 第 2 回(Task B 仕様レビュー): (a) CJK の受け入れは `likelyLanguage: "ja"` で測り、`--language zh` でも
  ja ≥ 99% を要求(事前確率であって絞り込みでない証明)。(b) 2 つ目の seed は held-out にならない(同じ記事名)ため、記事名を
  SHA-256 で tune / eval に 70/30 分割し、tune で調整・eval で受け入れ。(c) 規則の順序: `likelyLanguage` で勝者を 1 つに固定 →
  勝者が CP932 / EUC-JP の時だけ既存の日本語経路へ委ねる。nil の CJK 段階順位は CP932 > EUC-JP > GB18030 > CP950 > CP949 >
  Big5-HKSCS(現行既定を保つ)。(d) 正書法違反 0 は硬い門にしない(≤ 0.5%、違反行を分類)。(e) 既存テスト
  `price-€-quote.txt`(CP1252、policy nil、fromWindows)は MacRoman の `Ä`(de main +2)が `€`(記号 −0.25)に勝つため、
  **fromWindows では Mac 系候補に平均後 −1.5** を課す(段階順位だけでは不足)。(f) `foundationDetection` は日本語経路へ委ねる時
  だけ呼ぶ。IANA 名の往復は Task A 訂正でテスト化。
- 2026-09-14 advisor 第 3 回(Codex の初期採点で既存テストと衝突): 第 1 回 (c) と第 2 回 (e) を**置き換える**。
  (1) 事前確率は証拠量で減衰する数値 `score = (n·evidence + k·prior)/(n+k)`(k≈3、CP1252 1.0 … Big5-HKSCS 0.1、
  likelyLanguage +0.4、fromWindows で Mac −0.3)。書庫では事前確率を書庫全体で 1 回。(2) 記号は位置で採点: 語内の非 ASCII 記号 −2、
  単独の記号 0(`price-€-quote` → CP1252 と `Café` CP850 → CP850 を同時に満たすのは位置規則だけ)。(3) ハングルは KS X 1001 区分類
  のみ(ko main が全音節で membership が二重計上され、かなに勝っていた)。互換性規則(テスト形状の例外)は不可。
- 2026-09-14 advisor 第 4 回(Task B 初回結果の eval 未達・全体テスト 1 件失敗の切り分け): (A) 事前確率の混合と書庫の分母は
  **非 ASCII byte 数**(第 3 回の「scalar 数」は誤りで、1 byte 系がタイ語で多 byte 文字の 2 倍の重みを得ていた)、evidence の平均は scalar 数。
  復号不能名は分母にも byte 数を足す(C1 引用符を含む CP1252 書庫が ISO-8859-15 に負けていた)。(B) 記号は一般カテゴリ × 位置:
  P* は 0(low-9 引用符が文字の直後だけ −2)、Sk が文字に隣接 −5(´ の語中は 0)、Sc/Sm/So はアルファベット文字の間だけ −2(CJK の間は 0)。
  (C) 言語ごとの整合: 候補の言語ごとに合計して最大、和集合内のみ +0.5、同スクリプト集合外 −1。(D) 多 byte の trail が ASCII 英字で lead の直前が
  ASCII 英字 → −2(`Andr市`)。第 2 水準 0.75 → 0.5(tune)。(E) アルファベット語の 40 文字超は −2 / 文字、タイ文字 run の無母音 13 文字目以降
  −2 / 文字(`[A1 A6]×4000` の ZIP テストで CP850 `íª…` / CP874 が勝っていた)。性能上限 22 秒は据え置き。
- 2026-09-14 追補(訂正 3 の適用中に `[A1 A6]×4000` が ISO-8859-15 `¡Š¡Š…` に負けた): **反復区間は言語的証拠を持たない** —
  同じ 1〜3 scalar のパターンが 20 回以上連続する区間は全候補で得点 0。候補を選ばない規則なので、その名前は prior(ja なら CP932)で
  既存の日本語多数決に入る。
- 2026-09-14 advisor 第 5 回(訂正 3・4 後: ja 回復、書庫 k≥10 は 15/19 群 ≥99%、ko 書庫が 100% → 90% に退行): (1) 常用漢字の +0.5
  追加加点(区分類と main の二重計上)を撤去、韓国語の公知頻出音節 50 に +0.5。(2)「かなの不在」罰は**却下** — 書庫では prior が 2% 未満で
  −0.5 は決定になり、かなを含まない実在の日本語 EUC-JP 書庫が CP949 完成型ハングル読みに負ける。代わりに交差復号のガードテスト 3 件
  (漢字のみ EUC-JP / CP932 書庫 → 日本語、ハングルのみ CP949 書庫 → CP949)。(3) es / hu の書庫: 名前ごとの最良言語で外来名 1 つが書庫を
  揺らす → **書庫レベルの最良言語**(内訳で確認してから)。(4) **仕様変更**: 受け入れ基準 4 の ko / zh-cn / zh-tw(非 ASCII ≥4)は
  kaito(none) で ≥95% とし、kaito(ja) は「ja prior の下での本質的曖昧性」として並記。既定 ja では単独の韓国語・中国語短名は日本語に
  解決される(書庫は正しい、他アプリは自分の likelyLanguage を渡す)。
- 2026-09-14 訂正 6(訂正 5 後の残差 = CJK 名の CP874 交差復号): タイ語の main は全文字なので membership が非判別(ko と同型)。
  頻出 10 文字の比率(実在 ≈55% / 乱数 ≈23%)が 35% 未満なら不足分 −1.5、稀な記号(ํ ๎ ฺ ๏ ๚ ๛)−2、タイ数字が Thai 文字に挟まれる −3、
  配置規則の適合 bonus +0.5 → +0.25。西欧ラテンの書庫 k≥10 の 99% 未達(es 98.1 / fr 98.2 / de 97.5 / it 96.7、全て udet 以上)は
  外来名の一様混入と CP1250 / ISO-8859-15 の文字重なりとして残差を記録する(prior で直さない)。
