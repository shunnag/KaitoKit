# container fixture

既存の cpio / ar / xar / CAB / RPM fixture の出自は [`../NOTICE`](../NOTICE) に記録する。
従来の RPM は ad hoc 生成で、元の生成 script は保存されていない。`rpm-v6.rpm.b64` は変更しない。

## RPM stripped payload

```sh
bash Tests/Fixtures/container/generate-rpm6.sh
```

必要な設置済み CLI は rpm 6.1.0（`rpmbuild` / `rpm` / `rpm2cpio`）、`bsdtar`、`zstd`、`gzip`、Python 3。
追加 install はしない。作業場所・rpm 一時領域・keyring は `/private/tmp` の専用 directory に閉じる。
生成・照合の失敗時は停止し、代わりの RPM を手組みしない。

自作 [`rpm-stripped.spec`](rpm-stripped.spec) を 3 回 build する。

| fixture | 指定 | payload |
| --- | --- | --- |
| `rpm-stripped-v6-zstd.rpm.b64` | `_rpmformat 6`、圧縮指定なし | `07070X` / zstd level 19 |
| `rpm-stripped-v6-gzip.rpm.b64` | `_rpmformat 6` / `_binary_payload w9.gzdio` | `07070X` / gzip |
| `rpm-stripped-v4-gzip.rpm.b64` | `_rpmformat 4` / `_binary_payload w9.gzdio` | newc / gzip |

spec は directory、10,537-byte text、空 file、日本語名、symlink、3-member hard link、
ghost を含む別の 3-member hard link、独立 ghost を持つ。header は 12 件、payload は 10 件。
mtime は UTC 2026-09-22 00:00 に固定する。package の buildtime は再生成時刻なので RPM 自体の hash は変わり得る。

[`record-rpm6.py`](record-rpm6.py) は `rpm -qp --qf`、`rpm2cpio | bsdtar -tvf -`、
`rpm2cpio | bsdtar -xOf - <name>` の実行結果を [`rpm-stripped-manifest.json`](rpm-stripped-manifest.json) に保存する。
SHA-256 は header の digest を転記せず、`rpm2cpio` 本文と bsdtar が返す本文から独立に算出・照合する。
stripped の復号 byte 列も検査し、member offset / index / data length と trailer 位置を記録する。
既存 `rpm-v6.rpm.b64` の 6 entry も同じ手順で照合する。

実装 source は参照しない。公開 prose と black-box writer / oracle のみを使う。
検証結果・受理範囲は [`2026-09-22-rpm-stripped-payload.md`](../../../Documentation/verification/2026-09-22-rpm-stripped-payload.md)。
