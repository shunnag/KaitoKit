# 7z Deflate64 coder（04 01 09）の読み取り追加（2026-09-22）

環境: macOS 27.2（26B5091g）/ Apple Silicon arm64 / Apple Swift 6.4（Swift 6 言語モード、
macOS 26 deployment target）/ `/opt/homebrew/bin/7zz` 26.03。

## 実装と範囲

- method ID `04 01 09` を `.deflate64` に登録し、一覧名を `Deflate64` とした。
  従来の `unsupportedMethod("7z method 0x040109")` に代わり、既存の
  `Deflate64Decompressor` へ packed range と folder の宣言 unpack size を渡す。
- Deflate と同様に入力 1 / 出力 1、空の properties を要求する。
  非空 properties は `malformed("7z Deflate64 has unexpected properties")`。
- entry / 累積展開量 / readAll の `ReadLimits`、folder / entry の CRC 検査を維持する。
  solid folder のサイズは単一 entry の上限と区別し、宣言出力の過不足も拒否する。
- 公開 API と decoder 本体は変更していない。

## 実装入力

公式 [DOC/Methods.txt](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt)（24.02、SHA-256
`e7eacd2230f86de6348cb9f9ca077e5de27930475068fef1d52ba9480b8cf333`）の ID `04 01 09`
（task で指定された値と既存 fixture 文書のリンク）、既存の KaitoKit 7z pipeline と
`Deflate64Decompressor`（記録済みの RFC 1951 + PKWARE APPNOTE Deflate64 拡張）、
7zz 26.03 の black-box 入出力だけを用いた。7-Zip / p7zip / libarchive / XADMaster その他の
第三者 archive 実装 source は開かず、取得・参照・流用していない。追加の tool は導入していない。

## 独立した検証データ

`Tests/Fixtures/sevenzip-deflate64/` の `generate.py` / `manifest.json` / `README.md` と
2 本の `.7z.b64`。7zz 26.03 の `a -m0=Deflate64 -ms=on` / `-ms=off` で生成した。
`first.bin` 262,403 byte、`second.bin` 1,027 byte、`empty` は既存 sevenzip-zstd と同じ原本。
`long.bin` は固定 seed の SHA-256 連鎖から得た 48,000 byte を 4 回反復した 192,000 byte。
solid 書庫には全 4 entry、non-solid 書庫には元の 3 entry を入れ、後者を指定の 2 folder に保つ。
空 entry は stream を持たず、一覧名は `Copy`。

各書庫の `7zz t` 成功、各 entry の `7zz e -so ARCHIVE ENTRY` と原本の byte 一致を確認し、
`7zz l -slt` の `Method = Deflate64` / `Solid` / `Blocks` / `Packed Size` を manifest に記録する。
時刻と header 圧縮を無効化し、packed stream は offset 32 から順に置く。
solid stream を一覧の Packed Size で切り出して `zlib.decompressobj(-15)` に渡し、
失敗または原本との不一致を生成時に assert する。通常 Deflate では扱えない距離を要求する確認である。
base64 の総量にも 400,000 byte 未満の assertion を置く。

7zz の encoder は match length を 257 までしか生成しないため、orchestrator の訂正に従い
65,538 の match length は今回の fixture 要件から除いた。decoder の長い match は既存の
ZIP method 9 テストが対象とし、この task では合成 vector を追加していない。

回帰テストは method 表、properties / arity、宣言サイズの過不足、manifest SHA-256、
一覧順・小さい buffer の stream・逆順読み・`reopen()`、各 `ReadLimits`、packed stream 内の
切り詰め（書庫 open と coder の両方）、header を保った packed byte の破損を検証する。

## 検証コマンドと出力

以下は実行出力。生成器は全出力を、テストは build 終了行と suite 集計を抜粋する。

