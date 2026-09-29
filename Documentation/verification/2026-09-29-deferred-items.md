# 2026-09-29 後回しにしていた整理項目の処理記録（KaitoKit）

2026-09-28 のコード品質レビューで見送った項目を、Fable（orchestrator と advisor）と Codex の相談の上で「実施」か「据え置き（理由付き）」に振り分けた記録。
判断基準は「KaitoKit / GyoshukuKit を他の人や AI が使うときに使い勝手が良いのはどちらか」。

## 実施（この round）

| 項目 | 内容 | commit |
|---|---|---|
| KK-B F12 | AES-CBC random access を `Core/AESCBCRandomAccess` に一つに | 7d45183 |
| KK-C F15 | 圧縮単一 file の接尾辞の表 `CompressedNaming`（`.taz` の fallback 名は `x.tar`） | dee4e02 |
| KK-B F19 (a) | RAR / Blake2 のテスト専用 API の印、呼び手のない `Data` 版の鍵導出の削除 | 3674ad1 |
| KK-A F4 | `FormatDetector` の EOCD 走査を `ZipEndRecords.findEndRecords` に | 85d26b3 |
| KK-B F5 | RAR4 / RAR5 の solid coordinator を generic な一組に | 1006df4 |
| KK-D F16 | C library wrapper の入力補充を `Core/ChunkedSourceInput` に（over-read は `.truncated`） | 5992208 |
| KK-E F17 | LArc / LZHUF / StuffIt LZAH の初期化値を `Codecs/OkumuraLZSSSeeds` に（利用者の決定で StuffIt→LHA 依存を許可） | 0ca6046 |
| 軽微 | `LHAExtendedHeader` の型名、`NameEncodingScorer+*.swift`、`TarHeaderBlock.size` | a5494d7 |
| KK-D F2 | `Codecs/PPMd/VariantH/` と `VariantI/` | 897fcc0 |
| 883 行の locator | `ZipCentralDirectoryLocator` を三つの責務の file に分割（純移動。release `kaito list --raw` / `sha` を 13 種の ZIP で main と比較し同一） | 897fcc0 |

## 据え置き（理由付きで閉じる）

| 項目 | 理由 | 合意 |
|---|---|---|
| KK-E F20 `ZstdInput` と `LZ4FrameInput` の統一 | LZ4 は header 欄ごとの exact read で `contentSize` が payload を読まない契約（`LZ4LegacyTests`）。buffered read と exact read は別の挙動で、共通化は policy の機械を増やす | Fable・Codex 一致 |
| KK-B F14 任意層 `ByteCursor` | 7z / RAR5 / ZIP の cursor は形式固有の数値・bit vector・寛容な可変長整数を持ち、小さな具象型が文脈を保つ。extension でも module 内に露出する | 一致 |
| KK-E F21 (a) `StuffItXBrimstoneDecoder` の改名 | 「複数型の method 群だけ `Decoder` 接尾辞」で一貫している | 一致 |
| KK-B F19 (b) 一括復号 API の test 側への移動 | `ZipEncryptionPrimitiveTests` が鍵検証・CTR・遅延認証を一体で見る分離を変える。private を広げるか別経路を作るかのどちらも読みやすさを下げる。印で足りる | 一致 |

## 検証

`swift test` 全量、release `kaito` の byte 差分（perf 15 書庫・RAR 57 書庫・ZIP 13 種）、CI（macos-26 / macos-26-intel / xcode-27）。詳細は各 PR。
