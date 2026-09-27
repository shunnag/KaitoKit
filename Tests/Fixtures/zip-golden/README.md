# ZIP 公開値の golden（b518014）

P1-K Step 0 で Sources 無変更のまま入力と公開値を凍結した。S2 correction 1 で保存形式だけを変更した。
書庫の byte・期待する公開値・6 モードの比較内容は同じ。試験は公開 API と b518014 に存在した test support を使う。

`manifest.json` の 266 書庫（269 論理ファイル）は、既存の全 ZIP fixture 30 件と合成 236 件。
既存は zip-modern 7、zip-ppmd 7、zip-legacy 11、zstd 2、lzma-ringwrap 2、appledouble 1。
元 fixture の出典は親の NOTICE を参照。合成はプロジェクト所有の本文、公開 ZIP フィールドと既存の
HandZipEntry / RawRecordArchiveBuilder / ZipSplitFixture による。ditto、Info-ZIP、7-Zip は黒箱の書き手としてだけ使い、
日時・暗号乱数を含む出力を固定した。暗号の password は `raw-password`。

署名あり・なしの ZIP32 / ZIP64 descriptor（local / CD / 両方）、CRC が署名と同値、全 descriptor field の破損と
全切断位置、SFX / ZIP64 end、local 順の逆転と固定 seed `0x50314b` の並べ替え、名前と種類、2,000 件の UT extra と
descriptor、100 B / 8 KiB の隙間、2 × 1 MiB stored、壊れた local header、recovery、ZipCrypto、AES-128 / 256 の
AE-1 / AE-2、native / numbered 分割を含む。

## 小さく保存して同じ byte を比較する

`public-values.json.lzfse` は元の 12,192,438 byte の JSON を Foundation の
`NSData.compressed(using: .lzfse)` で圧縮した 72,795 byte。展開にも Foundation を使い、KaitoKit の codec は使わない。
`public-values.json.sha256` は展開後の JSON の SHA-256。毎回照合してから JSON を読む。
元の凍結値と byte 単位で同じで、hash は `2fbc5230042dbebf38920228980bf6c1973764656cfeb16d748bf029237fdaee`。

266 ファイルは従来どおり `inputs/` の base64 から読み、次の 3 ファイルは manifest の `generator` から試験時に作る。
`generated/` は論理 path であり、保存する ZIP ファイルはない。各 generator は version 付きの recipe と seed を使い、
生成後に**元の凍結 ZIP の SHA-256**と照合する。hash は保存形式の変更時に変更していない。

| 論理 ZIP | recipe / seed | 固定内容 | SHA-256 |
| --- | --- | --- | --- |
| large-stored | large-stored-v1 / 0 | `large0` / `large1`、各 1 MiB、本文は seed + entry index の byte を反復 | `d880a86844fc332078ca3a601b19387040e78910fa8800fd08364aec8ec23f34` |
| small-ut | small-ut-v1 / 120 | `d/f0`〜`d/f1999`、本文 1 B、13 B の UT extra、Unix time 1790000000 | `ade9bfee4f00fcb6155c1180665686136df252a786be23ffa028f80631aa97d0` |
| small-dd | small-dd-v1 / 120 | `d/f0`〜`d/f1999`、本文 1 B、descriptor の署名を交互に付ける | `6828912703ad74cf16663015918f26451ca1bc4d62d77529dbafaefc2d479eb3` |

生成は元と同じ test builder の固定ヘッダ（DOS 2020-01-02 03:04:06 など）を使う。
seed は乱数ではなく本文の byte pattern を指定する。small-ut / small-dd の本文はどちらも `0x78`。
SPI / window / 差分試験も同じ `ZipGoldenCorpus.decoded` を通るため、生成した入力にも同じ SHA-256 検査が掛かる。

## 照合と readable JSON の出力

入力の SHA-256 を検査してから expose lazy / eager、merge lazy / eager、hide lazy、expose recovery の 6 通りで照合する。
rawRecord は昇順・逆順ごとに新しい reader。全公開フィールドと文字列の UTF-8 byte を比較する。
64 entry を超える場合は全行の SHA-256 と先頭・末尾各 16 entry（先頭には open 行も付く）を保存する。
UTC では日時も比較し、UTC 以外では日時だけを除く。この範囲や比較式は保存形式の変更前と同じ。

repository root で実行する（必要なら SwiftPM の cache を書込み可能な一時領域へ指定）:

```sh
TZ=UTC swift test --filter ZipPublicValueGoldenTests
swift test --filter ZipPublicValueGoldenTests
TZ=UTC KAITOKIT_DUMP_ZIP_GOLDEN="${TMPDIR:-/tmp}/zip-golden-readable.json" swift test --filter ZipPublicValueGoldenTests
shasum -a 256 "${TMPDIR:-/tmp}/zip-golden-readable.json"
```

最後の実行は凍結 JSON を展開して指定 path に保存し、通常の全比較も行う。
比較が失敗したときは自動で `$TMPDIR/kaitokit-zip-golden-actual/` に次を出す:

- `expected.json`: 展開した凍結 JSON。
- `actual.json`: 同じ構造の現在値。UTC 以外では比較対象外の `utcValues` を期待値のまま残す。
- `all-rows.json`: 64 entry 超も省略しない全行（従来と同じ）。

```sh
diff -u "${TMPDIR:-/tmp}/kaitokit-zip-golden-actual/expected.json" "${TMPDIR:-/tmp}/kaitokit-zip-golden-actual/actual.json"
```

## 再生成（基準 source 専用）

b518014 の checkout にこの試験と `zip-golden/` 一式を写し、Sources が基準のままであることを確認して実行する。
期待値を変更後の parser から再生成しない。

```sh
git diff --quiet -- Sources
TZ=UTC KAITOKIT_WRITE_ZIP_GOLDEN=1 swift test --filter ZipPublicValueGoldenTests
TZ=UTC KAITOKIT_DUMP_ZIP_GOLDEN="${TMPDIR:-/tmp}/zip-golden-regenerated.json" swift test --filter ZipPublicValueGoldenTests
shasum -a 256 "${TMPDIR:-/tmp}/zip-golden-regenerated.json"
```

再生成は `.json.lzfse` と `.json.sha256` を書く。基準との独立比較には展開した JSON を `cmp` する。
今回も b518014 から再生成し、元の JSON と byte 一致を確認した。

`KAITOKIT_WRITE_ZIP_GOLDEN_INPUTS=1 swift test --filter ZipPublicValueGoldenTests` は Step 0 の全入力生成用。
3 つの決定的な入力には ZIP の代わりに recipe / seed / SHA-256 を manifest に書く。
暗号乱数・外部 tool の日時を持つ他の凍結入力を通常の検証で作り直さない。
