# 新規 6 形式の安全性と展開性能の検証

対象は 2026-09-09 に追加した ISO 9660(`a1a2753`)、cpio(`94bc3f5`)、ar(`4466c30`)、
xar(`deed11d`)、RPM(`975cde6`)、CAB(`efb978b`)。既存の各形式の検証記録は
「XADMaster との出力一致」と「異常入力を具体的な診断で止めること」を扱っており、
**スループットは測っていなかった**。本記録はその空白を埋め、実測で見つかった非効率を直す。

計測機は Apple Silicon / macOS 27.0、release ビルド(`swift build -c release`)。
コーパス生成と計測の要点は §7 に置く。

## 1. コーパス

現実の書庫はリポジトリに含めないため、同じ内容を 6 形式へ詰め直した合成コーパスを使う。
cooViewer の想定(中サイズの page を多数持つ書庫)と、純粋な展開スループットの
両方が見えるように 3 形を用意した。

| 形 | 内容 | 目的 |
| --- | --- | --- |
| `many` | 256 KiB × 200 file = 50 MiB | solid folder の再展開が効く形。cooViewer の実利用に最も近い |
| `big` | 64 MiB × 1 file | 純粋な展開スループット |
| `tree` | 512 byte × 5,000 file を深さ 3 の木に配置 | 一覧・metadata 経路 |

素材は擬似ランダムではなく語彙 512 語の反復文にした。乱数列は圧縮率が 1.0 に張り付き、
deflate / MSZIP の実挙動が出ないため。

## 2. 基準値(変更前)

`kaito bench <archive> 3` の中央値。`entries` は `kaito list` の行数。

| 書庫 | byte | entry | open ms | extract ms | 出力 byte |
| --- | ---: | ---: | ---: | ---: | ---: |
| cab-big-mszip.cab | 13,393,304 | 1 | 1.075 | 43.664 | 67,108,864 |
| cab-many-mszip.cab | 10,468,043 | 200 | 1.464 | **6,399.998** | 52,428,800 |
| cab-many-stored.cab | 52,447,444 | 200 | 1.476 | **1,291.794** | 52,428,800 |
| iso-big.iso | 67,483,648 | 1 | 1.216 | 4.505 | 67,108,864 |
| iso-many.iso | 52,826,112 | 200 | 1.664 | 3.676 | 52,428,800 |
| iso-tree.iso | 11,872,256 | 5,110 | 13.680 | 3.360 | 2,560,000 |
| cpio-big.cpio | 67,109,376 | 1 | 0.104 | 4.451 | 67,108,864 |
| cpio-many.cpio | 52,454,912 | 200 | 0.562 | 3.657 | 52,428,800 |
| cpio-tree.cpio | 3,233,792 | 5,111 | 11.776 | 3.313 | 2,560,000 |
| ar-big.a | 67,108,932 | 1 | 0.093 | 4.469 | 67,108,864 |
| ar-many.a | 52,440,808 | 200 | 0.308 | 3.700 | 52,428,800 |
| ar-flat.a | 3,070,068 | 5,000 | 5.525 | 3.244 | 2,560,000 |
| xar-big.xar | 12,301,889 | 1 | 0.464 | 53.742 | 67,108,864 |
| xar-many.xar | 9,756,380 | 200 | 12.021 | 43.989 | 52,428,800 |
| xar-many-stored.xar | 52,440,323 | 200 | 11.773 | 21.375 | 52,428,800 |
| xar-tree.xar | 1,161,750 | 5,110 | **291.460** | 75.911 | 2,560,000 |
| rpm-big.rpm | 12,736,596 | 1 | 39.094 | 4.657 | 67,108,864 |
| rpm-many.rpm | 9,972,403 | 200 | 25.584 | 2.418 | 52,428,800 |
| rpm-manystored.rpm | 52,455,169 | 200 | 6.340 | 2.468 | 52,428,800 |

同じ 50 MiB を持つ cpio / ar / ISO が 3.7 ms 前後で展開できるのに対し、CAB だけが
1,292 ms(stored)と 6,400 ms(MSZIP)で桁が違う。xar の open も、同じ entry 数の
ISO(13.680 ms)と cpio(11.776 ms)に対して 291.460 ms と 20 倍以上ある。
この 2 点が本記録の主題である。

