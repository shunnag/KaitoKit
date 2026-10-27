# 7z entry KDF

`python3 generate.py` で再生成する。自作 header と SHA-256 KDF、OpenSSL の AES-256-CBC primitive
だけを使い、第三者の archive writer / 実装ソースは使わない。password は `anypw`。
各 entry の平文は `Kaito KDF test!\n`、CRC 付き、cyclesPower は 8。
`distinct` は異なる salt の 33 folder、`shared` は同じ salt の 2 folder。

計測用（テスト suite では使わない）:

```sh
python3 Tests/Fixtures/sevenzip-kdf/generate.py --output /tmp/crafted4.7z --folders 4 --power 24 --opaque
```

`--opaque` は KDF を実行せず零の暗号文を置き、CRC を省く。復号結果の正しさは検査せず、
folder ごとの導出コストだけを測る。manifest の SHA-256 は復号前の書庫全体。
