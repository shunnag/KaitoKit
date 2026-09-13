# StuffIt X slice 7: JPEG 再圧縮

2026-09-13、bd `cooViewer-gu28.7`、ブランチ `feat/stuffit`。

compression 7 の mode 0、mode 1 の色 baseline、mode 2 の baseline / progressive を Swift へ移植した。
出力は JPEG の元バイト列であり、画素復号や IDCT は行わない。
292 ストリームは **280 一致、12 拒否、失敗 0**。12 拒否は参照 Python と理由まで一致する。
通常の Windows 2009 / 2010 と Windows 2009 DES の JPEG は 220 バイトで、SHA-256 は
`e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1`。
第四の historical 例（2009 redundancy）は未対応の Root recovery が外側にあり、内包 JPEG の検証は未達。

## 入力と出自

実装入力は、指定された `inbox/stuffit/tools/stuffitx_jpeg*.py` 6 本と Ch.25–34 のみ。
16 ファイルを `inbox/stuffit/SHA256SUMS` と照合した。
既存 KaitoKit の ByteSource、Decompressor、ReadLimits、coordinator、暗号接続、試験補助を参照した。
検証には支給 JPEG コーパス、CC0 書庫、`archive-verification.json` と指定 `compare.py` を使用した。
Web、vendor バイナリ・逆アセンブル、他の JPEG／再圧縮実装ソースは開いていない。

移植元は利用者自身の独立 Python 実装であり、利用者の明示許可を適用した。
`StuffItXJPEGTables.swift` の数値は vendor バイナリの**測定値**。
直接の入力は `stuffitx_jpeg_tables.py`、指定された出自記録は `research/THIRD_PARTY_DATA.md`
（今回は開いていない）。SCALE は Python の十進 Double 定数と演算順序を保持した。

| Python 入力 | SHA-256 |
|---|---|
| `stuffitx_jpeg.py` | `35c0cf5bb0eea2ff2dd14ce8d93a79053c250928062ec4ab3d094f750562a3d0` |
| `stuffitx_jpeg_models.py` | `c2737ecd53396ddd09740b930e400126cbd705e575858681ca3a56d38e7d98e5` |
| `stuffitx_jpeg_baseline.py` | `7b1d5c64f282b4d61e6c4bb86e4d0da8c85f61c264d89981a15f2ea7feda2868` |
| `stuffitx_jpeg_mode1.py` | `57035cee6b257836166fd8f7b769ff68f15f1b4670dd7adcc967bb3d37bf7851` |
| `stuffitx_jpeg_tables.py` | `156e7acbfbe6e7797de482b7b99d4c80de0969eb118f47f9b0760b98cbedb24e` |
| `stuffitx_jpeg_restore.py` | `9bd11d270700c8fe1f143dce4ac4f4d7087a5f982eee437565b1e5c3bdaf5675` |

## 関数単位の対応

Python の metadata 集計、dataclass、CLI 引数処理は復元処理と分離した。
Swift は `restore_jpeg` / CLI と同じ厳密終端を使い、研究用 `restore_jpeg_prefix(exact=False)` の
後続 member 許容モードは公開していない。

