# リリース前横断検証（2026-09-17）

環境: macOS 27.0 arm64、Xcode 27。KaitoFinder / GyoshukuKit の実利用経路から検証した。
他の OS / Intel の実行結果ではない。

## 修正

- `.tar.lzma` / `.tlz` / `.tbz` を圧縮 tar として開く。LZMA_Alone は名前 hint に加え
  従来の properties・辞書サイズ・range coder の検査を保つ。普通の `.lzma` の単一ファイルの意味は変えない。
- 空の LHA は `.lha` / `.lzh` と正確な1 byteの終端の両方があるときだけ受理。
  空の LHA は固有の magic がないので、名前のない Data / ByteSource では自動検出しない。
  この修正で、GyoshukuKit と KaitoFinder の全削除後の再編集・undo/redo が通る。
- XZ は Apple Compression の初期化前にすべての LZMA2 辞書を `maxDictionarySize` と照合する。
  後続 block、連結 stream、xar の `xz` と XZ payload の `lzma`、圧縮tar/RPM の共通経路にも適用する。
  `XZResourceValidator` は chunk envelope を走査して payload を seek で飛ばす。先頭の辞書や
  Index の主張だけを信用しない。固定容量の読み取りと SHA-256 の Index size 照合を使い、
  payload の復号・checksum は従来の native decoder に委ねる。

仕様入力は [XZ の公開形式文書](https://tukaani.org/xz/xz-file-format.txt) と既存の LZMA2 文法。
第三者 archiver の codec 実装は参照していない。

## 再現と回帰

`CompressedTarAliasTests` 3件は Python tarfile/bz2/lzma から生成。lc3/4、大小文字、
メモリ／disk staging、unlink後のreopen、切断、サイズ・辞書上限を照合。
`EmptyLHATests` 2件は hint の必須性、誤判定防止、unlink後のreopenを確認。
`XZResourceLimitTests` 5件は Python/lzma・xz 生成の独立入力を使う。
後半だけが大きい辞書の2 block、4種の Check、空 stream、raw chunk、Delta、
全byte位置でのtruncate、不正なheader/VLI/padding、3 byteずつの読み出し、非ゼロ範囲開始を含む。

いずれも修正前の失敗を確認してから修正した。
ログ prefix `/private/tmp/kaitofinder-release-` に
`tar-aliases-before.log`、`empty-lha-before.log`、`xz-limits-before.log`、
対応する `after.log` と `xz-boundaries.log` を保存。

空の LHA は lhasa の list/test が成功する。一方、7-Zip 26.03 は空 LHA を拒否する。
外部ツール間の違いを「すべてのツールで検証済み」と表現しない。

## 全件

```sh
KAITOKIT_CAB_CORPUS="$PWD/inbox/cab-corpus" \
STUFFIT_SLICE6_CORPUS="$PWD/inbox/stuffit-corpus" swift test
```

1,154件、43 skip、失敗0。Compat は24件、失敗0。
CAB LZX の実製品CABを cabextract と全byte比較、StuffIt の暗号化実書庫も成功。
外部 LHA/RAR/ar/cpio 等の未指定 corpus、明示指定の JPEG/大容量、
システム InfoZIP の BZip2 非対応が skip に残る。
ログ: `/private/tmp/kaitofinder-release-kaitokit-final.log`。

`Scripts/fuzz/make-compressed-seeds.sh` の15種に ZIP 93、ZIP 98、CAB LZX、連結XZを追加し、
`Scripts/fuzz/run-mutants.sh --count 399 --timeout 5 --password KaitoFuzz <seeds>` を実行。
ASan/UBSan 有効、19 seed、399変異、crash 0 / hang 0 / sanitizer finding 0。
終了コードだけでなく診断文字列も検査する既存runnerを使用。
ログ: `/private/tmp/kaitofinder-release-fuzz.log`。

追加の Release 検証4件も失敗・skipとも0（44.3秒）。
`STUFFITX_JPEG_CORPUS=1 STUFFITX_JPEG_MUTATE=1 STUFFITX_LARGE_WINDOWS=1` を指定した。
JPEG corpus 292件のうち280件が全byte一致、12件は既知の sampling profile の未対応として期待どおり拒否。
7つの歴史的な実書庫、32 MiB距離境界も成功。敵対的入力12,154件は
accepted 1,540 / limitExceeded 13 / malformed 2,484 / truncated 7,859 / unsupportedMethod 258。
ログ: `/private/tmp/kaitofinder-release-extra-corpus.log`。明示的な未対応を読めたことには数えない。
形式の追加計画は KaitoFinder の `Documentation/compression-roadmap.md` に横断してまとめる。
新しい codec の追加時には、エンジンのfixtureだけでなくアプリのプレビュー・編集可否も照合する。

## アプリ側の最終接続確認（2026-09-18）

Macのロック解除後、最終コードを組み込んだKaitoFinder全758件は失敗0。
通常の全件実行でskipする履歴の1件は、別プロセスの4回の起動で成功した。
実ドラッグ・タブ・置換・保存パネル・更新設定を含むUI結合53件も失敗・skip 0。
署名済みReleaseの起動も確認済み。詳細はKaitoFinderの
`Documentation/verification/2026-09-17-release-hardening.md`に記録する。
