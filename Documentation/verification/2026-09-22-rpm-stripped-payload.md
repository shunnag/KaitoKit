# RPM stripped cpio `07070X` の検証（2026-09-22）

対象: 未リリース。作業場所は KaitoKit の `wt/rpm` worktree。
環境: macOS 27.2 / Apple Silicon、Apple Swift 6.4、rpm 6.1.0、zstd 1.5.7、
bsdtar 3.5.3（libarchive 3.7.4）。git commit / push、追加 install、Web 取得は行っていない。

## 入力と実装

形式入力は ruling 1 で許可済みの rpm.org manual prose と rpm 6.1.0 の黒箱出力だけ。
`inbox/rpm/SHA256SUMS` の 7 本はすべて `shasum -a 256 -c SHA256SUMS` で `OK`。
全文 hash と参照範囲は [design.md §10](../design.md) に記録した。
rpm / libarchive / 7-Zip / XADMaster 等の実装 source は開いていない。

`RpmHeader` は int16 / int32 / int64 / string 配列から `RpmFileList` を組む。
既存の store / index / record / `stringWork` 上限を維持し、per-file 配列は `maxEntryCount + 1` 以下、
件数一致と Dirindexes の範囲を検査する。LONGFILESIZES を優先し、無ければ FILESIZES を使う。
配列・復号文字列・結合名・group / record の保持量も Checked と ReadLimits で検査する。
RPMFORMAT が実在すれば `rpmFormat` に公開する。signature header の同番号 tag は収集しない。

`RpmStrippedPayload` は staging 済みの source と file list を使い、payload 順に record を作る。
非 ghost の通常 file を (dev, ino) でまとめ、最大 file index に本文、他に 0 byte を割り当てる。
directory / other は 0 byte、symlink は target 長。uid / gid は合成しない。
`rpmFileIndex` / `rpmFileDigest` / `rpmFileDigestAlgorithm` と nlink / ino / dev / linkPath を公開する。
`hardLinkGroup` は `<carrier の公開 entry index>:<dev>:<ino>`。SHA-256 は data を持つ member の
完全読取時に照合し、不一致は `checksumMismatch(entry:)`。他の algorithm は表示のみ。
raw stream と 0-byte placeholder は既存 EntryStream を使う。

未知・重複・ghost index、件数不整合、途中の trailer、非 NUL padding、末尾の余分な data は malformed。
足りない header / data / trailer は truncated。trailer は既存 CpioHeader の newc 解析で読み、
`TRAILER!!!`・本文 0 byte・全非 ghost member の出現・後続 NUL ≤ 512 byte を要求する。
名前は `/usr/...` → `./usr/...` として v4 newc と揃え、相対名と既存 `./` は保持する。
bare `07070X` の detector は変更しない。file list 不足・drpm・非 cpio の blob fallback は維持する。

## fixture と黒箱計測

生成器: [`generate-rpm6.sh`](../../Tests/Fixtures/container/generate-rpm6.sh)。
同一の自作 [`rpm-stripped.spec`](../../Tests/Fixtures/container/rpm-stripped.spec) を
v6 の既定 zstd level 19、v6 gzip、v4 gzip で build した。各 RPM は 40 KB 未満。
[`rpm-stripped-manifest.json`](../../Tests/Fixtures/container/rpm-stripped-manifest.json) に
package hash、query 出力、bsdtar 一覧、本文から算出した per-file SHA-256、stripped offset を保存した。
digest の原本は tag 値の転記ではなく `rpm2cpio` の本文と `bsdtar -xOf` の stdout である。
既存 `rpm-v6.rpm.b64` は変更せず、同じ手順で再確認した。

| fixture | byte | header / payload 件数 | payload |
| --- | ---: | ---: | --- |
| rpm-stripped-v6-zstd.rpm | 7977 | 12 / 10 | `07070X` / zstd 19 |
| rpm-stripped-v6-gzip.rpm | 8003 | 12 / 10 | `07070X` / gzip 9 |
| rpm-stripped-v4-gzip.rpm | 7727 | 12 / 10 | newc / gzip 9 |
| 既存 rpm-v6.rpm | 7417 | 6 / 6 | `07070X` / gzip 9 |