## 3. CAB — solid folder の展開が entry 数の二乗になる

### 3.1 原因

`EntryStream.verifyCompletion()` は復号器が終端に達したことを確かめるため 1 byte
読みを出す。`MSZIPDecompressor.read` はその要求に対し、**folder に残る全 CFDATA を
inflate して**から 0 を返す。「folder 全体の CFDATA checksum を確定する」ためである。
加えて復号は常に block 0 から始まるので、entry *i* を取り出すには手前の block も
毎回やり直す。結果、1 folder に N entry があると N × folderSize の仕事になる。

モデルは 200 × 50 MiB ÷ 1.5 GB/s = 6.6 秒。実測 6.4 秒で一致する。

### 3.2 二乗であることの決定的な確認

総量を 32 MiB に固定したまま file 数だけ変えた。総量が同じなら、線形なら時間は一定、
二乗なら N に比例する。

| 1 folder あたりの file 数 | stored 展開 ms | MSZIP 展開 ms |
| ---: | ---: | ---: |
| 10 | 44.474 | 245.806 |
| 25 | 110.841 | 628.099 |
| 50 | 207.986 | 1,245.586 |
| 100 | 409.780 | 2,419.518 |
| 200 | 825.070 | 4,892.468 |

N を 20 倍にすると時間も 18.6 倍(stored)/ 19.9 倍(MSZIP)。**総量一定で N に比例する**、
つまり file 数に対して二乗である。

### 3.3 同じ原因による data 損失(こちらが本題)

性能を調べる過程で、同じ経路がもっと重い問題を起こしていることが分かった。
folder 全体を復号してその結果を entry の成否に反映しているため、
**folder 内の 1 block が壊れると、その folder の全 file が読めなくなる。**

`cab-many-mszip.cab`(200 file / 1 folder / 1600 block)の**最終 block だけ**を
2 通りに壊し、3 実装の出力を比べた。

**(a) 末尾 1 byte を反転する(その block の CFDATA checksum が合わなくなる)**

| 実装 | 結果 |
| --- | --- |
| KaitoKit(現行) | **全 200 entry** が `Checksum mismatch` |
| cabextract(libmspack) | `page0199.txt` だけ `checksum error`。0〜198 は byte 一致で取り出せる |
| XADMaster | 200 file すべて取り出す(CFDATA checksum を見ていない) |

**(b) checksum を保ったまま最終 block の DEFLATE を壊す**

CAB の checksum は little-endian 32-bit word の XOR 畳み込みなので、4 byte 離れた
2 byte の同じ bit を反転すれば値は変わらない。改変後に stored == computed
(`c8189702`)であることを確かめてから測定した。

| 実装 | 結果 |
| --- | --- |
| KaitoKit(現行) | **全 200 entry** が `cab MSZIP block stream` |
| cabextract | `page0199.txt` だけ `decompression error`。0〜198 は byte 一致 |
| XADMaster | 0〜198 は byte 一致。`page0199.txt` は 229,376 byte で切り詰め |

独立した 2 つのオラクルが揃って「壊れた block に重なる file だけを落とす」。
KaitoKit は救えるはずの 199 file を捨てている。cooViewer から見ると、
1 block 壊れた cab は 1 page も表示できず、fallback の XADMaster に切り替われば
199 page 見える、という差になる。

### 3.4 したがって契約を変える

`CabReaderTests.testChecksumsAreFinalizedForSlicesAndEmptyFilesAndZeroIsSkipped` は
現行の「folder 全体を 1 つの成否にまとめる」挙動を意図的に固定していたが、
§3.3 の比較はそれが誤りだったことを示している。契約を

> entry は **自分が消費する block だけ**で検証する

に改める。これは二乗性の解消と同じ変更で同時に達成される。修正は
`cooViewer-9qvh.1`(二乗)と `cooViewer-9qvh.6`(data 損失)の両方を閉じる。

**対照(他の solid 形式は健全)**: 同じ 100 file を 1 つの solid stream に持つ 7z を作り、
末尾から 2,000 byte 手前を壊した。KaitoKit は `page0099.txt` だけを
`LZMA output exceeds the expected size` で落とし、0〜98 は byte 一致で取り出した
(XADMaster も同じ)。つまりこの取りこぼしは solid 形式一般の設計ではなく、
CAB reader 固有である。

