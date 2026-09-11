# バイト分割書庫の実装・検証記録（2026-09-11）

対象 issue: `cooViewer-1h3p`（P1）。対象リポジトリは KaitoKit。
指定の `split-7z.md` を currentState / design / risks / testPlan / verification / review まで全文読み、
ユーザーが確定した方針と両レビュアーの指摘を反映した。
XADMaster / 7-Zip のソースコードは参照・移植していない。実装入力は供給された設計書、
そこに記録された公開ユーザーマニュアル・公開形式仕様・7zz 26.03 のブラックボックス観察、
KaitoKit 自身の既存コードであり、実生成・展開の比較には 7zz 実行ファイルのみを使った。

`ArchiveReader.open(url:)` と `FormatDetector.detect(url:)` が形式検出前に同じ
`SplitVolumeSet.assemble` を呼ぶ。`.001` から欠番までを一つの論理 ByteSource に連結し、
内側の形式を通常どおり処理する。SevenZipReader の変更は next header の切断エラー分類だけ。
公開 API のシグネチャと `maxVolumeCount` の既定値 128 は維持した。Swift 6 strict concurrency
でビルドし、共通型は internal のまま。追加したテスト・実装コメントは日本語。

変更ファイルと要旨は次のとおり。

| ファイル | 変更要旨 |
|---|---|
| `Sources/KaitoKit/Reader/SplitVolumeSet.swift`（新規） | 空でない stem、ASCII 数字 3 桁以上で値 1 の先頭巻、桁幅保持、`.999` → `.1000`、欠番停止、巻数上限、identity 不一致時の単独扱い、provenance |
| `Sources/KaitoKit/Core/ConcatenatedByteSource.swift`（新規） | RAR の連結処理を `SourceSegment` / `ConcatenatedByteSource` として移設。境界跨ぎ読み出しと二分探索は維持し、必須 `label` を導入 |
| `Sources/KaitoKit/Core/ByteSource.swift` | DirectoryAnchor に `openRegularFile` と `verifyFirstVolumeIdentity` を抽出。NOFOLLOW / NONBLOCK / fstat / dev-ino / 負サイズ検証を保持 |
| `Sources/KaitoKit/Reader/ArchiveReader.swift` | URL open の組み立て、単巻を含む stem の名前ヒント、RAR の実ファイル URL の保持、連結 RAR の匿名扱い、分割セットの `rawRecord` を nil に |
| `Sources/KaitoKit/Formats/FormatDetector.swift` | URL detect に同じ組み立てと stem ヒントを適用 |
| `Sources/KaitoKit/Formats/RAR/RARVolumeLocator.swift` | 共通型と helper を移設し共有呼び出しに置換。validate(first) → identity の順序と ENOENT → truncated を保持 |
| `Sources/KaitoKit/Formats/RAR/RAR4Reader.swift` | 共通型への参照変更と 2 箇所への `label: "RAR split stream"` 追加 |
| `Sources/KaitoKit/Formats/RAR/RAR5Reader.swift` | 共通型への参照変更と `label: "RAR split stream"` 追加 |
| `Sources/KaitoKit/Formats/SevenZip/SevenZipReader.swift` | 検証済み next header が EOF を超えるエラーを `truncated` に変更 |
| `Sources/KaitoKit/Core/ReadLimits.swift` | `.001` も上限対象と明記し、0 / 1 の境界を説明 |
| `Sources/KaitoKit/Model/RawEntryRecord.swift` | 分割セットでは `ArchiveReader.rawRecord` が nil になる契約を明記 |
| `Tests/KaitoKitTests/SplitVolumeTests.swift`（新規） | ツール不要 24 件、7zz 実生成 9 件の計 33 テスト |
| `Tests/KaitoKitTests/CLISmokeTests.swift` | 先頭 5 byte の 2 巻 fixture で CLI detect / list / sha と非分割版を比較する 1 テスト |
| `Tests/KaitoKitTests/RARCommonPrimitiveTests.swift` | 型名変更と 4 呼び出しへの必須 label 追加。エラー文言 assert は不変 |
| `Tests/KaitoKitTests/SevenZipHardeningTests.swift` | next header 切断の期待を `truncated` に更新 |
| `README.md` | 対応表・制約・日英説明を更新。`.zip.001` と `.z01` spanned を区別 |
| `Documentation/migration-from-xadmaster.md` | URL 経路の分割対応と制約を日英で更新し、7z 分割を非対応一覧から除去 |
| `Documentation/design.md` | Split と共有部品の provenance を追加 |
| `CHANGELOG.md` | 0.5.0 に分割対応の「追加」と切断エラー分類の「変更」を別項として日英で記録 |
| `Documentation/verification/2026-09-11-split-volumes.md`（本書、新規） | 変更一覧、レビュー反映、実出力、制約を記録 |

