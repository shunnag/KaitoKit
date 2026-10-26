# 2026-10-26 extraction metadata / CLI / CI 修正

作業先は `<repo> = /Users/nagash/Github/KaitoKit-wt/extract` のみ。開始状態は依頼記載の
143003a（v0.16.0）。変更一覧は開始時に保存したファイルの SHA-256 / 内容との差分で確認し、
git は使っていない。commit / push / branch 作成・追加 install・外部 archive 実装 source の参照は無い。
監査の全項目ではなく、依頼の triage S1〜S7 だけを対象とした。

環境は arm64、macOS 27.2（26B118）、Apple Swift 6.4（swiftlang-6.4.0.34.1）。
依頼の macOS 26 ではない。通常の `swift build` は既定 module cache への書込みが拒否されたため、
以下の共通指定で build / test した。package / source は変更していない。

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/kaito-audit-module-cache
# 以下の各 swift build / swift test に追加
--disable-sandbox --cache-path /private/tmp/kaito-audit-swiftpm-cache \
  --config-path /private/tmp/kaito-audit-swiftpm-config \
  --security-path /private/tmp/kaito-audit-swiftpm-security
```

`<tmp>` は `/private/tmp/kaito-audit-repro`。修正前に build した debug CLI を
`/private/tmp/kaito-audit-before` に保存し、同じ入力を修正後の `.build/debug/kaito` へ渡した。
`ls` の出力は絶対パスだけを `<tmp>` に置換した。

## S1 — file の setuid / setgid

- **再現**: mode 06755 の通常 file と mode 02775 の directory を持つ tar を既定 option で展開。
  ただし本 sandbox では、書庫と無関係な直接の `chmod 6755` も成功しながら 0755 になり、
  作業ツリー内の staff 所属 file でも同じだった。setgid directory も 0775 になる。
  triage の `-rwsr-sr-x` / `drwxrwsr-x` は、この環境では独立再現できない。
- **原因**: `restoreMetadata` が archive の permissions をそのまま `fchmod` に渡す。
- **修正**: directory 以外だけ `0o6000` を落とす。sticky は維持。
  `ExtractionOptions.preserveSetUserIDBits` を既定 `false` で追加し、`true` なら従来の引数を渡す。
  directory の sticky / setgid 復元は従来どおり。`preserveMetadata = false` は opt-in より優先する。
- **回帰テスト**: `ExtractorDefaultModeTests.testDefaultStripsFileSetIDBitsAndPreservesDirectorySpecialBits` と
  `testSetIDOptInRestoresKernelPermittedModeAndRespectsPreserveMetadata`。
  mode 07755 の file は既定で 01755。directory / opt-in は直接 chmod した参照 inode と比較し、
  OS が許す特殊 bit を維持する。特殊 bit が着地しない環境では、S1 単独の修正前失敗を主張しない。

実測の `ls -ld`（修正前 → 修正後）:

```text
$ kaito-before extract <tmp>/modes.tar -o <tmp>/before
exit=0
$ ls -ld <tmp>/before/setuid-file <tmp>/before/setgid-dir
drwxrwxr-x  2 nagash  wheel  64 Jan  1  1970 <tmp>/before/setgid-dir
-rwxr-xr-x  1 nagash  wheel   7 Jan  1  1970 <tmp>/before/setuid-file
$ kaito-after extract <tmp>/modes.tar -o <tmp>/after
exit=0
$ ls -ld <tmp>/after/setuid-file <tmp>/after/setgid-dir
drwxrwxr-x  2 nagash  wheel  64 Jan  1  1970 <tmp>/after/setgid-dir
-rwxr-xr-x  1 nagash  wheel   7 Jan  1  1970 <tmp>/after/setuid-file
```

## S2 — resource fork と既存 data inode

- **再現**: 内容 `VICTIM-CONTENT`、mode 0644、mtime 1700000000 の既存 `victim` に、
  mode 06755 / mtime 0 の `victim/..namedfork/rsrc`（本文 `RSRC`）だけを展開。
  修正前は `overwriteExisting = false / true` とも mode が 0755、mtime が 0 になった。
  修正前テストも `st_mode: 33261 != 33188`、`mtime: 0 != 1700000000` で失敗した。
- **原因**: 既存 data fork の fd にも resource entry の `restoreMetadata` を適用する。
- **修正**: **この呼出しで data inode を新規作成した場合だけ復元する**規則を選んだ。
  `overwriteExisting` によらず既存 data inode には書庫の mode / mtime を適用しない。
  resource fork の本文の上書き規則は維持し、非空の既存 fork と `overwriteExisting = false` は `EEXIST`。
  resource fork 書込み自体による OS の mtime 更新は残る。元の mtime を強制的に戻す処理は加えていない。
- **回帰テスト**: `ResourceForkExtractionTests.testResourceForkDoesNotApplyArchiveMetadataToPreexistingData` は
  両 overwrite 設定で inode / mode / data 本文が不変、fork 本文が更新、書庫の mtime 0 が未適用と確認。
  `testResourceOnlyRestoresNewDataInodeMetadata` は新規 data inode の mode 0740 / mtime 0 を確認。
  既存の `testDataAndResourceOverwritePolicyAndTruncation` / `testEmptyExistingResourceForkAllowsFirstNonemptyWrite` も維持。

実測の `ls -l` と `stat`:

```text
# 修正前: data 本文は同じ14 bytes、archive の mode / mtime が適用された
$ ls -l <tmp>/before/victim
-rwxr-xr-x@ 1 nagash  wheel  14 Jan  1  1970 <tmp>/before/victim
$ stat -f '%N mode=%OLp mtime=%m' <tmp>/before/victim
<tmp>/before/victim mode=755 mtime=0
# 修正後: mode 0644 を保持、mtime は fork 書込み時の OS 時刻
$ ls -l <tmp>/after/victim
-rw-r--r--@ 1 nagash  wheel  14 Oct 26 18:58 <tmp>/after/victim
$ stat -f '%N mode=%OLp mtime=%m' <tmp>/after/victim
<tmp>/after/victim mode=644 mtime=1793008699
```

S1 / S2 の入力は Python 標準 writer を黒箱として次の値で生成した（`tarfile.USTAR_FORMAT`）。

```python
import io, tarfile
with tarfile.open("modes.tar", "w", format=tarfile.USTAR_FORMAT) as archive:
    for name, mode, kind in [("setuid-file", 0o6755, tarfile.REGTYPE),
                             ("setgid-dir", 0o2775, tarfile.DIRTYPE)]:
        entry = tarfile.TarInfo(name)
        entry.mode, entry.type, entry.mtime = mode, kind, 0
        entry.size = 7 if kind == tarfile.REGTYPE else 0
        archive.addfile(entry, io.BytesIO(b"payload") if entry.size else None)
