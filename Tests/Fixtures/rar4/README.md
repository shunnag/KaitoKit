# RAR4 R0 の project-owned fixture

`r0-*.rar.b64` は RAR 6.24 の CLI が決定的な自作入力から作った書庫。
第三者の decoder source は使わず、unrar 7.23 と bsdtar 3.8.10 は展開の黒箱 oracle として使う。
他の既存 fixture の出自は [NOTICE](../NOTICE) を参照。

```sh
swift build -c release --product kaito
python3 Scripts/fixtures/make-rar4.py --kaito .build/release/kaito
swift test --filter RAR4FilterFixtureTests
```

writer は `RAR4_TOOL` → `rar6` → `~/.local/opt/rar-6.24/rar` の順に探す。
入力の生成式・固定 seed は生成器内、各 entry の原本の size / SHA-256、writer version、
switch と照合結果は [r0-manifest.json](r0-manifest.json) に固定する。
全書庫は packed 64 KiB 以下で、base64 は 76 column。

| fixture | 入力 | 検査 |
|---|---|---|
| r0-rgb | 128×128 の 24-bit BMP、勾配・noise・模擬文字・図版 | RGB token と原本 SHA |
| r0-delta | 16-bit stereo PCM WAV | 4 byte-channel Delta token と原本 SHA |
| r0-e8 | 自作 x86_64 風 bytes（system binary は使わない） | E8 token と原本 SHA |
| r0-audio | 同じ stereo WAV | 4 byte-channel Audio token と原本 SHA |
| r0-ppmd-solid | 自作 text 2 member | PPMd mode、2 個目の model continuation、solid flag、両方の原本 SHA |

`RAR4FilterFixtureTests` は公開 reader と 257-byte read の decoder の両方で SHA を照合する。
filter は `RAR3FilterToken.parse` が認識し、decoder が登録した `SolidState.filterPrograms` の
種類を検査する。Sources/ に観測用 API を増やさず、test 内の Mirror で table を取得する。
単に writer の switch や書庫全体の SHA に依存しないので、同じ原本を filter 無しで再圧縮すると失敗する。
PPMd solid は逆順 read、後方 seek、reopen も検査する。

unrar と KaitoKit は全 fixture の全 entry が原本と一致した。bsdtar は filter 4 書庫が一致したが、
PPMd solid は `RAR solid archive support unavailable` で拒否した。この未対応は manifest に明示する。
三者の source を読むことはない。

RAR 6.24 の `-?` は `mc<par>`、同梱の利用者向け `rar.txt` は A/C/D/E/T を掲載する。
`-mcI+` は CLI に受理されるが、`-mc- -mcI+` の probe を KaitoKit で復号しても
filter table は空だったため Itanium fixture は追加していない。
