#!/usr/bin/env python3
"""KaitoKit と UniversalDetector 黒箱のファイル名復号正解率を測定する。

入力: kaito 実行ファイル、任意の --udet、--corpus 内の names.tsv / archives.tsv
および任意の summary.json。CF の truth 復号と文字列が一致しない名前を除外する。
出力: --out-dir（既定 .build/name-corpus）の report.md / report.json と実行ログ。
単名は文字列の scalar 完全一致、書庫は全構成員の完全一致を主指標とする。
--baseline は保存済み report.json との言語別正解率差を追加する。
--self-check は実行ファイルなしで IANA / MIME と Python codec の対応を検査する。
"""

import argparse
import codecs
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BUCKETS = ("1", "2–3", "4–7", "8+")
LABELS = {"kaito_ja": "kaito(ja)", "kaito_none": "kaito(none)", "kaito_zh": "kaito(zh)", "udet": "udet"}
CODECS = {
    "shift-jis": "cp932", "windows-31j": "cp932", "cp932": "cp932",
    "euc-kr": "cp949", "cp949": "cp949", "windows-949": "cp949", "ks-c-5601-1987": "cp949",
    "gb2312": "gb18030", "gbk": "gb18030", "gb18030": "gb18030",
    "big5": "cp950", "cp950": "cp950", "windows-950": "cp950", "big5-hkscs": "big5hkscs",
    "tis-620": "cp874", "cp874": "cp874", "windows-874": "cp874", "iso-8859-11": "cp874",
    "ibm866": "cp866", "ibm-866": "cp866", "cp866": "cp866",
    "ibm850": "cp850", "ibm-850": "cp850", "cp850": "cp850",
    "iso-8859-1": "iso8859_1", "iso-8859-2": "iso8859_2", "iso-8859-5": "iso8859_5",
    "iso-8859-15": "iso8859_15", "koi8-r": "koi8_r", "koi8-u": "koi8_u",
    "iso-8859-7": "iso8859_7",
    "x-mac-cyrillic": "mac_cyrillic", "macintosh": "mac_roman", "macroman": "mac_roman",
    "x-mac-centraleurroman": "mac_latin2", "euc-jp": "euc_jp", "iso-2022-jp": "iso2022_jp",
    "utf-8": "utf-8", "utf-16le": "utf-16-le", "utf-16be": "utf-16-be",
    "us-ascii": "ascii", "ascii": "ascii",
    **{f"windows-125{i}": f"cp125{i}" for i in range(9)},
}


def codec_for(mime):
    # 不明時の復号だけに windows-1252 を使い、encoding 名の一致には数えない。
    name = mime.strip().lower().replace("_", "-")
    try:
        return codecs.lookup(CODECS.get(name, name)).name
    except LookupError:
        return None


def decode_udet(data, mime):
    codec = "cp1252" if mime == "(nil)" else codec_for(mime)
    if codec is None:
        return None
    try:
        return data.decode(codec, errors="strict")
    except UnicodeDecodeError:
        return None


def self_check():
    for name, mapped in CODECS.items():
        expected = codecs.lookup(mapped).name
        if codec_for(name) != expected:
            raise ValueError(f"{name}: codec lookup failed via {mapped}")
    if decode_udet(bytes.fromhex("e9"), "(nil)") != "é":
        raise ValueError("(nil) fallback is not windows-1252")
    print(f"CODECS: {len(CODECS)} keys resolve through the alias table with codecs.lookup; (nil) fallback OK")


def decoded_fields(value):
    """CLI のエスケープを解除し、エスケープされていない | だけで分割する。"""
    fields = [""]
    index = 0
    simple = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "|": "|"}
    while index < len(value):
        char = value[index]
        index += 1
        if char == "|":
            fields.append("")
        elif char != "\\":
            fields[-1] += char
        else:
            if index == len(value):
                raise ValueError("CLI output: incomplete escape")
            escape = value[index]
            index += 1
            if escape in simple:
                fields[-1] += simple[escape]
            elif escape == "u":
                match = re.match(r"\{([0-9a-fA-F]+)\}", value[index:])
                if not match:
                    raise ValueError("CLI output: invalid scalar escape")
                fields[-1] += chr(int(match[1], 16))
                index += len(match[0])
            else:
                raise ValueError(f"CLI output: unknown escape {escape!r}")
    return fields