レビューの修正点・改善点を次のように反映した。

| 指摘 | 実装・検証 |
|---|---|
| 境界を巻サイズと誤読すると上限超過 | `[6, 7, 16, 31, 32, 33, 4096]` は先頭巻の長さとし、残り全部を .002 にした。署名跨ぎ用の 1 / 5 byte も追加 |
| 7zz の `-t7z` / `-tzip` 重複 | ZIP だけ `SevenZipTestSupport.checkedRun` の別経路で `-tzip` を一度指定 |
| 必須 label の呼び出し漏れ | RAR4 の 2 箇所、RAR5 の 1 箇所、既存 primitive テストの 4 箇所に追加。RAR 文言の既定値は設けない |
| `maxVolumeCount <= 1` の矛盾 | 名前・先頭長・anchor・identity を満たす探索可能な先頭巻で 0 以下は limitExceeded。1 以上は実在する巻数だけで判定し、次巻が無ければ成功。-1 / 0 / 1 / 2 / 3 と 1 / 2 / 3 巻の全組合せを open と detect で検査 |
| raw record が物理ファイルの誤った範囲になる | source が ConcatenatedByteSource なら nil。単巻 ZIP .001 は従来どおり範囲を返し、reopen 後も検査 |
| 単巻 .001 の名前ヒント非対称 | naming 一致時は兄弟の有無にかかわらず stem を使用。tar.gz と LZMA_Alone の単巻・複数巻を検査 |
| stem が空の `.001` | naming は nil。全角数字・混在数字・2 桁・000・002 も除外 |
| provenance の種類を区別 | 公開ユーザーマニュアル、公開 7zFormat.txt、7zz のブラックボックス観察を分け、第三者実装ソース不参照を明記 |
| RAR の検証順序・文言・負サイズ検査 | validate(first) → identity を保持。既存 primitive / volume / hardening テストを全 suite で実行 |
| `.rar.001` 内に volume フラグ | 連結済み source を RAR に渡す場合だけ sourceURL を nil とし、一覧と完結 entry を読める。分割 entry は Data と同じ unsupportedMethod。単巻 RAR .001 の identity には元の URL を使う |
| detect と open の非対称 | 同じ assemble を通し、1 / 5 byte 先頭巻と LZMA 拡張子ヒントを検査 |
| 先頭 symlink | 単独扱い。隣に FIFO を置いて兄弟を開かないことを確認し、完全な単独書庫は読め、欠けた先頭巻は truncated |
| CHANGELOG / ZIP 説明 | 「追加」と「変更」を分離し、byte split `.zip.001` 対応と `.z01` 非対応を明記 |
| fd / 性能注記 | 下記のリソース制約として記録。上限変更・compat の API 追加・続巻からの巻き戻しは行わない |

テストでは上記に加え、実ファイルの差し替え、保持済み親ディレクトリの rename・差し替え、
兄弟の symlink / FIFO / directory 拒否、空巻、stale 巻、欠番以降を開かないこと、
Data / 任意 ByteSource が兄弟を解決しないこと、全巻 unlink 後の read / reopen、
SFX prefix を含む分割書庫を検査した。チェックイン済みの `.b64` は追加・変更していない。