| Python の関数・型 | Swift の対応 | 固定値の検証 |
|---|---|---|
| `JpegLimits`, `byte_limit`, `block_limit`, `jpeg_limits` | 呼び出しごとの `ReadLimits`、`maxJPEGBlocks` | 入力・出力・block 上限、異なる decoder の独立性 |
| `Bytes.byte`, `Bytes.wz`, `write_wz` | `StuffItXJPEGInput.byte/wz/writeWZ` | WZ の 0、127/128、16383/16384、UInt64.max、切詰め |
| `RangeDecoder.__init__`, `value` | `StuffItXJPEGRange.init/value/normalize/bit/bits` | code・range・消費位置の固定値、各 model の決定列 |
| `HeaderModel.__init__`, `byte` | `StuffItXJPEGHeaderModel.init/byte/update` | 1,000 バイト、rescale 回数と最終算術状態 |
| `wire_token` | `StuffItXJPEGEnvelope.wireToken` | literal、FF/FF、FF/00、FF/D8 |
| `_first_scan`, `jpeg_header`, `decode_header`, `Prefix` | `firstScan`、`JPEGPrefix`、decoder 初期化 | 固定ヘッダー、marker token、SOI/SOF/SOS、終端 |
| `decode_stored` | `StuffItXJPEGDecoder` の mode 0 | hex 固定例、64 ストリーム |
| `i16`, `trunc`, `cat4`, `category`, `activity` | `jpegI16`、Swift の整数 `/`、`jpegCat4/Category/Activity` | 分布・予測の固定値に符号・丸め境界を含める |
| `Model.__init__`, `row`, `combine` | `StuffItXJPEGModel.init/row/combine` | 共有領域のアドレス、水平／垂直 alias、全分布 |
| `Model.update`, `symbol`, `magnitude` | 同名関数と `updateRow` | byte wrap、rescale、escape と bit 順序 |
| `Model.dc_dist`, `dc` | `dcDist`, `dc` | 分布、ブロックの DC、算術状態 |
| `Model.h_dist`, `v_dist` | `hDist`, `vDist` | 文脈 offset と分布の hex 固定値 |
| `Model.ac_dist`, `sign_dist` | `acDist`, `signDist` | 3 成分 × 全 63 AC 位置の分布・更新後の次文脈 |
| `edge_predictor`, `dc_prediction` | `jpegEdgePredictor`, `jpegDCPrediction` | 近傍の有無 16 通り × quantizer 3 種、4 文脈 |
| `directional_prediction` | `jpegDirectionalPrediction` | profile 0/1/5 × 8 方向 |
| `Blocks.__init__`, `block` | `StuffItXJPEGBlocks`、`JPEGBlockStore` | mode 2 の 64 ブロック、coefficient/code/range の固定値 |
| `zigzag_order`, `ZIGZAG` | `StuffItXJPEGTables.zigzag` | Python 生成表、Huffman の完全出力 |
| `components_by_id` | `JPEGGeometry.componentsByID` | origin が途中で下がる場合の上書き・既定 slot |
| `Huffman.__init__`, `read`, `write` | `JPEGHuffman` | canonical code、読み書き、重複・all-ones 拒否 |
| `Tables.__init__`, `segment`, `scaled` | `JPEGTableSet` | DQT/DHT/DRI、SOF 固定 profile、scan snapshot |
| `EntropyWriter.__init__`, `put`, `finish`, `block` | `JPEGEntropyWriter` | stuffing、restart、算術 padding、baseline バイト列 |
| `decode_baseline` | `StuffItXJPEGBaseline.init/step` と decoder の `postScan/tail` | 240 px 段階照合、全 baseline、合成 marker/tail |
| `cat3`, `cat6`, `sc` | `jpegCat3`, `jpegCat6`, `jpegSignClass` | mode 1 の文脈・ブロック固定値 |
| `Mode1Blocks.dcrow`, `acrow`, `update`, `bits` | `dcrow/acrow/update`、`StuffItXJPEGRange.bits` | 480 回の関数入出力、更新後の行、算術状態 |
| `Mode1Blocks.dc`, `ac`, `sign` | 同名関数 | 上記固定値、MSB/LSB、row 80 の二重更新 |
| `Mode1Blocks.block` | 同名関数 | 96 ブロックの係数・置換 DC・算術状態、copy 上／左 |
| `decode_mode1` | `StuffItXJPEGMode1.init/step` と `postScan/tail` | 60 ストリーム、4:2:0 上左保存、AC terminator |
| `DelayedBits.flush/put/symbol/signed/finish/restart` | `JPEGDelayedBits` の同名関数 | 完全な最終 byte の保留・置換、stuffing、restart |
| `ScanEncoder.flush_eob/corrections/block/ac_first/ac_refine/finish` | `JPEGScanEncoder.flushEOB/corrections/block/acFirst/acRefine/finish` | DC 初回／refine、AC 初回／refine、出力と event 固定値 |
| `parse_scan`, `geometry`, `scan_units` | `parseScan`、`JPEGGeometry`、progressive `step` 内の走査 | slot 順、DC の padded 配置と AC の packed 配置 |
| `decode_progressive` | `StuffItXJPEGProgressive.headers/reconstruct/step` | 最終 DHT のみ保持、直接 marker の移動、DQT/DRI 更新 |
| `decode_literal_image` | decoder の literal 分岐と `tail` | scan のない mode 1/2、FF/D8 の EOI 化 |
| `_restore_jpeg`, `restore_jpeg` | `StuffItXJPEGDecoder`、compression 7 dispatch | 固定ストリーム、292 本、公開書庫 API |

固定値は `Tests/Fixtures/stuffit/slice7-jpeg-vectors.json` に保持する。
`Tests/Tools/stuffitx-jpeg-vectors.py` は許可 Python を直接呼ぶ再生成器。
試験用の range encoder はその区間更新式を逆向きに適用したもので、実装本体には含まれない。
長い EOB の 32,767 境界、correction buffer の 938 境界も固定出力・event 数で検証する。

## バッファと資源方針

- mode 0 は `read(into:)` の要求量だけをコピーする。
- baseline / mode 1 は MCU 一行ずつ出力し、近傍係数は二行の固定領域を再利用する。
- mode 2 の dequantized 値は Int16、量子化係数は escape を保持できる Int32 とする。
- progressive は量子化係数 plane と存在印・extent を block 上限以下で保持する。
  dequantized 近傍は二行。各 scan を再生成し、消費済み出力と scan descriptor を順次解放する。
