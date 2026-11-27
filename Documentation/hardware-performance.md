# Mac構成別の性能方針

## 目的

KaitoKit と GyoshukuKit の書庫のbyte列、公開 API / SPI、エラー順を変えずに、異なるCPU・メモリ・電力条件でも過剰な並列投入を避ける。製品名やコア数の表をコードへ埋め込まず、実行時のOS情報とcodecごとの作業量を使う。

## 確認した構成

| 構成 | CPU・メモリの例 | 実装上の意味 |
|---|---|---|
| [Mac mini M1](https://support.apple.com/en-us/111894) | 8 core（4 performance + 4 efficiency）、8〜16 GB | 小さいメモリと少数workerの両方を試す基準 |
| [Mac mini M4 / M4 Pro](https://support.apple.com/en-us/121555) | M4: 10 core（4+6）、16〜32 GB。M4 Pro: 標準 12 core（8+4）、14 core の選択肢あり、24〜64 GB | core構成とメモリが同じ世代でも異なる |
| 実測した M4 Max | 16 core（12+4）、128 GB | 現行のrelease計測基準。製品名はplannerへ埋め込まない |
| [MacBook Pro M5 Pro / M5 Max](https://support.apple.com/en-us/126318) | 15 / 18 core（5 / 6 super + 10 / 12 performance）、24〜128 GB | performance という名称をそのまま従来のP-core区分へ写像しない |
| [Mac Studio M5 Max / M5 Ultra](https://support.apple.com/en-us/128107) | M5 Ultra: 30 core（10 super + 20 performance）は96 GB。36 core 構成には256 / 512 GBの選択肢がある | 大きいメモリでも、job数とcodecごとの実予約を別に制限する |
| [MacBook Pro M6](https://support.apple.com/en-us/148300) | 12 core（2 super + 4 performance + 6 efficiency）、16〜32 GB | 新しいsuper coreの区分と3 level以上の構成を製品名なしで扱う |
| [Mac Pro（Rack, 2019、Intel Xeon W）](https://support.apple.com/en-us/111907) | 8〜28 core、16〜56 thread、32 GB〜1.5 TB | perflevelがない環境では logical CPU とメモリへのfallbackが必要 |

これらは設計入力の代表例であり、対応機種の限定リストではない。M6 / M5 Ultra / Intel実機での今回の実行結果を意味しない。

## 現在の実装

`Sources/KaitoKit/Core/CPUTopology.swift` は `hw.activecpu`、`hw.nperflevels`、`hw.perflevelN.logicalcpu` / `physicalcpu` を読む。level 0を最高性能とするOSの番号順を使い、M6のsuper coreを特別扱いする製品名分岐はない。欠落・不正値・途中levelの欠落時は、有効logical CPUから単一levelへ戻す。

- 自動並列数は active logical CPU と物理メモリ GiB の小さい方で、固定のcore数上限はない。
- Low Power Mode / serious / critical の温度では、policyに応じてactiveの半分（切上げ）と最低性能levelの小さい方へ減らす。
- topology・電力・温度はopen / writer開始時に一度だけ確定する。実行中の状態変化で同じjobの片境界や出力が変わることはない。
- `LeafDecodePool` が非同期に投入する job の実行枠は process 共通で active logical CPU 数まで。待機中の consumer は未開始の job を自分で実行できる。LZ4 の独立 block も別の並列経路を使う。
- codecの辞書・入出力・完了済み出力には、CPU数とは別に `ReadLimits.parallelDecodeMemory` / `WriterOptions.memoryLimit` を適用する。
- 入力latency、実block数、項目数、連続性によって、並列化せず既存の直列経路を使う。
- 並列数を変えても書庫の形式と復号結果は同じ。`prefersSpeed` のような明示optionで初めて圧縮片の構成を変える。

GyoshukuKit は同じ topology を利用する。回帰試験には、M1型の4+4、M4型の4+6 / 12+4、M5 Pro / Ultra型、M6型の2+4+6、perflevelのない56 logical CPU、将来の4 level構成を含める。これらはOS値のmockで、それぞれの実機が同じsysctlを返すと仮定するものではない。

## GPU・NPUを追加しない判断

既存の検証では、LZ4 GPU復号がCPU 16 laneの0.15〜0.6倍、GPU 1 threadはCPU 1 coreの約1/350、NPUのGRU + range coderは0.24〜0.65 MB/sだった。したがって本番PackageにはMetal / Core MLを追加しない。詳細は [codecの性能・安定性検証](verification/2026-11-05-codec-performance.md) と [decodeの検証](verification/2026-11-03-decode-performance.md) にある。

PPMd・LZMA・bzip2の状態更新やbitstream処理を、Neural Engine / Neural Acceleratorsへ移すことは、現在の測定からは高速化の根拠を得られていない。独立frame・独立blockはCPUの既存pipelineを使い、AES / SHAなどはOSのCryptoKit / CommonCrypto経路を維持する。

将来GPUを再評価する場合は、大きな独立jobに限定し、shaderのcompile・buffer確保・CPUとの同期を含むwall timeで現行CPUと交互比較する。出力・prefix・CRC / HMAC・エラー順が完全一致し、M1クラスと現行高速CPUの両方で利益がある場合だけ検討する。GPU使用率やNPUの利用率自体を目的にはしない。

## 継続する検証条件

1. M1 / M4 / M6の低・中メモリと、M5 Ultraなどの大メモリで、open・decode・encode・大量entry展開を測る。
2. Low Power Mode、thermal pressure、CPU制限、低メモリを組み合わせ、直列化しても結果とerror順が変わらないことを確かめる。
3. arm64 / x86_64のuniversal framework buildとIntel実機のtestを分けて記録する。Rosettaやbuild成功をIntel nativeの性能証拠には使わない。
4. 変更前後のrelease binaryを交互に実行し、digest、返却済みprefix、出力byteを先に比較する。単一Macの倍率を他機種へ外挿しない。
5. 新しいOSのperflevel追加・欠落をmockで試し、製品名や既知のcore数がなくても安全な既定へ戻ることを維持する。
6. 大きいメモリでは全体の使用量を測り、reader / writerごとの予算の積算がprocessを圧迫しないかを別途確認する。

今回の新規実行はM4 Max / arm64が対象である。M6・M5 Ultra・Intel nativeの新規性能値は未測定なので、推定値として提示しない。


## 出力先と展開並列数の実測（2026-11-27）

KaitoFinder の実際の展開処理で、同じ ZIP の 128 ファイル（各 64 KiB）を内蔵 SSD と microSD の一時ディレクトリへ展開した。並列数の順序を変えた 3 回の中央値（ミリ秒）。各試行後に 128 ファイルの内容を照合した。

| 出力先 | 1 並列 | 4 並列 | 8 並列 | 16 並列 |
|---|---:|---:|---:|---:|
| 内蔵 SSD | 23.7 | 17.0 | 12.2 | 14.9 |
| microSD | 466.5 | 386.9 | 349.9 | 391.0 |

M4 Max の Debug ビルドでの、アプリが展開を完了するまでの時間。別の既存試験では、内蔵 SSD への小ファイル 5 万件の展開が直列 11.02 秒、8 並列 7.03 秒だった。出力先で所要時間は大きく変わる。今回の 2 媒体は同じ並列数で中央値が最短で、媒体種別から別々の worker 上限を導く根拠は得られなかった。ネットワークボリュームと回転ディスクの実測はこの比較に含まない。
