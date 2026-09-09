# 破損書庫の救済モードの検証 — 2026-09-09

`ReaderOptions.recoverDamagedArchives`(既定 false)を入れたあとの実測。
比較対象の XADMaster は実行ファイルの入出力だけを使ったオラクルで、
source は参照していない。

## 小さい書庫(5 ファイル / 41,613 byte の ZIP など)

正解は原本の SHA-256。`[incomplete]` は KaitoKit が entry を不完全と報告した印。

| 書庫 | 既定(strict) | `recoverDamagedArchives` | XADMaster |
|---|---|---|---|
| EOCD の署名だけ潰した ZIP | `ZIP end-of-central-directory record was not found` | 6 entry、総合 SHA-256 は **XADMaster と一致**(`4abb9bc6b6…`) | 6 entry |
| ZIP を 90 / 60 / 30 / 10% に切り詰め | `truncated` 系で open 失敗 | いずれも 6 entry | 6 entry |
| central directory の署名を潰した ZIP | 失敗 | **失敗のまま**(救済の起動条件は EOCD の不在) | 失敗 |
| tar 60% | `The archive is truncated` | 4 entry、総合 SHA-256 は **XADMaster と一致**(`6eae291ee0…`) | 4 entry |
| LHA 60% | `The archive is truncated` | 3 entry | 3 entry |
| 7z 60% | 失敗 | 失敗のまま(ヘッダが末尾) | 失敗 |

## 切れた entry の中身

切断された entry について、KaitoKit は読めた分を返して `isIncomplete` を立てる。
XADMaster は 0 バイトを返す。返ってきた byte 列が原本の先頭と一致することを
すべて確認した。

| 書庫 | 切れた entry | KaitoKit | 原本の先頭 N byte の SHA-256 | XADMaster |
|---|---|---:|---|---:|
| ZIP 30% | `c.rnd` (40,000) | **11,378** byte | `c674990dcb…` = 一致 | 0 byte |
| tar 60% | `a.txt` (9,200) | **8,192** byte | `6094be6b43…` = 一致 | 8,192 byte |
| LHA 60% | `c.rnd` (40,000) | **23,850** byte | `bbf0b1198e…` = 一致 | 0 byte |

ZIP と LHA では **XADMaster より多く救済できている**。ごみを返しているのではなく、
いずれも原本の正しい prefix である。

## 実書庫での規模と速度

`book-deflate.cbz`(200 ページの JPEG、402 MB)を使う。

| 壊し方 | 結果 | 時間 |
|---|---|---:|
| 先頭 80%(321 MB)だけ残す | 161 entry を救済、最後の 1 件が `[incomplete]`(7,216 byte) | 698 ms |
| central directory の 200 byte 手前で切る | 200 entry すべて完全 | 872 ms |
| 最後の entry から 1 MB を削る | 200 entry、最後が `[incomplete]` で **1,024,545 byte** | 894 ms |

最後の行の 1,024,545 byte は原本 `page199.jpg` の先頭と SHA-256 が一致する
(`8db4bf3ad8…`)。

`RecoveryDecompressor` は切断を正常終端へ変換するために 1 byte ずつ読むが、
これが使われるのは **不完全な entry だけ**で、完全な entry は従来どおりの経路を通る。
1 MB の部分救済に要した増分は 872 → 894 ms、およそ 45 MB/s である。
破損書庫の救済経路としては十分で、通常の展開性能には影響しない。

## 併せて直した検出の誤り

先頭 1 KiB が 0 のファイルを「空の tar」として受理していた挙動を止めた。
tar と判定するには checksum の通る member header を 1 つ以上要求する。
ISO 9660(先頭 32 KiB が全 0 の system area)が tar と誤判定されて
0 件で成功する問題の直接の原因だった。

## 安全側の設計 — 救済フラグの内側に閉じ込める