なお `[MS-CAB]` の CFDATA checksum は**圧縮 byte**に対する値であり
(`CabDataBlock.computedChecksum` も生の block data を取る)、消費しない block の
検証に inflate は要らない。今回はその block 自体を触らない契約にしたため、
この性質は境界 block の扱いにだけ効く。

## 4. xar — open の 68% が `NSDateFormatter`

`sample` を 6 秒、`kaito bench xar-tree.xar` に当てた。open の 2,734 sample のうち
**1,874** が `XarReader.swift:97` の `-[NSDateFormatter dateFromString:]`。

```
1874 XarReader.init(source:options:)  XarReader.swift:97
| 1874 -[NSDateFormatter dateFromString:]
|   1872 -[NSDateFormatter getObjectValue:forString:errorDescription:]
|   + 1849 getObjectValue
|   + ! 1848 CFDateFormatterCreateDateFromString
|   + ! : 1484 CFDateFormatterGetAbsoluteTimeFromString
|   + ! : | 1484 udat_parseCalendar
|   + ! : |   1028 icu::SimpleDateFormat::parse
|   + ! : |   + 1027 icu::DateFormatSymbols::loadAllSymbols
```

`DateFormatSymbols::loadAllSymbols` が 1,027 sample を占めている。ICU が entry ごとに
日付シンボルを読み直しており、これが xar の open を支配していた。round-trip 検証の
`string(from:)` も別に 40 sample ある。

xar の `mtime` は `yyyy-MM-ddTHH:mm:ss` + 任意の `Z` という固定形なので、桁を直接読めば
`DateFormatter` も `Calendar` も要らない。ただし現行は非 lenient formatter の round-trip で
月 13 や 2 月 30 日を弾いているため、自前 parser も同じ範囲検査を持たなければならない。

## 5. ISO — finalize の String 照合

`iso-tree.iso` の open profile(3,211 sample):

| 箇所 | sample | 比率 |
| --- | ---: | ---: |
| `ISOReader.swift:300` `name.contains("/")` | 282 | 8.8% |
| `ISOReader.swift:299` `precomposedStringWithCanonicalMapping` | 103 | 3.2% |
| `FormatDetector.detect`(うち LHA SFX 走査 127) | 278 | 8.7% |

Foundation の `StringProtocol.contains` は `range(of:options:range:locale:)` 経由で
Unicode 照合を行う。`/` は単一の ASCII byte で、UTF-8 の後続 byte に 0x2F は現れないため、
byte 走査に置き換えても偽陽性は起き得ない。NFC 正規化も、名前が ASCII だけなら恒等である。

`FormatDetector` の SFX 走査は 6 形式に限らない横断的なコストなので別件とした
(`cooViewer-9qvh.5`)。直接測ると、detect 1 回の増分は 391 KB の ISO で約 0.37 ms、
1 MiB で頭打ちになる 11.9 MB の ISO で約 1.10 ms(iso-tree.iso の open 11.3 ms の約 10%)。
cpio は走査に到達しないため 0。走査を無くすには構造 magic を先に見る順序変更が要り、
これは SFX の優先順位という判定意味論を全形式で変えるため、今回は触っていない。
意味論を変えずにループだけを速くする余地(約 1.1 ms → 0.1 ms)はあるが、共有コードの
変更に対する全再検証の費用に見合わないと判断した。NAS 上では CPU ではなく 1.1 MB の
先読み I/O が効くため、そちらは順序変更でしか消せない。

## 6. 安全性

### 6.1 変異入力(ASan / UBSan)

6 形式の種書庫 8 個(cab-mszip / cab-stored / iso-rr / cpio-newc / cpio-odc / ar / xar / rpm)から
`Scripts/fuzz/run-mutants.sh --count 3000 --timeout 5` を実行。

```
generated 3000 mutants from 8 seed(s)
mutants: 3000, crashes: 0, hangs: 0, sanitizer findings: 0
```

各形式の実装時は 200〜350 件だったので、今回は約 10 倍の規模で追試したことになる。
修正後は多 block の CAB(`cab-multi` / `cab-multistored` / 末尾を壊した
`cab-multi-damaged`)を種に加えた 11 seed で再実行し、結果は同じ(§8.6)。