with tarfile.open("resource.tar", "w", format=tarfile.USTAR_FORMAT) as archive:
    entry = tarfile.TarInfo("victim/..namedfork/rsrc")
    entry.mode, entry.mtime, entry.size = 0o6755, 0, 4
    archive.addfile(entry, io.BytesIO(b"RSRC"))
```

## S3 — stdin password

- **再現**: 既存の header 暗号化 fixture `Tests/Fixtures/sevenzip-edit/z_aesh.7z` に
  `secret\n` を stdin で渡す。修正前は4コマンドとも usage / exit 2。
  `testPasswordStdinDecryptsForAllCommands` と空入力の診断検査が修正前に失敗。
- **原因**: `-p` の argv 経路しか無い。
- **修正**: 共有 `PasswordArgument` で入力元・重複・併用を検査し、全引数の検査後に先頭一行だけ読む。
  LF 一つだけを除き、空白と CR は保持。空 read / 空行は明示診断と exit 2。
  env / TTY prompt は追加していない。usage、README、CLI ガイドに反映し、同じユーザーの他 process と
  shell 履歴に `-p` が見える点を記載した。
- **回帰テスト**: `CLISmokeTests` の `testUsageIncludesPasswordStdinForAllCommands`、
  `testPasswordStdinDecryptsForAllCommands`、`testPasswordStdinRejectsConflictsDuplicatesAndEmptyInput`、
  `testPasswordStdinRemovesOnlyOneLF`。4コマンドで復号し、LF 無し・二行入力・両順序の併用・重複・EOF・空行を検査。
  CR / 前後空白が勝手に除去されないことも encrypted fixture で確認。

```text
# 修正前（usage の sha 行を抜粋）
$ kaito-before sha Tests/Fixtures/sevenzip-edit/z_aesh.7z --password-stdin
  kaito sha <archive> [--sink] [--forks] [-p <password>] [--threads <N|auto>] [--input-latency <auto|low|high>]
