# StuffIt X KDF

`generate.py` は `StuffItXContainerTests.Writer` と同じ自作 p2 / element / frames の文法だけを使う。
空 catalog に RC4 の key-length record を並べ、暗号文は置かない。password を与えると verifier の
読み取りより先に KDF が実行される。鍵長の受理範囲を変えず、仕事量の制限が先に働くことを検査する。
第三者の archive 実装ソースは参照しない。

```sh
python3 Tests/Fixtures/stuffitx-kdf/generate.py --output /tmp/catalog65536.sitx
```

`catalog65536.sitx.b64` は既定引数の出力。再生成は `base64.encodebytes` を使う。
回帰テストでは既存の Swift test writer で同じ byte 列を作り、checked-in fixture と照合する。
