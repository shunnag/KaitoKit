# decode の A/B 計測（B0 / RAR4 R0）

decoder を変える前に `list` と `sha --sink` の process 全体を比較する。
`sha --sink` は通常の `sha` と同じ entry を再利用する 4 MiB buffer へ読み、SHA-256 の計算を省く。
stdout は `index<TAB>bytes<TAB>name`、末尾は `total<TAB>rows<TAB>bytes<TAB>`。
失敗時は従来どおり ERROR 行・stderr・終了 1 とし、成功 entry だけの `partial` を出す。
`--forks`・`-p` の規則も通常の `sha` と同じ。

## 準備

両 binary を同一 Mac・同一 toolchain（Xcode 27 / Swift 6.4）の release 構成で build する。
base は detached worktree に置く。比較する両 revision に `--sink` が必要なので、古い base には
B0 の CLI 変更だけを適用し、その patch も記録する。decoder の変更を混ぜない。

```sh
git worktree add --detach ../KaitoKit-base v0.12.1
# base に B0 の Sources/kaito の変更だけを適用する
(cd ../KaitoKit-base && swift build -c release)
swift build -c release

bash Tests/Measurement/decode-ab/make-corpus.sh /tmp/kaito-decode-corpus
# smoke 用: 2 MiB text + 2 MiB random + 390 small files
bash Tests/Measurement/decode-ab/make-corpus.sh /tmp/kaito-decode-tiny --scale 0.0078125
```

出力先は新規または空の directory。既定値は text / random 各 256 MiB と小ファイル 50,000 件。
`DECODE_AB_SCALE` でも縮小できる。固定 seed・固定語彙・固定 mtime と `TZ=UTC` を使う。
`command -v` で writer を探し、無いもの・作成に失敗した形式は警告して skip する。
reader 専用の lhasa `lha` も skip となる。生成記録は `logs/`、書庫の path・size・SHA-256 は
`manifest.json`。AES 7z の固定 password は `decode-ab-password` で manifest に記録する。
AES の salt など、writer の乱数・metadata に依存する部分は書庫間で再現しない。
XZ の `-T0` は 1 MiB block、`-T1` は単一 thread の stream を作る。
同じ manifest と書庫を両 binary に使い、書庫自体は commit しない。

## RAR4 R0 corpus

RAR4 の writer は **RAR 6.x** が必要。PATH の RAR 7.23 は `-ma4` を書けない。
`RAR4_TOOL` → PATH の `rar6` → `~/.local/opt/rar-6.24/rar` の順に探し、`-iver` が
6.x のものを使う。無ければ警告して RAR4 だけを skip する。

```sh
RAR4_TOOL="$HOME/.local/opt/rar-6.24/rar" \
  bash Tests/Measurement/decode-ab/make-corpus.sh /tmp/kaito-rar4 --scale 0.0078125
```

既存の text / random / small に `-ma4 -m3 -s-` と `-ma4 -m3 -s` を追加し、
text.txt には `-mc8:16T+` の PPMd 版も作る。さらに固定 seed から次の入力を作る。

| 入力（scale=1） | 内容 | filter の対 |
|---|---|---|
| page-01〜03.bmp（各約 12 MiB、2048×2048） | 24-bit color BMP。色の勾配、noise、模擬文字行、図版 | RGB / Delta |
| stereo.wav（約 24 MiB） | 44.1 kHz、16-bit stereo PCM。倍音、包絡、左右別 noise | Audio / Delta |
| x86-code.bin（12 MiB） | 決定的な x86_64 風 prologue / E8 call / E9 jump / 即値。system binary は使わない | E8 |

各対は `-mc-` で他の optional module を無効にしてから、対象を強制 on / off にする。
RGB は `-mcC+/-`、Delta は 4 byte-channel の `-mc4D+/-`、Audio は `-mc4A+/-`、
x86 は `-mcE+/-`。`rar6 '-?'` の `mc<par>` と RAR 6.24 同梱の利用者向け `rar.txt` で
A/C/D/E/T を確認した。`-mcI+` は受理されても probe の token table は空で、公開 module 一覧にも
I が無いため Itanium を強制した標本としては扱わない。

