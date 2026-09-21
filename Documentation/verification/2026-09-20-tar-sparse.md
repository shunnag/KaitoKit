# tar の GNU sparse（pax 0.0 / 0.1 / 1.0）の展開追加（2026-09-20）

環境: macOS 27.2 / Apple Silicon / libarchive 3.7.4（OS 同梱 `bsdtar`）。

## 実装と範囲

- 実装入力は libarchive の `tar(5)` man page（BSD-2-Clause）"GNU tar pax archives" 節の記述
  （GNU.sparse.numblocks / offset / numbytes / size の 0.0、GNU.sparse.map の 0.1、
  GNU.sparse.major / minor / name / realsize と本文先頭の 512 byte block 列の 1.0）と、
  `bsdtar --format pax` が F_PUNCHHOLE で穴を開けた APFS 上の file から書いた 1.0 書庫の黒箱観察
  （map は改行区切りの十進で「fragment 数、offset、size…」、512 byte に padding、header 名は
  `GNUSparseFile.<pid>/<name>`、header の size は map block を含む格納長）。GNU tar / libarchive の
  実装 source と GNU tar manual（GFDL）は参照していない。
- `TarReader` は pax の GNU.sparse.* を保持し（0.0 の offset / numbytes 対は `parsePAX` が出現順のまま
  `GNU.sparse.map.0.0` にまとめる）、`TarSparseMap`（昇順・非重複・実サイズ内・格納長との一致を検証）
  を作る。1.0 は本文先頭から map block を `maxMetadataSize` の範囲で読み、fragment 本文の開始を
  その後ろへずらし、`GNU.sparse.name` を entry 名にする。
- `TarSparseDecompressor` が穴を 0 で埋めながら実サイズ分を返す。entry の `uncompressedSize` は
  実サイズ、`compressedSize` は格納長、method は `tar (sparse)`、`formatSpecific["sparse"]` に版、
  `sparseFragmentCount` に fragment 数。合計上限は実サイズで数える。
- 旧 GNU の typeflag `S`（header 内の sparse 表と拡張 header）は writer も reader オラクルも手元に無く、
  man page の記述に「各 fragment は 512 byte に padding される」という他の資料と一致しない曖昧さが
  あるため、従来どおり `unsupportedMethod` に留めた。star（`SCHILY.filetype=sparse`）と Solaris
  （`SUN.holesdata`）も同じ。global header の GNU.sparse は `malformed`。

## 検証

- `TarSparseTests` 5 件、失敗 0: 合成した 0.1 / 0.0 / 1.0 書庫（3 MiB の実サイズ、2 fragment、末尾は穴）
  を KaitoKit で読み、**同じ書庫を OS の bsdtar で file に展開した結果と SHA-256 が一致**（独立 reader）。
  bsdtar が書いた 1.0 書庫（F_PUNCHHOLE で穴を開けた実 file）も一致。map の非昇順 / 実サイズ超過 /
  格納長不一致 / 奇数個 / 非十進、size 無し、entry 上限、fragment 数上限、合計上限、major 2、
  realsize 無し、map が本文より長い、旧 GNU `S`、global の GNU.sparse、star の sparse、全部穴の file。
- 既存 `TarHardeningTests` 38 件、`TarIntegrationTests`、`CompressedTarAliasTests` が通過。
- release CLI: 4,204,400 byte の実 file（データ 4 KiB + 1 MiB の穴 + 3 MiB のデータ）を bsdtar 3.7.4 /
  3.8.9 で pax 化した書庫の `kaito sha` が原本と一致。

## 残る制約

- 展開時に穴は作らない（0 を書く）。
- 旧 GNU `S` 型は gnu-tar（Homebrew）などの writer で黒箱確認できるまで未対応。
