# 7z Deflate64 coder の fixture

プロジェクト所有の byte 列を `/opt/homebrew/bin/7zz` 26.03 の
`a -m0=Deflate64 -ms=on` / `-ms=off` で書いた書庫。
method ID `04 01 09` は公式
[Methods.txt](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt) による。
7-Zip / p7zip / libarchive / XADMaster の実装 source は参照していない。

`first.bin`（262,403 byte）、`second.bin`（1,027 byte）、`empty` は
`sevenzip-zstd/generate.py` と同じ入力。`long.bin` は種
`KaitoKit 7z Deflate64 long fixture` の SHA-256 を順に連鎖させた 48,000 byte を
4 回反復した 192,000 byte で、32 KiB を超える match distance を使わせる。
solid 書庫は全 4 entry を含み、非空 entry を 1 folder にまとめる。
non-solid 書庫は元の 3 entry を含み、`first.bin` / `second.bin` が別々の 2 folder になる。
空 entry は packed stream を持たず、KaitoKit の一覧では `Copy` と表示される。

生成器は各書庫を `7zz t`、各 entry を `7zz e -so ARCHIVE ENTRY` で検証し、
展開 byte を原本と照合する。`7zz l -slt` の `Method = Deflate64`、folder 数、
Packed Size と entry 順を確認し、archive / entry の SHA-256 と生成引数を
`manifest.json` に記録する。時刻と header 圧縮を無効化して再生成を安定させる。

solid folder の packed stream を offset 32 と一覧の Packed Size で切り出し、
`zlib.decompressobj(-15)` が失敗するか原本と異なる byte を返すことを必須にする。
これにより fixture が通常 Deflate だけでは復号できないことを確かめる。
7zz 26.03 の match length は最大 257 でよく、65,538 の長さはこの fixture の要件に含めない。
decoder の長い match は既存の ZIP method 9 テストで検証している。
base64 の合計は 400,000 byte 未満を要求する。

```sh
python3 Tests/Fixtures/sevenzip-deflate64/generate.py
swift test --filter SevenZipDeflate64Tests
```
