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