救済のために入れた「宣言サイズを実ファイル長で切り詰める」処理は、当初
`recoverDamagedArchives` の外側にあった。既定経路では手前の検証が先に
`truncated` を投げるため実害は観測されなかったが、それは**偶然の順序**に
依存した安全性で、検証順序を変えた瞬間に崩れる。次の 3 箇所を
フラグの内側へ移し、「フラグが false なら `isIncomplete` は決して立たない」
という不変条件を構造で保証するようにした。

- `LHAHeaderParser`: `compressedSize` の切り詰め
- `TarReader`: `isIncomplete` の判定と `Record.size` の切り詰め

移動前後で挙動が変わらないことを、header は無傷で payload の途中だけを
切った LHA を新たに作って確認した(既存の t60 系は後続 header の途中で
切れるため、この経路を踏まない)。

| | 既定(strict) | `recoverDamagedArchives` |
|---|---|---|
| header 無傷・payload 切断の LHA | `The archive is truncated` | 2 entry、末尾が `[incomplete]`(58,001 byte) |

## 暗号化書庫での再確認

不完全な entry では CRC-32 / WinZip AES の HMAC / MacBinary の CRC-16 を
すべて飛ばす。飛ばすこと自体は救済に必要だが、**黙って飛ばすと利用側が
検証済みと誤解する**ため、`ReaderOptions.recoverDamagedArchives` と
`ArchiveEntry.isIncomplete` の doc に「整合性検証を行わず、暗号化 entry から
救済した byte は認証されていない」と明記した。

そのうえで、変更が暗号化経路の既定動作を壊していないことを実測した。

| 確認 | 結果 |
|---|---|
| 暗号化書庫 6 件(7z-aes / 7z-headerenc / rar4-enc / rar5-headerenc / zip-aes256 / zip-zipcrypto)の strict と救済の一致 | **6/6 完全一致** |
| 健全な書庫 95 件の strict と救済の一致 | **95/95 完全一致** |
| 不完全な AES entry を誤ったパスワードで読む | 全 entry が `The password is incorrect`(2 byte の verifier は切断後も残るため、救済でも認証は素通りしない) |
| 不完全な AES entry を正しいパスワードで読む | 37,794 byte を救済、`5d8f19d32b…` は原本 `c.rnd` の先頭 37,794 byte と**一致** |

暗号化された不完全 entry でも、返るのは原本の正しい prefix であってごみではない。

## tar の検出条件を構造だけに絞る

検出用の `isPlausibleMemberHeader` が mode/uid/gid/size/mtime まで解析して
いたため、size フィールドが意図的に壊れた tar が「未対応形式」に化けて
`malformed` の診断を失っていた。検出は 512 byte・パス名が非空・checksum が
通ることだけを見るようにし、数値フィールドの妥当性は従来どおり parser の
責務に戻した。`TarHardeningTests.testOctalSizeRejectsDigitsAfterNULTerminator`
がこの退行を捉えている。

## 最終確認

- `swift build -c release` 成功
- `swift test` 終了コード **0**、651 test / 0 failure(33 skip)
- 先頭 4 KiB が 0 のファイル・ISO 9660 とも `Unsupported archive format`
  (以前は「空の tar」として 0 件で成功していた)。健全な tar は 7 entry で回帰なし

## 残る差 — RAR5 の切り詰め

今回の救済は ZIP / tar / LHA が対象で、**RAR5 は未対応のまま**である。

| 書庫 | KaitoKit(救済有効) | XADMaster |
|---|---|---|
| rar5 を 90 / 60 / 30% に切り詰め | いずれも `The archive is truncated` | 5 entry(`c8261f1296…`) |