def tsv_rows(path, header):
    rows = []
    with path.open(encoding="utf-8") as source:
        for number, line in enumerate(source, 1):
            line = line.rstrip("\n")
            if not line or (number == 1 and line == header):
                continue
            fields = line.split("\t")
            if len(fields) != 5:
                raise ValueError(f"{path}:{number}: expected five fields")
            rows.append(fields)
    if len({row[0] for row in rows}) != len(rows):
        raise ValueError(f"{path}: duplicate ids")
    return rows


def keyed_output(output, ids, columns):
    records = {}
    for line in output.split("\n"):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != columns or fields[0] in records:
            raise ValueError(f"unexpected or duplicate CLI output: {line[:120]!r}")
        records[fields[0]] = fields[1:]
    if set(records) != set(ids):
        raise ValueError("CLI output ids do not match input")
    return records


def length_bucket(text):
    count = sum(ord(char) > 127 for char in text)
    if count == 0:
        raise ValueError("non-ASCII corpus row has no non-ASCII scalar")
    return "1" if count == 1 else "2–3" if count <= 3 else "4–7" if count <= 7 else "8+"


def metric():
    return {"correct": 0, "encoding_correct": 0, "members_correct": 0, "fallback_count": 0,
            "detected_counts": Counter()}


def new_group(detectors):
    return {"rows": 0, "codec_mismatch": 0, "eligible": 0, "members": 0,
            "detectors": {name: metric() for name in detectors}}


def accumulate(group, excluded, expected, truth, results):
    group["rows"] += 1
    if excluded:
        group["codec_mismatch"] += 1
        return
    group["eligible"] += 1
    group["members"] += len(expected)
    for name, (encoding, decoded, fallback) in results.items():
        m = group["detectors"][name]
        m["correct"] += decoded == expected
        m["encoding_correct"] += codec_for(encoding) is not None and codec_for(encoding) == codec_for(truth)
        m["members_correct"] += sum(a == b for a, b in zip(decoded, expected))
        m["fallback_count"] += fallback
        m["detected_counts"][encoding] += 1


def finish(group):
    for m in group["detectors"].values():
        m["accuracy"] = m["correct"] / group["eligible"] if group["eligible"] else None
        m["encoding_accuracy"] = m["encoding_correct"] / group["eligible"] if group["eligible"] else None
        m["member_accuracy"] = m["members_correct"] / group["members"] if group["members"] else None
        counts = m["detected_counts"]
        m["top_detected"] = [{"encoding": name, "count": count} for name, count in
                             sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:3]]
        m["detected_counts"] = dict(sorted(counts.items()))
    return group


def table_rows(groups, dimensions):
    return [dict(zip(dimensions, key), **finish(value)) for key, value in sorted(groups.items())]


def percentage(value):
    return "—" if value is None else f"{100 * value:.2f}%"


def markdown_table(rows, dimensions, detectors, indicator="accuracy"):
    columns = list(dimensions) + ["行数", "codec-mismatch", "分母"] + [LABELS[d] for d in detectors]
    output = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for row in rows:
        cells = [str(row[d]) for d in dimensions] + [str(row[d]) for d in ("rows", "codec_mismatch", "eligible")]
        cells.extend(percentage(row["detectors"][d][indicator]) for d in detectors)
        output.append("| " + " | ".join(cells) + " |")
    return "\n".join(output)


def confusion_table(rows, dimensions, detectors):
    columns = list(dimensions) + ["分母"] + [LABELS[d] + " 検出名: 件数" for d in detectors]
    output = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for row in rows:
        cells = [str(row[d]) for d in dimensions] + [str(row["eligible"])]
        for detector in detectors:
            top = row["detectors"][detector]["top_detected"]
            cells.append("<br>".join(f"`{item['encoding']}`: {item['count']}" for item in top) or "—")
        output.append("| " + " | ".join(cells) + " |")
    return "\n".join(output)


