# classic StuffIt 分割セットの連結（2026-09-20）

環境: macOS 27.2 / Apple Silicon / unar・lsar 1.10.8（Homebrew、黒箱 reader。候補調査中に sub-agent が
承認なく導入したもので、利用者が残すと判断した。[候補調査の incident 記録](2026-09-20-format-candidates.md)）。

## 実装と範囲

- 実装入力は利用者所有の再構築レポート `inbox/stuffit/report/06-wrappers-and-segments.md`
  §"Classic StuffIt split files"（design.md §10 の StuffIt 出自一覧に含まれる散文）。各 part は
  100 byte header（署名 `B0 56`、part 番号（上位 byte 0）、元 file 名 1〜63 byte、type / creator /
  Finder flags / 日付、再構築後の resource fork 長 R と data fork 長 D）に続く連続した断片で、
  全 part の header を外して番号順に連結した [0, R) が resource fork、[R, R+D) が data fork。
- `StuffItSplitSet.assemble` は `ArchiveReader.open(url:)` / `FormatDetector.detect(url:)` で
  `.001` / split ZIP の後に呼ばれ、開いた file が part なら名前の中の part 番号と一致する最後の桁列を
  差し替えて（`name.sit.1` / `name.1.sit` / `name.sit.01`）同じ親から兄弟を 1 から順に開き、
  header（file 名と bytes 68〜93）が一致することを確認して連結する。2 桁の part（`disk.sit.10`）から
  1 桁の兄弟を探すときは名前だけでは綴りが決まらないので、ゼロ埋め（`disk.sit.01`）と埋めない綴り
  （`disk.sit.1`）を順に試す。file 名と bytes 68〜93 の一致は報告書が記す参照 reader の grouping 規則で、
  unar 1.10.8 も日付や Finder flags の 1 byte が違う part を同じセットに数えない（`lsar` の volume 数が
  1 になる）ことを黒箱で確認した。part 数は `maxVolumeCount`、
  兄弟は RAR と同じく symlink を追わず regular file だけを開き、明示的に開いた symlink は単独扱い。
- 連結結果は `StuffItSplitSource`（data fork を `length` / `read` に、resource fork を別 source に持つ）
  として既存の `stuffItInput` に渡り、通常の classic / StuffIt 5 / StuffIt X reader が開く。
  `reopen()` は保持した part の handle をそのまま使う。
- Data / 任意 ByteSource からは兄弟を探せないため、単独 part が R+D を覆う場合だけ開き、それ以外は
  `unsupportedMethod("StuffIt split file from Data")`。part 番号 0 は `malformed`、欠番は `truncated`、
  header 不一致は `malformed`。

## 検証

- 合成 part（CC0 corpus の `testfile.stuffit45_dlx.mac9.sit` を 2 分割、`whole.sit.N` と `whole.N.sit`）を
  `lsar` が "StuffIt in StuffIt split file" として一覧し、内容が元書庫と一致した（黒箱で header layout を確認）。
- `StuffItSplitTests` 4 件、失敗 0: MacBinary fixture から取り出した data / resource fork を resource
  fork の途中と data fork の途中で 3 分割し、3 通りの命名でどの part から開いても元の `.sit.bin` と
  同じ entry と SHA-256（**password 付き classic 書庫を、分割から復元した resource fork の MKey で
  復号**）、`reopen()`、欠番（`truncated`）、identity 不一致（`malformed`）、Data からの複数 part
  （`unsupportedMethod`）と単独 part、番号の無い名前、part 番号 0、`maxVolumeCount`、兄弟名の置換規則、
  12 part のセット（埋めない命名とゼロ埋め命名）を 12 通りの part から開いて同じ結果になること
  （埋めない 12 part セットを part 10 から開くと `truncated` になる初版の不具合を advisor の指摘で修正）。
- release CLI: `whole.sit.1` / `whole.2.sit` の `kaito sha` の総合 digest が `whole.sit` と一致。

## 残る制約

- 実際の StuffIt が書いた分割セットの標本は手元に無く、命名規則は unar が受理した 2 通り＋ゼロ埋めに
  基づく。他の命名（例: `name.sit.part1`）は番号の桁列が見つかれば同じ規則で扱うが未確認。
- 分割セットの `rawRecord(of:)` は連結後の offset を返す（`.001` と同じ扱い）。