- model 統計と scratch は固定長ポインタ。分布の四つの領域をまとめて検査してからアクセスする。
  可変長の marker／table 定義は低頻度のヘッダー処理に限定する。
- tail は最大 255 バイトの一 chunk、scan 後の segment は最大 65,535 バイト単位で出力する。
- `maxEntrySize` は圧縮入力と復元出力の双方に適用する。mode 1/2 の WZ 宣言長は
  参照どおり advisory とし、実終端・入力消費位置・容器の最終出力長を別に検証する。
- `maxJPEGBlocks` の既定は 2,097,152。幾何計算と上限検査を allocation より先に行う。
  上限超過は `limitExceeded`、入力不足は `truncated`、構造の破損は `malformed("StuffIt X JPEG …")`、
  未対応 profile は `unsupportedMethod("StuffIt X JPEG …")`。
  Python の 64 MiB / 1,048,576 は研究用 policy の許容範囲であり、Swift では既存 ReadLimits を
  呼び出し単位の上限とする。コーパスの Python には 64 MiB / 1,048,576 を明示した。

**仕様内の数値の食い違い:** 4032×3024 の 4:2:0 は `252 × 189 × 6 = 285,768` ブロックで、
4:4:4 は 571,536。元 spec の 262,144 は不足していたため、orchestrator の訂正で既定を
**2,097,152** に改めた。24 MP（6000×4000）の 4:4:4 と 48 MP（8000×6000）の 4:2:0 は
ともに 1,125,000 ブロックで、実在する写真を既定で拒否しないための値である。
progressive の量子化係数 plane は最大 `2,097,152 × 64 × Int32 = 512 MiB` で、
既存の `maxDictionarySize` 既定 1 GiB の資源方針の範囲内に収まる。
初回の大画像照合・性能測定で明示した `ReadLimits(maxJPEGBlocks: 1_048_576)` は試験に残した。

## エラー分類の訂正

元の `jpegError` は 89 出現で、内訳は helper 定義 1 と `throw` 88 箇所だった。全箇所を監査し、
文字列による動的な振り分けを使わず、各分岐で `jpegMalformed` / `jpegUnsupported` /
`KaitoError.truncated` を選んだ。複合条件 7 箇所の分離で `throw` が 8 箇所増え、
`read(into:)` の `catch KaitoError.truncated` による変換を 1 箇所削除した。
改訂後の明示 `throw` は **95 箇所: truncated 1 / malformed 79 / unsupportedMethod 15**。
削除した catch の経路と既存 byte reader からの入力不足も `truncated` のまま伝わる。
既存の資源上限検査による `limitExceeded` は、この集計に含めず維持した。

下表は Python のメッセージからの対応で、件数は改訂後 Swift の明示 `throw` 箇所数。
`malformed` と `unsupportedMethod` の診断には `StuffIt X JPEG ` を付ける。
`unsupported baseline scan` と `unsupported mode-1 scan` は語頭だけで分類せず、
SOF0 の scan パラメータ破損なので `malformed` とした。一方、16 bit の量子化表、
未対応の精度・成分数・sequential scan profile は、語頭が `unsupported` でなくても
`unsupportedMethod` とした。いずれも正常系の係数計算・出力処理には変更を加えていない。