### 6.2 展開先からの脱出

6 形式それぞれについて、脱出を狙う書庫を自作して `kaito extract` に与えた。
canary を置いた隣接ディレクトリと `/tmp` を検査対象にした。

| 書庫 | 仕掛け | 結果 |
| --- | --- | --- |
| evil-dotdot.cpio | `../escaped.txt` | malformed: entry path contains an unsafe component |
| 同上 | `/tmp/escaped-absolute.txt` | malformed: absolute or empty entry path |
| 同上 | `a/b/../../../escaped-mid.txt` | malformed: entry path contains an unsafe component |
| evil-symlink.cpio | symlink `hop` → `/tmp`、続けて `hop/…` へ書き込み | malformed: link target is missing or absolute。`hop` は通常ディレクトリとして作られ、子はその中に留まる |
| evil-dotdot.a | `../escaped-ar.txt`(string table 経由)/ 絶対パス | いずれも拒否 |
| evil-dotdot.cab | `..\..\escaped-cab.txt`(backslash 区切り) | `/` へ正規化した上で unsafe component として拒否 |
| evil-dotdot.xar | `<name>..</name>` 配下の file、symlink `hop` → `/tmp` | いずれも拒否 |
| evil-symlink.iso | Rock Ridge symlink `../../../etc/passwd` と `/tmp` | symbolic-link target escapes the extraction directory / link target is missing or absolute |

**canary は無傷、`/tmp` への書き込みは 0 件。** symlink を拒否した後に同名の通常
ディレクトリが作られる経路も確認し、それが symlink でないことを `-L` 検査で確かめた。

### 6.3 XADMaster との内容一致(健全な書庫)

コーパスの各書庫について、`kaito sha` と XADMaster ベースの `xadsha` の
「size + 各 entry の SHA-256」を突き合わせた。

| 書庫 | 判定 |
| --- | --- |
| cab-many-mszip / cab-many-stored / cab-big-mszip | 一致 |
| iso-many / iso-tree | 一致 |
| cpio-many / cpio-tree | 一致 |
| ar-many / ar-flat | 一致 |
| xar-many / xar-tree | 一致 |
| rpm-many | **意図的な差**。XADMaster は payload を `many.cpio.gz` 1 件として出す。KaitoKit は cpio を展開して 200 件を出す |

### 6.4 複雑度

| 検査 | 結果 |
| --- | --- |
| ISO 101,100 entry の open | 272.896 ms(5,110 entry で 13.680 ms。1 entry あたり 2.7 → 2.7 µs で線形) |
| cpio 101,101 entry の open | 247.707 ms(同じく線形) |
| xar hardlink の相互参照(a→b→a、c→c) | 0.01 秒で一覧。解決 queue は実体 file からのみ始まるので循環に入らない |
| xar hardlink 5,000 段の連鎖 | 0.02 秒 |

### 6.5 RPM の payload 展開量

RPM は cpio payload に random access するため、open の時点で payload 全体を
`SingleFileMaterializer` で展開する(64 MiB を超えると unlink 済み一時 file へ退避)。
これは `.tar.gz` と同じ設計判断だが、増幅率を実測しておく。

| 入力 | 宣言サイズ | `kaito list` の結果 | 所要 |
| --- | --- | --- | --- |
| 1,043,995 byte の rpm | 1 GiB | 一覧を返す(peak memory 72 MB、残りは一時 file) | 0.35 秒 |
| 5,218,500 byte の rpm | 5 GiB | `Read limit exceeded: entry size` | 1.69 秒 |

上限(既定 `maxEntrySize` = 4 GiB)で確実に止まり、crash も disk 溢れも起きない。
ただし **1 MB の入力が 1 GB の一時書き込みを起こす**増幅は残る。既定のままで
危険はないが、cooViewer のように一覧しか要らない用途では `ReadLimits.maxEntrySize` を
絞る余地がある(cooViewer は現在すべて既定値を使っている)。

## 7. 再現手順

`<work>` は任意の作業ディレクトリ、`<kaito>` は release ビルドの CLI。
素材は §1 のとおり `many`(256 KiB × 200)、`big`(64 MiB × 1)、
`tree`(512 byte × 5,000 を深さ 3 に配置)の 3 ディレクトリ。