```text
$ python3 Tests/Fixtures/sevenzip-deflate64/generate.py
deflate64-solid.7z: 7zz t / e -so OK; Method = Deflate64; Blocks = 1
raw Deflate: Error -3 while decompressing data: too many length or distance symbols
deflate64-non-solid.7z: 7zz t / e -so OK; Method = Deflate64; Blocks = 2
base64 total: 74128 bytes
{
  "writer": "7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03",
  "oracles": [
    "7zz 26.03 (test, extraction, listing)",
    "Python zlib (raw Deflate rejection)"
  ],
  "method": "04 01 09 (Methods.txt: Deflate64)",
  "entries": {
    "first.bin": {
      "size": 262403,
      "sha256": "a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9"
    },
    "second.bin": {
      "size": 1027,
      "sha256": "318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311"
    },
    "empty": {
      "size": 0,
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    },
    "long.bin": {
      "size": 192000,
      "sha256": "d948638317fa982a5d5eaac6df36a3487e6bb04b97c517890fdc1891141d9c25"
    }
  },
  "fixtures": [
    {
      "file": "deflate64-solid.7z.b64",
      "sha256": "71baa39e153362f288b77e2752d21a54a47e361af61da7a8eaff04e1870b28cf",
      "method": "Deflate64",
      "solid": true,
      "blocks": 1,
      "entries": [
        "empty",
        "first.bin",
        "long.bin",
        "second.bin"
      ],
      "packedStreams": [
        {
          "offset": 32,
          "size": 52151,
          "unpackedSize": 455430,
          "entries": [
            "first.bin",
            "long.bin",
            "second.bin"
          ],
          "rawDeflate": "Error -3 while decompressing data: too many length or distance symbols"
        }
      ],
      "arguments": [
        "a",
        "-t7z",
        "-m0=Deflate64",
        "-ms=on",
        "-mhc=off",
        "-mtm=off",
        "-mta=off",
        "-mtc=off",
        "ARCHIVE",
        "first.bin",
        "second.bin",
        "empty",
        "long.bin"
      ]
    },
    {
      "file": "deflate64-non-solid.7z.b64",
      "sha256": "cdb5c26437c928eac1ee43aa45911f21e7edbcefeaf5dc874e8819612c2d8286",
      "method": "Deflate64",
      "solid": false,
      "blocks": 2,
      "entries": [
        "empty",
        "first.bin",
        "second.bin"
      ],
      "packedStreams": [
        {
          "offset": 32,
          "size": 2067,
          "unpackedSize": 262403,
          "entries": [
            "first.bin"
          ]
        },
        {
          "offset": 2099,
          "size": 295,
          "unpackedSize": 1027,
          "entries": [
            "second.bin"
          ]
        }
      ],
      "arguments": [
        "a",
        "-t7z",
        "-m0=Deflate64",
        "-ms=off",
        "-mhc=off",
        "-mtm=off",
        "-mta=off",
        "-mtc=off",
        "ARCHIVE",
        "first.bin",
        "second.bin",
        "empty"
      ]
    }
  ]
}
```

最初の `swift build` は作業 sandbox 外の user cache に書けず、manifest の読み込みで失敗した。
製品コードの compile に到達する前の環境エラーである。出力は次のとおり。

```text
$ swift build
warning: <home>/Library/org.swift.swiftpm/configuration is not accessible or not writable, disabling user-level cache features.
warning: <home>/Library/org.swift.swiftpm/security is not accessible or not writable, disabling user-level cache features.
warning: <home>/Library/Caches/org.swift.swiftpm is not accessible or not writable, disabling user-level cache features.
error: 'kaitokit': Invalid manifest (compiled with: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-vfsoverlay", "<tmp>/TemporaryDirectory.uG1xOV/vfs.yaml", "-L", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-lPackageDescription", "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-target", "arm64-apple-macosx14.0", "-plugin-path", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-I", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-L", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", "-swift-version", "6", "-I", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI", "-sdk", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk", "-package-description-version", "6.0.0", "<repo>/Package.swift", "-o", "<tmp>/TemporaryDirectory.8g4AZf/kaitokit-manifest"])
<unknown>:0: error: error opening '<home>/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: <home>/.cache/clang/ModuleCache: Operation not permitted
<unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx14.0'
```

再実行では cache / configuration / security の保存先を書き込み可能な `/tmp` に移した。
`--disable-sandbox` は SwiftPM の子プロセス用 sandbox を無効にする指定で、外側の作業 sandbox は維持する。
以下の環境変数と追加引数を build / 3 本の test に共通で指定した。