| Python メッセージ（Swift 独自検査は注記） | KaitoError case | 箇所 | 条件・補足 |
|---|---|---:|---|
| `Huffman symbol range` | `malformed` | 1 | Swift の追加境界検査。 |
| `Huffman table selector` | `malformed` | 1 | — |
| `JPEG SOI required` | `malformed` | 1 | — |
| `JPEG encoded extent mismatch` | `malformed` | 1 | mode 1 / progressive / literal の encoded extent 検査も同じ経路に統合。 |
| `JPEG frame components` | `malformed` | 1 | 成分数 0 または ID の重複。 |
| `JPEG frame components` | `unsupportedMethod` | 1 | 重複のない 5 成分以上。 |
| `JPEG frame dimensions or precision` | `malformed` | 1 | 幅または高さが 0。 |
| `JPEG frame dimensions or precision` | `unsupportedMethod` | 1 | 寸法は正だが精度が 8 bit 以外。 |
| `JPEG frame layout` | `malformed` | 1 | — |
| `JPEG marker limit` | `malformed` | 1 | — |
| `JPEG marker prefix required` | `malformed` | 1 | — |
| `JPEG sampling factors` | `malformed` | 1 | — |
| `JPEG scan component references` | `malformed` | 1 | — |
| `JPEG scan layout` | `malformed` | 2 | SOF 不在、または SOS の長さ・成分数の不整合。 |
| `JPEG segment count` | `malformed` | 2 | — |
| `JPEG segment length` | `malformed` | 2 | — |
| `WZ integer overflow` | `malformed` | 1 | — |
| `ambiguous Huffman table` | `malformed` | 1 | — |
| `arithmetic code outside distribution` | `malformed` | 2 | — |
| `baseline AC range` | `malformed` | 1 | — |
| `baseline DC range` | `malformed` | 1 | — |
| `coefficient coordinates` | `malformed` | 2 | — |
| `coefficient model context range` | `malformed` | 3 | — |
| `duplicate coefficient block` | `malformed` | 1 | — |
| `duplicate mode-1 block` | `malformed` | 1 | — |
| `entropy bit value` | `malformed` | 1 | — |
| `inconsistent progressive approximation sequence` | `malformed` | 1 | — |
| `invalid JPEG Huffman code space` | `malformed` | 1 | — |
| `invalid frequency total` | `malformed` | 1 | — |
| `missing Huffman symbol` | `malformed` | 1 | — |
| `missing coefficient neighbor` | `malformed` | 1 | — |
| `missing mode-1 coefficient neighbor` | `malformed` | 1 | — |
| `missing progressive DC scan` | `malformed` | 1 | — |
| `mode-1 AC context range` | `malformed` | 1 | — |
| `mode-1 DC context range` | `malformed` | 1 | — |
| `mode-1 baseline JPEG required` | `malformed` | 1 | frame または scan が欠けている。 |
| `mode-1 baseline JPEG required` | `unsupportedMethod` | 1 | frame は存在するが SOF0 ではない。 |
| `mode-1 coefficient coordinates or block limit` | `malformed` | 2 | — |
| `mode-1 left copy without neighbor` | `malformed` | 1 | — |
| `mode-1 measured three-component interleaved profile required` | `unsupportedMethod` | 1 | mode 1 で未対応の成分数・interleave profile。 |
| `mode-1 sign context range` | `malformed` | 1 | — |
| `mode-1 upper copy without neighbor` | `malformed` | 1 | — |
| `mode-2 baseline JPEG required` | `malformed` | 1 | frame または scan が欠けている。 |
| `mode-2 baseline JPEG required` | `unsupportedMethod` | 1 | frame は存在するが SOF0 ではない。 |
| `mode-2 progressive JPEG required` | `malformed` | 1 | frame が欠けている。 |
| `mode-2 progressive JPEG required` | `unsupportedMethod` | 1 | frame は存在するが SOF2 ではない。 |
| `negative frequency` | `malformed` | 1 | — |
| `only eight-bit quantization tables supported` | `unsupportedMethod` | 1 | 表 ID は正常だが量子化表が 16 bit。 |
| `output extent mismatch` | `malformed` | 2 | Swift の容器出力長検査。 |
| `progressive AC range` | `malformed` | 1 | — |
| `progressive DC difference range` | `malformed` | 1 | — |
| `progressive DC scan arrangement` | `malformed` | 1 | — |
| `progressive Huffman selector` | `malformed` | 1 | — |
| `progressive Huffman symbol range` | `malformed` | 1 | Swift の追加境界検査。 |
| `progressive component references` | `malformed` | 1 | — |
| `progressive entropy bit value` | `malformed` | 1 | — |
| `progressive header length limit` | `malformed` | 1 | — |
| `progressive marker count limit` | `malformed` | 1 | — |
| `progressive scan count limit` | `malformed` | 1 | — |
| `progressive scan length` | `malformed` | 1 | — |
| `progressive spectral selection` | `malformed` | 1 | — |
| `progressive successive approximation` | `malformed` | 1 | — |
| `only eight-bit quantization tables supported` | `malformed` | 1 | 表 ID > 3 または精度 nibble > 1。Swift 診断は `quantization table selector`。 |
| `raw JPEG extent mismatch` | `malformed` | 1 | — |
| `restart interval length` | `malformed` | 1 | — |
| `scaled quantization table` | `malformed` | 2 | — |
| `single interleaved scan required` | `unsupportedMethod` | 1 | 成分を別 scan に分ける sequential profile。 |
| `truncated input` | `truncated` | 1 | segment 内 byte getter の明示 throw。外部入力の不足も変換せず伝播。 |
| `undefined Huffman table` | `malformed` | 1 | — |
| `undefined mode-1 Huffman table` | `malformed` | 1 | — |
| `undefined progressive Huffman table` | `malformed` | 2 | — |
| `undefined quantization table` | `malformed` | 1 | — |
| `unknown Huffman code` | `malformed` | 1 | — |
| `JPEG scan layout` | `unsupportedMethod` | 1 | 未対応 SOF の後の SOS。Swift 診断は `unsupported JPEG frame marker`。 |
| `unsupported baseline scan` | `malformed` | 1 | SOF0 の Ss/Se/Ah/Al 不整合。 |
| `unsupported component arrangement` | `unsupportedMethod` | 1 | progressive の component arrangement 検査も共有。 |
| `unsupported jcodec mode` | `unsupportedMethod` | 1 | — |
| `unsupported marker after baseline scan` | `unsupportedMethod` | 1 | mode 1 の scan 後 marker 検査も共有。 |
| `unsupported marker before first scan` | `unsupportedMethod` | 1 | — |
| `unsupported mode-1 scan` | `malformed` | 1 | SOF0 の Ss/Se/Ah/Al 不整合。 |
| `unsupported progressive inter-scan marker` | `unsupportedMethod` | 1 | — |
| `unsupported sampling arrangement` | `unsupportedMethod` | 1 | mode 1 / progressive の sampling 検査も共有。12 本の拒否理由を維持。 |
| `unterminated WZ integer` | `malformed` | 1 | — |
| `zero quantization value` | `malformed` | 1 | — |

