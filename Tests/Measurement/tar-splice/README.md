# 圧縮 tar の splice の probe の入力

`make-tar-splice-manifest.py` は、GyoshukuKit の prototype が残した P3 の corpus（`<corpus>/p3val`：
results.jsonl・chunk map・`tools/chain.py`）を読むだけで変えず、63 + 12 件の splice の segment を JSON で
標準出力へ書く。`Tests/KaitoKitTests/Probes/TarEditScaleProbeTests.swift` が `KAITOKIT_TAR_SPLICE_PROBE`
でこの manifest を読み、splice で開いた結果が全体を開き直した結果と一致することと、その時間を測る。

```sh
python3 Tests/Measurement/tar-splice/make-tar-splice-manifest.py <corpus>/p3val > <tmp>/splice-manifest.json
KAITOKIT_TAR_SPLICE_PROBE=<tmp>/splice-manifest.json swift test -c release -Xswiftc -enable-testing --filter TarEditScaleProbeTests
```

corpus はリポジトリに含めない。検証記録: `Documentation/verification/2026-09-25-tar-splice-verification.md`。
