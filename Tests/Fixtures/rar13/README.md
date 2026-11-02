# RAR 1.3 / 1.4 fixtures

`Scripts/fixtures/make-rar13.py` が RAR13_FORMAT_SPECIFICATION.md の container・16-bit rolling checksum と、
`make-rar15.py` の独立 encoder で生成する小さな書庫です。第三者の decoder source は使っていません。
UNRAR 7.23 の `t` と `x` により、全ファイルの CRC と展開後の全 byte を照合しています。

```sh
python3 Scripts/fixtures/make-rar13.py --unrar /opt/homebrew/bin/unrar
python3 Scripts/fixtures/make-rar13-crypto.py --unrar /opt/homebrew/bin/unrar
```

暗号・comment の fixture は `make-rar13-crypto.py` が生成し、UNRAR の password 展開と
`unrar v` の comment 表示も照合します。password は `password` です。

- `encrypted.rar`: stored と圧縮の暗号化。password 未指定・誤り・再試行を検証する。
- `solid-encrypted.rar`: 暗号化 solid。entry ごとの復号と逆順読みを検証する。
- `comments.rar`: packed archive comment（`RAR 1.3 comment.\r\n`）と stored file comment（`note\r\n`）。

- `normal.rar`: stored の `stored.txt` と、literal + ShortLZ の `compressed.txt`（独立した 2 member）。
- `solid.rar`: main と 2 件目の file flag で solid を指定した `first.txt` / `second.txt`。
- `solid-main.rar`: 実 RAR 1.402 と同じく main header だけで solid を指定した 2 member。

各本文は `RAR15!\r\n` の 8 byte、`compressed.txt` だけその 2 倍です。solid の 2 件目は
ShortLZ で 1 件目の窓を参照します。

archive SHA-256:

- `normal.rar`: `58d53afaad0645980a222536df5e3e3309baaa4158d7da22691793ec6ea52a27`
- `solid.rar`: `e28ab5c055aec2aebaa5d147419397e3e643714429d2ca29e73a3476cf809d06`
- `solid-main.rar`: `06f47c27b30e2ec7af2d96132789ad8cce7de9f1865212e1cc33849ece9a7287`
- `encrypted.rar`: `a3fdc9e65d646c444dbebf42d821c027ff5413f59f235f0f11095b6fc39662ab`
- `solid-encrypted.rar`: `ab1aec0527dcf8feaf050642f7f592fda8cee44d0898a822cf22bd0ad93b8950`
- `comments.rar`: `bf198b41ff9ccbb3c0fb001af2d3039cd248f1b012ef847fb884a35a15035ebd`

RAR 1.402 の大きい実書庫は `inbox/rar13` に置き、`KAITOKIT_RAR13_FIXTURES` で渡す
非配布の比較対象です。これらの fixture には含めていません。
