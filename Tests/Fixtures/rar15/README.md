# RAR 1.5 (unpack version 15) fixtures

`Scripts/fixtures/make-rar15.py` が
[bitplane/rar-research の RAR 1.3 形式ノート](https://github.com/bitplane/rar-research/blob/master/doc/RAR13_FORMAT_SPECIFICATION.md)
§6 の adaptive Huffman、ShortLZ、member 間状態共有から生成する小さな書庫です。
第三者の decoder source、外部書庫のデータは使っていません。生成器は独立した encoder ですが、
fixture の検証には使わず、UNRAR 7.23 を black-box oracle として CRC と展開後の全 byte を照合しています。

再生成:

```sh
python3 Scripts/fixtures/make-rar15.py --unrar /opt/homebrew/bin/unrar
python3 Scripts/fixtures/make-rar15-volumes.py --unrar /opt/homebrew/bin/unrar
```

- `normal.rar`: `literals.txt` は `RAR15!\r\n` の 8 byte、`match.txt` は同じ内容の
  literal 8 byte + 直前 8 byte を参照する ShortLZ の 8 byte。独立した 2 member。
- `solid.rar`: `first.txt` と `second.txt` はどちらも `RAR15!\r\n` の 8 byte。
  2 件目は ShortLZ で 1 件目の窓を参照し、adaptive 表と solid 状態の共有を検証する。
- `solid-split.rar` / `.r00`: `solid.rar` の 2 件目の packed stream を 2 巻に分割し、
  先頭巻の ENDARC を省略した標本。`make-rar15-volumes.py` が生成し、UNRAR でも照合する。
  非最終 part の CRC、継続巻の `SPLIT_BEFORE`、最終 part の全文 CRC を保持する。

archive SHA-256:

- `normal.rar`: `db6f81845c2773bbfaa300f98d9fc888f8f89c57b532abce2d699f2397e8c95d`
- `solid.rar`: `dfe5c7e9fb61f3371ad3723135e509b0e85c6982fdc9f966d43c905983c2e9bd`
- `solid-split.rar`: `6d6925e412ccca99031f154a055370d046a08646fd9af1d81d3a4321203093dd`
- `solid-split.r00`: `667099a709a5afa6700c64821cc4e32eb4c408d132e6feabd0b2c0e5964acae6`

開発時の大きい RAR 1.54 実書庫は `inbox/rar15` に置き、`KAITOKIT_RAR15_FIXTURES` で渡す
非配布の比較対象です。これらの fixture には含めていません。
