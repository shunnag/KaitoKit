# ZIP XZ・旧 Zstandard の追加検証

実行環境: macOS 27.2（26B5086k）、Xcode 27.0（27A266a）、arm64。
macOS 26 と Intel の実機実行は含めていない。

対象は KaitoKit の ZIP method 95（XZ）と deprecated method 20（Zstandard）の読み取り、
KaitoFinder のプレビュー、既存圧縮データを保つ編集への接続。
出力形式は ZIP stored/Deflate のまま。追加予定の tar.xz/tar.bz2 writer はこの変更に含めない。

## 仕様と fixture

- [PKWARE APPNOTE 4.4.5](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) に従い、20/93 を同じ Zstandard decoder へ接続する。
- `KaitoKit/Tests/Fixtures/zip-modern/` に生成スクリプト、base64 fixture、SHA-256 manifest を保持。
  7-Zip 26.03 が XZ の通常・AES256・ZipCrypto ZIP を生成した。
  Python 3.14.7 が Zstandard 93 を生成。20 は圧縮データを変えず方式番号のみ変更した。
- Zstandard AES の容器は [WinZip AES 1.04](https://www.winzip.com/en/support/aes-encryption/) の公開仕様で生成し、
  method 93 の全復号 bytes を 7-Zip と比較した。20 は AES extra の actual method のみ変更した。
- この環境の 7-Zip と Python は method 20 の直接展開を拒否する。
  歴史的な method 20 の実書庫と独立 decoder を直接比較した、とは主張しない。
- 全通常 fixture の内容は38,400 bytes、SHA-256 は
  `16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4`。
  `KaitoFixture` は公開テスト用パスワード。第三者 codec の実装ソースは参照していない。

## 回帰と性能

- 対応前は12テストで方式20/95の未対応を再現。アプリでも XZ のプレビュー拒否を再現した。
- 辞書上限、CRC、宣言サイズ、切断、破損、次 member との境界、AES認証失敗、誤パスワードを検査。
  AES認証失敗は既存 API と同じ `wrongPassword`。XZ の全block検査を省略しない。
- 空のXZ、連結ストリーム、padding、3 byteずつの入力、37 byteずつの出力、reopen、
  `.001` と native split ZIP、ZIP64、descriptor の署名有無・32/64 bit を検査。
  local と central の方式が違う場合は、既存仕様どおり central を優先する。
- GyoshukuKit は追加時にlocal record全体を、改名・削除時に圧縮・暗号化payloadをバイト比較。
  KaitoFinder はプレビュー用出力のSHA、2ファイル同時追加、改名、削除、3段階のUndo/Redoで原本全体を比較。
- 暗号化XZの事前検査で、1,619,222 byteの書庫に66,379,725 byteの読み取りが発生した。
  復号とHMAC検査を一度だけ行う一時入力へ変更し、1,619,085 byteに減少。
  時間の閾値ではなく実読み取り量を回帰テストで制限する。
- AES XZ の圧縮入力は `min(inMemorySingleFileLimit, 4 MiB)` までメモリ保持。
  それ以上は権限0600で作成直後unlinkする既存一時ファイル処理へ送る。
  辞書・展開サイズの上限は別に維持し、AES認証後にXZの事前検査とデコードを行う。
  大きな暗号化XZの読み取りには圧縮入力分の一時ディスク領域が必要。

## 最終検証

| 検証 | 結果 |
|---|---|
| KaitoKit 全件 | 1,168件、43 skip、失敗0。互換層24件も失敗0 |
| GyoshukuKit 全件 | 194件、skip・失敗とも0 |
| KaitoFinder 全件 | 763件、3 skip、失敗0 |
| 専用アプリのUI結合 | 操作50件＋recent-history別起動4件＝54件、skip・失敗とも0 |
| 正常fixtureをASan/UBSan付きCLIで展開 | 7種類すべてSHA-256一致 |
| 圧縮payloadを含む変異入力 | 7 seedから280件、crash・hang・sanitizer所見とも0 |
| Developer ID署名Release | ビルド、deep/strict署名検証、起動成功（PID 96890） |
| 実Sparkleと最新Release成果物 | 更新あり・同版は更新なし・改変feed拒否の3条件成功 |

KaitoKitの43 skipは外部歴史的コーパス・明示実行用の大型/性能検査、
この環境のInfo-ZIPにBZip2出力がないことによる既存の除外。新しいZIPテストのskipは0。
KaitoFinderの3 skipは別プロセス用のrecent-history1件と、通常テストhostが前面になれなかったQuick Look2件。
これらは専用bundle IDのUI結合検証ですべて成功した。
新形式5 fixtureを実メニューからQuick Lookに表示し、プレビュー先の全byteも照合した。
保存パネルの伸縮・入力フォーカス、タブのキー操作・ドラッグ中の切り替え、更新設定とメニューも含む。

ログは `build/ZIPMethodsVerification/` に保持。
UIの詳細ログは `build/UIIntegrationVerification/89d6d2bd-7693-48d1-ac83-6f934db28f60/`。
起動したアプリは `build/SparkleDerivedData/Build/Products/Release/KaitoFinder.app`。
元のアプリのウインドウがWelcomeだけであることを確認し、通常終了後に最新ビルドへ切り替えた。
更新ZIPと署名付きfeedは `build/ZIPMethodsUpdateVerification/` のローカル検証専用生成物。
GitHubへの初回公開、notarization、実インストールは実行していない。

今回追加した回帰テストは KaitoKit 14件、GyoshukuKit 2件、KaitoFinder 5件。
検証した変更ファイルのSHA-256は `build/ZIPMethodsVerification/tested-source-manifest.json` に保持する。

再実行の主なコマンド:

```sh
# KaitoKit
KAITOKIT_CAB_CORPUS="$PWD/inbox/cab-corpus" STUFFIT_SLICE6_CORPUS="$PWD/inbox/stuffit-corpus" swift test
Scripts/fuzz/run-mutants.sh --count 280 --timeout 5 --password KaitoFixture --require-payload-ranges <decoded-fixture-directory>

# GyoshukuKit
swift test

# KaitoFinder
caffeinate -d xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -destination 'platform=macOS,arch=arm64' -derivedDataPath build/SparkleDerivedData test
caffeinate -d python3 Tools/verify_ui_integration.py --derived-data build/UIIntegrationDerivedData
```