分類テストは WZ、三種類の extent、segment、Huffman、range、frame・scan、未対応の
精度・成分・sampling と、初期化後の読み取り不足を確認する。固定値の復号テストと
全 292 本の照合も維持し、12 本には引き続き
`unsupportedMethod("StuffIt X JPEG unsupported sampling arrangement")` を要求する。

## コーパスの内訳

manifest は writer 試行 384 行で、成功してファイルが存在するものが 292 本、writer exception が 92 行。
92 行は decoder に与えられるストリームではないので、復元結果の分母に含めない。

| 要求 mode / second | ストリーム | バイト一致 | 参照と同じ拒否 | 失敗 |
|---|---:|---:|---:|---:|
| 0 / 0 | 64 | 64 | 0 | 0 |
| 1 / 0 | 30 | 30 | 0 | 0 |
| 1 / 2 | 30 | 30 | 0 | 0 |
| 2 / 0 | 56 | 52 | 4 | 0 |
| 2 / 1 | 56 | 52 | 4 | 0 |
| 2 / 2 | 56 | 52 | 4 | 0 |
| 合計 | 292 | 280 | 12 | 0 |

拒否するものは `testfile-{240,800}-{b420q75,b422q50}.p2{0,1,2}.jc` の 12 本。
いずれも参照 Python は `unsupported sampling arrangement` を返す。
単一成分に 1×1 以外の sampling が指定されており、Swift も同じ理由で `unsupportedMethod` を返す。
復元できる profile として扱って別の JPEG を返すことはない。

段階照合は mode 0 の 64 本、mode 2 の 240 px 版、progressive の 240 px 版、mode 1 を含む
240 px の 83 本（77 一致・6 拒否）、release の全 292 本の順で行った。
Swift と Python の算術右シフトの演算子優先順位の差は、ブロック単位の固定値比較で検出して修正した。

## 書庫への接続

compression 7 は既存 coordinator の復号後に接続した。Ch.25 が指定する JPEG の key-6 digest は
展開後 JPEG の digest と区別する必要があったため、coordinator も変更した。
平文では圧縮入力全体、単層暗号では verifier と IV/salt を除く元の暗号文を照合する。
CRC-32 / MD5、AES / Blowfish / DES / RC4 の合成試験と digest 改変拒否を追加した。
複数暗号層そのものの後段 JPEG は動作するが、多層中の key-6 digest の位置はこの slice では
未対応として明示的に拒否する。反復・複数 scope の既存制限も維持する。

通常 2009、通常 2010、2009 DES の 3 書庫は公開 reader で JPEG と他 entry を読み切る。
各年の backcompat / install `.exe` 計 4 本も同じ JPEG の長さと SHA を検証する。
2009 の 168 バイト stream の最終算術状態は code `0x00acb00f` / range `0x0159601f` で参照と一致。

第四例 `testfile.stuffit_deluxe_2009.win.redundancy.sitx` は Root algorithm `5:0` で拒否される。
Ch.25 は同じ JPEG body と報告しているが、今回の許可入力には recovery 復元の実装・文法がない。
書庫 bytes から独立に取り出した payload を照合できていないため、第四例の一致は主張しない。
`archive-verification.json` の compression 7 明示レコードは通常 2009 / 2010 の 2 件であり、
Ch.25 の 4 件とは集合が異なる。この差を無視して historical 4/4 と数えない。

## 最終検証結果

| 検証 | 結果 |
|---|---|
| debug build | 成功、コンパイラ警告 0 |
| 全体 debug tests | KaitoKit 1,025 + Compat 23 = 1,048 件、45 skip、失敗 0 |
| 最終 JPEG release tests | 追加した mode 1 の 96 ブロック固定値テストを含む 15 件、2 skip、失敗 0 |
| 全 292 ストリーム | 280 バイト一致、12 同理由拒否、Swift / Python 差分 0 |
| historical 公開 API | 通常 2009 / 2010、2009 DES、および `.exe` 4 本の JPEG と他 entry を読み切った |
| historical 第四例 | Root recovery のため内包 JPEG は未検証 |
| ASan | 12,154 入力、所見 0、実行 19.506 秒 |
| `git diff --check` | 問題なし |