```sh
# CAB(gcab は 1 folder に全 file を詰めるので solid の再展開コストがそのまま出る)
(cd many && gcab -c -z <work>/cab-many-mszip.cab page*.txt)
(cd many && gcab -c    <work>/cab-many-stored.cab page*.txt)
(cd big  && gcab -c -z <work>/cab-big-mszip.cab big.txt)

# ISO(Rock Ridge + Joliet)
xorriso -as mkisofs -quiet -R -J -o <work>/iso-many.iso many

# cpio / xar
(cd many && find . -type f | sort | cpio -o -H newc --quiet > <work>/cpio-many.cpio)
(cd many && xar -c -f <work>/xar-many.xar .)
```

macOS の `ar(1)` は非 Mach-O の member を黙って捨てるため、ar は自前で書いた
(`!<arch>\n` + SysV の `//` string table + 60 byte header)。RPM も同様に
lead 96 byte + signature header + main header + gzip 圧縮 cpio payload を自前で組んだ。

計測と検証:

```sh
<kaito> bench <archive> 3          # open / extract の中央値
<kaito> sha   <archive>            # 全 entry の SHA-256(出力同一性の判定に使う)
<kaito> extract <archive> -o <dir> # 展開先脱出の検査
```

XADMaster をオラクルにする場合は cooViewer の `Scripts/bench/xadsha.swift` を使う。

```sh
xcrun swiftc -O Scripts/bench/xadsha.swift -F <cooViewer>/Frameworks \
    -framework XADMaster -Xlinker -rpath -Xlinker <cooViewer>/Frameworks -o xadsha
```

`kaito sha` と `xadsha` は同じ行形式なので、`total` 行を落として size と digest の列を
突き合わせれば内容一致を判定できる。

出力の同一性は `kaito sha` の全 entry digest を変更前後で比較して確かめる。
変更前の値:

```
cab-big-mszip.cab   b7bfe0bbaf2cbf07
cab-many-mszip.cab  cc4ac09d2eaf1571
cab-many-stored.cab cc4ac09d2eaf1571
iso-tree.iso        04d72ae4f374743e
iso-many.iso        cc4ac09d2eaf1571
xar-tree.xar        f9cee754555b310d
xar-many.xar        5c0fe15baf83d676
```

## 8. 修正後の実測 — CAB

`MSZIPDecompressor` を folder 単位の前進復号器に作り替え、`CabReader` に RAR5 の
`SolidCoordinator` と同じ形の folder 復号器 cache(世代番号で古い stream を無効化する)を
置いた。合わせて `inflateInit2_`/`inflateEnd` の block ごとの往復を 1 つの `z_stream` の
`inflateReset` に、`history = Array((history + output).suffix(32768))` の二重確保を
末尾切り出しだけにし、圧縮 block と出力 block の buffer を使い回した。

### 8.1 展開時間

| 書庫 | 変更前 ms | 変更後 ms | 倍率 |
| --- | ---: | ---: | ---: |
| cab-many-mszip.cab(200 file / 1 folder) | 6,844.092 | 32.403 | **211.2x** |
| cab-many-stored.cab(200 file / 1 folder) | 1,357.818 | 8.055 | **168.6x** |
| cab-big-mszip.cab(1 file / 64 MiB) | 46.755 | 40.628 | 1.2x |

単一 file の 1.1 倍は §8 冒頭の block ごとの往復を外した分。50 MiB を 200 file に
分けた MSZIP が 32.4 ms になり、64 MiB を 1 file で持つ 41.7 ms と同じ水準に並んだ。

### 8.2 二乗性の解消

§3.2 と同じ、総量 32 MiB 固定で file 数だけ変えた測定:

| 1 folder あたりの file 数 | stored 展開 ms | MSZIP 展開 ms |
| ---: | ---: | ---: |
| 10 | 5.773 | 23.604 |
| 25 | 5.177 | 23.198 |
| 50 | 6.529 | 23.333 |
| 100 | 6.361 | 23.282 |
| 200 | 5.698 | 23.705 |

**file 数に依存しなくなった。** 変更前は 10 → 200 で 18.6 倍 / 19.9 倍だった。

### 8.3 破損書庫の救済(§3.3 の再測)

