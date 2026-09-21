# ZIP / tar の AppleDouble sidecar 方針（2026-09-21）

環境: macOS 27.2 / Apple Silicon / ditto・bsdtar（OS 同梱、writer）/ Info-ZIP zip 3.0（暗号化標本）。

## 決定と実装

利用者の決定（2026-09-21）: 提案どおり **統合（merge）を既定**にする。`ReaderOptions.appleDoublePolicy` に
`.merge`（既定）/ `.hide` / `.expose` を追加した。

- 対象は ZIP と tar（圧縮 tar を含む）。`ArchiveReader` が `ZipReader` / `TarReader` を `AppleDoubleReader`
  （`FormatReader` の wrapper）で包み、内側 entry index への写像を持つ。sidecar が無ければ包まない。
- 候補は名前で選ぶ: `__MACOSX/a/._b` → `a/b`（Finder / ditto）、`a/._b` → `a/b`（macOS tar）。候補の先頭
  26 + 12 × entry 数 byte を内側 reader の stream で読み、AppleDouble の magic `00051607`・version 1 / 2・
  entry 表（32 個まで、範囲は宣言サイズ内）を確かめる。AppleDouble でなければ触らない。
- `.merge`: 参照先（file か directory）がある sidecar を隠し、entry 2（resource fork）の長さが 0 でなければ
  `target/..namedfork/rsrc`（`fork=resource`、`appleDoubleSidecar` に元の名前、日時は sidecar、権限は data file）を
  data file の直後に差し込む。fork の stream は sidecar の stream を offset まで読み飛ばして length byte 返す
  （`SliceDecompressor`）。参照先が無い sidecar は取りこぼさないため残す。
- `.hide`: AppleDouble と確かめた sidecar を全部隠す。暗号化された sidecar は中身を確かめられないので、
  Finder の `__MACOSX/` 配下だけ名前で隠す（merge では残す）。
- `__MACOSX` の directory entry は、その配下に見える file が残らなければ隠す。
- `rawRecord` は通常 entry だけ転送し、fork entry は nil。`reopen()` は内側を開き直して同じ写像を掛ける。
- compat の `entryIsResourceFork` は `formatSpecific["fork"] == "resource"` で true（従来は常に false）。
- Extractor は既存の `..namedfork/rsrc` 経路で fork を復元する（`__MACOSX` folder は作られない）。

## 出自

Apple の公開 developer note "AppleSingle/AppleDouble Formats for Foreign Files"（既存 StuffIt の AppleSingle
unwrap と同じ入力）と、`ditto -c -k --sequesterRsrc --keepParent` / bsdtar が書く sidecar の黒箱観察: Finder 製
sidecar は entry 9（Finder 情報 + xattr block）と entry 2（resource fork、無ければ長さ 0）の 2 entry を持ち、
xattr だけの file でも生成される。XADMaster の source は開いていない。

## 独立した検証データ

`Tests/Fixtures/appledouble/`（`generate.sh`、`SHA256SUMS`）: project-owned の 3 file（xattr だけの file、
resource fork 15 byte の file、sub directory 内の resource fork 9 byte の file）を ditto（ZIP、`__MACOSX/`）と
bsdtar（tar、`._name`）で書いたもの。

## 通過した検証

- `AppleDoubleSidecarTests` 5 件、失敗 0: ZIP / tar で merge の一覧・fork の内容（一括と 4 byte chunk）・
  fork の位置（data file の直後）・rawRecord・`reopen()`、hide / expose の一覧、展開で `__MACOSX` を作らず
  resource fork を復元、手組み tar で参照先の無い sidecar / AppleDouble でない `._` file / `__MACOSX` 配下の
  普通の file が残ること、暗号化 ZIP の sidecar が merge で残り hide で隠れること、header parser の境界。
- `KaitoArchiveAppleDoubleTests`（compat）、既存の ZIP / tar suite、`ReleaseReviewDocumentationTests`。
- release CLI: ditto の ZIP と bsdtar の tar で `list` / `sha` / `extract`。

```
$ kaito list finder.zip
0	0	directory	stored	plain	folder/
1	10	file	deflate	plain	folder/rsrc.txt
2	15	file	deflate	plain	folder/rsrc.txt/..namedfork/rsrc	fork=resource
…
```

## 残る制約

- Finder 情報（type / creator / flags）と xattr は復元しない。
- 7z / RAR など他形式の `__MACOSX` には適用しない（macOS の標準 writer が作らないため）。Archive Utility の
  `.cpgz`（ditto の cpio）も `._name` sidecar を書くが、利用者の指定範囲（ZIP / tar）に従い未対応。
- ZIP の directory 名は末尾 `/` を持つので、参照先の照合は `pathComponents` で行う（初版は `name` で照合し、
  directory の sidecar が残って `__MACOSX` ごと露出していた。advisor の指摘で修正、fixture に folder の xattr を追加）。
- 暗号化 ZIP の sidecar は password があっても open 時に中身を読まず、merge の対象にならない。
