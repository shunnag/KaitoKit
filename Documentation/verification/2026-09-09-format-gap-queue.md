# XADMaster が対応し KaitoKit が未対応の形式 — 実装キュー(2026-09-09)

出典は The Unarchiver の対応形式一覧(prose の documentation。`theunarchiver.com` と
GitHub wiki mirror `mietek/theunarchiver`。**source は参照していない**、§10)と、
手元コーパスでの black-box 実測。

**方針**: 汎用書庫ライブラリとして XADMaster との差をできるだけ減らす。特定の
利用側(cooViewer 等)の都合では優先順位を決めない。

## 実測で確認した差

`hdiutil` / `cpio` / `ar` / `xar` で生成した書庫を両エンジンに与えた結果:

| 書庫 | XADMaster | KaitoKit |
|---|---|---|
| ISO 9660(plain / Joliet)| 5 entry | `Unsupported archive format` |
| cpio(newc / odc)| 6 entry | 同上 |
| ar | 2 entry | 同上 |
| xar | 4 entry | 同上 |
| UNIX compress `.Z` | 1 entry | **一致**(対応済み)|
| HFS dmg | 開けない | 開けない(差ではない)|

## 検証方法とツールの状況

オラクルは XADMaster の実行ファイル(black-box)。fixture の作り方は 3 通り:

- **A. 手元にツールがある** — `hdiutil`(ISO)、`cpio`、`ar`、`xar`、`zip`、`7zz`、
  `lha`、`tar`、`zstd`。この範囲は即座に検証できる。
- **B. 既存ツールの組合せで作れる** — Deb は `ar` + `tar.gz`/`tar.xz`、
  RPM は header + cpio payload。どちらも手元の道具で構成できる。
- **C. writer が無い** — ARJ / ZOO / ARC / PAK / CAB / StuffIt / ACE / ALZip /
  LZX / ADF / DMS など。仕様から encoder を自作し、**XADMaster が正しく読めることを
  先に確認**してから KaitoKit と突き合わせる。XADMaster がオラクルとして機能するので、
  自作 encoder と自作 decoder が同じ誤読をする循環は避けられる。

C の形式は brew で writer を入れれば独立確認が増えるが、必須ではない。
導入が要る場面では都度ユーザーに確認する。

## 実装キュー

汎用性(遭遇頻度)と実装可能性で並べる。

| 順 | 形式 | 内容 | fixture | bead | 状況 |
|---:|---|---|---|---|---|
| 1 | **ISO 9660** | ECMA-119 + Joliet + Rock Ridge(SUSP/RRIP) | A | `cooViewer-ogfp` | 実装済み `a1a2753` |
| 2 | **cpio** | newc / odc / bin / crc / hpodc | A(checked-in)| `cooViewer-7wbx` | 実装済み `94bc3f5` |
| 3 | **ar** | SysV/GNU 長名表・BSD `#1/` 長名 | A(checked-in)| `cooViewer-7wbx` | 実装済み `4466c30` |
| 4 | **xar** | XML TOC + zlib/bzip2/lzma heap | A(checked-in)| `cooViewer-7wbx` | 実装済み `deed11d` |
| 5 | **Deb** | `ar` の中の `debian-binary` + `control.tar.*` + `data.tar.*` | B | 未作成 | 対応済み(ar reader が兼ねる) |
| 6 | **RPM** | lead + signature/header(index+store)+ cpio payload | B | 未作成 | — |
| 7 | **CAB** | MSZIP(Deflate)/ LZX / Quantum、folder 跨ぎ | C | 未作成 | — |
| 8 | **ZIP method 93/95/96/98** | Zipx: zstd / xz / JPEG / PPMd | A | `cooViewer-th30` | — |
| 9 | **ARJ** | 古典 DOS 書庫 | C | 未作成 | — |
| 10 | **ZOO** | 古典 | C | 未作成 | — |
| 11 | **ARC / PAK / Squeeze / Crunch / LBR** | CP/M・DOS 系。RLE と LZW が主 | C | 未作成 | — |
| 12 | **StuffIt / StuffIt X** | Mac 古典。SIT は方式が多い | C | `cooViewer-gu28` | — |
| 13 | **Compact Pro / PackIt / DiskDoubler** | Mac 古典 | C | 未作成 | — |
| 14 | **LZX / PowerPacker / ADF / DMS** | Amiga | C | 未作成 | — |
| 15 | **ACE**(旧形式のみ)| XADMaster も 2.0 は非対応 | C | 未作成 | — |
| 16 | **ALZip** | Bzip2 / Deflate / 難読化 Deflate | C | 未作成 | — |
| 17 | **WARC** | HTTP record の連結。構造は単純 | B | 未作成 | — |
| 18 | **MSI / NSIS** | MSI は CFB 複合ファイル、NSIS は版が多い | C | 未作成 | — |

### Deb について(2026-09-09 追記)

実測の結果、**追加実装は不要**だった。`.deb` は ar 書庫そのもので、XADMaster も
入れ子の `control.tar.*` / `data.tar.*` へは降りず、3 つの member をそのまま並べる。
KaitoKit の ar reader も同じ 3 entry を返し、data の圧縮を gz / xz / bz2 に変えた
3 種すべてで順序込みの総合 digest が XADMaster と一致した。

| fixture | entry 数 | 総合 digest | 判定 |
|---|---|---|---|
| gz.deb | 3 | 86b19017962a8c93bc8df683ff7d7cd8122b94e196e0453ea0a33e42deceedb0 | 一致 |
| xz.deb | 3 | 5424bbf28f1e6b82dc9819a342b6de04b54fbaae57f9ddbdf5fee5189f6da882 | 一致 |
| bz2.deb | 3 | e66abcf7a315a6bbe5a0e14e1a452c6df0ec19ab8045762bc41734ad108cc212 | 一致 |

入れ子の tar を透過的に展開するかどうかは形式対応の話ではなく UI の設計判断なので、
XADMaster との差を埋める本キューの対象からは外す。

ディスクイメージの BIN / MDF / NRG / CDI は ISO 9660 の上に載る raw sector 形式なので、
1 を終えてから同じ reader の入口として扱う。

SWF / PDF / NDS / NSA / SAR は「書庫の展開」ではなく「メディアの抽出」なので、
KaitoKit の対象外とする(XADMaster との差として残ることは記録しておく)。