3 段階の切り詰めで XADMaster の総合 SHA-256 が同じになるのは、この書庫では
非圧縮性の `c.rnd`(40,000 byte)が容量の大半を占め、どの切断点も `c.rnd` の
内側に落ちるためである。XADMaster が返すのは手前の 4 entry の完全な内容と、
`c.rnd` の **0 byte** で、部分救済をしているわけではない。したがって RAR5 に
同じ経路を入れれば、KaitoKit は ZIP / LHA と同様に XADMaster を上回れる見込みが
ある。作業単位として分離した(bead を参照)。

---

# RAR5 の切り詰め救済(追補)

ZIP / tar / LHA に続いて RAR5 を救済対象に加えた。オラクルは XADMaster の
実行ファイルの入出力のみ。RAR5 の block 構造は RARLab の RAR 5.0 technote だけを
使って解析した。

## 構造の把握

`full.rar`(RAR5 / -m3 / 非 solid / 40,594 byte)。

| block | header | data | packed |
|---|---|---|---|
| main | 8..25 | — | 0 |
| `b.bin` | 25..67 | 67..379 | 312(60,000 を圧縮)|
| `a.txt` | 379..421 | 421..473 | 52(9,200 を圧縮)|
| `c.rnd` | 473..515 | 515..40515 | 40,000(非圧縮性)|
| service | 40515..40586 | 40534..40586 | 52 |
| end marker | 40586..40594 | — | 0 |

packed data が header 直後にインラインなので、切断は必ず**最後に到達した block**
に落ちる。よって不完全 entry は常に最後の published entry になり、solid の
復号状態を共有する経路(`SolidCoordinator` / `makeSolidVerifiedStream`)を
一切変更せずに済む。

当初の bead は「90/60/30% に切り詰めた 3 書庫」でしか測っておらず、3 つとも
同じ digest になる理由を説明できていなかった。byte 単位で切断点を指定して
測り直した結果、非圧縮性の `c.rnd` が容量の大半を占めるためどの切断点も
`c.rnd` の内側に落ちていただけだと分かった。

## 切断点ごとの結果

| 切断 byte | KaitoKit(救済 ON) | XADMaster | 判定 |
|---:|---|---|---|
| 40,515(end marker のみ欠落)| 3 entry 完全 `51251bfa73…` | 同一 | **無傷と完全に同じ** |
| 20,515(`c.rnd` の途中)| 2 entry + `c.rnd` を **20,000 byte** 救済 | `c.rnd` は **0 byte** | **上回る** |
| 600 | 2 entry + `c.rnd` を **85 byte** 救済 | **0 byte** | **上回る** |
| 490(`c.rnd` の header 途中)| 2 entry 完全 `3060f071eb…` | 同一 | 一致 |
| 450(`a.txt` の途中)| 1 entry + `a.txt` 0 byte `af36d015f7…` | 同一 | 一致 |
| 200(`b.bin` の途中)| `b.bin` 0 byte のみ `cd372fb851…` | 同一 | 一致 |

**XADMaster は切れた entry を一度も部分救済しない**(常に 0 byte)。
KaitoKit は stored 相当の entry では部分救済でき、圧縮 entry では最初の block が
揃わないため 0 byte になる(XADMaster と同じ)。

「end marker だけ欠落」は、データは全部あるのに従来は**全件を失っていた**
ケースで、実害としては最大だった。

## solid

格納順 b.bin → c.rnd → a.txt の `-s` 書庫。

| 変種 | KaitoKit | XADMaster | 判定 |
|---|---|---|---|
| 無傷 | 3 entry `20ea442832…` | 同一 | 一致 |
| 中央で切断 | `b.bin` 完全 + `c.rnd` は一覧に出るが読むと `truncated` `af36d015f7…` | 同一 | **総合 digest が一致** |
| 末尾 80 byte 欠落 | `b.bin`/`c.rnd` 完全 + `a.txt` 同上 `478888093d…` | 同一 | **一致** |

solid 群では復号状態が連続するため、切れた member を部分救済すると後続の出力が
壊れる。よって切れた member は `isIncomplete` として一覧には出すが、読むと
`truncated` を投げる。XADMaster が 0 byte を返すのと結果は同じで、総合 digest も
一致する。