新 v6 の展開後は 10,916 byte。member header は 14 byte + NUL 2 byte、本文は 4-byte 境界まで NUL。
member の順は `0,1,5,6,11,2,3,4,7,8`、trailer は offset 10,792 から 124 byte で EOF になる。

| file index | header offset | data offset | data length | 種類 / 内容 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0 | 16 | 0 | directory |
| 1 | 16 | 32 | 0 | empty.txt |
| 5 | 32 | 48 | 10537 | large.txt |
| 6 | 10588 | 10604 | 13 | symlink → 日本語.txt |
| 11 | 10620 | 10636 | 25 | 日本語.txt |
| 2 | 10664 | 10680 | 0 | hard-a.txt |
| 3 | 10680 | 10696 | 0 | hard-b.txt |
| 4 | 10696 | 10712 | 18 | hard-c.txt（carrier） |
| 7 | 10732 | 10748 | 0 | partial-a.txt |
| 8 | 10748 | 10764 | 26 | partial-b.txt（carrier） |

ghost は index 9（partial-z-ghost.txt）と 10（standalone-ghost.txt）。9 は 7 / 8 と同じ dev / ino だが
payload に現れず、nlink は非 ghost の 2。通常の 3-member set の nlink は 3。
directory は省略されず index 0 の 0-byte member として現れる。既存 v6 にも directory が 2 件ある。
symlink の size は文字数でなく UTF-8 byte 数。本文は header target と一致した。

## 前提との差と検証範囲

利用者の黒箱 FACT 1〜6 は今回の fixture でも一致した。今回の spec は header 12 件なので、
提示されていた 8-member 例と payload 順の数列自体は異なる。directory の出現は上表で確認できる。

「既存 newc reader が許す後続 NUL は 512 byte まで」という前提は既存実装と異なる。
`CpioReader.maximumNULRun` は 1 MiB で、trailer 後の連結書庫も走査し、未知の末尾では読み止める。
今回は要求の厳密な RPM 終端を優先し、stripped だけを NUL ≤ 512 byte に制限した。
また既存 `CpioReader` の hardLinkGroup 先頭値は連結書庫番号（単体なら 0）。stripped では依頼どおり
carrier の公開 entry index とする。v4 / v6 で比較したのは名前・種類・本文長・mtime・mode・digest と nlink。

4 GB 超の実物 fixture は作っていない。64-bit size の保持と短い source の拒否は、LONGFILESIZES を
`2^32 + 10537` に変えた mutation で確認した。stripped の実物 codec は gzip / zstd、stored は再包装で確認。
bzip2 / xz は既存 classic RPM の回帰テストで確認し、lzma の新しい実物 fixture は追加していない。
per-file 配列上限は ghost も数える。この 12 件の fixture は `maxEntryCount=11`（+1 slack）で通り、10 では拒否する。

## 再実行コマンド

```sh
bash Tests/Fixtures/container/generate-rpm6.sh
swift build
swift test --filter Rpm
swift test --filter Cpio
swift test --filter ReleaseReviewDocumentationTests
for f in <decoded fixture rpms>; do
  .build/debug/kaito list "$f"
  .build/debug/kaito sha "$f"
  rpm2cpio "$f" | bsdtar -tvf -
done
rpm -qp --qf '[%{FILENAMES} %{FILEMODES:octal} %{LONGFILESIZES} %{FILEINODES} %{FILEDEVICES} %{FILELINKTOS} %{FILEFLAGS} %{FILEDIGESTS}\n]' "$f"
rpm2cpio "$f" | bsdtar -xOf - '<name>' | shasum -a 256
```

sandbox の最初の生成では rpm の既定一時領域で拒否された。

```text
error: error creating temporary file /opt/homebrew/var/tmp/rpm-tmp.cL2unh: m
error: Unable to open temp file: Operation not permitted
```

