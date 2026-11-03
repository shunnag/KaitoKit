# RAR 2.50 (unpack version 20) fixtures

公式の `https://www.rarlab.com/rar/rar250.exe` から UNRAR で取り出した RAR 2.50 を、
一時領域の DOSBox-X で実行して生成した書庫です。テストデータはこのプロジェクトで決定的に生成し、
bitplane/rar-research の書庫は fixture には含めていません。

| fixture | 生成コマンド | 入力 |
|---|---|---|
| `autorej.rar` | `RAR.EXE a -m5 -mm AUTOREJ.RAR PLAIN.TXT` | `Hello text not audio.\r\n` × 100 |
| `audio.rar` | `RAR.EXE a -m5 -mm AUDIO.RAR PCM_LR.WAV` | 8,192 frame の 16 bit little-endian stereo PCM。L = round(20000·sin(i·2π/256))、R = round(15000·sin(i·2π/384+1)) |
| `biglz.rar` | `RAR.EXE a -m5 BIGLZ.RAR BIGLZ.BIN` | 160 KiB。`i % 97 < 64` では `(i * 31 + i / 11) & 255`（整数除算）、それ以外は seed 20261102 の Python PRNG |
| `solid.rar` | `RAR.EXE a -m5 -s SOLID.RAR SOLID1.TXT SOLID2.TXT` | `RAR 2.50 solid fixture repeated phrase.\r\n` × 396、`Second member with the same repeated phrase.\r\n` と同じ phrase の連結 × 276 |

`autorej.rar` と `audio.rar` は `-mm` 指定です。`audio.rar` には音声ブロックが含まれ、
`biglz.rar` は長い LZ ストリーム、`solid.rar` は member 間の状態共有を検証します。
`RAR20DecoderTests.testVersion26DeclarationUsesTheSameDecoder` は `autorej.rar` の
UNP_VER だけを 26 に変更し、header CRC を再計算したものも使います。UNRAR 7.23 が同じ PLAIN.TXT を
展開することを確認しています。

期待値は UNRAR 7.23 の展開出力を入力と全 byte 比較したうえで、その SHA-256 です。
1 / 3 / 4 チャンネルの独立した実書庫は今回の fixture には含みません。