| fixture | 変更前 | 変更後 |
| --- | --- | --- |
| cab-lastbyte.cab(末尾 1 byte、checksum 破損) | 全 200 entry が失敗 | **199 entry を救済**、`page0199.txt` だけ `Checksum mismatch` |
| cab-lastblock-deflate.cab(checksum 保持・DEFLATE 破損) | 全 200 entry が失敗 | **199 entry を救済**、`page0199.txt` だけ `cab MSZIP block stream` |

cabextract および XADMaster と同じ局所化になった。

### 8.4 健全書庫の出力同一性

| 書庫 | digest | 期待値と一致 |
| --- | --- | --- |
| cab-many-mszip.cab | `cc4ac09d2eaf1571` | 一致 |
| cab-many-stored.cab | `cc4ac09d2eaf1571` | 一致 |
| cab-big-mszip.cab | `b7bfe0bbaf2cbf07` | 一致 |

### 8.5 残る限界(意図して受け入れたもの)

**(a) 履歴 block の checksum は検証しない。** MSZIP では entry の手前の block も
辞書再構築のために復号するが、その CFDATA checksum は entry の成否に反映しない。
消費 block だけで判定することで、読み出し順に依らず結果が決まるためである。

履歴 block まで検証すると順序依存が生じるだけでなく、**§3.3 の data 損失がそのまま
戻ってくる**。coordinator は例外時に復号器を捨てる(`decoder = nil`)ので、block 5 の
破損で page0000 が失敗すると復号器が破棄され、page0001 は block 0 からやり直して
再び block 5 を履歴として復号し、また失敗する。以下同様に全 entry が失敗する。
つまり履歴 block の検証は「1 block の破損で folder 全滅」を復活させる。

この選択の残余risk を測った。`cab-many-mszip.cab` の block 5 の DEFLATE data に
1 byte 単位の反転を 8,000 通り加えたところ、

- inflate 自体が失敗(検出できる): 84 件
- inflate は成功するが宣言サイズと違う(`total_out` 検査で検出できる): 3,178 件
- 宣言サイズちょうどで内容だけ違う(checksum だけが検出できる): 4,738 件

の内訳になった。最後の 4,738 件のうち先頭 1,139 件について、次の block 6 を
汚染された辞書で復号し直した結果は **1,139 件すべてで block 6 の出力が不変**だった。
つまりこのコーパスでは、履歴 block の破損は後続 file の byte へ伝播していない。
伝播しうる書庫(block 境界をまたぐ長い後方参照を持つもの)では、後続 file が
無警告で異なる byte になる余地は残る。cabextract は復号した全 block を検証するので
この穴が無い代わりに、結果が読み出し順に依存する。

**(b) folder 内を後方へ跳ぶと block 0 から復号し直す。** solid 形式である以上
避けられない。順方向の読み出し(cooViewer の通常の page 送り)は cache が効く。

**(c) folder をまたぐと直前の復号器を捨てる。** 復号器 1 つあたり
`input`(64 KiB 予約)・`output`(32,769)・`history`(32,768)と zlib の inflate 状態で
約 170 KB を持つ。folder ごとに残すと、CFFOLDER 8 + CFDATA 8 + data 1 + CFFILE 17 で
1 folder あたり約 34 byte の書庫が作れてしまうため、3.4 MB の入力で 10 万 folder を
宣言すれば 17 GB 規模を保持できる。RAR5 の `activeSolidGroup` と同じく、活きている
folder の復号器だけを残し、切り替え時に世代を進めて解放する。folder を交互に読むと
遅くなるが、これは RAR5 と同じ割り切りである。

### 8.6 検証

| 項目 | 結果 |
| --- | --- |
| `swift test`(orchestrator が独立に実行、CAB 修正のみの時点) | 761 core(37 skip)/ 22 compat、**失敗 0**(151.7 秒) |
| ASan + UBSan 変異入力 3,000 件(11 seed。多 block の cab-multi / cab-multistored / cab-multi-damaged を追加) | crashes 0 / hangs 0 / sanitizer findings 0 |
| 展開先脱出の 6 形式 8 書庫(§6.2) | 全件拒否、canary 無傷、`/tmp` 汚染なし |
| XADMaster との内容一致(§6.3) | 変更前と同じく一致 |