exit=2
# 修正後（stdin は secret + LF、末尾行を抜粋）
$ kaito-after sha Tests/Fixtures/sevenzip-edit/z_aesh.7z --password-stdin
total\t8\td649cc934984fffea65c5fba541505babb4fa5d2c23888e0b042516bfcf00505\t
exit=0
# 修正後の EOF / 空行
--password-stdin: empty input
exit=2
# 修正後の secret + CRLF / 前後空白
error: The password is incorrect
exit=1
```

## S4 — bidi 制御文字

- **再現**: `safe` + U+202E + `txt.exe` を名前とする tar。修正前の `list` は U+202E の実 scalar を
  そのまま出し、`testListAndSHAEscapeBidiFormattingScalars` が list / sha とも失敗した。
- **原因**: `oneLine` の escape 対象に bidi 制御範囲が無い。
- **修正**: U+202A〜U+202E / U+2066〜U+2069 を既存 escape case に追加。design の未対応記録も更新。
- **回帰テスト**: 上記テストで9 scalar 全部の escape を list / sha に要求し、生 scalar が無いことを確認。
  既存の端末制御文字テストも維持する。

```text
# 修正前 stdout の名前欄（hex: 73616665e280ae7478742e657865）
# 修正後 stdout（タブは \t と表記）
0\t0\tfile\ttar (stored)\tplain\tsafe\u{202e}txt.exe
exit=0
```

## S5 / Q4 — digest の無い folder CRC

- **再現**: digest が無い folder でも `read` / `discard` が全 output の CRC32 を更新する。
  機能上の修正前 failing test は無く、検証先の無い計算の除去が対象。
- **原因**: 更新が無条件なのに、結果を読むのは folder digest がある終端検証だけ。
- **修正**: `verifiesFolderCRC` を init 時の digest 有無から固定し、両更新箇所を guard。
  既存の終端・全 folder 範囲・CRC 不一致検査は維持する。
- **回帰テスト**: 既存 `folderCRC: true` テストは変更しない。
  `testCorruptPayloadWithFolderDigestStillFails` は raw payload を壊し、1 / 16 threads で検出。
  `testFolderDigestDetectsCorruptionInReadAndDiscardedBytes` は EntryStream を通さず coordinator を直接読み、
  返す範囲と読み捨てる範囲の両方の破損を `.checksumMismatch(entry: -1)` で検出する。
  最初の破損回帰テストは修正前も通過した。

## S6 / Q2 — tar checksum の加算

- **再現**: 512 byte ごとに range 判定と `Checked.add` を呼ぶ。機能上の修正前 failing test は無い。
- **原因**: checksum field の8 bytesを除く固定長の和にも throwing 加算を使っていた。
- **修正**: initializer で512 bytesを precondition にし、buffer 上の `0..<148`、定数 `8 * 0x20`、
  `156..<512` の和に変更。UInt64 / Int64 の `&+` は最大 130,560 の invariant で安全。
  field accessor は変更しない。
- **回帰テスト**: `TarHardeningTests.testUnsignedAndSignedOnlyHeaderChecksumsRemainAccepted`。
  147 / 156 / 511 の境界を使い、高位 bit を持ち unsigned / signed の和が異なる同一 header について
  各 checksum の受理・detect / open・追加1 byte破損の拒否を固定。
  修正前にも通過。既存 `testSignedByteChecksumHeaderIsAcceptedByDetectorAndReader` も維持する。

## S7 — CI oracle の version 記録

- **再現**: Homebrew で入れた oracle の version が、既存 version 表示2箇所に無い。
- **原因**: OS / Xcode / Swift / architecture の出力だけで、差分検証の道具を記録していない。
- **修正**: 既存2箇所それぞれに shell 一行だけ追加。7zz は `i` の banner を stderr も含めて取得し、
  xz / brotli / zstd は `--version` の先頭行。version の固定・assert は加えない。
- **回帰テスト**: 追加行を local shell で実行し、version が4本とも出ることを確認。workflow の変更は追加2行だけ。
  CI 自体はこの作業では起動していない。

```text
7-Zip (z) 26.05 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-10-21
xz (XZ Utils) 5.8.4
brotli 1.2.1
*** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***
```

## Q4 / Q2 計測

release / `-O`、ReaderOptions(decodeThreads: 1)、再利用する4 MiB buffer、SHA 無し。
7組を before→after / after→before と交互に実行し、各 binary / 入力を一度 warm-up。
7z は1 sampleで4回、tar は2回実行し、下表は1回あたりの中央値。
同時に tar の回帰テストも動いていたため wall は参考値。user CPU は harness 自身の
`getrusage(RUSAGE_SELF).ru_utime` の差を取り、process 起動・buffer 作成を計測範囲から除く。

| 対象 | 修正前 wall | 修正後 wall | 修正前 user CPU | 修正後 user CPU |
| --- | ---: | ---: | ---: | ---: |
| Q4: 512 MiB solid Copy、2 substreams、folder digest 無し | 112.731792 ms | 83.982802 ms | 56.779500 ms | 28.690500 ms |
| Q2: 空 member 100,000件の ustar を open | 275.680771 ms | 244.643229 ms | 251.388500 ms | 224.520500 ms |

Q4 は **0.056178 s/GiB の user CPU 削減**（この Copy 条件で49.5%、wall 25.5%）。
Q2 は user CPU 26.868 ms（10.7%）、wall 31.038 ms（11.3%）の削減。
一般の圧縮 7z の全体性能や macOS 26 の値を保証する測定ではない。
単一 substream の Copy は専用経路で coordinator を通らないため、2 substreams の solid 入力を使った。

修正前の release 全 products build は dSYM 生成を sandbox に拒否された。
その時点で完成済みの `libKaitoKit.a` と module を保存した状態で harness を link。
修正後は `swift build -c release --product kaito -debug-info-format none --scratch-path .build/audit-release`
（前記共通指定付き）を使い、dSYM を要求せず成功した。
同じ harness を前者の `-lKaitoKit`、後者の `KaitoKit.o` へそれぞれ静的 link した。

```sh
# 修正前。共通 module cache 指定も適用
swiftc -O -swift-version 6 -target arm64-apple-macosx26.0 \
  -I .build/out/Products/Release -I Sources/CBzip2 \
  -L .build/out/Products/Release -lKaitoKit -lz -lbz2 perf.swift -o before-perf