def baseline_comparison(report, baseline):
    result = {"baseline_split": baseline.get("corpus_split", (baseline.get("corpus_summary") or {}).get("split", "all")),
              "baseline_corpus_sha256": baseline.get("corpus_sha256"),
              "same_corpus": baseline.get("corpus_sha256") == report["corpus_sha256"]}
    for mode in ("single_by_language", "archive_by_language"):
        old = {row["lang"]: row for row in baseline[mode]}
        rows = []
        for row in report[mode]:
            prior = old.get(row["lang"], {})
            values = {}
            for detector in report["detectors"]:
                current = row["detectors"][detector]["accuracy"]
                previous = prior.get("detectors", {}).get(detector, {}).get("accuracy")
                values[detector] = {"current_accuracy": current, "baseline_accuracy": previous,
                                    "delta_pt": (current - previous) * 100 if current is not None and previous is not None else None}
            rows.append({"lang": row["lang"], "eligible": row["eligible"],
                         "baseline_eligible": prior.get("eligible"), "detectors": values})
        result[mode] = rows
    return result


def comparison_table(rows, detectors):
    columns = ["lang", "分母", "基準の分母"] + [LABELS[d] + " Δpt" for d in detectors]
    output = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for row in rows:
        cells = [row["lang"], str(row["eligible"]), str(row["baseline_eligible"]) if row["baseline_eligible"] is not None else "—"]
        for detector in detectors:
            delta = row["detectors"][detector]["delta_pt"]
            cells.append("—" if delta is None else f"{delta:+.2f}")
        output.append("| " + " | ".join(cells) + " |")
    return "\n".join(output)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def measure(args):
    started = time.perf_counter()
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    args.out_dir.mkdir(parents=True, exist_ok=True)
    runs = args.out_dir / "runs"
    runs.mkdir(exist_ok=True)
    timings = {}
    commands = {}

    def run(label, command, input_text=None):
        print(f"running {label}", file=sys.stderr, flush=True)
        start = time.perf_counter()
        result = subprocess.run([str(c) for c in command], input=input_text, encoding="utf-8", capture_output=True)
        timings[label] = time.perf_counter() - start
        commands[label] = [str(c) for c in command]
        (runs / f"{label}.stdout.tsv").write_text(result.stdout, encoding="utf-8")
        (runs / f"{label}.stderr.txt").write_text(result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"{label}: exit {result.returncode}: {result.stderr[:2000]}")
        return result.stdout

    names_path = args.corpus / "names.tsv"
    archives_path = args.corpus / "archives.tsv"
    names = tsv_rows(names_path, "id\tlang\ttruth_iana\thex\ttext")
    archives = tsv_rows(archives_path, "group\tlang\ttruth_iana\tk\thex1,hex2,...")
    if not names:
        raise ValueError("empty name corpus")
    summary_path = args.corpus / "summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.exists() else None
    hashes = {p.name: sha256(p) for p in (names_path, archives_path)}
    if summary and summary.get("files_sha256") != hashes:
        raise ValueError("corpus file hashes differ from summary.json; regenerate the corpus")

    by_encoding = defaultdict(list)
    by_bytes = defaultdict(list)
    for row in names:
        if bytes.fromhex(row[3]).isascii():
            raise ValueError(f"{row[0]}: ASCII bytes are outside the corpus scope")
        by_encoding[row[2]].append(row)
        by_bytes[(row[1], row[2], row[3])].append(row)
    mismatches = {}
    mismatch_counts = Counter()
    # 一回のプロセスで同じ正解 encoding の全行を検査する。
    with tempfile.TemporaryDirectory(prefix="cf-check-", dir=args.out_dir) as temporary:
        for encoding, rows in sorted(by_encoding.items()):
            subset = Path(temporary) / f"{encoding}.tsv"
            subset.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
            output = run(f"decode-{encoding}", [args.kaito, "detect-encoding", "--decode", encoding, subset])
            for identifier, (status, escaped) in keyed_output(output, [r[0] for r in rows], 3).items():
                decoded = decoded_fields(escaped)
                if status not in ("OK", "MISMATCH", "FAIL") or len(decoded) != 1:
                    raise ValueError("invalid --decode result")
                if status != "OK":
                    mismatches[identifier] = {"status": status, "decoded": decoded[0] if status != "FAIL" else None}
                    mismatch_counts[status] += 1
            # CLI の status と別に Python 側でも scalar の完全一致を照合する。
            checked = keyed_output(output, [r[0] for r in rows], 3)
            for row in rows:
                status, value = checked[row[0]]
                if (status == "OK") != (status != "FAIL" and decoded_fields(value)[0] == row[4]):
                    raise ValueError(f"{row[0]}: inconsistent CF equality result")

    detectors = ["kaito_ja", "kaito_none", "kaito_zh"] + (["udet"] if args.udet else [])
    single_results = {}
    archive_results = {}
    for detector, options in [("kaito_ja", ["--language", "ja"]), ("kaito_none", ["--no-language"]),
                              ("kaito_zh", ["--language", "zh"])]:
        output = run(f"names-{detector}", [args.kaito, "detect-encoding", *options, names_path])
        single_results[detector] = keyed_output(output, [r[0] for r in names], 4)
        output = run(f"archives-{detector}", [args.kaito, "detect-encoding", "--archive", *options, archives_path])
        archive_results[detector] = keyed_output(output, [r[0] for r in archives], 4)

    unknown_mimes = Counter()
    ud_names = {}
    ud_archives = {}
    if args.udet:
        output = run("names-udet", [args.udet], "".join(row[3] + "\n" for row in names))
        lines = output.rstrip("\n").split("\n")
        if len(lines) != len(names):
            raise ValueError("udet name output count mismatch")
        for row, line in zip(names, lines):
            fields = line.split("\t")
            if len(fields) != 3 or fields[0].lower() != row[3].lower():
                raise ValueError("udet name output does not match input")
            float(fields[2])
            ud_names[row[0]] = fields[1]
        output = run("archives-udet", [args.udet, "--archive"],
                     "".join("\n".join(row[4].split(",")) + "\n\n" for row in archives))
        lines = output.rstrip("\n").split("\n") if output else []
        if len(lines) != len(archives):
            raise ValueError("udet archive output count mismatch")
        for row, line in zip(archives, lines):
            fields = line.split("\t")
            if len(fields) != 2:
                raise ValueError("invalid udet archive output")
            float(fields[1])
            ud_archives[row[0]] = fields[0]
        unknown_mimes.update(mime for mime in list(ud_names.values()) + list(ud_archives.values())
                             if mime != "(nil)" and codec_for(mime) is None)

    groups = {key: defaultdict(lambda: new_group(detectors)) for key in
              ("single_by_language", "single_by_encoding", "single_by_length", "archive_by_language", "archive_by_encoding_k")}
    totals = {key: new_group(detectors) for key in ("single", "archive")}
    if summary:
        for entry in summary["encodings"]:
            groups["single_by_encoding"][(entry["lang"], entry["truth_iana"])]
            for k in (1, 2, 3, 5, 10, 30, 100):
                groups["archive_by_encoding_k"][(entry["lang"], entry["truth_iana"], k)]
    for identifier, lang, truth, hex_value, text in names:
        results = {}
        for detector, values in single_results.items():
            encoding, confidence, escaped = values[identifier]
            if not 0 <= float(confidence) <= 1:
                raise ValueError("invalid confidence")
            decoded = decoded_fields(escaped)
            if len(decoded) != 1:
                raise ValueError("unexpected field separator in a single name")
            results[detector] = (encoding, decoded, 0)
        if args.udet:
            mime = ud_names[identifier]
            results["udet"] = (mime, [decode_udet(bytes.fromhex(hex_value), mime)], 0)
        excluded = identifier in mismatches
        for group in [totals["single"], groups["single_by_language"][(lang,)],
                      groups["single_by_encoding"][(lang, truth)], groups["single_by_length"][(lang, truth, length_bucket(text))]]:
            accumulate(group, excluded, [text], truth, results)

    excluded_members = 0
    for identifier, lang, truth, k, hex_list in archives:
        data = [bytes.fromhex(h) for h in hex_list.split(",")]
        expected = []
        excluded = False
        non_ascii_count = 0
        for member in data:
            if member.isascii():
                expected.append(member.decode("ascii"))
                continue
            non_ascii_count += 1
            matching = by_bytes.get((lang, truth, member.hex()))
            if not matching:
                raise ValueError(f"{identifier}: member missing from names.tsv")
            if any(row[0] in mismatches for row in matching):
                excluded = True
                excluded_members += 1
            # 同一 bytes に複数の正解表記がある場合も、CF 不一致行として除外される。
            if len({row[4] for row in matching}) != 1 and not excluded:
                raise ValueError(f"{identifier}: ambiguous truth without codec mismatch")
            expected.append(matching[0][4])
        if non_ascii_count != int(k):
            raise ValueError(f"{identifier}: k differs from non-ASCII member count")
        results = {}
        for detector, values in archive_results.items():
            encoding, fallback, escaped = values[identifier]
            decoded = decoded_fields(escaped)
            if len(decoded) != len(data) or not 0 <= int(fallback) <= len(data):
                raise ValueError(f"{identifier}: invalid archive output")
            results[detector] = (encoding, decoded, int(fallback))
        if args.udet:
            mime = ud_archives[identifier]
            results["udet"] = (mime, [decode_udet(member, mime) for member in data], 0)
        for group in [totals["archive"], groups["archive_by_language"][(lang,)],
                      groups["archive_by_encoding_k"][(lang, truth, int(k))]]:
            accumulate(group, excluded, expected, truth, results)

    # 言語・符号化ごとに例を残す。同じ例ばかりで変換表の差が隠れないようにする。
    examples = []
    examples_per_encoding = Counter()
    for row in names:
        key = (row[1], row[2])
        if row[0] in mismatches and examples_per_encoding[key] < 3:
            examples.append(dict(zip(("id", "lang", "truth_iana", "hex", "text"), row), **mismatches[row[0]]))
            examples_per_encoding[key] += 1
    dimensions = {"single_by_language": ("lang",), "single_by_encoding": ("lang", "truth_iana"),
                  "single_by_length": ("lang", "truth_iana", "non_ascii_scalars"), "archive_by_language": ("lang",),
                  "archive_by_encoding_k": ("lang", "truth_iana", "k")}
    timings["total"] = time.perf_counter() - started
    report = {"schema_version": 2, "created_at": datetime.now(timezone.utc).isoformat(),
              "platform": platform.platform(), "python_version": platform.python_version(),
              "corpus_sha256": hashes, "corpus_summary": summary,
              "corpus_split": summary.get("split", "all") if summary else "unknown",
              "kaito_sha256": sha256(args.kaito), "udet_sha256": sha256(args.udet) if args.udet else None,
              "detector_source_sha256": sha256(ROOT / "Sources/KaitoKit/Text/EncodingDetector.swift"),
              "definitions": {"accuracy": "exact Unicode scalar sequence equality; archive requires all members correct",
                              "codec_mismatch": "CF truth decode FAIL or MISMATCH; exclude entire archive if any member mismatches",
                              "encoding_accuracy": "secondary: codec alias mapping equality; (nil) never matches an encoding name",
                              "udet_nil": "decode as windows-1252", "k": "non-ASCII members, before adding ASCII names",
                              "top_detected": "top 3 raw detector encoding names among eligible rows/groups, including correct predictions; ties sort by name",
                              "member_accuracy": "all eligible member occurrences, including mixed ASCII names"},
              "timings_seconds": timings, "commands": commands, "detectors": detectors,
              "codec_mismatch_status_counts": dict(mismatch_counts), "codec_mismatch_examples": examples,
              "archive_codec_mismatch_member_occurrences": excluded_members,
              "udet_unmapped_mimes": dict(unknown_mimes),
              "udet_nil_counts": {"single": sum(v == "(nil)" for v in ud_names.values()),
                                  "archive": sum(v == "(nil)" for v in ud_archives.values())},
              "totals": {key: finish(value) for key, value in totals.items()},
              **{key: table_rows(value, dimensions[key]) for key, value in groups.items()}}
    if baseline is not None:
        report["baseline_comparison"] = baseline_comparison(report, baseline)
    (args.out_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    md = ["# 名前エンコーディング判定の測定結果", "",
          "正解は復号後の Unicode scalar 列の完全一致。書庫の主指標は全構成員の一致。",
          "`--decode truth_iana` の FAIL / MISMATCH は codec-mismatch として全検出器の分母から除外する。",
          "書庫では不一致の構成員を一つでも含む group 全体を除外する。k は追加 ASCII 名を含まない。",
          "udet の `(nil)` は windows-1252 で復号。文字コード名の一致率は別表。",
          "長さは非 ASCII scalar 数（結合記号も 1）で、表の — は分母 0 または未測定を表す。", "",
          f"コーパス split: `{report['corpus_split']}`（summary.json による）。",
          f"単名 {len(names):,} 行、書庫 {len(archives):,} group、CF 不一致 {len(mismatches):,} 行。",
          f"実行時間（プロセス起動・入出力を含む）: {timings['total']:.3f} 秒。", ""]
    for key, title in [("single_by_language", "単名・言語別"), ("single_by_encoding", "単名・言語と符号化別"),
                       ("single_by_length", "単名・非 ASCII 文字数別"), ("archive_by_language", "書庫・言語別"),
                       ("archive_by_encoding_k", "書庫・言語と符号化と k 別")]:
        md.extend([f"## {title}", "", markdown_table(report[key], dimensions[key], detectors), ""])
    for key in ("single_by_encoding", "archive_by_encoding_k"):
        md.extend([f"## 文字コード名一致率（副次指標、{key}）", "",
                   markdown_table(report[key], dimensions[key], detectors, "encoding_accuracy"), ""])
    md.extend(["## 混同対（検出名の上位3件）", "",
               "codec-mismatch を除いた分母内の検出結果を数える。正しい検出名も含め、別名・大小文字は統合しない。", ""])
    for key, title in [("single_by_encoding", "単名"), ("archive_by_encoding_k", "書庫")]:
        md.extend([f"### {title}", "", confusion_table(report[key], dimensions[key], detectors), ""])
    if baseline is not None:
        comparison = report["baseline_comparison"]
        md.extend(["## 基準レポートとの差", "", f"基準: `{args.baseline}`、split: `{comparison['baseline_split']}`。",
                   "差は今回 − 基準の percentage points。基準にない policy や分母0は —。",
                   "コーパスの SHA-256 は" + ("同一。" if comparison["same_corpus"] else "異なるため、入力分布の変更も差に含む。"), ""])
        for key, title in [("single_by_language", "単名"), ("archive_by_language", "書庫")]:
            md.extend([f"### {title}", "", comparison_table(comparison[key], detectors), ""])
    md.extend(["## 実行時間", "", "| 実行 | 秒 |", "|---|---:|"])
    md.extend(f"| {label} | {seconds:.3f} |" for label, seconds in timings.items())
    md.extend(["", "## codec-mismatch の例", "", "```json", json.dumps(examples, ensure_ascii=False, indent=2), "```", "",
               "未対応の udet MIME: " + json.dumps(dict(unknown_mimes), ensure_ascii=False), ""])
    (args.out_dir / "report.md").write_text("\n".join(md), encoding="utf-8")
    print(f"{args.out_dir / 'report.md'} ({timings['total']:.3f}s)")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kaito", type=Path, nargs="?")
    parser.add_argument("--udet", type=Path)
    parser.add_argument("--out-dir", type=Path, default=ROOT / ".build/name-corpus")
    parser.add_argument("--corpus", type=Path, default=ROOT / ".build/name-corpus")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return
    if args.kaito is None:
        parser.error("kaito is required unless --self-check is used")
    args.kaito = args.kaito.resolve()
    if args.udet:
        args.udet = args.udet.resolve()
    measure(args)


if __name__ == "__main__":
    main()