7zz 実生成の 9 テストは `-v40k` LZMA2、末尾・中間欠巻、stale `.005`、
`-v10k -v15k -v2m` 不揃い巻、128 巻以内の小さな `-v16b`、
`-mhe=on -ms=on -pSECRET`、solid、`-v1m` 単巻、`-tzip -v40k`。
各正常書庫で KaitoKit の出力を元 payload と比較し、`7zz x -so` の SHA-256 も照合した。

検証環境は macOS / arm64、Apple Swift 6.4 (`swiftlang-6.4.0.34.1`)、7zz 26.03。
最初の通常 `swift build 2>&1 | tail -3` は次のキャッシュ書き込みで失敗した。

```text
error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted
unable to load standard library for target 'arm64-apple-macosx14.0'
```

指示に従い `--disable-sandbox` と `/private/tmp` のパスを付けて再実行した。
実行コマンド（tee は完全なログを保存するため。pipefail で swift の終了コードを保持）:

```sh
set -o pipefail
CLANG_MODULE_CACHE_PATH=/private/tmp/kaitokit-split-validation/clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kaitokit-split-validation/swift-cache \
swift build --disable-sandbox \
  --cache-path /private/tmp/kaitokit-split-validation/cache \
  --scratch-path /private/tmp/kaitokit-split-validation/build \
  2>&1 | tee /private/tmp/kaitokit-split-build-final.log | tail -3

CLANG_MODULE_CACHE_PATH=/private/tmp/kaitokit-split-validation/clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kaitokit-split-validation/swift-cache \
KAITO_EXECUTABLE=/private/tmp/kaitokit-split-validation/build/debug/kaito \
KAITO_REQUIRE_7ZZ=1 KAITO_REQUIRE_XZ=1 \
swift test --disable-sandbox \
  --cache-path /private/tmp/kaitokit-split-validation/cache \
  --scratch-path /private/tmp/kaitokit-split-validation/build \
  2>&1 | tee /private/tmp/kaitokit-split-tests.log | tail -5
```

build の実出力（終了コード 0）:

```text
Building for debugging...
[Planning deferred tasks]
Build complete! (0.34秒)
```

test の実出力の末尾 5 行（終了コード 0）:

```text
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
◇ Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

Swift 6.4 では末尾に Swift Testing の空 suite が表示されるため、同じログ中の XCTest 集計を併記する。

```text
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-11 22:14:03.868.
    Executed 823 tests, with 37 tests skipped and 0 failures (0 unexpected) in 162.153 (162.201) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-11 22:14:04.714.
    Executed 22 tests, with 0 failures (0 unexpected) in 0.735 (0.737) seconds