生成器で `_topdir` / `_tmppath` / `_dbpath` / `_keyringpath` を `/private/tmp` 配下へ指定すると
`rpmbuild` / `rpm -qp` / `rpm2cpio` がすべて成功した。最初の query の既定 keyring lock も
`Operation not permitted` だったため、以後は同じ作業用 keyring を指定している。
`rpmbuild` は locale を `C` にして libmagic の locale 依存 regex warning を避けた。
query / bsdtar は `en_US.UTF-8`、時刻表示は UTC。

SwiftPM の既定 module cache は書込不可、入れ子の `sandbox-exec` も
`sandbox_apply: Operation not permitted` だったため、実行時には次を指定した。
外側の作業 sandbox は維持している。

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/kaitokit-rpm-check/ModuleCache
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox \
  --cache-path /private/tmp/kaitokit-rpm-check/swift-cache \
  --config-path /private/tmp/kaitokit-rpm-check/swift-config \
  --security-path /private/tmp/kaitokit-rpm-check/swift-security
# swift test の各 filter にも同じ option を付ける。
```

## テスト出力

| コマンド | 成功 | 失敗 | skip |
| --- | ---: | ---: | ---: |
| swift build | 成功（warning / error 無し） | 0 | — |
| swift test --filter Rpm | 20（core 18 / Compat 2） | 0 | 0 |
| swift test --filter Cpio | 19（core 18 / Compat 1） | 0 | 3 |
| swift test --filter ReleaseReviewDocumentationTests | 4 | 0 | 0 |

Cpio の skip は既存の外部 corpus テスト 3 件。`KAITOKIT_CPIO_ORACLE` / `KAITOKIT_CPIO_DETECTION_BASELINE`
が未指定のためで、bare `07070X` の拒否を含む固定 fixture の検証は通過した。

build の出力:

```text
Building for debugging...
[2 / 14] KaitoKit
[5 / 17] KaitoKit
[14 / 16] KaitoKitDynamic-product
Build complete! (2.08秒)
```

各 filter の最終集計（実出力から抜粋）:

```text
$ swift test --filter Rpm
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 19:12:52.229.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.073 (0.074) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 19:12:52.300.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.006 (0.007) seconds
$ swift test --filter Cpio
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 19:01:18.735.
	 Executed 21 tests, with 3 tests skipped and 0 failures (0 unexpected) in 1.270 (1.272) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 19:01:18.805.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.005 (0.006) seconds