全体 debug suite の実行は約 334 秒。全体実行後に追加した mode 1 の block 固定値テストも、
最終 release の JPEG suite と追加の debug 単独実行でも成功した。skip は外部コーパス・測定を明示する環境変数や既存試験環境の条件による。
最終 JPEG suite の 2 skip は ASan 用敵対入力と個別性能測定で、両方とも別コマンドで実行した。

### compare.py の期待値補完

元の比較スクリプトは XADMaster の 0 バイト JPEG 行を使うため、正しく JPEG を復元すると
4 match / 14 superset / 2 Root recovery error / 0 mismatch になった。
通常 2009 / 2010 のオラクルにある `testfile.jpg` の空行だけを、**利用者指定の**
220 バイト・SHA-256 `e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1` で補完した。
KaitoKit の実行結果から期待値を生成せず、他の行は補完しない。
この必要な検証用変更は `inbox/stuffit-corpus/compare.py` に適用し、外部コーパスを再設置する場合の
同じ差分を `Tests/Tools/stuffitx-jpeg-compare.patch` に保存した。元の `.sha` オラクルファイルは変更していない。

指定フィルター `deluxe_20(09|10).win` の最終集計は **18 match / 0 name_diff / 0 superset /
0 no_oracle / 2 kaito_error / 0 mismatch**。
通常 2009 / 2010 はともに match。残る 2 error は各年の `.redundancy.sitx` の Root `5:0` であり、
compression 7 の失敗ではない。比較スクリプトの終了コードは 0。

### 性能

Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、`arm64-apple-macosx27.0.0`、release。
各 `IMG_0243-full-*.p20.jc` を 5 回復元し、毎回元 JPEG と全バイトを比較した。
入力ファイルのロード後から Decompressor の生成・読み切り・出力 Data の生成までを計測した。
SHA と元 JPEG の比較時間は計測外。block 上限は 1,048,576。

| stream の画像 profile | 中央値（秒） | 最大（秒） |
|---|---:|---:|
| b420q75 | 0.319237 | 0.324182 |
| b444q95 | 0.916384 | 0.919756 |
| b422q50 | 0.215429 | 0.216306 |
| gray | 0.357740 | 0.364963 |
| restart | 0.398665 | 0.400789 |
| prog | 0.645837 | 0.651652 |
| sips | 0.744498 | 0.747064 |

全 35 回が 2 秒以内。別に単一プロセスで実行した Python 参照の `b420q75` は 48.369223 秒、
Swift 中央値は 0.319237 秒で **151.5 倍**。
この実測環境では依頼文の Python 約 100 秒より短かったため、倍率は今回の実測値から計算した。

### 敵対的入力

初回の ASan を付けた release では、合成 stream 8 本と 240 px の mode 0/1/2、gray、4:4:4、
progressive、restart を含む 7 本を seed にした。
先頭 192 位置と全体 64 分割の切詰め、先頭 64 バイトの全 bit 反転、seed 固定の 128 bit 反転、
末尾追加・同一 stream 連結を実行した。上限は 65,536 バイト／4,096 blocks。
次の集計はエラー分類訂正前の記録である。

| 結果分類 | 件数 |
|---|---:|
| 復元成功（変異後も受理できる入力を含む） | 1,540 |
| `unsupportedMethod` | 3,765 |
| `truncated` | 6,836 |
| `limitExceeded` | 13 |
| 合計 | 12,154 |

ASan の error / warning、Swift trap、テスト失敗はいずれも 0。
変異 stream 単体には checksum がないため、「復元成功」は元 seed の画像と同一であることを意味しない。
checksum の改変拒否は別の coordinator 合成試験で検証した。

訂正後の `testAdversarialStreams` は `malformed` も正常な拒否結果として集計する。
乱数の初期値は `STUFFITX_JPEG_SEED` で指定でき、10 進または `0x`（`0X` も可）付き 16 進の
UInt64 を受け付ける。既定は `0x7357_2026`。各入力に対する乱数 bit 反転の回数は
`STUFFITX_JPEG_ROUNDS`（非負の 10 進 Int、既定 128）で指定する。0 の場合も切詰め・
先頭の全 bit 反転・末尾追加・連結は行う。設定は実行ログへ出力する。
設定値の解析は既定値、10 進／16 進の一致、0、UInt64 上限、不正文字・負数・桁溢れを単体検証した。

## orchestrator 指摘後の再検証

