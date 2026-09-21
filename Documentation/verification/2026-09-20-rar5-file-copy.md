# RAR5 file copy（redirection type 5、`rar -oi`）の本文公開（2026-09-20）

環境: macOS 27.2 / Apple Silicon / RAR 7.23 / UNRAR 7.23（`unrar lt` で record 種別と target を確認）。

## 実装と範囲

- RAR 5.0 technote の file redirection record（type 5 = file copy）は本文を持たず、同一内容の
  file 名を target に持つ。従来は本文 0 の `.other` として公開し、展開は
  `unsupportedMethod("RAR5 file-copy redirection")` だった。
- 変更後は、target が**先行する通常 file**（`.file`、それ自身が file copy でない）に解決でき、かつ
  参照 header の宣言サイズが参照先の `uncompressedSize` と一致するときだけ、参照を `.file` として
  公開する。`uncompressedSize` は宣言サイズ、`compressedSize` は 0、`crc32` は nil（reference の
  header は CRC を持たない。`unrar lt` は `CRC32: 00000000`）、`methodDescription` は
  `RAR5 file copy`、`formatSpecific["fileCopyTargetIndex"]` が参照先 index。`isEncrypted` と
  `solidGroup` は参照先の値（読み取りは参照先の本文を復号するため）。
- `stream(entry)` は参照先 entry の stream をそのまま返す（参照先の CRC / BLAKE2sp 検証込み）。
  solid 書庫では参照は decoder の連鎖（`solidGroupMembers`）に加えず、参照先の group を
  名乗るだけにする。
- 解決できない参照（target 不在、後方参照、サイズ不一致、target が file でない）は従来どおり
  `.other`・本文 0・展開は `unsupportedMethod`。
- 合計展開上限（`maxTotalUncompressedSize`）と `maxEntrySize` は参照の出力にも掛かる。

実装入力は RAR 5.0 technote の file header / redirection record の記述と既存 RAR5Reader、
RAR 7.23 / UNRAR 7.23 の黒箱出力である。unrar / 7-Zip / libarchive の RAR5 source は開いていない。

technote は redirection record の type / flags / target 名しか定めず、**参照先が参照より前に
置かれること**も、**参照 header の Unpacked size / CRC32 に何が入るか**も述べていない。上の 2 つの
解決規則の出自は次の黒箱観察である（2026-09-21 に再確認）。

- 先行する参照先だけを解決する: RAR 7.23 `rar a -oi1:1` は列挙順にかかわらず先に処理した file を
  本体、後の file を参照として書く。自作の block 並べ替えで参照を参照先の前に置いた書庫は
  `unrar lt` / `unrar t` は通るが `unrar x` が "Cannot copy … You need to unpack the entire archive
  to create file reference entries" で失敗する。後方参照を解決しないのは UNRAR の展開規則と同じで、
  KaitoKit は `.other` のまま `unsupportedMethod` にする。
- 宣言サイズの一致を要求する: UNRAR は参照の Unpacked size を無視して参照先を複製する。
  `rar u` で参照先を 30,000 byte の別内容に差し替えた書庫は、参照の header が 20,000 のまま残り、
  UNRAR は新しい 30,000 byte を参照の名前でも書き出す（`rar d` / `rar rn` も参照を追随させない）。
  KaitoKit は宣言と参照先のサイズが違う参照を `.other` に留める。UNRAR より厳しい KaitoKit 固有の
  整合性検査で、technote に根拠は無い。

## 独立した検証データ

`Tests/Fixtures/rar5/file-copy{,-solid,-aes}.rar.b64`: project-owned の同一 text 3 本（a.txt、b.txt、
sub/c.txt、20,000 byte）と d.txt を `rar a -ma5 -m3 -oi1:1`（`-s` / `-pKaitoFixture` の変種）で
書いたもの。`unrar lt` で b.txt と sub/c.txt が `File reference`、Target `a.txt`、Size 20000、
Packed size 0 であることを確認。出自と SHA-256 は `Tests/Fixtures/NOTICE`。

## 通過した検証

- `RAR5FileCopyTests` 4 件、失敗 0: 3 fixture の種別・サイズ・暗号化・solid group・method 名・
  `fileCopyTargetIndex`、逆順 stream（chunk 4,099）と `reopen()` の byte 一致、AES 書庫で参照を
  password なしで読むと `passwordRequired`、合計上限の加算（60,018 で通り 60,017 で拒否）、
  `maxEntrySize` の参照への適用、rar 7.23 で生成した 150 KB 乱数 ×3 + 小 file の書庫（生成器が
  無ければ skip）。
- `RAR5ReaderTests`（更新 3 件を含む 37 件）、`RAR5RecoveryTests`（全 checked-in fixture の完全性、
  AES fixture は password 付き）、その他 RAR5 suite 計 53 件が通過。合成書庫の否定例は宣言サイズ不一致、
  target 不在、後方参照、参照の参照、directory record を target にする参照（すべて `.other`）と、同名の
  先行 entry が複数あるときに最後のものへ解決すること。
- release CLI: 300 KB 乱数 ×3 + 9 byte の plain / solid / AES 書庫で参照 2 本の SHA-256 が原本と一致。

```
$ kaito list oi.rar
0	300000	file	RAR5 stored	plain	a.bin
1	300000	file	RAR5 file copy	plain	b.bin
2	300000	file	RAR5 file copy	plain	sub/c.bin
3	9	file	RAR5 stored	plain	d.txt
```

## 残る制約

- 参照先が参照より後ろにある書庫（RAR 自身は書かない）と、`rar u` / `rar d` / `rar rn` の後で
  宣言サイズや target が合わなくなった参照は解決せず `.other` のままにする（上記）。
- 参照は参照先の stream を毎回復号する（内容の cache はしない）。solid 書庫で参照先が group の
  後方にあれば、参照の読み取りも group の先頭からの復号を伴う。
- 参照先が multi-volume で分割されている場合も参照先の解決規則（URL open のみ）に従う。
- `recoverDamagedArchives` でも解決規則は同じ。参照は本文を持たないので自身が切れることはなく、
  参照先の header が読めれば参照先と同じ結果（同じ部分出力・同じ error）を返す。RAR は参照 header を
  参照先の data の後ろに置くため、参照先の途中で切れた書庫では参照 header も失われ、参照は一覧に
  現れない。切れた first volume を持つ multi-volume は救済でも open できない（2026-09-21 に rar 7.23
  の plain / solid / `-v15k` 書庫を切り詰めて確認）。したがって `isIncomplete` な参照先を指す完全な
  参照は到達できず、参照の `isIncomplete` は参照先から引き継がない。
- `KaitoKitCompat` は `.file` として通常どおり公開する（`contents(ofEntry:)` は参照先の内容）。
