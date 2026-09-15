# ZIP 分割巻の実装・検証（Task Z1、2026-09-15）

対象: bd `cooViewer-6lrc.2`。`feat/zip-split-volumes`、基点 `d8da022`。
macOS 27.0（26A428）、Apple Silicon、Apple Swift 6.4、Swift 6 strict concurrency。

## 形式の根拠とクリーンルーム方針

- [PKWARE APPNOTE 6.3.9](https://pkware.cachefly.net/webdocs/APPNOTE/APPNOTE-6.3.9.TXT):
  §4.3 の EOCD / ZIP64、§4.4 のディスク番号・ディスク相対位置、§4.5.3 の ZIP64 extra、
  §8 の巻名・署名・分割境界を参照した。
- [WinZip: Split Zip files and how to create them](https://kb.winzip.com/en/130395):
  `.z01`…`.zip` と `.zx01`…`.zipx` の命名を確認した。
- Info-ZIP zip 3.0 と 7zz 26.03 は実行結果だけを比較した。
  XADMaster、The Unarchiver、7-Zip、Info-ZIP、libzip のソースコードは参照・移植していない。
  新規依存関係はない。

### 支給 fixture の観察

- `zip -s 64k -r split.zip src`: `.z01`〜`.z06` は各 65,536 byte、最終巻は 901 byte。
  EOCD は this disk = 6、CD disk = 6、9 / 9 entries、CD offset = `0xa0`。
  entry の開始ディスクは `0,0,0,1,2,3,4,4,4` で、位置は各ディスク先頭からの相対値。
- `-fz` の `split64.zip`: EOCD は disk = 6、CD disk = 6、9 / 9 entries、CD size = 827、
  CD offset = `0xffffffff`。locator は record disk = 6、record offset = 1167、total disks = 7。
  ZIP64 EOCD は disk = 6、CD disk = 6、9 / 9 entries、CD size = 827、CD offset = 340。
- `big.zip`: `.z01`〜`.z99`、`.z100`〜`.z106`、`.zip` の計 107 巻。
  99 の次を 2 桁へ切り詰めない。
- `single.zip` は `PK\x07\x08`、`single-pk00.zip` は `PK00` で始まる単巻。
  EOCD disk = 0 のまま単巻として読める。
- 支給の 7zz 観察では `.zip` / `.z01` の両方から 7 巻として開け、欠番は
  `Missing volume : split.z03`、孤立した最終巻は `Missing volume : split.z01`。
  宣言数を超えた `.z08` は無視する。今回のテストでも同じ欠番拒否・余剰巻無視を確認した。

## 実装と選択した方針

| ファイル | 変更 |
| --- | --- |
| `Sources/KaitoKit/Formats/Zip/ZipEndRecords.swift` | 既存 EOCD 走査を共有 helper へ移動。最終巻の EOCD / locator だけで巻数を調べ、偽の末尾候補・コメント内署名を判別する |
| `Sources/KaitoKit/Reader/ZipSplitVolumeSet.swift` | 巻名、兄弟探索、上限、欠番、空巻を保持したディスク位置表、連結 source |
| `Sources/KaitoKit/Core/ByteSource.swift` | 追加の `openat` を伴わない anchored identity 検査、既存 fd 同士の identity 比較 |
| `Sources/KaitoKit/Formats/Zip/ZipReader.swift` | ディスク相対位置を索引作成時に絶対位置へ変換。ZIP32 / ZIP64 整合性と候補判定を連結空間で検証 |
| `Sources/KaitoKit/Reader/ArchiveReader.swift` | `.001` 優先後の ZIP 巻探索、`reopen()` の位置表保持、split ZIP の raw record |
| `Sources/KaitoKit/Formats/FormatDetector.swift` | 同じ兄弟探索、`PK00` の直接認識、別形式の連結結果の拒否 |
| `Tests/KaitoKitTests/ZipSplitVolumeTests.swift` | APPNOTE のフィールドを加工するテスト専用 splitter と境界・異常系・外部実行比較 |
| `Tests/KaitoKitTests/TestZipSupport.swift` | 既存の整数 append helper をテスト内で共有 |
| `Tests/KaitoKitCompatTests/KaitoArchiveZipConfigurationTests.swift` | `fileURL:` / `file:` で先頭巻・最終巻から内容を取得する回帰テスト |
| `README.md`、`Documentation/migration-from-xadmaster.md`、`CHANGELOG.md` | 対応範囲、移行手順、制約、bd の記録を更新 |

- **復旧**: split ZIP では `recoverLocalHeaders` を実行しない。欠番・破損 CD を部分成功として
  隠さず、offset 0 の spanning 署名を data descriptor と誤認しない。
  正常なセットは `recoverDamagedArchives = true` でも通常の CD 経路で読める。
- **空巻**: 最小巻長を強制せず、0 byte の中間巻もディスク番号と巻数上限に含める。
  連結 source が空巻を省いても、ディスク位置表は省かない。空巻へのレコード開始参照は拒否する。
  空の CD の終端位置に限りディスク末尾を許す。最終巻には EOCD が必要。
- **位置**: `Record.localHeaderOffset` 自体が連結絶対位置。ソート、非重複検証、payload 範囲、
  descriptor、ZipCrypto / AES、lazy local header が同じ位置を使う。
  source の位置加算・減算・長さ合計は `Checked` を通す。split の archive base は 0。
- **ZIP64**: locator と EOCD は最終巻。本体レコードは連結後に
  `diskStart[recordDisk] + relativeRecordOffset` から読む。本体が前巻にある場合も扱う。
  ZIP32 の非 sentinel フィールド、ZIP64、実際のディスク位置表を照合する。
- **探索**: `.zip.001` は既存バイト分割が優先。`.zNN` / `.zxNN` は同じ親の最終巻を
  `openRegularFile` で取得する。拡張子は大文字・小文字を優先順付きで試す。
  開いた番号が宣言巻数に入らない場合、別ファイルの内容を返さず開いた巻名付きエラーにする。
- **上限・identity**: 宣言巻数を得た時点で `maxVolumeCount` を検査し、番号付き兄弟の
  `openat` や最終巻の再オープンによる identity 検証より前に拒否する。
  `.zNN` から開く場合、宣言を読むための最終巻取得だけはこの検査に先行する。
  明示 symlink は `.001` と同じ単巻扱い、兄弟 symlink / 非通常ファイルは拒否する。
- **候補走査**: コメント包含判定は線形走査、候補試行回数と metadata work は上限付き。
  偽 EOCD や CD コメント内の偽 locator により、通常 ZIP / SFX の読取先を変えない。
- **公開 API**: 既存シグネチャの変更も追加もない。CLI / Compat 実装の変更も不要。
  `rawRecord(of:)` は split ZIP で連結絶対範囲を返す。`.001` バイト分割では従来どおり `nil`。
  `reopen()` はディスク位置表と全巻の fd を保持し、巻を削除した後も読める。

## テスト一覧

`ZipSplitVolumeTests` の 21 件と Compat の 1 件。正常系は単巻との内容・SHA-256 一致を確認し、
raw record、独立 reader の再開、CLI / 外部実行比較も加えた。

| テスト | 検証内容 |
| --- | --- |
| `testNamingAndHundredthVolume` | ASCII、空 stem、0、2 桁、100 以上、巨大な番号、大文字小文字 |
| `testZIP32LocalHeaderDataAndCentralDirectoryCrossBoundaries` | 3 種類の境界、`.zip` / `.z01` / `.z03`、lazy on/off、検出、削除後の reopen |
| `testZIP64ExtraDiskSentinelAndEndRecordOnEarlierDisk` | ZIP64 全幅 extra、EOCD disk sentinel、本体レコードが前巻 |
| `testAbsoluteOffsetsDetermineOrderingAcrossDisks` | ディスク相対位置の大小が実際の entry 順序と逆になる構成 |
| `test101TinySegmentsAndZIPXCaseVariants` | 実ファイル 101 巻、`.z100`、ZIPX、各大文字拡張子 |
| `testSingleSegmentSpanningMarkersRemainOrdinaryZIP` | `PK00` / `PK\x07\x08`、disk 0、範囲外の `.z01` |
| `testMissingMiddleLoneLastMissingLastAndStrayExtra` | 欠番・最終巻不在・孤立最終巻・余剰巻・明示した余剰巻の拒否 |
| `testSymlinkedSiblingRejectedAndExplicitSymlinkDoesNotDiscover` | 番号巻と最終巻の symlink、明示 symlink の単巻扱い |
| `testDeclaredVolumeLimitPrecedesSiblingOpens` | 上限 -1 / 0 / 1 / 2 / 3、宣言 `2^32 - 1`、開けない兄弟より先に拒否 |
| `testByteSplit001KeepsPrecedenceAndDataHasNoSiblingDiscovery` | `.zip.001` 優先、最終巻 Data は従来の `spanned` エラー |
| `testEmptyIntermediateSegmentsAndCheckedDiskBounds` | 空巻の保持、巻番号・巻内位置の範囲、合計 overflow |
| `testDataDescriptorCrossesBoundaryAndRawRecordWorks` | 署名あり / なしの descriptor 境界越え |
| `testZipCryptoPayloadCrossesBoundary` | Info-ZIP ZipCrypto、再開、復号した内容の一致 |
| `testRecoveryOptionDoesNotRescanSplitPrefix` | 復旧 option、破損 CD、終端なしの split source |
| `testMalformedDiskFieldsOffsetsAndNonZIPAssembly` | ZIP32 / ZIP64 のディスク・位置・宣言不一致、別形式署名 |
| `testZIP64DiskOnlyExtraAndLayoutCandidateLimitChecks` | 8 byte フィールドを持たない disk-only extra、coherent CD の上限エラー |
| `testZIP64ConsistencyMutationsAndNoSplitSFX` | ZIP32 / ZIP64 の個数・サイズ・位置・長さ・ディスク不一致、非零 base 相当のずれ |
| `testZIP64DescriptorAndAESAcrossBoundaries` | ZIP64 descriptor、7zz AES 書庫の境界越え |
| `testOptionalZIP64LocatorAndFalseLocatorInSingleSFXComment` | sentinel なしの ZIP64、単巻 SFX の CD コメントにある偽 locator |
| `testTrailingEOCDCandidatesDoNotChangeVolumeDiscovery` | 単巻・分割巻の末尾にある偽 EOCD |
| `testInfoZipSplitAndZIP64AgreeWithSevenZipAndCLI` | `zip -s 64k` / `-fz` を生成し、7zz 展開と CLI detect/list/extract/sha を比較 |
| Compat `testZipSplitURLAndPathInitializersReadBothEnds` | URL / path initializer、先頭巻 / 最終巻、一覧と内容取得 |

## 実行方法と結果

sandbox が既定のユーザーキャッシュと dSYM の生成を許さないため、キャッシュを worktree 内へ向け、
release はデバッグ情報の生成を省いた。製品コードの警告はない。テストは native build system を使用し、
Swift 6.4 自体が出す `--build-system native` 廃止予定の警告は release の警告件数に含めない。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift build -c release -debug-info-format none \
  --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" swift test --build-system native \
  --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox \
  --filter '[Zz]ipSplit'
# 全体は同じコマンドから --filter とその値を除く。
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-asan" swift test --build-system native \
  --scratch-path .build/z1-asan --cache-path .build/cache-asan --config-path .build/config-asan \
  --security-path .build/security-asan --disable-sandbox --sanitize address --filter '[Zz]ipSplit'
```

- release: `Build complete! (46.82秒)`、終了 0、`warning` を含む行は **0**。
- 追加テスト: **22 tests、0 failures、0 skipped**（ZIP 21 件、Compat 1 件）。
- ASan: **22 tests、0 failures、0 skipped**、AddressSanitizer 診断なし。
- 全体: **1,158 tests、45 tests skipped、0 failures (0 unexpected)**、368.357 秒。
  追加 22 件のスキップはなく、外部 oracle を使う Info-ZIP / 7zz の比較も実行済み。
- `git diff --check`: 成功。

公開 API は `xcrun swift-api-digester -dump-sdk` で基点と実装後の `KaitoKit` / `KaitoKitCompat` を
出力し、`-diagnose-sdk --input-paths before.json -input-paths after.json` で比較した。
Removed / Moved / Renamed / Type / Protocol 等、すべての変更欄が空。宣言ツリーも完全一致した。
JSON の差は出力先ファイル名を記録したコマンド引数だけで、公開 API の追加・削除・変更はない。

### 提供 fixture の release CLI 結果

次のすべてで `kaito detect` / `list` / `sha` が成功した。各 entry の byte 数と SHA-256 を
7zz 26.03 のディレクトリ展開と照合し、`split` / `split64` は `src/`、`big` は `big/` の元ファイルとも照合した。
単巻 2 種の `one/` 原本は支給ディレクトリにないため、7zz の展開を比較対象とした。
`total` は CLI が出力する全 entry の集約値で、個々のファイルの SHA-256 とは異なる。

| 入力 | entry 数（directory 含む） | `kaito sha` の `total` | 一致 |
| --- | ---: | --- | --- |
| `split.zip` | 9 | `6c5757fdea958d655f4b3bfa21707c0b899c880cf8979c9597a5afa90a488835` | 原本・7zz 全件 |
| `split.z01` | 9 | `6c5757fdea958d655f4b3bfa21707c0b899c880cf8979c9597a5afa90a488835` | 原本・7zz 全件 |
| `split64.zip` | 9 | `6c5757fdea958d655f4b3bfa21707c0b899c880cf8979c9597a5afa90a488835` | 原本・7zz 全件 |
| `big.zip` | 2 | `e70566e303c5ae0fce9e752005d2031528054de79c9ecaf6f4a10c22cdfb24ee` | 原本・7zz 全件 |
| `single.zip` | 2 | `d28b465dfbb45e07ba31e91cd87574c7b28eb1ce900cbd8f2e08274834d5833b` | 7zz 全件 |
| `single-pk00.zip` | 2 | `d28b465dfbb45e07ba31e91cd87574c7b28eb1ce900cbd8f2e08274834d5833b` | 7zz 全件 |

```text
$ kaito list inbox/zip-split/lone/split.zip
error: Malformed archive: ZIP split archive is missing volume split.z01
```

提供 fixture のコピーから `split.z03` を除いた場合も、Kaito は終了 1、7zz は終了 2 で拒否し、
両方の診断に `split.z03` が含まれた。

`src/` の通常ファイル 7 件は SHA-256 が以下の値と一致した。

```text
f1.txt      31f1b9227db612a07f4542a04a7ad1a688cd1a7d80a4ff32f3982bcc4e036d61
f2.txt      75bda2892aeedb02118be614d0d822c4decc178beb7e0e1c4ae8575fbbe544c0
f3.txt      70e2f1da0fc9bde47c11dbaf6694e390de20518c2a83c3540b8a67ee11ac3df5
f4.txt      8a71015a41907ac7c432f1f3cc5863c0d50b80839b8b6f509bde48e7469c8286
f5.txt      a3a876c303fcd288eb98499231e9e22294f257cb1e8a77b9b3f7981b9adb06c5
tiny.txt    8258e8dff446de1dd8c11c4de46a44b420b678d11e9824370a515907c6c82632
sub/img.bin bc1189c0761047c3064dfe2df1204eaaf02763e75ae75f21af846b02611ed77f
```

`big/blob.bin` は 7,000,000 byte、`01616654b5906f889584f30176e5f6676f955c1e843d83e93ac9702191132da0`。
`one/a.txt` は 6 byte、`5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03`。
詳細ログ・照合スクリプトはローカルの `.build/z1-verification/` に保存した。

## 残る制約

- 同名ファイルをリムーバブルメディアで順に交換する spanned と、先頭巻が `.exe` の split PKSFX は対象外。
- 全巻が同じディレクトリに必要。欠落巻の補完や split ZIP の damaged-directory recovery は行わない。
- Data / 任意の ByteSource に最終巻だけ渡しても、兄弟を探索しない。
- 既存の未対応圧縮方式・暗号方式の範囲は変更しない。