訂正前の成果物について、orchestrator は manifest の SHA と照合して 280 一致・12 拒否、
Python の独立再実行でも同じ 12 拒否を確認した。全体の compare.py は 200 match / 4 superset /
12 既知 error / 0 mismatch。slice 6 binary との 250 書庫比較は JPEG の 3 書庫だけが変わり、
容器経由の ASan 888 runs は所見 0 と報告された。本訂正はこの受理済み結果を出発点とする。

今回の変更ファイルは次の 11 本。係数モデル・予測・Huffman 出力の計算と数値表は変更していない。

- `Sources/KaitoKit/Core/ReadLimits.swift`
- `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGEnvelope.swift`
- `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGModels.swift`
- `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGBaseline.swift`
- `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGMode1.swift`
- `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEGDecoder.swift`
- `Tests/KaitoKitTests/StuffItXJPEGTests.swift`
- `README.md`
- `CHANGELOG.md`
- `Documentation/design.md`
- `Documentation/verification/2026-09-13-stuffit-slice7.md`

| 再検証 | 結果 |
|---|---|
| `swift build` | 成功、warning 0 |
| `swift test` 全体 | KaitoKit 1,029 件（45 skip）＋ Compat 23 件、失敗 0、warning 0 |
| release `testCorpus` | 292 本: 280 一致 / 12 拒否 / 失敗 0、warning 0 |
| `git diff --check` | 成功 |

コーパス内訳は mode 0 が 64 一致、mode 1 が 60 一致、mode 2 が 156 一致・12 拒否で不変。
復元できた 280 本は元 JPEG との全バイト比較と manifest の `source_sha256` の両方に一致した。
12 本の拒否理由はすべて `StuffIt X JPEG unsupported sampling arrangement`。
訂正前の `.build/jpeg-release.json` とも、292 本すべての状態・SHA・長さ・拒否理由が同一だった。
ログは `.build/jpeg-revision-{build,tests,corpus}.log`、結果は `.build/jpeg-revision-corpus.json`。

環境変数の上書きを ASan 付き release でも実行した。
`STUFFITX_JPEG_SEED=0x123456789abcdef STUFFITX_JPEG_ROUNDS=17` により、
**10,489 入力、所見 0、warning 0、テスト失敗 0**（17.793 秒）。
内訳は復元成功 1,287 / `truncated` 7,046 / `malformed` 1,912 /
`unsupportedMethod` 235 / `limitExceeded` 9。
ログは `.build/jpeg-revision-asan.log`、集計は `.build/jpeg-revision-mutation.json`。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
STUFFITX_JPEG_CORPUS=1 STUFFITX_JPEG_REPORT=revision-corpus swift test -c release -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItXJPEGTests/testCorpus
STUFFITX_JPEG_MUTATE=1 STUFFITX_JPEG_SEED=0x123456789abcdef STUFFITX_JPEG_ROUNDS=17 swift test -c release -debug-info-format none --build-path .build/jpeg-asan --sanitize address --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItXJPEGTests/testAdversarialStreams
git diff --check
```

## 変更ファイルと検証出力

- 新規 codec 6 本: `Sources/KaitoKit/Codecs/StuffItX/StuffItXJPEG{Envelope,Models,Baseline,Mode1,Tables,Decoder}.swift`
- 接続: `StuffItXCodec.swift`、`ReadLimits.swift`、`StuffItXStreamCoordinator.swift`
- 試験: `Tests/KaitoKitTests/StuffItXJPEGTests.swift`、`Tests/Fixtures/stuffit/slice7-jpeg-vectors.json`
- 再生成・一括照合: `Tests/Tools/stuffitx-jpeg-{vectors,tables}.py`、`verify-stuffitx-jpeg.py`
- 比較期待値: 外部 `inbox/stuffit-corpus/compare.py` と保存差分 `Tests/Tools/stuffitx-jpeg-compare.patch`
- 文書: 本記録、CHANGELOG、README、design §10/§11、`Tests/Fixtures/NOTICE`

主要ログは `.build/jpeg-final-{build,tests,release-build,release-tests,compare,differential}.log`、
結果は `.build/jpeg-release.json`、`jpeg-oracle-expanded.json`、`jpeg-historical.json`、
`jpeg-performance.json`、`jpeg-python-benchmark.json`、`jpeg-mutation.json`。
ASan ログは `.build/jpeg-asan-final.log`。
最終変更は指定 worktree 内にある。初回の表生成器だけは `/private/tmp/jpeg_tables_generate.py` に
一時作成してしまったため、直ちに worktree 内へ移動した。既存の worktree 外ファイルは変更していない。
checkout / restore / stash / reset / commit / push は実行していない。

## 再現コマンド

この環境ではホーム側 cache が書込み禁止のため、既存 slice と同じく cache / config / security と
Clang module cache を worktree 内へ向けた。通常の素の `swift build` は cache 権限で失敗する。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
swift build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift test --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
swift build -c release --product kaito -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
# 外部 compare.py が未補完なら、一度だけ patch -p1 < Tests/Tools/stuffitx-jpeg-compare.patch を適用
python3 inbox/stuffit-corpus/compare.py .build/out/Products/Release/kaito --only 'deluxe_20(09|10).win'
STUFFITX_JPEG_CORPUS=1 STUFFITX_JPEG_REPORT=release swift test -c release -debug-info-format none --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItXJPEGTests
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Tools/verify-stuffitx-jpeg.py --swift-report .build/jpeg-release.json
STUFFITX_JPEG_BENCHMARK=1 swift test -c release --skip-build --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItXJPEGTests/testFullSizePerformance
STUFFITX_JPEG_MUTATE=1 swift test -c release -debug-info-format none --build-path .build/jpeg-asan --sanitize address --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox --filter StuffItXJPEGTests/testAdversarialStreams
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Tools/stuffitx-jpeg-vectors.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Tools/stuffitx-jpeg-tables.py
```

