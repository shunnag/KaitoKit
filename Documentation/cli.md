# kaito CLI

[README](../README.md#コマンドライン) の基本操作に加え、出力形式・差分検証・計測・password の規則を説明します。

## 復号の並列数

`list` / `sha` / `extract` / `bench` は `--threads N`（1〜1024）または `--threads auto` を受け付けます。
既定は `auto`。`ReaderOptions.decodeThreads` に対応し、XZ / bzip2 の単独 stream と圧縮 tar の staging に
適用します。自動値は CPU 構成と物理メモリから open 時に一度決め、Low Power Mode では減らします。
保持予算は既定で物理メモリの 50%。実行中 job は process 共通の CPU 数上限を共有し、超える要求は queue に入ります。
範囲外・値なし・重複した `--threads` は usage error です。出力 byte と SHA は並列数によらず同一です。

```console
kaito sha --threads 1 payload.xz
kaito sha --threads 16 payload.xz
kaito list archive.tar.bz2 --threads auto
kaito extract payload.bz2 -o unpacked --threads 4
kaito bench --threads 36 archive.tar.xz 5
```

## 名前の文字コードを診断する

`detect-encoding` は TSV に記録した名前の元 byte 列から文字コード・確信度・復号名を表示する診断用コマンドです。
`--archive` は同じ書庫の名前群をまとめて判定し、`--check-orthography` は正解 text の言語別の位置規則違反を表示します。

```console
kaito detect-encoding [--archive | --check-orthography] [--language <code> | --no-language] [--from-windows] [--decode <iana>] <tsv>
swift run kaito detect-encoding --language ja names.tsv
swift run kaito detect-encoding --archive --language ja archives.tsv
swift run kaito detect-encoding --check-orthography names.tsv
```

入力は UTF-8 の TSV です。通常は `id<TAB>lang<TAB>truth_iana<TAB>hex<TAB>text` の5欄、
`--archive` では `group<TAB>lang<TAB>truth_iana<TAB>k<TAB>hex1,hex2,...` の5欄を使います。
`hex` は名前 byte 列の16進数、`k` は非 ASCII 名の件数です。この header 行は省略できます。
`--language` の既定値は `ja`、`--no-language` は言語の事前情報を使わず判定します。
`--decode <iana>` は指定文字コードの復号結果を正解 text と照合し、`--archive` / `--check-orthography` と併用できません。
測定用 TSV の生成・評価は [名前判定の測定ガイド](../Tests/Measurement/name-encoding/README.md) を参照してください。

> **Name encoding diagnostics**
>
> `detect-encoding` diagnoses raw name bytes supplied as UTF-8 TSV rows. `--archive` evaluates a group of
> names together; `--check-orthography` reports violations of language-specific positional rules in the reference text.

## コマンドライン

```console
$ swift run kaito detect samples/book.tar
tar
$ swift run kaito list samples/book.zip
0\t12345\tfile\tdeflate\tplain\t表紙.jpg
$ swift run kaito list samples/book.zip --raw
$ swift run kaito list samples/book-encrypted.7z -p secret
$ swift run kaito extract samples/book.tar -o /tmp/book
$ swift run kaito sha samples/book.tar
$ swift run kaito sha samples/book-encrypted.7z -p secret
$ swift run kaito bench samples/book.tar 5
$ swift run kaito bench --data samples/book.tar 5
$ swift run kaito bench --random samples/book-solid.7z 5
$ swift run kaito bench --random samples/book-encrypted.7z 5 -p secret
```

`sha` はエントリ順の SHA-256 と総合ダイジェストを出力し、別の展開実装との
差分テストに利用できます。`sha` / `extract` は entry ごとの失敗を stderr へ報告して後続を処理し、
失敗が一件でもあれば終了コード 1 を返します。`sha` の失敗行は `index<TAB>ERROR<TAB>message<TAB>name`、
末尾は成功 entry だけを集計した `partial` となり、完全な `total` は出力しません。`list` は index、size、kind、method、暗号方式 (`plain`、
`ZipCrypto`、`AES-128/192/256`、`7zAES-256`)、name の順でタブ区切り表示し、LHA では
末尾に `level=N` を追加します。`--raw` は
名前の format 上の論理バイト列を末尾へ 16 進数で併記します。LHA の 0x02 directory + 0x01
filename は一つの path に組み立て、0xFF directory 区切りは `/` に正規化されます。
`bench --data` は `mappedIfSafe` で作った `Data`
から書庫を開き、map 作成を含む `open-median-ms` を表示します。`bench --random` は
固定 seed で選んだ最大 20 件の非ディレクトリエントリをランダム順に読み、solid 書庫の
後方シークを含むアクセスを再現可能な条件で計測します。表示する `bytes` は選択した
エントリの合計です。

StuffIt / StuffIt X の `list` は末尾に `fork=data` / `fork=resource` を追加します。
StuffIt X は `solid=<stream ID>`（独立 fork は `-1`）も表示します。
`sha` は支給 XADMaster オラクルに合わせ、既定では data fork のみを検証・表示します。
resource だけのファイルは空 data fork の行を表示します。`sha --forks` は公開 entry の
全 fork を検証・表示します。StuffIt の失敗詳細は stderr にだけ出し、stdout の行は数値サイズを保ちます。
`extract` は data / hardlink → resource fork → directory の順に処理し、resource-only entry は
空の通常ファイルに `com.apple.ResourceFork` を付けます。[展開・日本語名の検証記録](verification/2026-09-13-stuffit-slice8.md)。
支給 `compare.py`、password 付き StuffIt X・`.exe` は [slice 6 検証記録](verification/2026-09-13-stuffit-slice6.md)、
JPEG の 292 ストリームと Windows 2009 DES の追加照合は [slice 7 検証記録](verification/2026-09-13-stuffit-slice7.md) に記載しています。

`bench` の時間は process 内の open / extract だけを複数回計測した median で、process 起動、
SHA-256、標準出力は含みません。`swift run` には SwiftPM の planning / build も含まれるため、
CLI 全体の性能は release build 済みの `.build/release/kaito` を直接実行して比較します。
`sha` は再利用する 4 MiB buffer で逐次 hash します。release binary を warm 条件で直接測ると、
変更前→変更後の median は book RAR5 が 155.346→155.431 ms、TIFF RAR5 が
637.541→610.447 ms でした。最終確認の wall time はそれぞれ 0.15 / 0.61 s です。
以前観測した約 0.62 秒の差は decoder ではなく、`swift run` の cold-start / build planning を
測定へ混ぜたことが原因でした。

`list`、`extract`、`sha`、`bench` は `-p <password>` を受け付けます。ヘッダも暗号化された
7z / RAR は、一覧やベンチマークの開始時にも password が必要です。
RAR3 は長いパスワードの旧 SHA-1 入力更新規則に対応します。
writer と同じ最大127文字（UTF-16 候補は127 code units、Unix 候補は127 scalars）で区切ります。BMP 外の文字を含む RAR3 password は
UTF-16 を先に試し、検証失敗時に Unix RAR の Unicode scalar 下位 16 bit 表現へ再試行します。
file data は独立した stream で CRC を最後まで検証してから公開するため、この場合だけ追加の展開が生じます。

RAR5 は先頭127 Unicode scalars の UTF-8 を優先し、有効な password 検査値が一致しなければ
入力全体の UTF-8 を試します。127 scalars 以下の password は変更しません。

圧縮 tar の編集用 `TarEditLayout` SPI は opt-in で配置・区切り・snapshot を記録します。
`KAITOKIT_BENCH_TAR_EDIT_LAYOUT=1` で CLI の記録を有効にでき、
[段階 A の検証記録](verification/2026-09-25-tar-edit-layout.md)に golden・fuzz・計測結果をまとめています。
`openSplicedCompressedTar` は保存した digest と image を使って継ぎの出力を検証します（[段階 B の検証記録](verification/2026-09-25-tar-splice-verification.md)）。

> **Command line**
>
> `sha` prints the SHA-256 of each entry in order plus an overall digest, which can be used for
> differential testing against another extraction implementation. `sha` and `extract` report a
> per-entry failure on stderr, continue with the remaining entries, and exit with status 1 if any
> entry failed. A failing `sha` line is `index<TAB>ERROR<TAB>message<TAB>name`, and the final line is
> a `partial` covering only the successful entries; no complete `total` is printed. `list` prints
> index, size, kind, method, encryption (`plain`, `ZipCrypto`, `AES-128/192/256`, `7zAES-256`) and
> name, separated by tabs, appending `level=N` for LHA. `--raw` also prints the format-level logical
> bytes of the name in hexadecimal at the end of the line. An LHA 0x02 directory plus 0x01 filename
> is assembled into one path, and the 0xFF directory separator is normalized to `/`.
> `bench --data` opens the archive from a `Data` created with `mappedIfSafe` and reports an
> `open-median-ms` that includes creating the map. `bench --random` reads up to 20 non-directory
> entries chosen with a fixed seed, in random order, so that access patterns including backward seeks
> in a solid archive are measured reproducibly. The reported `bytes` is the total of the selected
> entries.
>
> `bench` times only the in-process open and extract, repeated and reported as a median; process
> startup, SHA-256 and standard output are excluded. `swift run` also includes SwiftPM planning and
> building, so compare whole-CLI performance by running a release-built `.build/release/kaito`
> directly. `sha` hashes incrementally through a reused 4 MiB buffer. Measuring the release binary
> directly under warm conditions, the before-to-after medians were 155.346 to 155.431 ms for the book
> RAR5 and 637.541 to 610.447 ms for the TIFF RAR5, with final wall times of 0.15 and 0.61 s. The
> roughly 0.62 second difference observed earlier came not from the decoder but from mixing the
> `swift run` cold start and build planning into the measurement.
>
> `list`, `extract`, `sha` and `bench` accept `-p <password>`. A 7z or RAR archive whose headers are
> also encrypted needs the password even to start listing or benchmarking.
> RAR3 supports the old SHA-1 input update rule for long passwords.
> The password is cut at the same maximum of 127 characters as the writer uses (127 code units for
> the UTF-16 candidate, 127 scalars for the Unix candidate). A RAR3 password containing characters
> outside the BMP tries UTF-16 first and, if verification fails, retries with the low 16 bits of the
> Unicode scalars as Unix RAR represents them. File data is published only after its CRC has been
> verified to the end on an independent stream, so this case alone performs an extra expansion.
>
> RAR5 prefers the UTF-8 of the first 127 Unicode scalars and, if no valid password check value
> matches, tries the UTF-8 of the whole input. Passwords of 127 scalars or fewer are unchanged.
