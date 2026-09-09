# XADMaster が対応し KaitoKit が未対応の形式 — 実装キュー(2026-09-09)

出典は The Unarchiver の対応形式一覧(prose の documentation。`theunarchiver.com` と
GitHub wiki mirror `mietek/theunarchiver`。**source は参照していない**、§10)と、
手元コーパスでの black-box 実測。

## 実測で確認した差(XADMaster が開き KaitoKit が開けない)

`hdiutil` / `cpio` / `ar` / `xar` で生成した書庫を両エンジンに与えた結果:

| 書庫 | XADMaster | KaitoKit |
|---|---|---|
| ISO 9660(plain / Joliet)| 5 entry | `Unsupported archive format` |
| cpio(newc / odc)| 6 entry | 同上 |
| ar | 2 entry | 同上 |
| xar | 4 entry | 同上 |
| UNIX compress `.Z` | 1 entry | **一致**(対応済み)|
| HFS dmg | 開けない | 開けない(差ではない)|

## 実装キュー

cooViewer は漫画ビューアなので、書庫としての実用度と、cooViewer が既に対応を
宣言しているかを基準に並べる。

| 順 | 形式 | 根拠 | bead |
|---:|---|---|---|
| 1 | **ISO 9660**(+ Joliet / Rock Ridge)| スキャン漫画のディスクイメージ。P1 | `cooViewer-ogfp` |
| 2 | **StuffIt / StuffIt X** | cooViewer が `.sit` の対応を宣言しているのに開けない | `cooViewer-gu28` |
| 3 | **cpio / ar / xar** | 実測済みの差。fixture は checked-in 済み | `cooViewer-7wbx` |
| 4 | **ZIP method 93/95/96/98**(Zipx)| ZIP の中の方式差。zstd / xz / JPEG / PPMd | `cooViewer-th30` |
| 5 | ARJ | 古い書庫。漫画では稀 | 未作成 |
| 6 | ACE(旧形式のみ)| `.cba` は Comic Book ACE。XADMaster も 2.0 は非対応 | 未作成 |
| 7 | Zoo / ARC / PAK / LBR / Squeeze / Crunch | 歴史的形式 | 未作成 |
| 8 | CAB / MSI / NSIS | Windows installer 系。漫画では稀 | 未作成 |
| 9 | ALZip(`.alz`)| 韓国圏。漫画配布に使われることがある | 未作成 |
| 10 | RPM / Deb / WARC | 漫画ビューアの用途外 | 作らない |
| 11 | LZX / PowerPacker / ADF / DMS / DiskDoubler / Compact Pro / PackIt | Amiga・旧 Mac。用途外 | 作らない |
| 12 | NDS / SWF / PDF / NSA / SAR | 書庫ではなく抽出。用途外 | 作らない |

ディスクイメージの BIN / MDF / NRG / CDI は ISO 9660 の上に載る raw sector 形式なので、
1 を終えてから同じ reader の入口として検討する。