# 修正後
swiftc -O -swift-version 6 -target arm64-apple-macosx26.0 \
  -I .build/audit-release/out/Products/Release -I Sources/CBzip2 \
  perf.swift .build/audit-release/out/Products/Release/KaitoKit.o -lz -lbz2 -o after-perf
before-perf read solid-copy.7z 4
before-perf open many.tar 2
# after-perf も同じ引数。以下は1回あたりに正規化した実出力
```

```text
MEDIAN read before wall=0.112731792 user=0.056779500
MEDIAN read after wall=0.083982802 user=0.028690500
MEDIAN open before wall=0.275680771 user=0.251388500
MEDIAN open after wall=0.244643229 user=0.224520500
```

harness（`perf.swift`）:

```swift
import Darwin
import Dispatch
import Foundation
import KaitoKit

func userTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
}
let mode = CommandLine.arguments[1]
let url = URL(fileURLWithPath: CommandLine.arguments[2])
let repetitions = Int(CommandLine.arguments[3])!
var bytes: UInt64 = 0
var entries = 0
var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
let cpuStart = userTime()
let start = DispatchTime.now().uptimeNanoseconds
for _ in 0..<repetitions {
    let reader = try ArchiveReader.open(url: url, options: ReaderOptions(decodeThreads: 1))
    entries += reader.entries.count
    if mode == "read" {
        for entry in reader.entries where entry.kind != .directory {
            let stream = try reader.stream(entry)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                if count == 0 { break }
                bytes += UInt64(count)
            }
        }
    }
}
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
print("wall=\(elapsed) user=\(userTime() - cpuStart) entries=\(entries) bytes=\(bytes)")
```

入力は自作。tar は `tarfile.USTAR_FORMAT` で `entry-000000.txt`〜`entry-099999.txt`、
全て size 0 / mtime 1700000000。7z は公開 header の byte 構造と既存の自作 test writer と同じ規則で、
単一 Copy folder・2本の256 MiB substream・entry CRC 有り・folder CRC 無しを構成した。
本文は `bytes(range(256))` の繰返し。pack / next header の CRC と各 entry CRC は Python zlib で計算した。

| 入力 | bytes | SHA-256 |
| --- | ---: | --- |
| many.tar | 51210240 | e1b11508bd3cd7cd7bc13294cac0099a3284a9a090c0e4b423706b0a74ae6b59 |
| solid-copy.7z | 536871040 | 22271cde3f3fed060c59b0fd5efa0dd9049be1811bc3b4cc6f7d5787b3c05f50 |

7z 入力の生成（大きな計測入力は repository に含めない）:

```python
import struct, zlib