## 9. 修正後の実測 — xar と ISO

### 9.1 xar の日時解析

`mtime` は `yyyy-MM-ddTHH:mm:ss` + 任意の `Z` という定型なので、その形かつ
**年が 1583 以上**のときだけ桁を直接読み、UTC の proleptic Gregorian で秒を算術計算する。
1583 年以降なら Foundation の `.gregorian`(1582-10-15 を境とする混合暦)と一致するため、
算術で厳密に同じ値になる。

それ以外(1582 年以前、5 桁の年、形が違う文字列)は従来どおりの `DateFormatter`
(`en_US_POSIX` / gregorian / UTC / 非 lenient / `string(from:)` の往復検査)へ落とす。
formatter は遅延生成なので、通常の書庫は 1 つも作らない。この二段構えにより
**入力ごとの挙動は完全に同一**で、現実の書庫だけが ICU の費用を払わなくなる。

同等性は差分 test で固定した。従来の formatter 経路を test 内に参照実装として置き、
**23,724 通り**の候補(各月の妥当日、閏 / 非閏の 2 月、`2023-02-29`、`2024-02-30`、
月 0 / 13、日 0 / 32、時 24、分 60、秒 60、`T` 欠落、区切り違い、18 / 20 文字、空、
非数字、`Z` 単独、前後空白、年 1500 / 1582 / 1583 / 10000)で両者が一致することを確かめる。

### 9.2 ISO の名前検査

`name.contains("/")` を UTF-8 の byte 走査に置き換え、NUL 検査と 1 回の走査にまとめた。
`/` は単一 ASCII byte で UTF-8 の継続 byte に 0x2F は現れないため、偽陽性は起き得ない。
NFC 正規化は非 ASCII byte を含む名前だけに限った(全 ASCII では恒等変換)。

### 9.3 open 時間

| 書庫 | 変更前 ms | 変更後 ms | 倍率 |
| --- | ---: | ---: | ---: |
| xar-tree.xar(5,110 entry) | 299.416 | 84.322 | **3.55x** |
| xar-many.xar(200 entry) | 12.151 | 3.425 | 3.55x |
| xar-many-stored.xar | 12.023 | 3.361 | 3.58x |
| xar-big.xar(1 entry) | 0.511 | 0.200 | 2.55x |
| iso-tree.iso(5,110 entry) | 13.477 | 11.255 | **1.20x** |
| iso-many.iso(200 entry) | 1.802 | 1.644 | 1.10x |
| iso-big.iso(1 entry) | 1.233 | 1.290 | 0.96x |

`iso-big.iso` の 0.96x は 1 entry しかない書庫での測定ゆらぎ。

### 9.4 出力同一性

`kaito list` の出力には更新日時が入るので、その digest が日時解析の同等性そのものの
検査になる。9 書庫すべてで変更前と一致した。

| 書庫 | list digest |
| --- | --- |
| xar-tree.xar | `3c4896cfb640e241` |
| xar-many.xar | `acdab7167482d056` |
| xar-big.xar | `ca0a652dcc2b6184` |
| xar-many-stored.xar | `b601e3c3114fd452` |
| iso-tree.iso | `a99c68cea7807d7b` |
| iso-many.iso | `148b08738595dcc9` |
| iso-big.iso | `46881d2f6092f7c2` |
| xar.xar(seed) | `d072d46bd911df57` |
| iso-rr.iso(seed) | `e4a7b7329589bc45` |

内容 digest は **コーパスと seed の 27 書庫すべて**で変更前と一致した(§7 の
`digests-before.tsv` と突き合わせ)。CAB の変更と合わせた最終状態での確認である。

### 9.5 最終状態の検証

| 項目 | 結果 |
| --- | --- |
| `swift test`(orchestrator が独立に実行) | **764 core**(37 skip)/ 22 compat、**失敗 0**(155.1 秒) |
| ASan + UBSan 変異入力 3,000 件 / 11 seed | crashes 0 / hangs 0 / sanitizer findings 0 |
| 内容 digest 27 書庫 + 日時込み list digest 9 書庫 | すべて変更前と一致 |
| 展開先脱出の 6 形式 8 書庫 | 全件拒否、canary 無傷、`/tmp` 汚染なし |