$ swift test --filter ReleaseReviewDocumentationTests
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 19:13:52.685.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.016 (0.016) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 19:13:52.746.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
```

RPM の追加検証は、v4 / v6 全 entry の黄金値、symlink 本文、日本語名、ghost 省略、carrier を先頭へ
移した hard link、SHA-256 の完全読取時エラー、他の algorithm の非検証、未知・重複・ghost index、
member / data / trailer の非 NUL padding、trailer の前倒し・名前・data size・512 / 513 byte 境界、
切断、配列件数・型・重複 tag・Dirindexes、32 / 64-bit size と優先順、file list 不足の fallback、
各上限、stored / disk staging と reopen()。既存 v6 の期待値は blob 1 件から実体 6 件へ変更した。

## CLI と oracle の出力

全 36 entry の名前・本文長・SHA-256 が `rpm2cpio` 本文と一致。通常 file は 27 件分すべて、
実際の `rpm2cpio | bsdtar -xOf - <name> | shasum -a 256` pipeline と照合した。
3 種の新 fixture は順序に依存しない per-file digest 集合も一致した。
method 表示の訂正後は `kaito list` の全行も一致し、テストでも v4 / v6 の methodDescription を比較する。

```text
rpm-stripped-v6-zstd: 10 entries; 8 regular files matched; total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
rpm-stripped-v6-gzip: 10 entries; 8 regular files matched; total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
rpm-stripped-v4-gzip: 10 entries; 8 regular files matched; total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
rpm-v6: 6 entries; 3 regular files matched; total	6	058d0a9d9c28c2133c547d0a13fed38414a921b21f2b4109fef179c979d9150c	
27 regular-file pipelines: PASS; all 36 entry digests: PASS; three fixture SHA-256 sets: identical
```

新 spec の header query（3 package で同一）:

```text
$ rpm -qp --qf '[%{FILENAMES} %{FILEMODES:octal} %{LONGFILESIZES} %{FILEINODES} %{FILEDEVICES} %{FILELINKTOS} %{FILEFLAGS} %{FILEDIGESTS}\n]' rpm-stripped-v6-zstd.rpm
/usr/share/kaito-rpm6 40755 0 1 1  0 
/usr/share/kaito-rpm6/empty.txt 100644 0 2 1  0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
/usr/share/kaito-rpm6/hard-a.txt 100644 18 3 1  0 ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0
/usr/share/kaito-rpm6/hard-b.txt 100644 18 3 1  0 ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0
/usr/share/kaito-rpm6/hard-c.txt 100644 18 3 1  0 ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0
/usr/share/kaito-rpm6/large.txt 100644 10537 6 1  0 609a4c0abb1a2493eb4895c531c8b1e23e1699ddd6a96002a91f3b2b62a878f1
/usr/share/kaito-rpm6/link.txt 120755 13 7 1 日本語.txt 0 
/usr/share/kaito-rpm6/partial-a.txt 100644 26 8 1  0 580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9
/usr/share/kaito-rpm6/partial-b.txt 100644 26 8 1  0 580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9
/usr/share/kaito-rpm6/partial-z-ghost.txt 100644 26 8 1  64 
/usr/share/kaito-rpm6/standalone-ghost.txt 100644 14 11 1  64 
/usr/share/kaito-rpm6/日本語.txt 100644 25 12 1  0 2730575686faebe98e0224377619037d0d8f6feedee58616794a6e6ef35235d7
```

`RPMFORMAT PAYLOADCOMPRESSOR PAYLOADFLAGS FILEDIGESTALGO` の query:

```text
rpm-stripped-v6-zstd.rpm: 6 zstd 19 8
rpm-stripped-v6-gzip.rpm: 6 gzip 9 8
rpm-stripped-v4-gzip.rpm: 4 gzip 9 8
rpm-v6.rpm: 6 gzip 9 8
```

以下は各 package の kaito list / sha と、対応する rpm2cpio + bsdtar の実出力。
作業用 directory の prefix だけを省略した。v4 / v6 の method 表示はともに `cpio (stored)`。
hard link の空本文は bsdtar stdout でも空で、tag の論理 digest とは別に比較している。

<details>
<summary>rpm-stripped-v6-zstd.rpm</summary>

```text
$ .build/debug/kaito list rpm-stripped-v6-zstd.rpm
0	0	directory	cpio (stored)	plain	./usr/share/kaito-rpm6
1	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/empty.txt
2	10537	file	cpio (stored)	plain	./usr/share/kaito-rpm6/large.txt
3	13	symlink	cpio (stored)	plain	./usr/share/kaito-rpm6/link.txt
4	25	file	cpio (stored)	plain	./usr/share/kaito-rpm6/日本語.txt
5	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-a.txt
6	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-b.txt
7	18	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-c.txt
8	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-a.txt
9	26	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-b.txt
$ .build/debug/kaito sha rpm-stripped-v6-zstd.rpm
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6
1	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/empty.txt
2	10537	609a4c0abb1a2493eb4895c531c8b1e23e1699ddd6a96002a91f3b2b62a878f1	./usr/share/kaito-rpm6/large.txt
3	13	e1422b2811100c295d75af1df0724ed59039fd602ab0b653d8377f97fc239fef	./usr/share/kaito-rpm6/link.txt
4	25	2730575686faebe98e0224377619037d0d8f6feedee58616794a6e6ef35235d7	./usr/share/kaito-rpm6/日本語.txt
5	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-a.txt
6	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-b.txt
7	18	ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0	./usr/share/kaito-rpm6/hard-c.txt
8	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/partial-a.txt
9	26	580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9	./usr/share/kaito-rpm6/partial-b.txt
total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -tvf -
drwxr-xr-x  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6
-rw-r--r--  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/empty.txt
-rw-r--r--  1 0      0       10537 Sep 22 00:00 ./usr/share/kaito-rpm6/large.txt
lrwxr-xr-x  1 0      0          13 Sep 22 00:00 ./usr/share/kaito-rpm6/link.txt -> 日本語.txt
-rw-r--r--  1 0      0          25 Sep 22 00:00 ./usr/share/kaito-rpm6/日本語.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-b.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0          18 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-c.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  2 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-a.txt
-rw-r--r--  2 0      0          26 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-b.txt link to ./usr/share/kaito-rpm6/partial-a.txt
```

</details>

<details>
<summary>rpm-stripped-v6-gzip.rpm</summary>

```text
$ .build/debug/kaito list rpm-stripped-v6-gzip.rpm
0	0	directory	cpio (stored)	plain	./usr/share/kaito-rpm6
1	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/empty.txt
2	10537	file	cpio (stored)	plain	./usr/share/kaito-rpm6/large.txt
3	13	symlink	cpio (stored)	plain	./usr/share/kaito-rpm6/link.txt
4	25	file	cpio (stored)	plain	./usr/share/kaito-rpm6/日本語.txt
5	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-a.txt
6	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-b.txt
7	18	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-c.txt
8	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-a.txt
9	26	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-b.txt
$ .build/debug/kaito sha rpm-stripped-v6-gzip.rpm
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6
1	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/empty.txt
2	10537	609a4c0abb1a2493eb4895c531c8b1e23e1699ddd6a96002a91f3b2b62a878f1	./usr/share/kaito-rpm6/large.txt
3	13	e1422b2811100c295d75af1df0724ed59039fd602ab0b653d8377f97fc239fef	./usr/share/kaito-rpm6/link.txt
4	25	2730575686faebe98e0224377619037d0d8f6feedee58616794a6e6ef35235d7	./usr/share/kaito-rpm6/日本語.txt
5	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-a.txt
6	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-b.txt
7	18	ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0	./usr/share/kaito-rpm6/hard-c.txt
8	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/partial-a.txt
9	26	580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9	./usr/share/kaito-rpm6/partial-b.txt
total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
$ rpm2cpio rpm-stripped-v6-gzip.rpm | bsdtar -tvf -
drwxr-xr-x  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6
-rw-r--r--  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/empty.txt
-rw-r--r--  1 0      0       10537 Sep 22 00:00 ./usr/share/kaito-rpm6/large.txt
lrwxr-xr-x  1 0      0          13 Sep 22 00:00 ./usr/share/kaito-rpm6/link.txt -> 日本語.txt
-rw-r--r--  1 0      0          25 Sep 22 00:00 ./usr/share/kaito-rpm6/日本語.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-b.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0          18 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-c.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  2 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-a.txt
-rw-r--r--  2 0      0          26 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-b.txt link to ./usr/share/kaito-rpm6/partial-a.txt
```

</details>

<details>
<summary>rpm-stripped-v4-gzip.rpm</summary>

```text
$ .build/debug/kaito list rpm-stripped-v4-gzip.rpm
0	0	directory	cpio (stored)	plain	./usr/share/kaito-rpm6
1	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/empty.txt
2	10537	file	cpio (stored)	plain	./usr/share/kaito-rpm6/large.txt
3	13	symlink	cpio (stored)	plain	./usr/share/kaito-rpm6/link.txt
4	25	file	cpio (stored)	plain	./usr/share/kaito-rpm6/日本語.txt
5	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-a.txt
6	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-b.txt
7	18	file	cpio (stored)	plain	./usr/share/kaito-rpm6/hard-c.txt
8	0	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-a.txt
9	26	file	cpio (stored)	plain	./usr/share/kaito-rpm6/partial-b.txt
$ .build/debug/kaito sha rpm-stripped-v4-gzip.rpm
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6
1	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/empty.txt
2	10537	609a4c0abb1a2493eb4895c531c8b1e23e1699ddd6a96002a91f3b2b62a878f1	./usr/share/kaito-rpm6/large.txt
3	13	e1422b2811100c295d75af1df0724ed59039fd602ab0b653d8377f97fc239fef	./usr/share/kaito-rpm6/link.txt
4	25	2730575686faebe98e0224377619037d0d8f6feedee58616794a6e6ef35235d7	./usr/share/kaito-rpm6/日本語.txt
5	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-a.txt
6	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/hard-b.txt
7	18	ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0	./usr/share/kaito-rpm6/hard-c.txt
8	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaito-rpm6/partial-a.txt
9	26	580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9	./usr/share/kaito-rpm6/partial-b.txt
total	10	98fc29f44032a1f1ab6b28a6c4b2b7fe430a561c4e4d8d10ce14f57b95c3437b	
$ rpm2cpio rpm-stripped-v4-gzip.rpm | bsdtar -tvf -
drwxr-xr-x  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6
-rw-r--r--  1 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/empty.txt
-rw-r--r--  1 0      0       10537 Sep 22 00:00 ./usr/share/kaito-rpm6/large.txt
lrwxr-xr-x  1 0      0          13 Sep 22 00:00 ./usr/share/kaito-rpm6/link.txt -> 日本語.txt
-rw-r--r--  1 0      0          25 Sep 22 00:00 ./usr/share/kaito-rpm6/日本語.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-b.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  3 0      0          18 Sep 22 00:00 ./usr/share/kaito-rpm6/hard-c.txt link to ./usr/share/kaito-rpm6/hard-a.txt
-rw-r--r--  2 0      0           0 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-a.txt
-rw-r--r--  2 0      0          26 Sep 22 00:00 ./usr/share/kaito-rpm6/partial-b.txt link to ./usr/share/kaito-rpm6/partial-a.txt
```

</details>

<details>
<summary>rpm-v6.rpm</summary>

```text
$ .build/debug/kaito list rpm-v6.rpm
0	0	directory	cpio (stored)	plain	./usr/share/kaitotest
1	10	file	cpio (stored)	plain	./usr/share/kaitotest/a.txt
2	4096	file	cpio (stored)	plain	./usr/share/kaitotest/b.bin
3	5	symlink	cpio (stored)	plain	./usr/share/kaitotest/link.txt
4	0	directory	cpio (stored)	plain	./usr/share/kaitotest/sub
5	20	file	cpio (stored)	plain	./usr/share/kaitotest/sub/nested.txt
$ .build/debug/kaito sha rpm-v6.rpm
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaitotest
1	10	7ccc92b5adfd832a3f56064ad8304349e7b373a3b90c76de110a012251ed3455	./usr/share/kaitotest/a.txt
2	4096	0d356260eaf09e3b3dc81a65b2ad2399aa7c4921c0274bd2cbb54c2a21c46e3b	./usr/share/kaitotest/b.bin
3	5	18b7cb099a9ea3f50ba899b5ba81e0d377a5f3b16f8f6eeb8b3e58cd4692b993	./usr/share/kaitotest/link.txt
4	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	./usr/share/kaitotest/sub
5	20	5d0e5bc93dbc8febbb6b3cea0503bfd7460284e544c2f689538fd55da59accb2	./usr/share/kaitotest/sub/nested.txt
total	6	058d0a9d9c28c2133c547d0a13fed38414a921b21f2b4109fef179c979d9150c	
$ rpm2cpio rpm-v6.rpm | bsdtar -tvf -
drwxr-xr-x  1 0      0           0 Sep  9 09:10 ./usr/share/kaitotest
-rw-r--r--  1 0      0          10 Sep  9 09:10 ./usr/share/kaitotest/a.txt
-rw-r--r--  1 0      0        4096 Sep  9 09:10 ./usr/share/kaitotest/b.bin
lrwxr-xr-x  1 0      0           5 Sep  9 09:10 ./usr/share/kaitotest/link.txt -> a.txt
drwxr-xr-x  1 0      0           0 Sep  9 09:10 ./usr/share/kaitotest/sub
-rw-r--r--  1 0      0          20 Sep  9 09:10 ./usr/share/kaitotest/sub/nested.txt
```

</details>

通常 file の pipeline 出力（新 spec の 3 本は同じ値なので zstd 版と既存 v6 を掲載）:

```text
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/empty.txt | shasum -a 256
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/large.txt | shasum -a 256
609a4c0abb1a2493eb4895c531c8b1e23e1699ddd6a96002a91f3b2b62a878f1  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - './usr/share/kaito-rpm6/日本語.txt' | shasum -a 256
2730575686faebe98e0224377619037d0d8f6feedee58616794a6e6ef35235d7  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/hard-a.txt | shasum -a 256
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/hard-b.txt | shasum -a 256
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/hard-c.txt | shasum -a 256
ed2b5c4f53a8c01342068c133a32d3e0d9a98c93f229d6a8e0a4165e439748e0  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/partial-a.txt | shasum -a 256
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
$ rpm2cpio rpm-stripped-v6-zstd.rpm | bsdtar -xOf - ./usr/share/kaito-rpm6/partial-b.txt | shasum -a 256
580fdbb498f4474210fee227739cb2275b71b258589759160444cd6b09134ab9  -
$ rpm2cpio rpm-v6.rpm | bsdtar -xOf - ./usr/share/kaitotest/a.txt | shasum -a 256
7ccc92b5adfd832a3f56064ad8304349e7b373a3b90c76de110a012251ed3455  -
$ rpm2cpio rpm-v6.rpm | bsdtar -xOf - ./usr/share/kaitotest/b.bin | shasum -a 256
0d356260eaf09e3b3dc81a65b2ad2399aa7c4921c0274bd2cbb54c2a21c46e3b  -
$ rpm2cpio rpm-v6.rpm | bsdtar -xOf - ./usr/share/kaitotest/sub/nested.txt | shasum -a 256
5d0e5bc93dbc8febbb6b3cea0503bfd7460284e544c2f689538fd55da59accb2  -
```

symlink と directory も kaito sha を `rpm2cpio` の対応 member 本文と照合済み。
既存 v6 の総合 digest `058d0a9d9c28c2133c547d0a13fed38414a921b21f2b4109fef179c979d9150c` は
既存 classic RPM の黄金値と一致する。

## 変更ファイル

git コマンドを使わず、この作業で編集・追加した 19 本を列挙する。既存 RPM fixture は変更していない。

| 変更 | ファイル |
| --- | --- |
| header / entry 接続 | `Sources/KaitoKit/Formats/Rpm/RpmHeader.swift`、`Sources/KaitoKit/Formats/Rpm/RpmReader.swift` |
| stripped walker（追加） | `Sources/KaitoKit/Formats/Rpm/RpmStrippedPayload.swift` |
| テスト | `Tests/KaitoKitTests/RpmReaderTests.swift`、`Tests/KaitoKitCompatTests/KaitoArchiveRpmTests.swift` |
| 生成器・spec（追加） | `Tests/Fixtures/container/generate-rpm6.sh`、`Tests/Fixtures/container/record-rpm6.py`、`Tests/Fixtures/container/rpm-stripped.spec` |
| fixture（追加） | `Tests/Fixtures/container/rpm-stripped-v6-zstd.rpm.b64`、`Tests/Fixtures/container/rpm-stripped-v6-gzip.rpm.b64`、`Tests/Fixtures/container/rpm-stripped-v4-gzip.rpm.b64` |
| fixture 記録（追加） | `Tests/Fixtures/container/rpm-stripped-manifest.json`、`Tests/Fixtures/container/README.md` |
| 出自 | `Tests/Fixtures/NOTICE` |
| 利用者向け文書 | `README.md`、`CHANGELOG.md` |
| 設計・検証 | `Documentation/design.md`、`Documentation/verification/README.md`、`Documentation/verification/2026-09-22-rpm-stripped-payload.md`（追加） |