`verify-stuffitx-jpeg.py` は同一 SHA のストリームを一度だけ Python で復元し、292 行へ展開して
Swift の結果と比較する。`.build/jpeg-oracle.jsonl` に中間結果を保存する。
初回は全入力を読み、以降は同じ入力 SHA の結果を再利用する。

## orchestrator の独立検証（受理）

Codex の結果を、同じ worktree で別に組み立てた binary と別の seed で確かめた。

| 検証 | 結果 |
|---|---|
| `swift build` / release build | warning 0 |
| `swift test`（訂正前・訂正後の 2 回） | 全 suite 失敗 0（訂正後の全件数は Codex の同時刻ログ `1,029 + 23`、`.build/jpeg-revision-tests.log`） |
| 292 ストリーム（release、`testCorpus`） | Swift の出力 SHA-256 と長さを **manifest の `source_sha256` / `source_bytes`**（コーパス生成時に元 JPEG から計算した値。Codex の Python オラクルとは独立）と照合し、280 一致・12 `unsupportedMethod("StuffIt X JPEG unsupported sampling arrangement")`・不一致 0 |
| 参照 Python の再実行 | 拒否 12 本のうち 2 本を自分で `stuffitx_jpeg_restore.py` に流し `unsupported sampling arrangement`。一致側 3 本（mode 1 / 2、restart、800 px progressive）も自分で復元して元 JPEG と `cmp` 一致 |
| 拒否 12 本の正体 | 元画像 `testfile-*.jpg` は**グレースケール 1 成分**で、`cjpeg -sample 2x2` / `2x1` により単一成分に 1×1 以外の sampling が付いた人工的 profile。参照 Python と同じ拒否で、黙って別の出力を返さない |
| `compare.py`（CC0 216 本） | 200 match / 4 superset（`rreceipt.exe` の受領書 1 件）/ 0 no_oracle / 12 kaito_error（classic password の resource fork なし 2、SITX recovery/redundancy 10。いずれも slice 6 以前から同じ）/ **0 mismatch**。2009 / 2010 / 2009 DES の `testfile.jpg` は 220 バイト・`e5142325…` |
| 出力同一性（slice 6 の main binary との比較、CC0 216 + go 17 + perf 17 = 250 書庫、`kaito sha --forks -p password`） | 差分は JPEG を含む 3 書庫のみ（`unsupportedMethod` → 220 バイトの JPEG 行）。他 247 書庫は全行一致 |
| 性能（release、`testFullSizePerformance`、4032×3024 の mode 2、5 回） | b420q75 0.33 s / b444q95 0.96 s / b422q50 0.22 s / gray 0.37 s / restart 0.41 s / prog 0.67 s / sips 0.78 s。すべて 2 秒以内 |
| ASan（`swift test --sanitize address`、`testAdversarialStreams`、**seed 0x5158650、rounds 512**） | 17,914 入力（accepted 2,389 / truncated 10,582 / malformed 4,557 / unsupportedMethod 370 / limitExceeded 16）、所見 0 |
| ASan（容器経由、`inbox/bench/mutate-sitx.py`、ASan 付き `kaito sha`） | 888 runs、所見 0 |

訂正 3 点（`maxJPEGBlocks` 既定 2,097,152、エラー分類 truncated / malformed / unsupportedMethod、
敵対的テストの seed / rounds 環境変数）は orchestrator の指示によるもので、codec の復号結果は変えていない
（訂正後の 292 本の SHA・拒否理由は訂正前と同一）。
`compare.py` の `superset` 区分・`oracle/known/`（StuffIt 7 Mac `.sitx` の期待値）・`.exe` の兄弟オラクル対応は
orchestrator が同日に加えた比較ハーネス側の変更で、KaitoKit の出力からは期待値を生成していない。
