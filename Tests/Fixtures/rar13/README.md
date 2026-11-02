# RAR 1.3 / 1.4 fixtures

`Scripts/fixtures/make-rar13.py` が RAR13_FORMAT_SPECIFICATION.md の container・16-bit rolling checksum と、
`make-rar15.py` の独立 encoder で生成する小さな書庫です。第三者の decoder source は使っていません。
UNRAR 7.23 の `t` と `x` により、全ファイルの CRC と展開後の全 byte を照合しています。

```sh
python3 Scripts/fixtures/make-rar13.py --unrar /opt/homebrew/bin/unrar
python3 Scripts/fixtures/make-rar13-crypto.py --unrar /opt/homebrew/bin/unrar
python3 Scripts/fixtures/make-rar13-volumes.py --unrar /opt/homebrew/bin/unrar
```

`make-rar13-volumes.py` は書庫を 2 巻に分け、UNRAR でも連結展開を照合します。
`split.rar` / `.r00` は stored + 圧縮、`stored-split.rar` / `.r00` は stored の 2 巻です。
`solid-split` と `solid-main-split` は 2 件目の圧縮 bitstream を分割し、前 file の
辞書・adaptive Huffman 状態を巻またぎで引き継ぎます。各巻の `MHD_SOLID` も保持します。

暗号・comment の fixture は `make-rar13-crypto.py` が生成し、UNRAR の password 展開と
`unrar v` の comment 表示も照合します。password は `password` です。

- `encrypted.rar`: stored と圧縮の暗号化。password 未指定・誤り・再試行を検証する。
- `solid-encrypted.rar`: 暗号化 solid。entry ごとの復号と逆順読みを検証する。
- `comments.rar`: packed archive comment（`RAR 1.3 comment.\r\n`）と stored file comment（`note\r\n`）。

- `normal.rar`: stored の `stored.txt` と、literal + ShortLZ の `compressed.txt`（独立した 2 member）。
- `solid.rar`: main と 2 件目の file flag で solid を指定した `first.txt` / `second.txt`。
- `solid-main.rar`: 実 RAR 1.402 と同じく main header だけで solid を指定した 2 member。

SFX は `RAR13ReaderTests` が `normal.rar` に synthetic MZ / `RSFX` header を前置して検証します。
実 RAR 1.402 の `SFXSRC.EXE` は非配布の比較対象です。

各本文は `RAR15!\r\n` の 8 byte、`compressed.txt` だけその 2 倍です。solid の 2 件目は
ShortLZ で 1 件目の窓を参照します。

archive SHA-256:

- `normal.rar`: `58d53afaad0645980a222536df5e3e3309baaa4158d7da22691793ec6ea52a27`
- `solid.rar`: `e28ab5c055aec2aebaa5d147419397e3e643714429d2ca29e73a3476cf809d06`
- `solid-main.rar`: `06f47c27b30e2ec7af2d96132789ad8cce7de9f1865212e1cc33849ece9a7287`
- `encrypted.rar`: `a3fdc9e65d646c444dbebf42d821c027ff5413f59f235f0f11095b6fc39662ab`
- `solid-encrypted.rar`: `ab1aec0527dcf8feaf050642f7f592fda8cee44d0898a822cf22bd0ad93b8950`
- `comments.rar`: `bf198b41ff9ccbb3c0fb001af2d3039cd248f1b012ef847fb884a35a15035ebd`
- `split.rar`: `e8dd6776a52bad1d539a51f82706d111752fb3d03d9538820add1d5e2b5c8daf`
- `split.r00`: `ddb960e89bb242b9d2ed36aea9db5e42a5df10252496beefc4640dc2598c88cb`
- `stored-split.rar`: `62a7f69a3918d80a34feda96d43738d7ec3bca0eca5e6a3010046330087ee46c`
- `stored-split.r00`: `5f55567d2c08caf881eda61b0e04505210434ff73aef15e5acee7aff52237f7c`
- `solid-split.rar`: `61815b43cc68624658df374a9960fe08f0f313861b70883c60096125e0ec7023`
- `solid-split.r00`: `52309c9bcdfa767aa2341e94260a99cb4f20131da11d022fed8e32114b5202d0`
- `solid-main-split.rar`: `ce6cef51ff0228f5f43c53fd0eeff35eb7258b25bcf962c641d495fe837f1052`
- `solid-main-split.r00`: `b23c2ab349e57f88954fd4d47a7e72f1a676c9a60c02f491048127181f347f23`

RAR 1.402 の大きい実書庫は `inbox/rar13` に置き、`KAITOKIT_RAR13_FIXTURES` で渡す
非配布の比較対象です。これらの fixture には含めていません。