## 暗号化書庫の切り詰め

`-ppw`(データ暗号化)と `-hppw`(ヘッダ暗号化)で作り、最後の entry の
内側で切ったもの。**16 byte 境界に揃えた切断も含めて**確認した。

| 確認 | 結果 |
|---|---|
| 正しいパスワード + 救済 | 切断前の entry は完全に復号でき、切れた entry は **0 byte + `truncated`** |
| 誤ったパスワード + 救済 | データ暗号化は全 entry が `The password is incorrect`、ヘッダ暗号化は書庫全体が同エラー |
| 16 byte 境界で切断 + 誤パスワード | 同上。**ごみを返す経路は無い** |
| 救済 OFF | 従来どおり `The archive is truncated` |

RAR5 では、暗号化された不完全 entry は**認証されない byte を返さず、何も返さない**。
ZIP の WinZip AES が部分 byte を返す(認証なし)のとは異なり、こちらの方が
安全側に倒れている。password verifier は救済モードでも素通りしない。

## 多巻は救済しない(意図的な差)

| 状況 | KaitoKit | XADMaster |
|---|---|---|
| 全巻あり | 3 entry `51251bfa73…` | 一致 |
| part2/part3 を削除 | **`truncated`(救済 ON でも)** | part1 に収まる 2 entry を返す |

XADMaster は多巻の欠落を切り詰めと同じに扱うが、KaitoKit は救済しない。
次巻へまたがる entry を「完全」と偽らないことを優先した。`.volume` フラグの
立った書庫が救済停止した場合は従来どおり失敗させるため、`RARVolumeLocator` /
`mergeSplitParts` / `activeSplit` は救済経路から到達不能になる。

## 規模と速度(40MB / 20 entry)

非圧縮性 2MB × 20 = 41,945,353 byte。すべて `-m0`(stored)。

| 変種 | 結果 | 時間 |
|---|---|---:|
| 無傷 | 20 entry `b65637540a…` | 15〜24ms |
| 末尾 8 byte 欠落 | 20 entry、**無傷と同一の digest** | 15ms |
| 末尾 1MB 欠落 | 19 entry 完全 + `page19.bin` を **1,098,419 byte** 救済(原本の先頭と一致)| 295〜300ms |

XADMaster は同じ書庫で `page19.bin` を 0 byte で返す。

**部分救済の速度は現状 3.9 MB/s で、ZIP の約 50 MB/s に対しておよそ 13 倍遅い。**
原因は `RecoveryDecompressor` が 1 byte ずつ読む点にある。ZIP では inflate の
内部バッファから 1 byte を取り出すだけだが、RAR5 の stored entry では
`CopyDecompressor` 経由で毎回 `ByteSource` に触れるため割高になる。
不完全 entry にしか使わない経路なので機能上の問題は無いが、実測値として記録する。

## 既定動作が変わっていないことの確認

| 確認 | 結果 |
|---|---|
| 健全な書庫 95 件の strict と救済の一致 | **95/95** |
| 暗号化書庫 6 件の strict と救済の一致 | **6/6** |
| 禁止領域(RAR4Reader / RAR29Decoder / RARStandardFilters / RARPPMdRangeDecoder)| すべて HEAD と同一 |
| `SolidCoordinator` / `makeSolidVerifiedStream` | 差分なし |
| `swift build -c release` / `swift test` | BUILD=0 / TEST=0、662 test・0 failure(33 skip)|

`Checked.size(record.packedSize, limit: limits.maxEntrySize)` は**宣言値**を見続ける。
宣言サイズをその場で切り詰めると資源上限が黙って緩むため、ZIP と同じく
`availablePackedSize` を別に持つ形にした(`RAR5RecoveryTests`
`testRecoveryPreservesDeclaredPackedSizeLimit` がこれを固定している)。