```sh
mkdir -p /tmp/kaito-deflate64-swiftpm/cache /tmp/kaito-deflate64-swiftpm/configuration /tmp/kaito-deflate64-swiftpm/security /tmp/kaito-deflate64-swiftpm/module-cache
CLANG_MODULE_CACHE_PATH=/tmp/kaito-deflate64-swiftpm/module-cache swift build --cache-path /tmp/kaito-deflate64-swiftpm/cache --config-path /tmp/kaito-deflate64-swiftpm/configuration --security-path /tmp/kaito-deflate64-swiftpm/security --disable-sandbox
```

```text
Building for debugging...
[Planning deferred tasks]
[2 / 13] KaitoKit
[14 / 25] KaitoKit
[15 / 26] KaitoKit
[23 / 33] KaitoKit
[28 / 34] KaitoKitCompat
[36 / 38] KaitoKitDynamic-product
Build complete! (3.04秒)
```

再実行した build は警告なしで成功した。test のコマンドにも上記の追加引数を付けた。

```text
$ CLANG_MODULE_CACHE_PATH=/tmp/kaito-deflate64-swiftpm/module-cache swift test --filter SevenZipDeflate64Tests --cache-path /tmp/kaito-deflate64-swiftpm/cache --config-path /tmp/kaito-deflate64-swiftpm/configuration --security-path /tmp/kaito-deflate64-swiftpm/security --disable-sandbox
Build complete! (2.26秒)
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 18:45:22.483.
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.699 (0.700) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 18:45:22.546.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
```

```text
$ CLANG_MODULE_CACHE_PATH=/tmp/kaito-deflate64-swiftpm/module-cache swift test --filter SevenZip --cache-path /tmp/kaito-deflate64-swiftpm/cache --config-path /tmp/kaito-deflate64-swiftpm/configuration --security-path /tmp/kaito-deflate64-swiftpm/security --disable-sandbox
Build complete! (0.22秒)
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 18:46:25.776.
	 Executed 128 tests, with 0 failures (0 unexpected) in 49.670 (49.679) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 18:46:26.013.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.148 (0.148) seconds
```

```text
$ CLANG_MODULE_CACHE_PATH=/tmp/kaito-deflate64-swiftpm/module-cache swift test --filter ReleaseReviewDocumentationTests --cache-path /tmp/kaito-deflate64-swiftpm/cache --config-path /tmp/kaito-deflate64-swiftpm/configuration --security-path /tmp/kaito-deflate64-swiftpm/security --disable-sandbox
Build complete! (0.22秒)
Test Suite 'KaitoKitTests.xctest' passed at 2026-09-22 18:46:58.961.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.018 (0.018) seconds
Test Suite 'KaitoKitCompatTests.xctest' passed at 2026-09-22 18:46:59.021.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
```

全選択テストが成功した。`SevenZip` は KaitoKit 128 件と互換層 1 件、専用テストは 6 件、
文書テストは 4 件で、失敗・skip は 0。成功した build / test の出力に警告はない。

```sh
python3 - <<'EOF'
import base64,pathlib,subprocess
for p in pathlib.Path('Tests/Fixtures/sevenzip-deflate64').glob('*.7z.b64'):
    out=pathlib.Path('/tmp')/p.stem; out.write_bytes(base64.b64decode(p.read_bytes()))
    print(subprocess.run(['.build/debug/kaito','sha',str(out)],capture_output=True,text=True).stdout)
    print(subprocess.run(['.build/debug/kaito','list',str(out)],capture_output=True,text=True).stdout)
EOF
```

出力順は `deflate64-solid.7z`、`deflate64-non-solid.7z`。各組は SHA-256、一覧の順。

```text
0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	empty
1	262403	a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9	first.bin
2	192000	d948638317fa982a5d5eaac6df36a3487e6bb04b97c517890fdc1891141d9c25	long.bin
3	1027	318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311	second.bin
total	4	60c9c2c0ae26f45eef26979b47e2298a9c8b9b983e733bfca1cfb6627479dde3

0	0	file	Copy	plain	empty
1	262403	file	Deflate64	plain	first.bin
2	192000	file	Deflate64	plain	long.bin
3	1027	file	Deflate64	plain	second.bin

0	0	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855	empty
1	262403	a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9	first.bin
2	1027	318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311	second.bin
total	3	76fb545caf6b3b3d24ce961650e062f94d83b83097771c0fb96c0c1a7e83d47d

0	0	file	Copy	plain	empty
1	262403	file	Deflate64	plain	first.bin
2	1027	file	Deflate64	plain	second.bin

```