```

合計 845 件（既存 811 + 新規 34）、失敗 0、skip 37。新規テストの skip は 0。
既存の任意条件による skip の内訳は ar 1、cpio 3、LHA 21、RAR4 11、ZIP 1。
ar / cpio / LHA / RAR4 は外部 corpus・oracle・関連ツール未指定等、ZIP は同梱 Info-ZIP の
BZip2 圧縮未対応による既存の skip。7zz / xz は必須化し、欠如による skip はない。

最初の対象テスト実行では新規 Split 33 件はすべて成功したが、CLI テストの既存探索 helper が
作業ディレクトリの古い `.build` の kaito を選び、3 比較が Unsupported archive format になった。
上記 `KAITO_EXECUTABLE` で今回ビルドした CLI を指定し、その 1 テストと全 suite で成功を確認した。
テスト対象の変更や期待値の緩和では解決していない。

CLI の実書庫検証は `/private/tmp/kaitokit-split-validation/manual` に新規生成した書庫で実施。
同じ source を `-t7z -m0=LZMA2 -ms=on -mtc=off -mta=off -mtm=off` で通常作成し、
もう一方には `-v40k` を付けた。`kaito list` / `kaito sha` の一致、`kaito extract` の全出力、
および `7zz x` の展開結果を比較した。結果の実出力:

```text
7zz 26.03: -t7z -m0=LZMA2 -ms=on -v40k
Volume bytes: [40960, 40960, 40960, 7312]
Concatenated == whole SHA-256: e58349eef662a6fb8e8a884556b9e143af6d189eda23efcb9d6dbc981791418c
kaito list (split == whole):
0	100000	file	LZMA2	plain	a.bin
1	30000	file	LZMA2	plain	b.bin
2	18	file	LZMA2	plain	c.txt
kaito sha (split == whole):
0	100000	d4e5ea3bcab0c76476180fe08260ccdb9fe30c8b73832f36b102002ddb6b6f1f	a.bin
1	30000	b01a206995c49f3c00a3e6a6913dfe64ac55deb87322c2ecb700d44e20e4d4eb	b.bin
2	18	2a51590f6b10690498b89986d8aaabb201569f08b523e5d5da0b7cf899ac1c39	c.txt
total	3	e1f44e7373a9633e671bbd4e6eb0e0745a13acde3915f17a44601cd55bde9ee5
kaito extract: 3/3 files match source, whole archive and 7zz x byte-for-byte
Direct .002: exit 1, error: Unsupported archive format
```

フレームワーク検証では、元の `./Scripts/build-framework.sh` は Xcode build system の
`GenerateDSYMFile` が `Operation not permitted` で失敗した。出力・キャッシュを `/private/tmp`
にし `--disable-sandbox` を付けても同じ dSYM 制限が発生した。
一時コピー `/private/tmp/kaitokit-split-validation/build-framework-validation.sh` で
SwiftPM `--build-system native` に切り替え、元スクリプトと同じ universal dylib・module・
swiftinterface の梱包と署名を実行した。リポジトリ内のスクリプトは変更していない。
一時コピーの差分はプロジェクト root の固定、出力・scratch・cache の一時パス、
module cache / TMPDIR の指定、`--disable-sandbox` / `--build-system native` の追加だけ。

```text
Built /private/tmp/kaitokit-split-validation/frameworks/KaitoKit.framework (Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1))
Architectures in the fat file: /private/tmp/kaitokit-split-validation/frameworks/KaitoKit.framework/Versions/A/KaitoKit are: x86_64 arm64
```

`codesign --verify` は成功。KaitoKit と KaitoKitCompat の両アーキテクチャの module / interface があり、
追加した internal 型・private 引数が公開 swiftinterface に現れないことを確認した。
native 方式は Swift 6.4 により deprecated 警告が出るため、通常の CI 用スクリプトは変更しない。

設計からの調整は、ユーザー確定済みの detect 対応・rawRecord の nil・RAR 匿名経路等に加え、
単巻 `.001` の名前ヒントと RAR identity 用実パスを混同しないための private `sourceVolumeURL`
引数である。公開 API と reopen の source 保持方式は変えていない。

分割探索では最大 N 巻の fd を保持する。`reopen()` は既存 source を共有し fd を増やさないが、
別々の `open(url:)` は各自で兄弟を開く。設計書に記載された cooViewer の extractor pool が
初回に加えて P 個を別 open する場合、巻 fd は最大 `(P + 1) × N` となる（P は 3〜6 程度）。
既定 128 巻と compat の既定 ReaderOptions は維持した。空巻は巻数には数えるが連結範囲から除く。
性能の改善は主張せず、新たな実書庫 benchmark は行っていない。

このセッションの書き込み可能範囲は KaitoKit と一時ディレクトリに限定されるため、
cooViewer 側の development-guide 編集、framework 置換、アプリ build / UI 受入は実施していない。
cooViewer のコード変更は不要という設計に従い、KaitoKit の URL 経路を実装・検証した。
利用側の後続受入では `.7z.001` の書庫エンジンが KaitoKit になることとページ送りを確認する。
先頭 symlink は単独扱いなので、不完全な先頭巻で fallback する場合は仕様どおり。

`bd --readonly --sandbox -C /Users/nagash/Github/cooViewer show cooViewer-1h3p --json` も
次の制限により失敗し、issue は close していない。

```text
Error: failed to open database: embeddeddolt: init schema: embeddeddolt: open db: failed to load database "cooViewer": openat LOCK: operation not permitted
```

git commit / push / checkout / restore / stash / reset は実行していない。
`git diff --check` は成功し、Sources / Tests に旧 RAR 連結型名と旧 next-header エラー文言の残存はない。