def number(value):
    for count in range(8):
        if value < 1 << (7 + count * 7):
            return bytes([((0xff << (8-count)) & 255) | (value >> (count*8))]) + value.to_bytes(8, 'little')[:count]
    return b'\xff' + struct.pack('<Q', value)

block = bytes(range(256)) * 4096
size = 256 * 1024 * 1024
crc = 0
for _ in range(size // len(block)):
    crc = zlib.crc32(block, crc)
names = b'\x00' + 'first.bin\x00second.bin\x00'.encode('utf-16le')
header = (b'\x01\x04\x06' + number(0) + number(1) + b'\x09' + number(2*size)
          + b'\x00\x07\x0b' + number(1) + b'\x00' + number(1) + b'\x01\x00\x0c' + number(2*size)
          + b'\x00\x08\x0d' + number(2) + b'\x09' + number(size) + b'\x0a\x01'
          + struct.pack('<II', crc, crc) + b'\x00\x00\x05' + number(2)
          + b'\x11' + number(len(names)) + names + b'\x00\x00')
start = struct.pack('<QQI', 2*size, len(header), zlib.crc32(header))
with open('solid-copy.7z', 'wb') as output:
    output.write(b'7z\xbc\xaf\x27\x1c\x00\x04' + struct.pack('<I', zlib.crc32(start)) + start)
    for _ in range(2*size // len(block)):
        output.write(block)
    output.write(header)
```


## build / 回帰テスト

指定された build / 4フィルタ / 全件をすべて実行し、終了コードはすべて0。

| コマンド（共通指定付き） | KaitoKitTests | Compat | 結果 |
| --- | --- | --- | --- |
| swift build | — | — | 成功（9.15秒） |
| swift test --filter Extract | 59 / skip 5 | 1 / skip 0 | exit 0 |
| swift test --filter CLI | 46 / skip 0 | 0 | exit 0 |
| swift test --filter Tar | 142 / skip 3 | 1 / skip 0 | exit 0 |
| swift test --filter SevenZip | 202 / skip 1 | 1 / skip 0 | exit 0 |
| swift test | 1840 / skip 51 | 34 / skip 0 | exit 0 |

CLI filter の後に加えた LF / CR / 空白テストも全件実行で通過した。
依頼の本体 baseline 1828 tests / 51 skipped に対し、追加12件で1840 tests / 51 skipped。
Compat 34件を含めると合計1874件、skip 51、失敗0。

全件の実出力:

```text
Test Suite 'KaitoKitTests.xctest' passed at 2026-10-26 19:39:23.681.
	 Executed 1840 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1747.057 (1747.281) seconds
Test Suite 'All tests' passed at 2026-10-26 19:39:23.682.
	 Executed 1840 tests, with 51 tests skipped and 0 failures (0 unexpected) in 1747.057 (1747.283) seconds
Test Suite 'All tests' passed at 2026-10-26 19:39:27.341.
	 Executed 34 tests, with 0 failures (0 unexpected) in 2.621 (2.628) seconds
full exit=0
```

## 仕様との差・検証の制約

- 実行環境は指定の macOS 26 ではなく macOS 27.2 / Swift 6.4。既定 cache への書込み制約のため、
  前記の cache / SwiftPM sandbox 指定を追加した。macOS 26 の CI はここでは起動していない。
- S1 の特殊 bit の実着地は sandbox に阻まれ、直接 chmod しても落ちる。実際の before / after の
  `ls` を上に残し、triage の 06755 を独立再現したとは主張しない。テストは kernel が許す mode と比較する。
- S2 は指定された「今回 data inode を作成した場合だけ metadata 復元」を採用。
  OS による fork 書込み時の mtime 更新は保持する。既存の元 mtime を復元する別処理は追加しない。
- Q4 / Q2 は合成入力での7組の交互計測。wall は同時実行した回帰テストの影響を受ける参考値。
  修正前 release build の dSYM 制約と harness の link 方法は計測節に明記した。
- CI は既存2箇所への追加2行のみ。7zz は `--version` が error を返すため、指定例どおり `i` の banner を使った。



## 変更ファイル

開始時の内容 / SHA-256 と比較した23ファイル。`.build` と一時領域の計測生成物は除く。

```text
.github/workflows/ci.yml
CHANGELOG.md
Documentation/cli.md
Documentation/design.md
Documentation/migration-from-xadmaster.md
Documentation/verification/2026-10-26-audit-extract-fixes.md
Documentation/verification/README.md
README.md
Sources/KaitoKit/Formats/SevenZip/SevenZipFolderCoordinator.swift
Sources/KaitoKit/Formats/Tar/TarHeaderBlock.swift
Sources/KaitoKit/Reader/ExtractionOptions.swift
Sources/KaitoKit/Reader/Extractor.swift
Sources/kaito/ArgumentCursor.swift
Sources/kaito/Commands/Bench.swift
Sources/kaito/Commands/Extract.swift
Sources/kaito/Commands/List.swift
Sources/kaito/Commands/SHA.swift
Sources/kaito/main.swift
Tests/KaitoKitTests/CLI/CLISmokeTests.swift
Tests/KaitoKitTests/Core/ExtractorDefaultModeTests.swift
Tests/KaitoKitTests/Core/ResourceForkExtractionTests.swift
Tests/KaitoKitTests/SevenZip/SevenZipFolderPrefetchTests.swift
Tests/KaitoKitTests/Tar/TarHardeningTests.swift
```