`--scale` / `DECODE_AB_SCALE` は新しい入力にも掛かる。画像は画素数、WAV は frame 数、code は
byte 数を縮め、有効な header と最小限の入力を残す。0.0078125 は画像各約 97 KiB、
WAV 約 192 KiB、code 96 KiB となり、速度の判断には使わない。
`manifest.json` の RAR4 record に writer version、全 switch、solid の有無と各原本の
path / size / SHA-256 を残す。`ab.py` は既存の `archives` 一覧だけで全形式を処理する。

原本の entry 集合・byte 数・SHA-256 を、unrar 7.23 / bsdtar 3.8.10 / release kaito の
実際の展開結果と照合する（同じ内容の余分な entry も拒否する）。

```sh
python3 Scripts/fixtures/make-rar4.py \
  --verify-manifest /tmp/kaito-rar4/manifest.json --kaito .build/release/kaito
```

bsdtar 3.8.10 は複数 member の RAR4 solid を `RAR solid archive support unavailable` で拒否する。
照合器は solid record のこの診断だけを `unsupported` と明示し、unrar と KaitoKit は全 member を
原本と照合する。他の失敗・不一致は終了 1。bsdtar の未対応を三者一致には数えない。
checked-in の小型標本と filter 存在の検査は [rar4/README](../../Fixtures/rar4/README.md) を参照。

## 実行

まず同じ binary 同士で揺らぎを測り、それから A/B を測る。

```sh
python3 Tests/Measurement/decode-ab/ab.py \
  --base .build/release/kaito --same --rounds 5 \
  --base-rev "$(git rev-parse HEAD)" \
  --manifest /tmp/kaito-decode-corpus/manifest.json --out /tmp/kaito-decode-noise.jsonl

python3 Tests/Measurement/decode-ab/ab.py \
  --base ../KaitoKit-base/.build/release/kaito --branch .build/release/kaito \
  --base-rev "$(git -C ../KaitoKit-base rev-parse HEAD)" --branch-rev "$(git rev-parse HEAD)" \
  --manifest /tmp/kaito-decode-corpus/manifest.json --out /tmp/kaito-decode-ab.jsonl

python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaito-decode-ab.jsonl
python3 Tests/Measurement/decode-ab/ab.py --summary /tmp/kaito-decode-ab.jsonl --metric max_rss
```

通常の `sha` の stdout と終了コードを先に照合する。不一致の書庫は timing を止め、JSONL に記録する。
各 mode を既定 5 round、base→branch / branch→base と交互に実行する。
各 round の前に書庫全体を読んで warm にし、各 sample は別 process の `/usr/bin/time -l` で
user / sys（秒）と max RSS（bytes）を測る。wall は `perf_counter` の経過時間（秒）を使い、
10 ms 単位の `time -l` real は `wall_time_l` に残す。取得できる場合は `instructions`・`cycles`（数）と
`peak_footprint`（bytes）も記録し、取得できなければ `null` とする。stdout は `/dev/null` に送る。
sample の stderr 全文は終了コードが 0 以外の場合だけ保存する。
起動・metadata 解析・標準出力の整形・decoder の CRC 検証は時間に含む。

JSONL の先頭は machine 情報・toolchain・指定 revision・binary / manifest の digest。
同じ引数で再実行すると保存済み sample を飛ばす。`--rounds` を増やして続けられる。
不一致や失敗をやり直す場合、条件を変える場合は新しい `--out` を使う。
summary は両側が成功した round だけの best / median と branch/base・各 round の比を表示する。
`--metric instructions|cycles|peak_footprint` も選べる。値が無い round は対比較から除き、比は `n/a`。
user / sys の丸めなどで分母が 0 の場合も比は `n/a`。wall に `time -l` real を使った旧 JSONL と混ぜず、
新しい `--out` を使う。実測には十分大きい corpus を使う。

sandbox が `time -l` の `sysctl kern.clockrate` を拒否する場合だけ、user / sys / max RSS を
`wait4` に切り替え、その理由と計測元を記録する。機械情報の取得失敗も残す。
この代替は smoke の確認に使い、本計測は sandbox 外で行う。異なる計測元の結果を混ぜない。

計測中は build・test・他の処理を止め、電源・温度条件を揃える。
noise floor の比の範囲内の変化は採用しない。範囲を外れる変化だけを再測定し、
identity の一致と複数 round の再現を確認して採否を決める。
